import DrawingKit
import Foundation
import HostKit
import UniformTypeIdentifiers
import GudoCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension PaneDrawing {
    var hostId: String? { workspace?.hostId }

    func dragRef(_ placement: Placement) -> DrawingDragRef? {
        guard let hostId else { return nil }
        return DrawingDragRef(
            hostId: hostId, paneId: paneId, placementId: placement.placementId,
            artifactId: placement.artifactId, imageHash: placement.image.hash)
    }

    /// The drawing hub of another host this window shows.
    func hub(forHost hostId: String) -> DrawingHub? {
        if hostId == self.hostId { return hub }
        guard let daemon = window?.app.hosts.connection(hostId) as? DaemonConnection,
              let client = daemon.workspace.api as? DaemonClient
        else { return nil }
        return DrawingHub.shared(for: client)
    }

    /// A drawing dropped from another pane: sent to the agent on an agent pane, else placed here
    /// at the cursor row (uploaded, scene included, when it comes from another host).
    func dropped(_ ref: DrawingDragRef) {
        guard !isReadOnly, ref.paneId != paneId || ref.hostId != hostId else { return }
        guard let source = hub(forHost: ref.hostId) else {
            showToast("That drawing's host is not connected", failure: true)
            return
        }
        let sameHost = ref.hostId == hostId
        let agent = agentTarget().flatMap { $0.pane == paneId ? $0.name : nil }
        let client = hub.client
        let paneId = paneId
        Task {
            do {
                guard let png = await source.png(hash: ref.imageHash) else { throw ArtifactError.NotFound(message: "the drawing's image") }
                if let agent {
                    _ = try await client.sendToAgent(paneId: paneId, artifactId: sameHost ? ref.artifactId : nil, version: nil, png: png)
                    showToast("Sent to \(agent)")
                    CanvasWebView.log.info("drop: drawing \(ref.artifactId) sent to the agent in pane \(paneId)")
                    return
                }
                let artifact: UInt64
                if sameHost {
                    artifact = ref.artifactId
                } else if let scene = try? await source.client.excalidrawFile(artifactId: ref.artifactId) {
                    // The scene stays editable on the new host; it shows with this device's render.
                    let imported = try await client.importToPane(paneId: paneId, name: "Drawing.excalidraw", data: scene)
                    try await client.unplace(placementId: imported.placementId)
                    artifact = imported.artifactId
                } else {
                    let imported = try await client.importToPane(paneId: paneId, name: "Drawing.png", data: png)
                    hub.seed(hash: imported.image.hash, png: png)
                    hub.noteLocal(imported, replacing: nil)
                    flash(imported.placementId)
                    return
                }
                let placed = try await client.placePng(
                    request: PlaceRequest(paneId: paneId, artifactId: artifact, version: nil, anchor: nil, col: 0, cols: 0, rows: 0, replace: nil),
                    png: png)
                hub.seed(hash: placed.image.hash, png: png)
                hub.noteLocal(placed, replacing: nil)
                flash(placed.placementId)
                CanvasWebView.log.info("drop: drawing \(ref.artifactId) from \(ref.hostId, privacy: .public) placed in pane \(paneId) as \(artifact)")
            } catch {
                showToast("Could not move the drawing here: \(DrawOverlay.describe(error))", failure: true)
            }
        }
    }

    // MARK: Version history

    /// Finished versions, newest first; empty when the host keeps no history.
    func history(of placement: Placement) async -> [ArtifactVersion] {
        (try? await hub.client.artifactHistory(artifactId: placement.artifactId)) ?? []
    }

    /// Restores `version` as a new version on top.
    func restore(_ placement: Placement, to version: ArtifactVersion) {
        let client = hub.client
        Task {
            do {
                let restored = try await client.artifactRestore(artifactId: placement.artifactId, version: version.version)
                CanvasWebView.log.info("history: drawing \(placement.artifactId) v\(version.version) restored as v\(restored.version.version)")
                showToast("Restored the drawing from \(Self.when(version))")
            } catch {
                showToast("Could not restore that version: \(DrawOverlay.describe(error))", failure: true)
            }
        }
    }

    /// "5 min ago", "Yesterday, 14:02".
    static func when(_ version: ArtifactVersion) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(version.atMs) / 1000)
        if Date().timeIntervalSince(date) < 3600 * 6 { return date.formatted(.relative(presentation: .named)) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Version 3 · shown" / "Version 5 · restored from 2".
    static func versionDetail(_ version: ArtifactVersion, current: Bool) -> String {
        var parts = ["Version \(version.version)"]
        if current { parts.append("shown") }
        if let from = version.restoredFrom { parts.append("restored from \(from)") }
        return parts.joined(separator: " · ")
    }
}

#if os(iOS)
extension PaneDrawing {
    /// The PNG and the `.excalidraw` file, loaded only when the destination asks for it.
    func itemProvider(for placement: Placement) -> NSItemProvider {
        let hub = hub
        let hash = placement.image.hash
        let artifact = placement.artifactId
        return DrawingTransfer.itemProvider(
            png: { @MainActor in await hub.png(hash: hash) },
            sceneFile: { @MainActor in
                try PaneDrawing.exportFile(try await hub.client.excalidrawFile(artifactId: artifact), format: .excalidraw)
            })
    }
}
#endif
