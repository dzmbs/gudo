import DesignSystem
import Foundation
import HostKit
import PaneLayout
import GudoCore
#if os(iOS)
import UIKit
#endif

/// Standalone drawings: New Drawing makes an `.excalidraw` file in the project folder on the
/// host and opens it in a floating canvas window (full screen on iPhone); opening such a file
/// from the file list does the same with its scene.
@MainActor
enum DrawingDocuments {
    /// The window's daemon host, which keeps the scene and the file.
    struct Host {
        let workspace: Workspace
        let daemon: DaemonConnection
        let client: DaemonClient
        let api: any DaemonWorkspaceAPI

        init?(window: WindowModel) {
            guard let workspace = window.workspace, let daemon = workspace.host as? DaemonConnection, daemon.status.isLive,
                  daemon.layout.sessionId != nil, let api = daemon.workspace.api, let client = api as? DaemonClient
            else { return nil }
            self.workspace = workspace
            self.daemon = daemon
            self.client = client
            self.api = api
        }

        var hub: DrawingHub { DrawingHub.shared(for: client) }
        var sessionId: UInt64 { daemon.layout.sessionId ?? 0 }
    }

    static func canCreate(in window: WindowModel) -> Bool {
        Host(window: window) != nil
    }

    static func newDrawing(window: WindowModel) {
        guard let host = Host(window: window) else {
            return window.toasts.show(Toast("New drawings are kept on a computer running the helper", systemImage: "scribble.variable", style: .neutral))
        }
        Task {
            do {
                let folder = await projectFolder(host: host, window: window)
                let artifact = try await host.client.artifactCreate(create: ArtifactCreate(
                    sessionId: host.sessionId, kind: .excalidraw, title: "Drawing", space: .canvas, anchor: nil, image: nil, ops: []))
                let contents = DrawingFile.contents(fromExport: try await host.client.excalidrawFile(artifactId: artifact.artifactId))
                let path: String
                do {
                    path = try await writeNew(contents, in: folder, api: host.api)
                } catch {
                    try? await host.client.artifactDelete(artifactId: artifact.artifactId)
                    throw error
                }
                _ = try await host.client.excalidrawPut(
                    artifactId: artifact.artifactId, elements: [], appState: appStateJSON([DrawingFile.pathKey: path]), files: [])
                CanvasWebView.log.info("new drawing \(artifact.artifactId) in \((path as NSString).lastPathComponent, privacy: .private)")
                present(artifact.artifactId, host: host, window: window)
            } catch {
                window.toasts.show(Toast(
                    "Could not make a drawing: \(describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    /// Opens a `.excalidraw` file: the canvas already showing it, or a new one with its scene.
    static func open(path: String, window: WindowModel) {
        guard let host = Host(window: window) else { return }
        if let pane = openCanvas(for: path, host: host) {
            host.workspace.apply(.focus(PaneId(pane)))
            return
        }
        Task {
            do {
                let scene = try DrawingFile.scene(from: try await read(path, api: host.api))
                var files: [ExFile] = []
                for embedded in scene.files {
                    let image = try await host.client.blobUpload(sessionId: host.sessionId, data: embedded.data, progress: nil)
                    files.append(ExFile(fileId: embedded.id, image: image))
                }
                let elements = scene.elements.compactMap { try? excalidrawElement(json: $0) }
                let artifact = try await host.client.artifactCreate(create: ArtifactCreate(
                    sessionId: host.sessionId, kind: .excalidraw, title: (path as NSString).lastPathComponent, space: .canvas,
                    anchor: nil, image: nil, ops: []))
                var appState = scene.appState
                appState[DrawingFile.pathKey] = path
                _ = try await host.client.excalidrawPut(
                    artifactId: artifact.artifactId, elements: elements, appState: appStateJSON(appState), files: files)
                present(artifact.artifactId, host: host, window: window)
            } catch {
                window.toasts.show(Toast(
                    "Could not open the drawing: \(describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    /// The repository's top level when the focused pane is in one, else its folder, as an
    /// absolute path (renames and other devices need one).
    private static func projectFolder(host: Host, window: WindowModel) async -> String {
        let directory = HostContext.resolve(app: window.app, window: window)?.directory
        var root: String?
        if let directory { root = try? await host.api.gitStatus(path: directory).root }
        let folder = DrawingFile.folder(directory: directory, repositoryRoot: root)
        guard folder.hasPrefix("~") else { return folder }
        return (try? await host.api.fsStat(path: folder).path) ?? folder
    }

    private static func writeNew(_ data: Data, in folder: String, api: any DaemonWorkspaceAPI) async throws -> String {
        let now = Date()
        for attempt in 1...50 {
            let path = (folder as NSString).appendingPathComponent(DrawingFile.name(at: now, attempt: attempt))
            do {
                try await DrawingFileSaver.write(data, to: path, createNew: true, api: api)
                return path
            } catch WorkspaceError.Conflict {
                continue
            }
        }
        throw WorkspaceError.Conflict(message: "too many drawings named for this minute")
    }

    private static func read(_ path: String, api: any DaemonWorkspaceAPI) async throws -> Data {
        var data = Data()
        while true {
            let chunk = try await api.fsRead(path: path, offset: UInt64(data.count), len: 1 << 20)
            data.append(chunk.data)
            if chunk.eof || chunk.data.isEmpty || data.count > 64 << 20 { return data }
        }
    }

    private static func openCanvas(for path: String, host: Host) -> UInt64? {
        let open = host.hub.canvases
        return open.first { _, artifact in
            guard let state = host.client.excalidrawScene(artifactId: artifact)?.appState,
                  let object = SceneSync.object(state) as? [String: Any] else { return false }
            return object[DrawingFile.pathKey] as? String == path
        }?.key
    }

    private static func present(_ artifactId: UInt64, host: Host, window: WindowModel) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            DrawingSheet.present(artifactId: artifactId, host: host, window: window)
            return
        }
        #endif
        let workspace = host.workspace
        guard let anchor = workspace.focusedPane ?? workspace.session.activeTab?.focused else { return }
        let launch = GudoCore.PaneLaunch.canvas(artifactId: artifactId)
        host.hub.focusWhenOpened(artifactId)
        if workspace.canFloat {
            _ = host.client.op(op: .newFloat(paneId: anchor.rawValue, launch: launch, frame: nil, focus: true, closeWhenDone: false))
        } else {
            _ = host.client.op(op: .split(paneId: anchor.rawValue, axis: .horizontal, launch: launch))
        }
    }

    private static func appStateJSON(_ state: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: state)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func describe(_ error: any Error) -> String {
        if error is ArtifactError { return DrawOverlay.describe(error) }
        if error is DrawingFile.ReadError { return "it is not an Excalidraw drawing" }
        return ScreenError.describe(error)
    }
}

#if os(iOS)
/// A standalone drawing full screen on iPhone, with Done to put it away.
final class DrawingSheet: UIViewController {
    private let editor: CanvasEditor

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(artifactId: UInt64, host: DrawingDocuments.Host, window: WindowModel) {
        let workspace = host.workspace
        let dark = workspace.appearance.background.isDark
        let editor = CanvasEditor(artifactId: artifactId, context: CanvasEditor.Context(
            hub: host.hub, sessionId: host.sessionId, readOnly: workspace.multiplayer?.isViewOnly ?? false, dark: dark,
            background: workspace.appearance.background,
            files: { [weak daemon = host.daemon] in daemon?.workspace.api },
            destinations: { [weak window, weak workspace] in
                guard let window, let workspace else { return [] }
                let tab = workspace.session.activeTab?.root.panes.map(\.rawValue) ?? []
                return AgentDestination.all(in: window, hostId: workspace.hostId, target: nil, tabPanes: Set(tab))
            },
            window: { [weak window] in window }))
        let sheet = DrawingSheet(editor: editor)
        editor.onDone = { [weak sheet] in sheet?.dismiss(animated: true) }
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController
        else { return }
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(sheet, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "drawing.sheet"
        view.backgroundColor = editor.view.backgroundColor
        editor.view.autoresizingMask = []
        view.addSubview(editor.view)
        editor.start()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        editor.takeKeyboard()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        editor.view.frame = view.safeAreaLayoutGuide.layoutFrame
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { editor.close() }
    }
}
#endif
