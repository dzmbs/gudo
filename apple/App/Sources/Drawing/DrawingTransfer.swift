import Foundation
import HostKit
import UniformTypeIdentifiers
import UnnamedCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// PNG and the `.excalidraw` scene; a pane of this app gets this reference too, so a drop
/// places the same drawing there (same host), uploads it (another host), or hands it to the
/// agent running in that pane.
nonisolated struct DrawingDragRef: Codable, Equatable, Sendable {
    var hostId: String
    var paneId: UInt64
    var placementId: UInt64
    var artifactId: UInt64
    /// The image shown (a blob on the source host).
    var imageHash: String

    /// The private pasteboard type that carries it inside the app (Mac).
    static let typeIdentifier = "dev.unnamed.drawing-ref"
}

extension PaneDrawing {
    /// The host this pane is on.
    var hostId: String? { workspace?.hostId }

    /// What a drag of `placement` carries.
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

    /// A drawing dropped onto this pane from a pane of this app: on an agent pane it goes to
    /// the agent; otherwise it is placed here at the cursor row, with its own render (same
    /// host: the same drawing; another host: uploaded, the scene too when it has one).
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

    /// The placement's drawing's finished versions, newest first (empty when there are none or
    /// the host keeps no history).
    func history(of placement: Placement) async -> [ArtifactVersion] {
        (try? await hub.client.artifactHistory(artifactId: placement.artifactId)) ?? []
    }

    /// Brings the drawing back to `version` (a new version on top; every device follows).
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

    /// "Version 3 · current" / "Version 4 · restored 1".
    static func versionDetail(_ version: ArtifactVersion, current: Bool) -> String {
        var parts = ["Version \(version.version)"]
        if current { parts.append("shown") }
        if let from = version.restoredFrom { parts.append("restores \(from)") }
        return parts.joined(separator: " · ")
    }
}

#if os(iOS)
extension PaneDrawing {
    /// What dragging `placement` into another app offers: the PNG and, for scenes and
    /// images, the `.excalidraw` file (loaded only when the destination asks for it).
    func itemProvider(for placement: Placement) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "Drawing"
        let hub = hub
        let hash = placement.image.hash
        let artifact = placement.artifactId
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            Task { @MainActor in
                let png = await hub.png(hash: hash)
                completion(png, png == nil ? ArtifactError.NotFound(message: "the drawing's image") : nil)
            }
            return nil
        }
        provider.registerFileRepresentation(forTypeIdentifier: UTType.excalidraw.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let scene = try await hub.client.excalidrawFile(artifactId: artifact)
                    completion(try PaneDrawing.exportFile(scene, format: .excalidraw), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}
#endif
