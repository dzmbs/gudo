#if os(macOS)
import AppKit
import DesignSystem
import HostKit
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
    /// The fixture's window, for captures made while it runs.
    private var current: NSWindow?

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
        // `SNAPSHOT_DRAW=1`: the views' own drawing, for when the window server hands back blank
        // pictures (a locked or sleeping display).
        if env["SNAPSHOT_DRAW"] == nil, let image = Self.windowImage(window.windowNumber) {
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
        early: String? = nil, then: ((WindowModel) async -> Void)? = nil
    ) async throws {
        guard wanted(name) else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: size)
        current = window
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        model.isSidebarShown = true
        if let workspace = model.workspace {
            // The local layout outlives each window: start every fixture from one fresh tab.
            for tab in workspace.session.tabs { workspace.apply(.closeTab(tab.id)) }
            workspace.apply(.newTab)
            for _ in 0..<20 where workspace.focusedPane == nil { await pump(0.1) }
            await DesignFixtures.apply(screen, workspace: workspace, model: model)
        }
        if let early {
            await pump(2)
            try capture(window, early)
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
        // Window tabs outlive the window: a page left in one would be shown by the next
        // fixture's window too, which WebKit does not allow.
        for tab in model.composites.tabs where !tab.browsers.isEmpty { model.closeMixedTab(tab.id) }
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

    /// Projects across hosts in the sidebar, then a reorder recorded frame by frame: the rows
    /// must slide apart (never overlap) and the drop must not move anything again.
    func testProjects() async throws {
        try await window("projects", screen: "projects")
        try await window("projects-drag", screen: "projects") { model in
            let drag = model.sidebarDrag
            guard let app = model.projects.first(where: { $0.name == "acme-app" }), let last = app.tabs.last,
                  let logs = model.groups.sections.first(where: { $0.container == .host("fixture-studio") })?.rows.first
            else { return XCTFail("fixture") }
            await self.pump(1.5)
            // Within a project: the last tab to the top.
            let plan = SidebarDrop.insert(last, into: .project(app.id), at: 0)
            drag.dragging = last
            withAnimation(DS.Motion.reorder) { drag.plan = plan }
            for (index, delay) in [0.0, 0.04, 0.04, 0.05, 0.06, 0.08, 0.12, 0.3].enumerated() {
                await self.pump(delay)
                try? self.capture(self.current!, "projects-reorder-\(index)")
            }
            withAnimation(DS.Motion.reorder) {
                model.commit(plan)
                drag.reset()
            }
            for index in 0..<3 {
                await self.pump(0.05)
                try? self.capture(self.current!, "projects-dropped-\(index)")
            }
            XCTAssertEqual(model.projects.first { $0.id == app.id }?.tabs.first, last)
            // A loose tab hovering the middle of a project's row: "will group".
            drag.dragging = logs
            withAnimation(DS.Motion.reorder) { drag.plan = .group(logs, onto: app.tabs[0]) }
            await self.pump(0.5)
            try? self.capture(self.current!, "projects-will-group")
            // Into another project between its rows: the row leaves its host and slides in.
            guard let infra = model.projects.first(where: { $0.name == "infra" }) else { return XCTFail("infra") }
            withAnimation(DS.Motion.reorder) { drag.plan = .insert(logs, into: .project(infra.id), at: 1) }
            for (index, delay) in [0.03, 0.05, 0.08, 0.3].enumerated() {
                await self.pump(delay)
                try? self.capture(self.current!, "projects-into-\(index)")
            }
            withAnimation(DS.Motion.reorder) { drag.reset() }
        }
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }

    /// Any program's own status (pi blocked on a question) in its pane header and tab glyph.
    func testProgramStatus() async throws {
        defer {
            MockPaneStatus.fixture = nil
            MockPaneStatus.details = [:]
        }
        try await window("program-status", screen: "program-status")
    }

    /// A kitty graphics image a program printed, drawn in the pane by the Metal renderer from
    /// the render state's placements: a gradient over 24 × 6 cells between lines of text.
    func testKittyImageInAPane() async throws {
        try await window("kitty-image", screen: "single") { model in
            guard let workspace = model.workspace, let id = workspace.focusedPane, let pane = workspace.panes[id] else {
                return XCTFail("no pane")
            }
            let surface = pane.view.surface
            let (width, height) = (240, 120)
            var pixels: [UInt8] = []
            for y in 0..<height {
                for x in 0..<width { pixels += [UInt8(x * 255 / width), UInt8(y * 255 / height), 210, 255] }
            }
            let image = "\u{1b}_Ga=T,f=32,s=\(width),v=\(height),i=1,c=24,r=6,q=2;\(Data(pixels).base64EncodedString())\u{1b}\\"
            surface.terminal.write(Array("\r\n$ kitten icat gradient.png\r\n\(image)\r\n$ echo after\r\nafter\r\n".utf8))
            surface.outputArrived()
            await self.pump(1)
            XCTAssertEqual(surface.kittyPlacements.map(\.imageID), [1])
        }
    }

    func testSheets() async throws {
        for route in ["links", "launchAgent", "pairing", "join", "invite", "shortcuts"] {
            try await window(route, screen: route)
        }
        try await window("ticket", screen: "ticket")
    }

    /// Form sheets are as tall as their rows: macOS 26 centres a sheet shorter than its window,
    /// so blank space under a form would show as a sheet that opens low.
    func testFormSheetsFitTheirRows() async throws {
        guard wanted("sheet-fit") else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: CGSize(width: 1180, height: 760))
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        // The mock's empty Add Host and Join forms: a field, its note and the buttons.
        for route in [SheetRoute.pairing, .join] {
            model.sheet = route
            await pump(1.5)
            let sheet = try XCTUnwrap(window.attachedSheet, "\(route)")
            XCTAssertLessThan(sheet.frame.height, 320, "\(route) has blank space under its form")
            model.sheet = nil
            for _ in 0..<30 where window.attachedSheet != nil { await pump(0.1) }
        }
        window.close()
        model.close()
    }

    /// Files, Changes, Ports and Replays beside the focused pane (the default on the Mac).
    func testToolLeaves() async throws {
        for route in [SheetRoute.files, .diff, .browser, .replays] {
            try await window("leaf-\(route.rawValue)") { $0.sheet = route }
        }
    }

    /// A page opened from the Ports leaf opens in a browser leaf beside it; Ports stays a list.
    func testPortsLeafOpensPagesBeside() async throws {
        try await window("leaf-browser-open") { model in
            model.sheet = .browser
            await model.openPort(model.ports.ports[0])
            let tab = try? XCTUnwrap(model.activeMixed)
            XCTAssertEqual(tab?.tools.values.map(\.tool), [.ports], "Ports stays a leaf")
            XCTAssertEqual(tab?.browsers.count, 1, "the page is a leaf of its own")
            XCTAssertNotNil(tab?.focusedBrowser, "and has the focus")
            XCTAssertNil(model.browserURL, "the Ports leaf shows no page")
            // Again: the leaf showing it comes forward.
            await model.openPort(model.ports.ports[0])
            XCTAssertEqual(model.activeMixed?.browsers.count, 1)
        }
    }

    /// Pane ▸ Open in New Window moves the focused tool leaf to a window, with ⌥⌘N.
    func testOpenInNewWindowIsInTheMenuBar() throws {
        guard wanted("menu") else { return }
        let item = NSApp.mainMenu?.item(withTitle: "Pane")?.submenu?.item(withTitle: "Open in New Window")
        XCTAssertNotNil(item, "Pane ▸ Open in New Window")
        XCTAssertEqual(item?.keyEquivalent, "n")
        XCTAssertEqual(item?.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]), [.command, .option])
    }

    /// A new browser tab's start page while its host's dev servers are found, and after: they
    /// arrive below Frequently and Recently Visited, which stay where they were.
    func testStartPageKeepsItsPlace() async throws {
        try await window("start-page", screen: "start-page", early: "start-page-scanning") { _ in await self.pump(3) }
    }

    /// Add Host fits its mode: compact for SSH, a ticket's lines, the sign-in section with the
    /// real hosts model; an address typed changes values, never the sheet's size.
    func testAddHostFitsItsMode() async throws {
        guard wanted("addHost") else { return }
        let model = WindowModel(app: .shared)
        for live in [false, true] {
            for (mode, destination) in [(PairingSheet.Mode.ssh, ""), (.ssh, "me@devbox:2222"), (.ticket, "")] {
                let window = makeWindow(ThemedRoot {
                    Color.clear.sheet(isPresented: .constant(true)) {
                        PairingSheet(directory: model.hosts, live: live ? model.app.hosts : nil, initialMode: mode, destination: destination)
                            .environment(model).environment(model.app)
                    }
                }, size: CGSize(width: 1180, height: 760))
                await pump(1.5)
                let sheet = try XCTUnwrap(window.attachedSheet)
                try capture(sheet, "addHost-\(mode.rawValue)\(destination.isEmpty ? "" : "-typed")\(live ? "-live" : "")")
                window.close()
            }
        }
    }

    /// Changes on a folder outside any repository: a calm state, not git's words.
    func testToolProblems() async throws {
        final class NotARepository: DiffSource {
            var title: String { "Changes" }
            var unavailableReason: String? { nil }
            func repository() async throws -> DiffRepository { throw ToolProblem.notARepository(folder: "/Users/me/notes") }
            func files(_ scope: DiffScope) async throws -> [DiffFile] { [] }
            func turns() async throws -> [DiffTurn] { [] }
            func reviewer(for scope: DiffScope) -> String? { nil }
            func sendReview(_ notes: [ReviewNote], scope: DiffScope, preamble: String?) async throws {}
        }
        try await tool("diff-not-a-repository", size: CGSize(width: 720, height: 480)) {
            NavigationStack { DiffReviewView(source: NotARepository()) }
        }
    }


    /// New Agent opens at its final size: the host's answer (Claude Code off the PATH here)
    /// changes the status row, never the sheet. Its height is its form's, with nothing blank
    /// under the prompt.
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
        try await settings("settings")
        try await settings("settings-theme", SettingsNavigation(path: [.theme]))
        try await settings("settings-acknowledgements", SettingsNavigation(pane: .about, path: [.acknowledgements]))
        try await settings("settings-privacy", SettingsNavigation(pane: .privacy))
    }

    /// App Lock's screen, as it covers a locked window.
    func testAppLockScreen() async throws {
        struct Owner: AppLockAuthenticator {
            func method() -> AppLockMethod? { .touchID }
            func authenticate(reason: String) async -> AppLockAuthResult { .cancelled }
        }
        let suite = "app-lock-snapshot"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = AppLock(defaults: defaults, authenticator: Owner())
        guard wanted("app-lock") else { return }
        let window = makeWindow(AppLockScreen(lock: lock, prompts: false), size: CGSize(width: 1180, height: 760))
        await pump(1)
        try capture(window, "app-lock")
        window.close()
    }

    private func settings(_ name: String, _ navigation: SettingsNavigation = SettingsNavigation()) async throws {
        guard wanted(name) else { return }
        let window = makeWindow(ThemedRoot { SettingsView(navigation: navigation) }, size: CGSize(width: 820, height: 560))
        await pump(1.5)
        try capture(window, name)
        window.close()
    }
}
#endif
