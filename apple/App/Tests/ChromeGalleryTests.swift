#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Renders the window's chrome in its main states and themes to PNGs, for reviewing the look
/// without launching the app: `TEST_RUNNER_GUDO_CHROME_CAPTURE_DIR=<dir>` with the mock hosts.
@MainActor
final class ChromeGalleryTests: XCTestCase {
    private var captureDirectory: URL!
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["GUDO_CHROME_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            "set TEST_RUNNER_GUDO_CHROME_CAPTURE_DIR to capture")
        captureDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        for key in [TerminalPreferences.Key.theme, ThemePair.enabledKey] + Self.windowStateKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        savedDefaults["sidebar"] = TabPlacement.sidebarShown
    }

    override func tearDown() async throws {
        MockPaneStatus.fixture = nil
        for (key, value) in savedDefaults where key != "sidebar" {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let sidebar = savedDefaults["sidebar"] as? Bool { TabPlacement.sidebarShown = sidebar }
    }

    /// What the captures change in the window's saved state, put back afterwards.
    private static let windowStateKeys = ["window.projects", "window.focusedTab", "window.focusedPane", "window.mixedTabs", "tab-touches"]
    private static let size = NSSize(width: 1280, height: 800)
    private static let themes = ["dark": TerminalPreferences.Default.theme, "light": ThemePair.resolvedDefaultLight]

    func testCaptureChrome() async throws {
        let only = ProcessInfo.processInfo.environment["GUDO_CHROME_THEMES"]
        for (appearance, theme) in Self.themes.sorted(by: { $0.key < $1.key }) where only.map({ $0.contains(appearance) }) ?? true {
            UserDefaults.standard.set(false, forKey: ThemePair.enabledKey)
            UserDefaults.standard.set(theme, forKey: TerminalPreferences.Key.theme)
            try await capture("\(appearance)-sidebar") { model in model.isSidebarShown = true }
            try await capture("\(appearance)-sidebar-projects") { model in await Self.arrangeProjects(model) }
            try await capture("\(appearance)-agents") { model in
                model.isSidebarShown = true
                model.destination = .inbox
            }
            try await capture("\(appearance)-tab-strip") { model in
                model.isSidebarShown = false
                for _ in 0..<4 { model.newTab() }
            }
            try await capture("\(appearance)-splits") { model in
                model.isSidebarShown = true
                model.workspace?.split(.horizontal)
                model.workspace?.split(.vertical)
            }
            try await capture("\(appearance)-palette") { model in
                model.isSidebarShown = true
                model.isPaletteShown = true
            }
            try await capture("\(appearance)-settings") { model in model.sheet = .settings }
        }
    }

    /// Two projects, three Claude Codes and a Codex in one, a long name, a project folded away
    /// and an agent that needs the user: the sidebar's hard cases.
    private static func arrangeProjects(_ model: WindowModel) async {
        model.isSidebarShown = true
        guard let workspace = model.workspace else { return }
        while workspace.session.tabs.count < 9 { model.newTab() }
        let tabs = workspace.session.tabs
        let rows: [(title: String, program: String, state: AgentState?)] = [
            ("Chat view timeline", "claude", .working),
            ("Release blockers A to D", "codex", .done),
            ("~/Downloads", "zsh", nil),
            ("Pricing page copy", "claude", .blocked),
            ("Refactor the authentication middleware and its session storage", "claude", .working),
            ("Onboarding tests", "claude", nil),
            ("Landing page", "zsh", nil),
            ("Deploy preview", "zsh", nil),
            ("Scratch", "zsh", nil),
        ]
        var fixture: [String: (program: String, state: AgentState?)] = [:]
        for (tab, row) in zip(tabs, rows) {
            workspace.apply(.rename(tab.id, row.title))
            for pane in tab.root.panes { fixture[pane.description] = (row.program, row.state) }
        }
        MockPaneStatus.fixture = fixture
        let refs = tabs.map { TabRef(hostId: model.groups.groups.first?.id ?? HostGroups.localId, tab: $0.id) }
        model.newProject(from: Array(refs[0..<3]), name: "Gudo", naming: false)
        model.newProject(from: Array(refs[3..<6]), name: "ascend", naming: false)
        model.newProject(from: Array(refs[6..<8]), name: "website", naming: false)
        if let website = model.groups.projects.first(where: { $0.name == "website" }) {
            model.groups.toggleCollapsed(project: website.id)
        }
        model.focus(refs[0])
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func capture(_ name: String, _ arrange: (WindowModel) async -> Void) async throws {
        let model = WindowModel(app: .shared)
        model.start()
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingController(rootView: AnyView(WindowContent(request: nil, model: model).environment(AppModel.shared)))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.size)
        window.orderFrontRegardless()
        defer {
            window.close()
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        await arrange(model)
        try await Task.sleep(for: .seconds(1.5))
        window.setContentSize(Self.size)
        try await Task.sleep(for: .milliseconds(300))
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: captureDirectory.appendingPathComponent("\(name).png"))
    }
}
#endif
