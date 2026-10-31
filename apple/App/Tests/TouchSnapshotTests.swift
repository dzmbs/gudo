#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit
import XCTest
@testable import App

/// Design review on touch without UI tests: a window's content drawn in-process into a window
/// of the test host's scene and written as `<dir>/<ipad|iphone>-<name>-<mode>.png` (a foldable's
/// open screen and an iPad both get the sidebar). Runs only with
/// `SNAPSHOT_DIR` and `UNNAMED_MOCK` set, like `MacSnapshotTests`.
@MainActor
final class TouchSnapshotTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        try XCTSkipIf(env["SNAPSHOT_DIR"] == nil || !LaunchOptions.mock, "snapshots run on request")
    }

    private var mode: String { env["SNAPSHOT_MODE"] ?? "dark" }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func capture(_ window: UIWindow, _ name: String) throws {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let dir = URL(fileURLWithPath: env["SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let url = dir.appendingPathComponent("\(device)-\(name)-\(mode).png")
        try image.pngData()?.write(to: url)
        print("snapshot: \(url.path)")
    }

    func testProjects() async throws {
        let theme = mode == "light" ? "Apple System Colors Light" : "Ghostty Default"
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TerminalPreferences.Key.theme] = theme
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = WindowModel(app: .shared)
        model.start()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.isHidden = false
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        model.isSidebarShown = true
        if let workspace = model.workspace {
            await DesignFixtures.apply("projects", workspace: workspace, model: model)
        } else {
            DesignFixtures.projects(model)
        }
        await pump(2)
        try capture(window, "projects")

        // The sidebar as iPad and a foldable's open screen draw it (touch metrics, regular width).
        let sidebar = UIWindow(windowScene: scene)
        sidebar.frame = CGRect(x: 0, y: 0, width: SidebarWidth.standard + 40, height: min(scene.screen.bounds.height, 900))
        sidebar.rootViewController = UIHostingController(rootView: WorkspaceSidebar()
            .environment(model)
            .environment(\.horizontalSizeClass, .regular)
            .chromeTheme(ThemeCatalog.theme(named: theme), windowTheme: .auto))
        sidebar.isHidden = false
        await pump(1.5)
        try capture(sidebar, "sidebar")

        // A row being dragged within its project: frames of the gap opening.
        let drag = model.sidebarDrag
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        let last = try XCTUnwrap(app.tabs.last)
        drag.dragging = last
        withAnimation(DS.Motion.reorder) { drag.plan = .insert(last, into: .project(app.id), at: 0) }
        for (index, delay) in [0.05, 0.08, 0.3].enumerated() {
            await pump(delay)
            try capture(sidebar, "sidebar-reorder-\(index)")
        }
        withAnimation(DS.Motion.reorder) { drag.reset() }
        await pump(0.5)
        window.isHidden = true
        sidebar.isHidden = true
        model.close()
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }
}
#endif
