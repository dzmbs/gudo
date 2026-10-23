#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// Design review of the Mac window, its sheets and popovers without putting anything on screen:
/// each fixture is drawn in-process into an offscreen window (titlebar and toolbar bridged from
/// SwiftUI) and written as `<dir>/mac-<name>-<mode>.png`. Runs only with `SNAPSHOT_DIR` and
/// `UNNAMED_MOCK` set (`TEST_RUNNER_SNAPSHOT_DIR`, `TEST_RUNNER_UNNAMED_MOCK=1`);
/// `SNAPSHOT_MODE` is `dark` (default) or `light`, `SNAPSHOT_ONLY` a comma list of fixtures.
@MainActor
final class MacSnapshotTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        try XCTSkipIf(env["SNAPSHOT_DIR"] == nil || !LaunchOptions.mock, "snapshots run on request")
    }

    private var mode: String { env["SNAPSHOT_MODE"] ?? "dark" }

    private func wanted(_ name: String) -> Bool {
        guard let only = env["SNAPSHOT_ONLY"] else { return true }
        return only.split(separator: ",").contains { $0 == name }
    }

    /// A window that never reaches the screen: far off it, never key, never ordered in front of
    /// another app.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func makeWindow(_ root: some View, size: CGSize) -> NSWindow {
        let theme = mode == "light" ? "Apple System Colors Light" : "Ghostty Default"
        // The argument domain: it wins over the app's saved settings and is never written to
        // disk, so a snapshot run leaves the real app's theme alone.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TerminalPreferences.Key.theme] = theme
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        // What `toolbarBackgroundVisibility(.hidden)` asks of a scene window.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        return window
    }

    private func capture(_ window: NSWindow, _ name: String) throws {
        guard let frameView = window.contentView?.superview else { return XCTFail("no frame view") }
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        let rep: NSBitmapImageRep
        if let image = Self.windowImage(window.windowNumber) {
            // The window server's picture of our own window (no recording permission needed):
            // glass and vibrancy included, which `cacheDisplay` draws as white slabs.
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            guard let cached = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return XCTFail("no bitmap") }
            frameView.cacheDisplay(in: bounds, to: cached)
            rep = cached
        }
        let dir = URL(fileURLWithPath: env["SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mac-\(name)-\(mode).png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }

    /// `CGWindowListCreateImage`, looked up at run time: the SDK marks it unavailable, and it is
    /// the one capture of an app's own window that asks no permission.
    private static func windowImage(_ number: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .optionIncludingWindow; .boundsIgnoreFraming | .bestResolution
        return create(.null, 1 << 3, UInt32(number), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// The window on the design fixture `screen`, then whatever `then` opens over it.
    private func window(
        _ name: String, screen: String = "splits", size: CGSize = CGSize(width: 1180, height: 760),
        then: ((WindowModel) async -> Void)? = nil
    ) async throws {
        guard wanted(name) else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: size)
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        model.isSidebarShown = true
        if let workspace = model.workspace {
            // The local layout outlives each window: start every fixture from one fresh tab.
            for tab in workspace.session.tabs { workspace.apply(.closeTab(tab.id)) }
            workspace.apply(.newTab)
            for _ in 0..<20 where workspace.focusedPane == nil { await pump(0.1) }
            await DesignFixtures.apply(screen, workspace: workspace, model: model)
        }
        await then?(model)
        await pump(2)
        try capture(window, name)
        if let sheet = window.attachedSheet {
            try capture(sheet, name + "-sheet")
        }
        for child in window.childWindows ?? [] where child.isVisible {
            try capture(child, name + "-popover")
        }
        model.sheet = nil
        await pump(0.3)
        window.close()
        model.close()
    }

    func testMainWindow() async throws {
        try await window("splits")
        try await window("single", screen: "single")
        try await window("hosts", screen: "hosts")
        try await window("inbox", screen: "inbox")
        try await window("narrow", size: CGSize(width: 820, height: 600))
        try await window("nosidebar") { $0.isSidebarShown = false }
    }

    func testSheets() async throws {
        for route in ["links", "launchAgent", "pairing", "join", "invite", "shortcuts"] {
            try await window(route, screen: route)
        }
        try await window("ticket", screen: "ticket")
    }

    /// New Agent opens at its final size: the host's answer (Claude Code off the PATH here)
    /// changes the status row, never the sheet.
    func testNewAgentKeepsItsSize() async throws {
        guard wanted("launchAgent-steady") else { return }
        for answer in ["installed", "notOnPath", "missing"] {
            try await newAgent(answer: answer)
        }
    }

    private func newAgent(answer: String) async throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["mockAgentInstall"] = answer
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            arguments["mockAgentInstall"] = nil
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: CGSize(width: 1180, height: 760))
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        model.sheet = .launchAgent
        var opened: NSRect?
        for _ in 0..<40 where opened == nil {
            await pump(0.05)
            opened = window.attachedSheet?.frame
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try capture(sheet, "launchAgent-checking-\(answer)")
        await pump(2.5)
        XCTAssertEqual(sheet.frame.size, opened?.size, "the sheet keeps the size it opened at")
        try capture(sheet, "launchAgent-\(answer)")
        model.sheet = nil
        await pump(0.3)
        window.close()
        model.close()
    }

    /// Files, Changes, Ports and Replays: windows of their own on the Mac.
    func testToolWindows() async throws {
        for route in [SheetRoute.files, .diff, .browser, .replays] {
            try await tool("tool-\(route.rawValue)") { ToolWindowContent(route: route) }
        }
        let entry = FileEntry(path: "~/projects/unnamed/Cargo.toml", name: "Cargo.toml", isDirectory: false, size: 1_412)
        try await tool("file-preview") {
            NavigationStack {
                FilePreviewScreen(
                    source: MockFileSource(), entry: entry,
                    actions: FileActions(openInEditor: { _ in }, revealInTerminal: { _ in }, insertPath: { _ in }))
            }
        }
    }

    private func tool(_ name: String, size: CGSize = CGSize(width: 960, height: 680), _ content: () -> some View) async throws {
        guard wanted(name) else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(
            ThemedRoot { content().environment(model).environment(model.app).environment(\.isToolWindow, true) },
            size: size)
        await pump(2)
        try capture(window, name)
        window.close()
        model.close()
    }

    func testHostSwitcher() async throws {
        try await window("host-switcher", screen: "host-switcher")
    }

    func testEmptyStates() async throws {
        guard wanted("empty") else { return }
        let window = makeWindow(ThemedRoot {
            HStack(spacing: 0) {
                EmptyState("No Agents Yet", systemImage: "tray", message: "Start Claude Code or Codex on a host. Agents show here, and say when they need you or finish.") {
                    Button("New Agent", systemImage: "sparkle") {}.buttonStyle(.primaryGlass)
                }
                Divider()
                EmptyState("No Host", systemImage: "server.rack", message: "Connect a host to browse its files.") {}
            }
            .chromeBackground(DS.Palette.base)
            .chromeContent()
        }, size: CGSize(width: 1000, height: 640))
        await pump(1.5)
        try capture(window, "empty")
        window.close()
    }

    func testSettings() async throws {
        guard wanted("settings") else { return }
        let window = makeWindow(ThemedRoot { SettingsView() }, size: CGSize(width: 820, height: 560))
        await pump(1.5)
        try capture(window, "settings")
        window.close()
    }
}
#endif
