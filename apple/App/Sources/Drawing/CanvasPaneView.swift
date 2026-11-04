import DesignSystem
import DrawingKit
import Foundation
import HostKit
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer
import GudoCore
#if os(iOS)
import PencilKit
import UIKit
#else
import AppKit
#endif

/// A canvas pane: the full Excalidraw editor in a split leaf or a floating window, synced live
/// with every device through the daemon. It covers the pane's empty terminal view; viewers get
/// it read-only.
@MainActor
final class CanvasPaneView {
    let artifactId: UInt64
    let editor: CanvasEditor
    var view: OverlayContainer { editor.view }

    init(drawing: PaneDrawing, artifactId: UInt64) {
        self.artifactId = artifactId
        let paneId = drawing.paneId
        editor = CanvasEditor(artifactId: artifactId, context: CanvasEditor.Context(
            hub: drawing.hub, sessionId: drawing.sessionId, readOnly: drawing.isReadOnly, dark: drawing.isDarkTheme,
            background: drawing.pane?.view.surface.appearance.background ?? TerminalAppearance.fromPreferences().background,
            files: { [weak drawing] in (drawing?.workspace?.host as? DaemonConnection)?.workspace.api },
            destinations: { [weak drawing] in
                guard let drawing, let window = drawing.window else { return [] }
                let tab = drawing.workspace?.session.tab(containing: PaneId(paneId))?.root.panes.map(\.rawValue) ?? []
                return AgentDestination.all(in: window, hostId: drawing.workspace?.hostId, target: nil, tabPanes: Set(tab))
            },
            window: { [weak drawing] in drawing?.window }))
        editor.onFocus = { [weak drawing] in
            guard let drawing, let workspace = drawing.workspace else { return }
            let pane = PaneId(drawing.paneId)
            if workspace.focusedPane != pane { workspace.apply(.focus(pane)) }
        }
        editor.onFileChanged = { [weak drawing] path in
            guard let drawing else { return }
            drawing.workspace?.canvasTitles[PaneId(drawing.paneId)] = path.map(DrawingFile.title(ofPath:)) ?? DrawingFile.untitled
        }
        #if os(iOS)
        view.accessibilityIdentifier = "drawing.canvas"
        #else
        view.setAccessibilityIdentifier("drawing.canvas")
        #endif
    }

    func start() { editor.start() }

    func follow(dark: Bool, background: RGB) { editor.follow(dark: dark, background: background) }

    var ownsKeyboard: Bool { editor.ownsKeyboard }

    func takeKeyboard() { editor.takeKeyboard() }

    /// Debug: calls a bridge function once the editor is up.
    func call(_ function: String, _ argument: Any) { editor.call(function, argument) }

    func close() { editor.close() }
}

/// The Excalidraw editor with the app's glass chrome (Send, Copy, Rename), shown in a canvas
/// pane or full screen on iPhone. A drawing made with New Drawing also saves to its
/// `.excalidraw` file on the host. On iPad the Pencil inks through PencilKit (pressure, tilt,
/// prediction, hover) while fingers select, pan and zoom.
@MainActor
final class CanvasEditor: NSObject {
    struct Context {
        let hub: DrawingHub
        let sessionId: UInt64
        let readOnly: Bool
        let dark: Bool
        let background: RGB
        let files: () -> (any DaemonWorkspaceAPI)?
        let destinations: () -> [AgentDestination]
        let window: () -> WindowModel?
    }

    let artifactId: UInt64?
    let view = OverlayContainer()
    var onFocus: (() -> Void)?
    /// The drawing's file on the host, once known and after each rename (here or elsewhere).
    var onFileChanged: ((String?) -> Void)?
    /// Set when the editor is presented on its own (iPhone), for its Done button.
    var onDone: (() -> Void)? {
        didSet { chrome.showsDone = onDone != nil }
    }

    private let context: Context
    private var dark: Bool
    private var background: RGB
    private let web = CanvasWebView()
    private var sync: SceneSync?
    private let chrome = CanvasChromeModel()
    private var saver: DrawingFileSaver?
    private var destinationsTimer: Timer?
    private var closed = false
    #if os(iOS)
    private var ink: InkCanvasController?
    private var geometry: OverlayGeometry?
    private var editorTool = "selection"
    private var pencilSwitch = PencilToolSwitch()
    private var penMode = false
    private var chromeHost: UIHostingController<ThemedRoot<CanvasChrome>>?
    #else
    private var chromeHost: NSHostingView<ThemedRoot<CanvasChrome>>?
    #endif

    init(artifactId: UInt64, context: Context) {
        self.artifactId = artifactId
        self.context = context
        dark = context.dark
        background = context.background
        super.init()
        #if os(iOS)
        web.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.wantsLayer = true
        web.webView.autoresizingMask = [.width, .height]
        #endif
        paintBackground()
        web.webView.frame = view.bounds
        view.addSubview(web.webView)
        let focus = FocusOnTouch()
        focus.onTouch = { [weak self] in self?.onFocus?() }
        view.addGestureRecognizer(focus)
        web.onMessage = { [weak self] in self?.message($0) }

        #if os(iOS)
        if !context.readOnly {
            let ink = InkCanvasController(host: self)
            ink.canvas.frame = view.bounds
            view.addSubview(ink.canvas)
            ink.setTool(.select)
            self.ink = ink
            view.addInteraction(UIPencilInteraction(delegate: self))
        }
        #endif

        chrome.readOnly = context.readOnly
        chrome.onSend = { [weak self] in self?.send(to: $0) }
        chrome.onCopy = { [weak self] in self?.copy() }
        chrome.onRename = { [weak self] in self?.askForName() }
        chrome.onDone = { [weak self] in self?.onDone?() }
        #if os(iOS)
        let host = UIHostingController(rootView: ThemedRoot { CanvasChrome(model: chrome) })
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        view.addSubview(host.view)
        pinChrome(host.view)
        chromeHost = host
        #else
        let host = NSHostingView(rootView: ThemedRoot { CanvasChrome(model: chrome) })
        view.addSubview(host)
        chromeHost = host
        #endif
        applyChromeAppearance()
        view.onLayout = { [weak self] in self?.layout() }
    }

    /// The terminal theme changed: the editor, its chrome and what Send and Copy export follow.
    func follow(dark: Bool, background: RGB) {
        guard dark != self.dark || background != self.background else { return }
        let themeChanged = dark != self.dark
        self.dark = dark
        self.background = background
        paintBackground()
        applyChromeAppearance()
        if themeChanged { web.call("setTheme", ["theme": dark ? "dark" : "light"]) }
    }

    private func paintBackground() {
        let red = CGFloat(background.r) / 255, green = CGFloat(background.g) / 255, blue = CGFloat(background.b) / 255
        #if os(iOS)
        view.backgroundColor = UIColor(red: red, green: green, blue: blue, alpha: 1)
        #else
        view.layer?.backgroundColor = CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    private func applyChromeAppearance() {
        #if os(iOS)
        chromeHost?.overrideUserInterfaceStyle = dark ? .dark : .light
        #else
        chromeHost?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        #endif
    }

    func start() {
        guard let artifactId else { return }
        let sync = SceneSync(artifactId: artifactId, sessionId: context.sessionId, hub: context.hub, web: web)
        sync.readOnly = context.readOnly
        // What the scene holds ("rectangle:1"), for UI tests and VoiceOver.
        let view = view
        sync.onElementsChanged = { [weak sync] in
            let summary = sync?.elementSummary ?? ""
            #if os(iOS)
            view.accessibilityValue = summary
            #else
            view.setAccessibilityValue(summary)
            #endif
        }
        self.sync = sync
        refreshDestinations()
        destinationsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDestinations() }
        }
        sync.onAppStateChanged = { [weak self, weak sync] in
            guard let self, let sync else { return }
            followFile(sync.appState[DrawingFile.pathKey] as? String)
        }
        let theme = dark ? "dark" : "light"
        Task {
            await sync.load(mode: "canvas", theme: theme, viewport: nil)
            guard !closed else { return }
            followFile(sync.appState[DrawingFile.pathKey] as? String)
        }
    }

    private func followFile(_ path: String?) {
        guard let artifactId, let path, !path.isEmpty else {
            onFileChanged?(nil)
            return
        }
        if let saver {
            guard saver.path != path else { return }
            saver.follow(path)
        } else {
            saver = DrawingFileSaver(path: path, artifactId: artifactId, client: context.hub.client, files: context.files)
        }
        chrome.fileName = (path as NSString).lastPathComponent
        view.setNeedsLayoutSoon()
        onFileChanged?(path)
    }

    var ownsKeyboard: Bool { web.webView.ownsKeyboard }

    /// Takes the keyboard from the terminal behind, so its software keyboard and key bar go
    /// away while hardware keys reach the editor and the app's shortcuts.
    func takeKeyboard() {
        guard !closed else { return }
        web.webView.claimKeyboard()
    }

    func call(_ function: String, _ argument: Any) {
        web.call(function, argument)
    }

    func close() {
        guard !closed else { return }
        closed = true
        destinationsTimer?.invalidate()
        saver?.flush()
        sync?.close()
        web.tearDown()
        #if os(iOS)
        ink?.tearDown()
        #endif
        view.removeFromSuperview()
    }

    private func refreshDestinations() {
        let list = context.destinations()
        if chrome.destinations != list { chrome.destinations = list }
    }

    /// The page leaves this band at the top for the chrome (index.html).
    private static let band: CGFloat = 56

    #if os(iOS)
    /// Constraints rather than frames: the chrome's size follows its content (the name, Done, the
    /// compact labels) once SwiftUI applies it, which is after the layout pass that changed it.
    private func pinChrome(_ chromeView: UIView) {
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.setContentHuggingPriority(.required, for: .horizontal)
        chromeView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            chromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            chromeView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            chromeView.centerYAnchor.constraint(equalTo: view.topAnchor, constant: Self.band / 2),
        ])
    }
    #endif

    private func layout() {
        let bounds = view.bounds
        let compact = bounds.width < 560
        if chrome.compact != compact { chrome.compact = compact }
        #if os(iOS)
        ink?.canvas.frame = bounds
        #else
        guard let chromeHost else { return }
        let size = chromeHost.fittingSize
        chromeHost.frame = CGRect(
            x: bounds.width - size.width - 8, y: max(4, (Self.band - size.height) / 2), width: size.width, height: size.height)
        #endif
    }

    // MARK: Editor messages

    private func message(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "change":
            sync?.changed(body)
            saver?.changed()
        case "files":
            sync?.filesAdded(body)
            saver?.changed()
        case "loaded":
            #if os(iOS)
            ink?.pageLoaded()
            #endif
        case "inkApplied":
            #if os(iOS)
            ink?.applied(ids: body["ids"] as? [String] ?? [])
            #endif
        case "viewport":
            #if os(iOS)
            guard let scrollX = body["scrollX"] as? Double, let scrollY = body["scrollY"] as? Double,
                  let zoom = body["zoom"] as? Double, zoom > 0 else { return }
            let offsetLeft = body["offsetLeft"] as? Double ?? 0
            let offsetTop = body["offsetTop"] as? Double ?? 0
            geometry = OverlayGeometry(
                cell: CGSize(width: OverlayGeometry.pxPerColumn * zoom, height: OverlayGeometry.pxPerRow * zoom),
                origin: CGPoint(x: offsetLeft + scrollX * zoom, y: offsetTop + scrollY * zoom))
            ink?.convertNew()
            #endif
        case "tool":
            #if os(iOS)
            guard let type = body["tool"] as? String else { return }
            editorTool = type
            ink?.setTool(DrawRouting.canvasPencilInks(editorTool: type) ? .select : .rectangle)
            #endif
        default:
            break
        }
    }

    // MARK: Send, copy, rename

    /// The selection, or the whole drawing when nothing is selected, as the canvas shows it: in
    /// the theme, on the pane's background.
    private func image() async -> Data? {
        web.call("flushNow")
        await sync?.settle()
        guard await web.value("canvas.bounds()") is [String: Any] else { return nil }
        return await web.export(scale: 2, bounds: nil, background: true, backgroundColor: background, selectionOnly: true)?.data
    }

    private func send(to destination: AgentDestination) {
        guard !chrome.busy else { return }
        chrome.busy = true
        Task {
            defer { chrome.busy = false }
            guard let png = await image() else {
                return toast("Draw something to send first", failure: true)
            }
            do {
                try await AgentDestination.send(png, artifactId: artifactId, to: destination, hub: context.hub, window: context.window())
                toast("Sent to \(destination.agent.title)")
            } catch {
                toast("\(destination.agent.title) did not get it: \(DrawOverlay.describe(error))", failure: true)
            }
        }
    }

    private func copy() {
        Task {
            guard let png = await image() else { return toast("Nothing to copy yet", failure: true) }
            let scene = try? await artifactId.asyncMap { try await context.hub.client.excalidrawFile(artifactId: $0) }
            PaneDrawing.copy(png: png, scene: scene.map(DrawingFile.contents(fromExport:)))
            toast("Image copied", systemImage: "doc.on.doc")
        }
    }

    private func toast(_ message: String, failure: Bool = false, systemImage: String = "paperplane.fill") {
        (context.window() ?? ActiveWindow.model)?.toasts.show(Toast(
            message, systemImage: failure ? "exclamationmark.triangle.fill" : systemImage, style: failure ? .failure : .success))
    }

    private func askForName() {
        guard let saver else { return }
        let current = ((saver.path as NSString).lastPathComponent as NSString).deletingPathExtension
        #if os(iOS)
        guard var presenter = view.window?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        let alert = UIAlertController(title: "Rename Drawing", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            self?.rename(to: alert?.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
        #else
        let alert = NSAlert()
        alert.messageText = "Rename Drawing"
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.rename(to: field.stringValue) }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
        #endif
    }

    private func rename(to typed: String) {
        guard let saver, let name = DrawingFile.renamed(typed) else { return }
        Task {
            do {
                let path = try await saver.rename(to: name)
                sync?.setAppState([DrawingFile.pathKey: path])
                chrome.fileName = name
                view.setNeedsLayoutSoon()
                onFileChanged?(path)
            } catch {
                toast("Could not rename the drawing: \(ScreenError.describe(error))", failure: true)
            }
        }
    }
}

#if os(iOS)
extension CanvasEditor: InkHost {
    var currentGeometry: OverlayGeometry? { geometry }
    var client: DaemonClient { context.hub.client }

    func addInk(_ elements: [[String: Any]]) {
        web.call("addElements", ["elements": elements])
    }

    /// A Pencil stroke landed: from now on fingers pan and zoom instead of drawing.
    func markEdited() {
        guard !penMode else { return }
        penMode = true
        web.call("setPenMode", ["enabled": true])
    }
}

extension CanvasEditor: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        respondToPencil(PencilPreference(UIPencilInteraction.preferredTapAction))
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        respondToPencil(PencilPreference(UIPencilInteraction.preferredSqueezeAction))
    }

    private func respondToPencil(_ preference: PencilPreference) {
        let current = DrawTool(excalidrawType: editorTool) ?? .select
        guard let tool = pencilSwitch.respond(to: preference, current: current) else { return }
        web.call("setTool", ["type": tool.excalidrawType])
    }
}
#endif

/// Writes a standalone drawing back to its `.excalidraw` file a moment after each change made
/// on this device, so every device editing it keeps the file current.
@MainActor
final class DrawingFileSaver {
    private(set) var path: String
    private let artifactId: UInt64
    private let client: DaemonClient
    private let files: () -> (any DaemonWorkspaceAPI)?
    private var pending: Task<Void, Never>?
    private var dirty = false

    init(path: String, artifactId: UInt64, client: DaemonClient, files: @escaping () -> (any DaemonWorkspaceAPI)?) {
        self.path = path
        self.artifactId = artifactId
        self.client = client
        self.files = files
    }

    func changed() {
        dirty = true
        pending?.cancel()
        pending = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            await self?.save()
        }
    }

    func flush() {
        pending?.cancel()
        guard dirty else { return }
        Task { await save() }
    }

    func save() async {
        guard dirty, let api = files() else { return }
        dirty = false
        do {
            // The scene settles on the daemon a moment after the editor's last put.
            try? await Task.sleep(for: .milliseconds(200))
            let data = DrawingFile.contents(fromExport: try await client.excalidrawFile(artifactId: artifactId))
            try await Self.write(data, to: path, createNew: false, api: api)
        } catch {
            dirty = true
            CanvasWebView.log.error("drawing file: \(String(describing: error), privacy: .public)")
        }
    }

    /// The file moved on another device.
    func follow(_ renamed: String) {
        path = renamed
    }

    func rename(to name: String) async throws -> String {
        guard let api = files() else { throw HostError.notConnected }
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        guard target != path else { return path }
        _ = try await api.fsRename(from: path, to: target, overwrite: false)
        path = target
        return target
    }

    /// Small files in one request; larger ones (embedded images) as an upload.
    static func write(_ data: Data, to path: String, createNew: Bool, api: any DaemonWorkspaceAPI) async throws {
        let target = WriteTarget(path: path, ifMatch: nil, createNew: createNew, mkdirs: false, mode: nil)
        if data.count < 1 << 20 {
            _ = try await api.fsWrite(target: target, data: data)
            return
        }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-\(UUID().uuidString).excalidraw")
        try data.write(to: local, options: .atomic)
        defer { try? FileManager.default.removeItem(at: local) }
        _ = try await api.uploadFile(localPath: local.path, target: target, progress: nil)
    }
}

@Observable
final class CanvasChromeModel {
    var fileName: String?
    var destinations: [AgentDestination] = []
    var busy = false
    var readOnly = false
    var showsDone = false
    /// A narrow canvas: the name goes into the More menu.
    var compact = false
    @ObservationIgnored var onSend: (AgentDestination) -> Void = { _ in }
    @ObservationIgnored var onCopy: () -> Void = {}
    @ObservationIgnored var onRename: () -> Void = {}
    @ObservationIgnored var onDone: () -> Void = {}
}

/// A standalone drawing's controls, in the draw overlay's glass: its name, Send to an agent
/// (the selection, or all of it), and a menu with Copy Image and Rename.
struct CanvasChrome: View {
    @Bindable var model: CanvasChromeModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: DS.Space.s) {
                if let name = model.fileName, !model.compact {
                    Text((name as NSString).deletingPathExtension)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                        .padding(.leading, 6)
                        .accessibilityIdentifier("canvas.name")
                }
                Menu {
                    if let name = model.fileName, model.compact {
                        Text(name)
                    }
                    Button("Copy Image", systemImage: "doc.on.doc") { model.onCopy() }
                        .accessibilityIdentifier("canvas.copy")
                    if model.fileName != nil, !model.readOnly {
                        Button("Rename…", systemImage: "pencil") { model.onRename() }
                            .accessibilityIdentifier("canvas.rename")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .menuIndicator(.hidden)
                .accessibilityLabel("More")
                .accessibilityIdentifier("canvas.more")
                Menu {
                    if model.destinations.isEmpty {
                        Text("No agents are running")
                    } else {
                        Section("Sends the selection, or the whole drawing") {
                            ForEach(model.destinations) { destination in
                                Button {
                                    model.onSend(destination)
                                } label: {
                                    Label {
                                        Text(destination.label)
                                        if !destination.sameHost { Text(destination.hostName) }
                                    } icon: {
                                        Image(systemName: destination.agent.systemImage)
                                    }
                                }
                                .accessibilityIdentifier("canvas.send.\(destination.id)")
                            }
                        }
                    }
                    Button("Copy Image", systemImage: "doc.on.doc") { model.onCopy() }
                } label: {
                    Label(model.compact ? "Send" : "Send to Agent", systemImage: "paperplane.fill")
                        .lineLimit(1)
                        .fixedSize()
                }
                .menuStyle(.button)
                .buttonStyle(.primaryGlass)
                .menuIndicator(.hidden)
                .help("Attach the selection, or the whole drawing, to an agent's prompt as an image")
                .accessibilityIdentifier("canvas.send")
                if model.showsDone {
                    Button { model.onDone() } label: { Text("Done").lineLimit(1).fixedSize() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("canvas.done")
                }
            }
            .disabled(model.busy)
            .padding(6)
            .floatingCapsule()
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.toolbar")
    }
}

/// Reports a touch (or click) as it begins and fails at once, so it never delays or takes
/// the touch from the views underneath.
private final class FocusOnTouch: PlatformGestureRecognizer {
    var onTouch: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        #if os(iOS)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        #endif
    }

    #if os(macOS)
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    #endif

    #if os(iOS)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }
    #else
    override func mouseDown(with event: NSEvent) {
        onTouch?()
        state = .failed
    }
    #endif
}

#if os(iOS)
private typealias PlatformGestureRecognizer = UIGestureRecognizer
#else
private typealias PlatformGestureRecognizer = NSGestureRecognizer
#endif
