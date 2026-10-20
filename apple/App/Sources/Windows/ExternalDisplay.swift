#if os(iOS)
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import TerminalRenderer
import UIKit

/// An external display (docs/APP-ARCHITECTURE.md "Windows"). With Stage Manager, iPadOS gives it
/// its own windows (ordinary scenes of `WindowGroup`, each a full window with its own layout).
/// Without Stage Manager the display would mirror the iPad; instead the app gives it a scene of
/// its own (`UIWindowSceneSessionRoleExternalDisplayNonInteractive`): a full-size window showing
/// the tab the iPad shows, with its own terminals rendered at the display's scale, while the
/// keyboard and touch stay on the iPad.
enum ExternalDisplay {
    /// The scene configuration for an external display's non-interactive role, nil for others.
    static func configuration(for session: UISceneSession) -> UISceneConfiguration? {
        guard session.role == .windowExternalDisplayNonInteractive else { return nil }
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: session.role)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }
}

/// The external display's window: a `WindowModel` of its own that follows the iPad's active
/// window (host, tab, focused pane) and draws only the terminal.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var model: WindowModel?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let model = WindowModel(app: AppModel.shared, isPresentation: true)
        model.start()
        self.model = model
        let window = UIWindow(windowScene: scene)
        let root = ExternalDisplayRoot(model: model).environment(AppModel.shared)
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        AppModel.log.info("external display connected: \(Int(scene.screen.bounds.width))×\(Int(scene.screen.bounds.height)) pt at \(scene.screen.scale)x")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        model?.close()
        model = nil
        window = nil
        AppModel.log.info("external display disconnected")
    }
}

/// The presentation: the iPad window's tab, full size, no chrome. The terminals keep the
/// pane's grid (the iPad drives the size, it has the keyboard) and scale their font so that
/// grid fills the display.
struct ExternalDisplayRoot: View {
    let model: WindowModel
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @State private var size = CGSize.zero

    private var theme: TerminalTheme { ThemeCatalog.theme(named: themeName) }

    var body: some View {
        Group {
            if let workspace = model.workspace, workspace.session.activeTab != nil {
                ActiveTabView(workspace: workspace)
                    .id(ObjectIdentifier(workspace))
            } else {
                VStack(spacing: DS.Space.m) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 40, weight: .light))
                    Text("Open a terminal on the iPad to show it here")
                        .font(DS.Font.title)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .environment(model)
        // Chrome-free and all terminal: always the theme's own scheme.
        .chromeTheme(theme)
        .environment(\.horizontalSizeClass, .regular)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .task { await follow() }
    }

    /// Follows the iPad's active window: the same host, tab and focused pane, and a font that
    /// fits its terminal area to this display.
    private func follow() async {
        while !Task.isCancelled {
            let presenter = AppModel.shared.openWindows.first { !$0.isPresentation && $0 === ActiveWindow.model }
                ?? AppModel.shared.openWindows.first { !$0.isPresentation }
            mirror(presenter)
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                let once = Once()
                withObservationTracking {
                    _ = presenter?.currentTab
                    _ = presenter?.workspace?.focusedPane
                    _ = presenter?.terminalArea
                    _ = presenter?.workspace?.appearance.fontSize
                    _ = AppModel.shared.windowsChanged
                } onChange: {
                    once.run { resume.resume() }
                }
                // Also wake up now and then: the active window can change without any of these.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    once.run { resume.resume() }
                }
            }
        }
    }

    private func mirror(_ presenter: WindowModel?) {
        guard let presenter, var ref = presenter.currentTab else { return }
        // A mixed tab belongs to its window: the display shows its focused pane's host tab.
        if ref.hostId == HostGroups.mixedId {
            guard let tab = presenter.workspace?.session.activeTabId else { return }
            ref = TabRef(hostId: presenter.currentGroupId, tab: tab)
        }
        let pane = presenter.workspace?.focusedPane
        if model.currentTab != ref || model.workspace?.focusedPane != pane {
            model.select(ref, pane: pane)
        }
        // Same grid, bigger cells: scale the iPad's font by how much larger this display's
        // terminal area is (a hair under, so the grid is never a column short).
        guard let workspace = model.workspace, let source = presenter.workspace,
              presenter.terminalArea.width > 0, presenter.terminalArea.height > 0, size.width > 0 else { return }
        let scale = min(size.width / presenter.terminalArea.width, size.height / presenter.terminalArea.height) * 0.99
        var appearance = source.appearance
        appearance.fontSize = (source.appearance.fontSize * scale).rounded(.down)
        if workspace.appearance.fontSize != appearance.fontSize { workspace.appearance = appearance }
    }
}

/// Runs a closure once (a continuation resumed by whichever wake-up comes first).
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
#endif
