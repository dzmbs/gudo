import CoreGraphics
import Foundation
import ImageIO
import os
import Synchronization
import TerminalRenderer
import GudoCore

/// One daemon client's drawing state: placements per pane, canvas panes, artifact infos, open
/// scenes, and decoded images by blob hash. Fed by the client's single `ArtifactListener`.
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
    /// Drawings this device just opened, whose canvas pane takes focus once it is made.
    private var focusRequests: Set<UInt64> = []
    /// Encoded images by hash, for copies, drags and drops (what the placements show).
    private var pngs: [String: Data] = [:]

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
        // The list pushed on attach can arrive before this hub's listener exists (a relaunch),
        // and is not pushed again, so read the client's cache.
        for canvas in client.canvasPanes(sessionId: pane.sessionId) where canvases[canvas.paneId] == nil {
            canvases[canvas.paneId] = canvas.artifactId
        }
    }

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

    /// The window's own focus stays where it was when the host makes a pane, so a drawing opened
    /// here asks for its canvas pane to be focused when it appears.
    func focusWhenOpened(_ artifactId: UInt64) {
        focusRequests.insert(artifactId)
    }

    func takeFocusRequest(for artifactId: UInt64) -> Bool {
        focusRequests.remove(artifactId) != nil
    }

    /// Records a placement this client just made, before its `Placed` push arrives.
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
        case .excalidraw(let artifactId, _, let elements, let appState, let files):
            for scene in scenes[artifactId] ?? [] {
                if let appState { scene.value?.applyRemote(appState: appState) }
                scene.value?.applyRemote(elements: elements, files: files)
            }
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
        let task = Task<InlineImagePixels?, Never> { [weak self] in
            guard let data = await self?.png(hash: hash) else { return nil }
            return await Task.detached { Self.decode(data) }.value
        }
        images[hash] = task
        let result = await task.value
        if result == nil { images[hash] = nil }
        return result
    }

    /// Seeds the cache with a PNG this device rendered, so its own placements need no download.
    func seed(hash: String, png: Data) {
        pngs[hash] = png
        guard images[hash] == nil else { return }
        images[hash] = Task.detached { Self.decode(png) }
    }

    /// A blob's bytes, downloaded once per hash.
    func png(hash: String) async -> Data? {
        if let data = pngs[hash] { return data }
        guard let blob = try? await client.blobDownload(hash: hash, progress: nil) else { return nil }
        pngs[hash] = blob.data
        return blob.data
    }

    /// Drag sources must answer at once, so this never downloads.
    func cachedPNG(hash: String) -> Data? { pngs[hash] }

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

/// Keeps one open editor (overlay or canvas pane) in step with the daemon's Excalidraw scene:
/// puts local changes, applies remote ones and winners of lost offers, and turns images added in
/// the editor into blobs.
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
    /// The scene's live elements' types by id, as this editor knows them.
    private(set) var liveElements: [String: String] = [:]
    var onElementsChanged: (() -> Void)?
    /// Another device changed the app state (a rename moves the drawing's file).
    var onAppStateChanged: (() -> Void)?

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
        var options: [String: Any] = [
            "elements": elements, "files": fileList, "mode": mode, "readOnly": readOnly, "theme": theme,
            "appState": appState.filter { ["viewBackgroundColor", "gridSize"].contains($0.key) },
        ]
        if let viewport { options["viewport"] = viewport }
        options.merge(extra) { $1 }
        web.call("load", options)
        trackLiveElements(elements)
    }

    private func trackLiveElements(_ elements: [Any]) {
        guard !elements.isEmpty else { return }
        for case let element as [String: Any] in elements {
            guard let id = element["id"] as? String else { continue }
            liveElements[id] = (element["isDeleted"] as? Bool ?? false) ? nil : element["type"] as? String ?? "?"
        }
        onElementsChanged?()
    }

    /// "rectangle:1" per element type, sorted; the editor's accessibility value.
    var elementSummary: String {
        Dictionary(grouping: liveElements.values, by: { $0 }).map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: " ")
    }

    static func object(_ element: ExElement) -> Any? { object(element.json) }

    static func object(_ json: String) -> Any? {
        json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    func changed(_ message: [String: Any]) {
        guard !readOnly, let list = message["elements"] as? [[String: Any]] else { return }
        let elements = list.compactMap { object -> ExElement? in
            guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return nil }
            return try? excalidrawElement(json: json)
        }
        if let state = message["appState"] as? [String: Any] { appState.merge(state) { $1 } }
        trackLiveElements(list)
        put(elements)
    }

    /// Images added in the editor become blobs, referenced by the next put.
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

    /// Runs `work` after everything queued before it, so puts stay in order.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func settle() async {
        await chain?.value
    }

    func applyRemote(appState json: String) {
        guard let state = Self.object(json) as? [String: Any] else { return }
        appState.merge(state) { $1 }
        onAppStateChanged?()
    }

    /// Reconciles pushes and winners into the editor without entering its undo stack.
    func applyRemote(elements: [ExElement], files: [ExFile]) {
        Task { [self] in
            var fileList: [[String: Any]] = []
            for file in files where !knownFiles.contains(file.fileId) {
                knownFiles.insert(file.fileId)
                if let url = await hub.dataURL(file.image) {
                    fileList.append(["id": file.fileId, "mimeType": file.image.media == .jpeg ? "image/jpeg" : "image/png", "dataURL": url])
                }
            }
            let objects = elements.compactMap(Self.object)
            web.call("applyRemote", ["elements": objects, "files": fileList])
            trackLiveElements(objects)
        }
    }
}
