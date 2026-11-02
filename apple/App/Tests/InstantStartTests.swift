#if os(macOS)
import AppKit
import HostKit
import PaneLayout
import Synchronization
import SwiftUI
import TerminalCore
import TerminalRenderer
import GudoCore
import XCTest
@testable import App

/// A daemon client that never answers until told to: the host of an instant start before it
/// is reachable. Records what reaches it.
nonisolated final class SilentDaemonClient: DaemonClientAPI, @unchecked Sendable {
    private let state = Mutex<(listener: (any ClientEventListener)?, inputs: [String], subscribed: [UInt64])>((nil, [], []))

    func dial(_ listener: any ClientEventListener) -> SilentDaemonClient {
        state.withLock { $0.listener = listener }
        return self
    }

    /// Delivers an event as the core would.
    func send(_ event: ClientEvent) { state.withLock { $0.listener }?.onEvent(event: event) }
    var inputs: [String] { state.withLock { $0.inputs } }

    func attach(sessionId: UInt64?) {}
    func op(op: GudoCore.LayoutOp) -> UInt64 { 1 }
    func subscribe(paneId: UInt64) { state.withLock { $0.subscribed.append(paneId) } }
    func unsubscribe(paneId: UInt64) {}
    func setView(focused: UInt64?, visible: [UInt64]) {}
    func resize(paneId: UInt64, size: PaneSize) {}
    func sendInput(paneId: UInt64, data: Data) { state.withLock { $0.inputs.append(String(decoding: data, as: UTF8.self)) } }
    func sendPaste(paneId: UInt64, text: String) { state.withLock { $0.inputs.append(text) } }
    /// Answers a history request (nil: there is none).
    var history: (@Sendable (UInt64) -> ClientEvent?)? {
        get { historyAnswer.withLock { $0 } }
        set { historyAnswer.withLock { $0 = newValue } }
    }
    private let historyAnswer = Mutex<(@Sendable (UInt64) -> ClientEvent?)?>(nil)
    func fetchHistory(paneId: UInt64, maxBytes: UInt32) -> Bool {
        guard let event = history?(paneId) else { return false }
        DispatchQueue.global().async { self.send(event) }
        return true
    }
    func decide(requestId: UInt64, optionId: UInt32) {}
    func reconnect() {}
    func suspend() {}
    func paneText(paneId: UInt64) -> String? { nil }
}

/// A host's saved workspace and the same host live a moment later: two tabs, the first split
/// between a shell and a test run, the second an agent.
@MainActor
enum InstantStartFixture {
    static let hostId = "fixture-instant"
    static let esc = "\u{1b}["

    static var shell: [String] {
        [
            "\(esc)32m~/projects/acme\(esc)0m on \(esc)35mmain\(esc)0m",
            "❯ git status --short",
            " \(esc)31mM\(esc)0m crates/api/src/routes.rs",
            " \(esc)31mM\(esc)0m crates/api/src/auth.rs",
            "\(esc)32m??\(esc)0m crates/api/tests/sessions.rs",
            "",
            "\(esc)32m~/projects/acme\(esc)0m on \(esc)35mmain\(esc)0m",
            "❯ ",
        ]
    }

    static func tests(done: Bool) -> [String] {
        var lines = [
            "\(esc)32m~/projects/acme\(esc)0m",
            "❯ cargo test -p api",
            "\(esc)1;32m   Compiling\(esc)0m api v0.4.0 (crates/api)",
            "\(esc)1;32m    Finished\(esc)0m test profile in 6.42s",
            "\(esc)1;32m     Running\(esc)0m tests/sessions.rs",
            "",
            "running 14 tests",
        ]
        let names = ["login_issues_a_token", "token_expires", "refresh_rotates", "logout_revokes", "session_survives_restart",
                     "rate_limit_applies", "bad_password_is_slow", "lockout_after_five", "audit_logs_login"]
        for name in names { lines.append("test \(name) ... \(esc)32mok\(esc)0m") }
        if done {
            for name in ["sso_round_trip", "scim_sync", "mfa_required", "device_trust", "admin_override"] {
                lines.append("test \(name) ... \(esc)32mok\(esc)0m")
            }
            lines += ["", "test result: \(esc)32mok\(esc)0m. 14 passed; 0 failed; finished in 1.84s", "", "❯ "]
        }
        return lines
    }

    static var agent: [String] {
        [
            "\(esc)38;5;173m✻\(esc)0m Welcome to Claude Code",
            "",
            "> Add a sessions test for the refresh path",
            "",
            "\(esc)38;5;173m⏺\(esc)0m I'll add a test that rotates the refresh token and checks the old one is revoked.",
            "",
            "\(esc)38;5;173m⏺\(esc)0m \(esc)1mUpdate\(esc)0m(crates/api/tests/sessions.rs)",
            "  ⎿  Added 24 lines",
        ]
    }

    static func terminal(_ lines: [String], cols: UInt16 = 64, rows: UInt16 = 40) -> Terminal {
        let terminal = Terminal(cols: cols, rows: rows) { _ in }
        terminal.write(Array(lines.joined(separator: "\r\n").utf8))
        return terminal
    }

    static func screen(_ lines: [String], cols: UInt16 = 64) -> Data {
        CachedPane(terminal: terminal(lines, cols: cols), title: "", cwd: nil).screen ?? Data()
    }

    /// Tab 10: panes 1 | 2; tab 20: pane 3. Tab 10 active, pane 1 focused.
    static var layout: SessionLayout {
        SessionLayout(
            sessionId: 7, name: "main", revision: 1, activeTab: 10,
            tabs: [
                TabLayout(
                    tabId: 10, name: "api",
                    nodes: [.split(axis: .horizontal, ratio: 0.5, first: 1, second: 2), .leaf(paneId: 1), .leaf(paneId: 2)],
                    focused: 1, zoomed: nil),
                TabLayout(tabId: 20, name: "claude", nodes: [.leaf(paneId: 3)], focused: 3, zoomed: nil),
            ])
    }

    static var session: Session {
        Session(
            tabs: [
                Tab(id: TabId(10), title: "api", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)), second: .leaf(PaneId(2))), focused: PaneId(1)),
                Tab(id: TabId(20), title: "claude", root: .leaf(PaneId(3)), focused: PaneId(3)),
            ],
            activeTabId: TabId(10))
    }

    static var saved: CachedWorkspace {
        let panes: [UInt64: CachedPane] = [
            1: CachedPane(terminal: terminal(shell), title: "zsh", cwd: "/Users/me/projects/acme"),
            2: CachedPane(terminal: terminal(tests(done: false)), title: "cargo test", cwd: "/Users/me/projects/acme"),
            3: CachedPane(terminal: terminal(agent, cols: 130), title: "claude", cwd: "/Users/me/projects/acme"),
        ]
        return CachedWorkspace(
            hostId: hostId, daemonId: "fixture-i", sessionId: 7, sessionName: "main", session: session, panes: panes)
    }

    /// The host attached to the app with only its saved workspace: nothing from the host yet.
    static func attach(_ app: AppModel) throws -> (DaemonConnection, SilentDaemonClient) {
        let client = SilentDaemonClient()
        let connection = DaemonConnection(hostId: hostId, ticket: "t", session: 7) { _, listener in client.dial(listener) }
        connection.seed(saved)
        try connection.connect()
        app.hosts.attachPreview(HostRecord(id: hostId, name: "studio", kind: .daemon, daemonId: "fixture-i"), connection: connection)
        return (connection, client)
    }

    /// The host answers: its layout, then each pane's screen (the tests have finished since).
    static func goLive(_ client: SilentDaemonClient) {
        client.send(.connected(epoch: 1, resumed: false))
        client.send(.attached(sessionId: 7, via: .requested, missing: nil))
        client.send(.layout(layout: layout))
        client.send(.paneSnapshot(paneId: 1, seq: 0, data: screen(shell)))
        client.send(.paneSnapshot(paneId: 2, seq: 0, data: screen(tests(done: true))))
        client.send(.paneSnapshot(paneId: 3, seq: 0, data: screen(agent, cols: 130)))
    }
}

/// Instant start in the app: the first frame of a window is the saved workspace, drawn by the
/// renderer, before the host has said anything; input typed over it waits for the host's
/// screen; the live screens replace it in place.
@MainActor
final class InstantStartTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    override func tearDown() async throws {
        AppModel.shared.hosts.disconnect(InstantStartFixture.hostId)
    }

    private func window(_ model: WindowModel) -> NSWindow {
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1180, height: 760),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.setFrame(NSRect(x: -30000, y: -30000, width: 1180, height: 760), display: false)
        return window
    }

    /// Whether an image has more than the background in it (text was drawn).
    private func hasContent(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let count = CFDataGetLength(data)
        var colours = Set<UInt32>()
        for offset in stride(from: 0, to: count - 4, by: 4 * 97) {
            colours.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            if colours.count > 3 { return true }
        }
        return false
    }

    func testTheFirstFrameIsTheSavedWorkspaceWithNoHostConnected() async throws {
        let started = ContinuousClock.now
        let (connection, client) = try InstantStartFixture.attach(.shared)
        let attached = ContinuousClock.now
        let model = WindowModel(app: .shared)
        model.start()
        model.show(.host(InstantStartFixture.hostId))
        let shown = ContinuousClock.now
        let window = window(model)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let drawn = ContinuousClock.now
        let firstFrame = drawn - started
        defer {
            window.close()
            model.close()
        }

        XCTAssertFalse(connection.status.isLive, "nothing from the host")
        let workspace = try XCTUnwrap(model.workspace)
        XCTAssertEqual(workspace.session.tabs.map(\.id), [TabId(10), TabId(20)])
        XCTAssertEqual(workspace.session.activeTab?.root.panes, [PaneId(1), PaneId(2)])
        let group = try XCTUnwrap(model.groups.group(InstantStartFixture.hostId))
        XCTAssertTrue(group.isCached)
        XCTAssertEqual(group.tabs.map(\.id), [TabId(10), TabId(20)])
        XCTAssertTrue(workspace.showsSavedWorkspace)
        let pane = try XCTUnwrap(workspace.panes[PaneId(2)])
        XCTAssertTrue(pane.showsSavedScreen)
        XCTAssertTrue(pane.view.surface.terminal.visibleText().contains("audit_logs_login"))
        // Our renderer draws it: the pane's own picture has text in it.
        let image = try XCTUnwrap(pane.view.surface.snapshot())
        XCTAssertTrue(hasContent(image))
        print("instant start: saved workspace on screen \(firstFrame) (seed \(attached - started), window model and panes \(shown - attached), layout and draw \(drawn - shown))")

        // The host answers: the screens are the host's, in place, same tabs. (Panes of other
        // tabs are made in later stages and subscribe then; this silent host sends each screen
        // once, so it answers after all three exist.)
        for _ in 0..<100 where workspace.panes.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        InstantStartFixture.goLive(client)
        let deadline = ContinuousClock.now + .seconds(5)
        while workspace.showsSavedWorkspace || pane.showsSavedScreen || !connection.status.isLive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(pane.showsSavedScreen)
        XCTAssertFalse(workspace.showsSavedWorkspace)
        XCTAssertTrue(pane.view.surface.terminal.visibleText().contains("14 passed"))
        // And the renderer draws the host's screen, not the saved one it drew before.
        pane.view.surface.renderIfDirty(offscreen: true)
        let liveImage = try XCTUnwrap(pane.view.surface.snapshot())
        XCTAssertNotEqual(liveImage.dataProvider?.data as Data?, image.dataProvider?.data as Data?)
        XCTAssertEqual(workspace.session.tabs.map(\.id), [TabId(10), TabId(20)])
        XCTAssertTrue(workspace.panes[PaneId(2)] === pane, "the same pane and view: swapped in place")
    }

    /// The same first frame again once the process is warm (fonts, Metal pipelines loaded):
    /// what a window opened later costs; the first run above is a cold process's.
    func testFirstFrameTimesWarm() async throws {
        for round in 0..<3 {
            let started = ContinuousClock.now
            _ = try InstantStartFixture.attach(.shared)
            let model = WindowModel(app: .shared)
            model.start()
            model.show(.host(InstantStartFixture.hostId))
            let window = window(model)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            print("instant start: round \(round) saved workspace on screen \(ContinuousClock.now - started)")
            // The window's tab first, the other tabs' panes in the next stages.
            XCTAssertEqual(model.workspace?.panes.count, 2)
            for _ in 0..<50 where model.workspace?.panes.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.workspace?.panes.count, 3)
            window.close()
            model.close()
            AppModel.shared.hosts.disconnect(InstantStartFixture.hostId)
            try await Task.sleep(for: .milliseconds(200))

            // The same window on this device's own shell, for comparison: the window's cost.
            let local = ContinuousClock.now
            let plain = WindowModel(app: .shared)
            plain.start()
            let other = self.window(plain)
            other.contentView?.layoutSubtreeIfNeeded()
            other.displayIfNeeded()
            print("instant start: round \(round) a window on this device's shell \(ContinuousClock.now - local)")
            other.close()
            plain.close()
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// A window coming back at launch has its saved workspace in its first layout: never a
    /// frame of bare background while its model is made, nor one of another host while it
    /// restores.
    func testAWindowsFirstFrameIsItsSavedWorkspace() throws {
        _ = try InstantStartFixture.attach(.shared)
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "restoreLastTarget"), defaults.object(forKey: "window.openHosts"), defaults.object(forKey: "window.focusedTab"))
        defaults.set(true, forKey: "restoreLastTarget")
        defaults.set("[\"\(InstantStartFixture.hostId)\"]", forKey: "window.openHosts")
        let focus = try JSONEncoder().encode(TabRef(hostId: InstantStartFixture.hostId, tab: TabId(10)))
        defaults.set(String(decoding: focus, as: UTF8.self), forKey: "window.focusedTab")
        defer {
            for (key, value) in [("restoreLastTarget", saved.0), ("window.openHosts", saved.1), ("window.focusedTab", saved.2)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let before = Set(AppModel.shared.openWindows.map(ObjectIdentifier.init))
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowRoot(request: nil).environment(AppModel.shared))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let made = AppModel.shared.openWindows.filter { !before.contains(ObjectIdentifier($0)) }
        defer {
            window.close()
            made.forEach { $0.close() }
        }
        XCTAssertEqual(made.count, 1, "the window's model exists by its first frame")
        let model = try XCTUnwrap(made.first)
        XCTAssertTrue(model.workspace?.showsSavedWorkspace == true, "the first frame is the saved workspace")
        XCTAssertEqual(model.workspace?.session.tabs.map(\.id), [TabId(10), TabId(20)])
        func terminals(_ view: NSView) -> [TerminalView] { ((view as? TerminalView).map { [$0] } ?? []) + view.subviews.flatMap(terminals) }
        let shown = window.contentView.map(terminals) ?? []
        XCTAssertTrue(shown.contains { $0.surface.terminal.visibleText().contains("audit_logs_login") }, "drawn in that frame")
    }

    /// A sheet asked for as the window's content first appears (a link that opened the app)
    /// still comes up, with the model made in the scene's first update.
    func testASheetAskedForAtOnceShows() async throws {
        let before = Set(AppModel.shared.openWindows.map(ObjectIdentifier.init))
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowRoot(request: nil).environment(AppModel.shared))
        window.contentView?.layoutSubtreeIfNeeded()
        let model = try XCTUnwrap(AppModel.shared.openWindows.first { !before.contains(ObjectIdentifier($0)) })
        defer {
            window.close()
            model.close()
        }
        model.sheet = .join
        window.orderFrontRegardless()
        for _ in 0..<40 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(window.attachedSheet)
        model.sheet = nil
        for _ in 0..<40 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// A pane saved scrolled back stays at that position when the host's screen replaces the
    /// saved one, its older scrollback fetched to get there.
    func testAScrolledBackPaneKeepsItsPositionWhenItGoesLive() async throws {
        let lines = (1...200).map { String(format: "line %04d", $0) }
        let host = InstantStartFixture.terminal(lines, rows: 24)
        let saving = InstantStartFixture.terminal(lines, rows: 24)
        saving.scrollViewport(by: -40)
        let seen = saving.visibleText()
        var saved = InstantStartFixture.saved
        saved.panes[1] = CachedPane(terminal: saving, title: "zsh", cwd: nil)
        XCTAssertEqual(saved.panes[1]?.scrolledBack, 40)

        let client = SilentDaemonClient()
        let connection = DaemonConnection(hostId: InstantStartFixture.hostId, ticket: "t", session: 7) { _, listener in client.dial(listener) }
        connection.seed(saved)
        try connection.connect()
        AppModel.shared.hosts.attachPreview(
            HostRecord(id: InstantStartFixture.hostId, name: "studio", kind: .daemon, daemonId: "fixture-i"), connection: connection)
        let model = WindowModel(app: .shared)
        model.start()
        model.show(.host(InstantStartFixture.hostId))
        defer { model.close() }
        let pane = try XCTUnwrap(model.workspace?.panes[PaneId(1)])
        XCTAssertEqual(pane.view.surface.terminal.visibleText(), seen, "the saved screen where it was scrolled to")

        // The host's snapshot has only its screen; the rows above it come as history.
        let (ready, history) = try XCTUnwrap(Terminal.splitSnapshot(try XCTUnwrap(host.encodeSnapshot()), images: false))
        client.history = { $0 == 1 ? .paneHistory(paneId: 1, snapshotSeq: 0, data: history, rows: 0, done: true) : nil }
        client.send(.connected(epoch: 1, resumed: false))
        client.send(.attached(sessionId: 7, via: .requested, missing: nil))
        client.send(.layout(layout: InstantStartFixture.layout))
        client.send(.paneSnapshot(paneId: 1, seq: 0, data: ready))
        let deadline = ContinuousClock.now + .seconds(5)
        while pane.showsSavedScreen || pane.view.surface.terminal.visibleText() != seen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(pane.showsSavedScreen, "live")
        XCTAssertEqual(pane.view.surface.terminal.visibleText(), seen, "still where it was scrolled to")
        XCTAssertFalse(pane.view.surface.terminal.viewportAtBottom)
    }

    func testInputBeforeLiveWaitsForTheHostsScreen() async throws {
        let (connection, client) = try InstantStartFixture.attach(.shared)
        let model = WindowModel(app: .shared)
        model.start()
        model.show(.host(InstantStartFixture.hostId))
        defer { model.close() }
        let workspace = try XCTUnwrap(model.workspace)
        let shell = try XCTUnwrap(workspace.panes[PaneId(1)])
        let tests = try XCTUnwrap(workspace.panes[PaneId(2)])

        // Typed at the shell's saved prompt and into the saved test run.
        shell.view.onInput?(Array("ls\r".utf8))
        tests.view.onInput?(Array("q".utf8))
        XCTAssertEqual(client.inputs, [], "nothing reaches the host before its screen is shown")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(shell.heldInput, .holding(1), "and says it waits")

        // The shell's screen is the same: its input is sent. The test run moved on: dropped.
        InstantStartFixture.goLive(client)
        let deadline = ContinuousClock.now + .seconds(5)
        // The toast follows the drop on a later turn of the main actor.
        while client.inputs.isEmpty || tests.heldInput != .dropped || model.toasts.current == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.inputs, ["ls\r"])
        XCTAssertEqual(tests.heldInput, .dropped)
        XCTAssertTrue(connection.status.isLive)
        XCTAssertTrue(model.toasts.current?.message.contains("wasn't sent") == true)
    }
}
#endif
