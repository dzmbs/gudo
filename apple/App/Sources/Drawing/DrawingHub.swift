import CoreGraphics
import Foundation
import ImageIO
import os
import Synchronization
import TerminalRenderer
import UnnamedCore

/// One daemon client's drawing state, on the main actor: placements per pane, canvas panes,
/// artifact infos, open scenes, and decoded images by blob hash. Fed by the client's
/// `ArtifactListener` (one per client, docs/APPLE-FFI.md "Drawings and images").
@MainActor
final class DrawingHub {
    let client: DaemonClient
    private(set) var placements: [UInt64: [UInt64: Placement]] = [:]
    private(set) var canvases: [UInt64: UInt64] = [:]
    private(set) var infos: [UInt64: ArtifactInfo] = [:]
    /// Pane controllers by daemon pane id.
    private let panes = NSMapTable<NSNumber, PaneDrawing>.strongToWeakObjects()
    /// Open editors (overlay or canvas) by artifact.
    private var scenes: [UInt64: [WeakScene]] = [:]
    private var images: [String: Task<InlineImagePixels?, Never>] = [:]

    private static var hubs: [ObjectIdentifier: (client: Weak<DaemonClient>, hub: DrawingHub)] = [:]

    /// The hub for `client`, installing its artifact listener on first use.
    static func shared(for client: DaemonClient) -> DrawingHub {
        hubs = hubs.filter { $0.value.client.value != nil }
        if let hub = hubs[ObjectIdentifier(client)]?.hub { return hub }
        let hub = DrawingHub(client: client)
        hubs[ObjectIdentifier(client)] = (Weak(client), hub)
        client.setArtifactListener(listener: ArtifactRelay { [weak hub] event in
            Task { @MainActor in hub?.handle(event) }
        })
        return hub
    }

    private init(client: DaemonClient) {
        self.client = client
    }

    func register(_ pane: PaneDrawing) {
        panes.setObject(pane, forKey: NSNumber(value: pane.paneId))
        reloadPlacements(pane: pane.paneId)
    }

    /// The pushed placements of a pane as the client caches them (after attach / resume).
    func reloadPlacements(pane: UInt64) {
        let current = client.placements(paneId: pane)
        placements[pane] = Dictionary(current.map { ($0.placementId, $0) }, uniquingKeysWith: { $1 })
        self.pane(pane)?.placementsChanged()
    }

    func register(scene: SceneSync) {
        scenes[scene.artifactId, default: []].append(WeakScene(scene))
    }

    func unregister(scene: SceneSync) {
        scenes[scene.artifactId]?.removeAll { $0.value == nil || $0.value === scene }
    }

    private func pane(_ id: UInt64) -> PaneDrawing? { panes.object(forKey: NSNumber(value: id)) }

    /// Records a placement this client just made (before its `Placed` push arrives).
    func noteLocal(_ placement: Placement, replacing: UInt64?) {
        if let replacing { placements[placement.paneId]?[replacing] = nil }
        placements[placement.paneId, default: [:]][placement.placementId] = placement
        pane(placement.paneId)?.placementsChanged()
    }

    func noteRemoved(_ placementId: UInt64, pane: UInt64) {
        placements[pane]?[placementId] = nil
        self.pane(pane)?.placementsChanged()
    }

    // MARK: Events

    func handle(_ event: ArtifactEvent) {
        switch event {
        case .created(let info), .info(let info):
            infos[info.artifactId] = info
        case .changed(let info, _):
            infos[info.artifactId] = info
        case .deleted(_, let artifactId):
            infos[artifactId] = nil
        case .canvases(_, let list):
            let previous = Set(canvases.keys)
            canvases = Dictionary(list.map { ($0.paneId, $0.artifactId) }, uniquingKeysWith: { $1 })
            for pane in previous.union(canvases.keys) { self.pane(pane)?.canvasChanged() }
        case .placed(let placement):
            placements[placement.paneId, default: [:]][placement.placementId] = placement
            pane(placement.paneId)?.placementsChanged()
        case .unplaced(let paneId, let placementId):
            placements[paneId]?[placementId] = nil
            pane(paneId)?.placementsChanged()
        case .excalidraw(let artifactId, _, let elements, _, let files):
            for scene in scenes[artifactId] ?? [] { scene.value?.applyRemote(elements: elements, files: files) }
            for pane in panes.objectEnumerator()?.allObjects as? [PaneDrawing] ?? [] { pane.peerInk.finish(artifactId: artifactId) }
        case .ink(let ink):
            let anchorPane = infos[ink.artifactId]?.anchor?.paneId
                ?? placements.first { $0.value.values.contains { $0.artifactId == ink.artifactId } }?.key
            if let anchorPane { pane(anchorPane)?.peerInkArrived(ink, info: infos[ink.artifactId]) }
        case .synced:
            break
        }
    }

    // MARK: Images

    /// The decoded pixels of a blob, downloaded once per hash.
    func pixels(hash: String) async -> InlineImagePixels? {
        if let task = images[hash] { return await task.value }
        let client = client
        let task = Task<InlineImagePixels?, Never> {
            guard let blob = try? await client.blobDownload(hash: hash, progress: nil) else { return nil }
            return await Task.detached { Self.decode(blob.data) }.value
        }
        images[hash] = task
        let result = await task.value
        if result == nil { images[hash] = nil }
        return result
    }

    /// Seeds the cache with a PNG this device rendered (no download for its own placements).
    func seed(hash: String, png: Data) {
        guard images[hash] == nil else { return }
        images[hash] = Task.detached { Self.decode(png) }
    }

    nonisolated static func decode(_ data: Data) -> InlineImagePixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return InlineImagePixels(image: image)
    }

    /// A blob as a `data:` URL for Excalidraw's `files`.
    func dataURL(_ image: ImageRef) async -> String? {
        guard let blob = try? await client.blobDownload(hash: image.hash, progress: nil) else { return nil }
        let mime = image.media == .jpeg ? "image/jpeg" : "image/png"
        return "data:\(mime);base64,\(blob.data.base64EncodedString())"
    }
}

/// Forwards artifact pushes from the Rust runtime thread.
nonisolated final class ArtifactRelay: ArtifactListener {
    private let handler: @Sendable (ArtifactEvent) -> Void

    init(_ handler: @escaping @Sendable (ArtifactEvent) -> Void) {
        self.handler = handler
    }

    func onArtifactEvent(event: ArtifactEvent) {
        handler(event)
    }
}

final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

final class WeakScene {
    weak var value: SceneSync?
    init(_ value: SceneSync) { self.value = value }
}

/// Keeps one open editor (overlay or canvas pane) in step with the daemon's Excalidraw scene
/// (docs/DAEMON.md §7.9): loads it, puts local changes, applies remote ones and winners of lost
/// offers, and turns images added in the editor into blobs.
@MainActor
final class SceneSync {
    let artifactId: UInt64
    let sessionId: UInt64
    let hub: DrawingHub
    let web: CanvasWebView
    /// The scene's app state as stored (Excalidraw's background and grid, plus ours).
    private(set) var appState: [String: Any] = [:]
    private(set) var version: UInt64 = 0
    private var files: [ExFile] = []
    private var knownFiles: Set<String> = []
    private var chain: Task<Void, Never>?
    var readOnly = false

    init(artifactId: UInt64, sessionId: UInt64, hub: DrawingHub, web: CanvasWebView) {
        self.artifactId = artifactId
        self.sessionId = sessionId
        self.hub = hub
        self.web = web
        hub.register(scene: self)
    }

    func close() {
        hub.unregister(scene: self)
    }

    /// Fetches the scene and loads the editor with it.
    func load(mode: String, theme: String, viewport: [String: Any]?, extra: [String: Any] = [:]) async {
        var elements: [Any] = []
        var fileList: [[String: Any]] = []
        if let scene = try? await hub.client.excalidrawGet(artifactId: artifactId, since: 0) {
            version = scene.info.version
            elements = scene.elements.filter { !$0.deleted }.compactMap(Self.object)
            appState = scene.appState.flatMap { Self.object($0) as? [String: Any] } ?? [:]
            for file in scene.files {
                knownFiles.insert(file.fileId)
                if let url = await hub.dataURL(file.image) {
                    fileList.append(["id": file.fileId, "mimeType": file.image.media == .jpeg ? "image/jpeg" : "image/png", "dataURL": url])
                }
            }
        }
        var config: [String: Any] = [
            "elements": elements, "files": fileList, "mode": mode, "readOnly": readOnly, "theme": theme,
            "appState": appState.filter { ["viewBackgroundColor", "gridSize"].contains($0.key) },
        ]
        if let viewport { config["viewport"] = viewport }
        config.merge(extra) { $1 }
        web.call("load", config)
    }

    static func object(_ element: ExElement) -> Any? { object(element.json) }

    static func object(_ json: String) -> Any? {
        json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// `{type: "change"}` from the editor: puts the changed elements.
    func changed(_ message: [String: Any]) {
        guard !readOnly, let list = message["elements"] as? [[String: Any]] else { return }
        let elements = list.compactMap { object -> ExElement? in
            guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return nil }
            return try? excalidrawElement(json: json)
        }
        if let state = message["appState"] as? [String: Any] { appState.merge(state) { $1 } }
        put(elements)
    }

    /// `{type: "files"}`: images added in the editor become blobs, referenced by the next put.
    func filesAdded(_ message: [String: Any]) {
        guard !readOnly, let list = message["files"] as? [[String: Any]] else { return }
        enqueue { [self] in
            for file in list {
                guard let id = file["id"] as? String, !knownFiles.contains(id), let url = file["dataURL"] as? String,
                      let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...]))
                else { continue }
                knownFiles.insert(id)
                if let image = try? await hub.client.blobUpload(sessionId: sessionId, data: data, progress: nil) {
                    files.append(ExFile(fileId: id, image: image))
                }
            }
        }
        put([])
    }

    /// Stores extra app-state keys (e.g. the overlay's row offset) with the next put.
    func setAppState(_ values: [String: Any]) {
        appState.merge(values) { $1 }
        put([])
    }

    private func put(_ elements: [ExElement]) {
        enqueue { [self] in
            let pending = files
            files = []
            let state = (try? JSONSerialization.data(withJSONObject: appState)).flatMap { String(data: $0, encoding: .utf8) }
            do {
                let applied = try await hub.client.excalidrawPut(artifactId: artifactId, elements: elements, appState: state, files: pending)
                version = applied.version
                if !applied.rejected.isEmpty { applyRemote(elements: applied.rejected, files: []) }
            } catch {
                CanvasWebView.log.error("excalidraw put: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Runs `work` after everything queued before it (puts stay in order).
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits for every queued put.
    func settle() async {
        await chain?.value
    }

    /// Pushes and winners: reconciled into the editor without entering its undo stack.
    func applyRemote(elements: [ExElement], files: [ExFile]) {
        Task { [self] in
            var fileList: [[String: Any]] = []
            for file in files where !knownFiles.contains(file.fileId) {
                knownFiles.insert(file.fileId)
                if let url = await hub.dataURL(file.image) {
                    fileList.append(["id": file.fileId, "mimeType": file.image.media == .jpeg ? "image/jpeg" : "image/png", "dataURL": url])
                }
            }
            web.call("applyRemote", ["elements": elements.compactMap(Self.object), "files": fileList])
        }
    }
}
