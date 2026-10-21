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
        configuration(for: session.role)
    }

    static func configuration(for role: UISceneSession.Role) -> UISceneConfiguration? {
        guard role == .windowExternalDisplayNonInteractive else { return nil }
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: role)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }

    /// The tab the display shows for the iPad window's: the same, or for a mixed tab (which
    /// belongs to its window) the focused pane's host tab.
    static func mirroredTab(current: TabRef?, activeTab: TabId?, focusedGroup: String) -> TabRef? {
        guard let current else { return nil }
        guard current.hostId == HostGroups.mixedId else { return current }
        return activeTab.map { TabRef(hostId: focusedGroup, tab: $0) }
    }

    /// The font that makes the iPad's grid fill the display: the iPad's size scaled by how much
    /// larger the display's terminal area is, a hair under so the grid is never a column short.
    /// Nil until both areas are known.
    static func fontSize(_ source: CGFloat, presenterArea: CGSize, display: CGSize) -> CGFloat? {
        guard presenterArea.width > 0, presenterArea.height > 0, display.width > 0, display.height > 0 else { return nil }
        let scale = min(display.width / presenterArea.width, display.height / presenterArea.height) * 0.99
        return (source * scale).rounded(.down)
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
        guard let presenter, let ref = ExternalDisplay.mirroredTab(
            current: presenter.currentTab, activeTab: presenter.workspace?.session.activeTabId,
            focusedGroup: presenter.currentGroupId)
        else { return }
        let pane = presenter.workspace?.focusedPane
        if model.currentTab != ref || model.workspace?.focusedPane != pane {
            model.select(ref, pane: pane)
        }
        // Same grid, bigger cells: scale the iPad's font by how much larger this display's
        // terminal area is (a hair under, so the grid is never a column short).
        guard let workspace = model.workspace, let source = presenter.workspace,
              let fontSize = ExternalDisplay.fontSize(source.appearance.fontSize, presenterArea: presenter.terminalArea, display: size)
        else { return }
        var appearance = source.appearance
        appearance.fontSize = fontSize
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
