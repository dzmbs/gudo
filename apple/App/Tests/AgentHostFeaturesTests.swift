#if os(macOS)
import AppKit
import DesignSystem
import GudoCore
import HostKit
import PaneLayout
import SwiftUI
import Vision
import XCTest
@testable import App

/// Agents on a real `gudo-hostd` (temporary state directory) whose `claude` is a stand-in that
/// reports through the real hook shim: New Agent starts it in a tab of its own, its requests are
/// answered from the Inbox's keys, and what it does reaches the toasts. Clicks and keys go
/// through the window as a user's do.
@MainActor
final class AgentHostFeaturesTests: XCTestCase {
    private var agents: FakeAgents?
    private var daemon: TestDaemon?
    private var hostId: String?
    private var window: NSWindow?
    private var model: WindowModel?

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let agents = try FakeAgents()
        self.agents = agents
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: agents.environment)
        self.daemon = daemon
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "agents-host")
        self.hostId = hostId
        let feed = LiveAgentFeed(hosts: AppModel.shared.hosts)
        let model = WindowModel(app: .shared, agents: feed)
        feed.window = model
        model.start()
        let window = AgentTestWindow.open(model: model, width: 1300)
        self.model = model
        self.window = window
        model.show(.host(hostId))
        try await until("a live pane on the host") {
            guard let workspace = model.workspace, workspace.hostId == hostId, let id = workspace.focusedPane else { return false }
            return workspace.panes[id]?.connection == .live
        }
        model.isOnScreen = true
    }

    override func tearDown() async throws {
        window?.close()
        model?.close()
        if let hostId { AppModel.shared.hosts.remove(hostId) }
        daemon?.stop()
        agents = nil
    }

    // MARK: New Agent

    func testNewAgentStartsTheAgentInATabOfItsOwnBesideTheOneItCameFrom() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        let workspace = try XCTUnwrap(model.workspace)
        let originTab = try XCTUnwrap(workspace.session.activeTab?.id)
        let tabsBefore = workspace.session.tabs.map(\.id)
        let origin = TabRef(hostId: hostId, tab: originTab)
        model.newProject(from: [origin], name: "parser", naming: false)
        let project = try XCTUnwrap(model.groups.project(of: origin)?.id)
        defer { model.ungroupProject(project) }

        model.newAgent()
        let sheet = try await self.sheet(of: window)
        let connection = try XCTUnwrap(AppModel.shared.hosts.connection(hostId) as? DaemonConnection)
        let runners = try await runnerSegments(in: sheet)
        XCTAssertEqual(runners.count, connection.workspace.startsPi ? 4 : 3, "Claude Code, Codex, pi where the helper starts it, and Shell")

        // Codex is not on this host: picked, Start does nothing.
        try await click(runners[1], in: sheet)
        try await click(try startButton(in: sheet), in: sheet)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotNil(window.attachedSheet, "Start stays off for an agent the host doesn't have")
        XCTAssertEqual(workspace.session.tabs.map(\.id), tabsBefore)

        try await click(try await runnerSegments(in: sheet)[0], in: sheet)
        try type("fix the parser", intoPromptOf: sheet)
        try await click(try startButton(in: sheet), in: sheet)
        try await until("the sheet closes") { window.attachedSheet == nil }
        try await until("a tab of its own") { workspace.session.tabs.count == tabsBefore.count + 1 }
        let tabs = workspace.session.tabs.map(\.id)
        let newTab = try XCTUnwrap(tabs.first { !tabsBefore.contains($0) })
        XCTAssertEqual(tabs.firstIndex(of: newTab), (tabs.firstIndex(of: originTab) ?? -2) + 1, "right after the tab it came from")
        try await until("the new tab shows its agent") {
            guard let tab = workspace.session.activeTab, tab.id == newTab else { return false }
            return connection.meta[tab.focused]?.agent?.kind == "claude"
        }
        let agentPane = try XCTUnwrap(workspace.session.activeTab?.focused)
        try await until("in the project of the tab it came from, right after it") {
            model.groups.project(project)?.tabs == [origin, TabRef(hostId: hostId, tab: newTab)]
        }

        // The prompt is typed once the agent is ready: it asks to run the tests.
        try await untilBlocked(agentPane)
        let item = try XCTUnwrap(model.agents.items.first { $0.paneId == agentPane.rawValue })
        guard case .permission(_, let detail)? = item.request else { return XCTFail("a permission request: \(String(describing: item.request))") }
        XCTAssertTrue(detail.contains("make test"), detail)
    }

    // MARK: Inbox

    func testTheInboxCountsAndAnswersWithItsKeys() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window), connection = try XCTUnwrap(connection)
        let pane = try await launchAgent(prompt: "fix the parser")
        try await untilBlocked(pane)
        model.destination = .inbox
        try await untilShown("Waiting for your approval", in: window)
        XCTAssertNotNil(try words(in: window).first { $0.text.replacingOccurrences(of: " ", with: "") == "NeedsYou1" }, "Needs You counts it")

        // ↩ approves this once, and nothing more.
        press(.return, in: window)
        try await until("approved: the turn ends", timeout: .seconds(20)) { self.state(of: pane) == .done }
        let id = try XCTUnwrap(model.agents.items.first { $0.paneId == pane.rawValue }?.id)
        XCTAssertEqual(model.agents.autoApprovals(id), [], "a plain ↩ approves all like it for no one")
        try await untilShown("Tests pass", in: window)

        // ↩ on the finished agent, still the keyboard's row, opens its pane.
        press(.return, in: window)
        try await until("its pane shows") { model.destination == .terminal && model.workspace?.focusedPane == pane }

        // E edits the command; ↩ approves what was typed instead.
        _ = try await connection.workspace.client().prompt(paneId: pane.rawValue, text: "again", submit: true)
        try await untilBlocked(pane)
        model.destination = .inbox
        try await untilShown("Waiting for your approval", in: window)
        press("e", in: window)
        try await until("the command opens for editing") { self.editField(in: window) != nil }
        let field = try XCTUnwrap(editField(in: window))
        field.currentEditor()?.selectAll(nil)
        field.currentEditor()?.insertText("make check")
        press(.return, in: window)
        try await until("approved as edited: the turn ends", timeout: .seconds(20)) { self.state(of: pane) == .done }
        XCTAssertTrue(screen(of: pane).contains("make check"), "the agent ran the edited command: \(screen(of: pane))")

        // Esc denies.
        _ = try await connection.workspace.client().prompt(paneId: pane.rawValue, text: "once more", submit: true)
        try await untilBlocked(pane)
        try await untilShown("Waiting for your approval", in: window)
        press(.escape, in: window)
        try await until("denied: the turn ends", timeout: .seconds(20)) { self.state(of: pane) == .done }
        XCTAssertTrue(screen(of: pane).contains("turn 3: Stopped, not allowed"), screen(of: pane))
        try await untilShown("Waiting for your next prompt", in: window)
    }

    func testApproveAllLikeThisApprovesTheNextOneUntilRevoked() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window), connection = try XCTUnwrap(connection)
        let pane = try await launchAgent(prompt: "fix the parser")
        try await untilBlocked(pane)
        model.destination = .inbox
        try await untilShown("Waiting for your approval", in: window)
        press(.return, modifiers: .shift, in: window)
        try await until("approved: the turn ends", timeout: .seconds(20)) { self.state(of: pane) == .done }
        try await untilShown("Auto-approving", in: window)

        // The same command again is approved without asking.
        _ = try await connection.workspace.client().prompt(paneId: pane.rawValue, text: "again", submit: true)
        try await until("approved by the rule", timeout: .seconds(20)) { self.screen(of: pane).contains("turn 2: Tests pass") }

        // A list row in a window that is never key in a test run can take a first click to select.
        for _ in 0..<3 where (try? words(in: window).contains { $0.text.hasPrefix("Auto-approving") }) == true {
            try await click(try await shown("Revoke", in: window), in: window)
            try await Task.sleep(for: .seconds(1))
        }
        try await until("the rule is gone") { (try? self.words(in: window).contains { $0.text.hasPrefix("Auto-approving") }) == false }
        _ = try await connection.workspace.client().prompt(paneId: pane.rawValue, text: "once more", submit: true)
        try await untilBlocked(pane)
    }

    func testAFailedAgentNeedsYouInEveryCount() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window)
        let pane = try await launchAgent(prompt: "fail please")
        try await until("the turn fails", timeout: .seconds(30)) { self.state(of: pane) == .error }
        let hostId = try XCTUnwrap(hostId)
        XCTAssertEqual(model.agentState(ofPane: pane, onGroup: hostId), .error, "the sidebar, tab strip and palette agree with the Inbox")
        let workspace = try XCTUnwrap(model.workspace(ofGroup: hostId))
        let tab = try XCTUnwrap(workspace.session.tab(containing: pane))
        XCTAssertEqual(workspace.windowSubtitle(of: tab), "Claude Code · failed")
        model.destination = .inbox
        try await untilShown("API Error: rate limited", in: window)
        let lines = try words(in: window).map { $0.text.replacingOccurrences(of: " ", with: "") }
        XCTAssertTrue(lines.contains("Needsyou1"), "its section: \(lines)")
        XCTAssertTrue(lines.contains("NeedsYou1"), "the Needs You filter counts what its section holds: \(lines)")
        XCTAssertTrue(lines.contains("Errors1"), "\(lines)")
        try await until("the badge counts it") { model.agents.needsYouCount == 1 }
    }

    // MARK: Worktrees

    func testANewTaskMakesAWorktreeOnItsOwnBranchInATabOfItsOwn() async throws {
        let model = try XCTUnwrap(model), hostId = try XCTUnwrap(hostId), agents = try XCTUnwrap(agents)
        let repo = agents.home.appending(path: "parser")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "start"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = repo
            try git.run()
            git.waitUntilExit()
        }
        let workspace = try XCTUnwrap(model.workspace)
        let tabsBefore = workspace.session.tabs.count
        _ = try await model.agents.launch(AgentLaunchRequest(
            agent: .claude, hostId: hostId, prompt: "", worktree: true, branch: nil, name: "fix parser", repo: repo.path, shell: false, account: nil))
        try await until("a tab of its own") { workspace.session.tabs.count == tabsBefore + 1 }
        try await until("the worktree is listed", timeout: .seconds(20)) {
            self.connection?.existingWorkspace?.repos?.worktrees.contains { $0.branch == "fix-parser" && !$0.main } == true
        }
        let worktree = try XCTUnwrap(connection?.existingWorkspace?.repos?.worktrees.first { $0.branch == "fix-parser" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), worktree.path)
        try await until("its agent runs in the worktree") {
            guard let pane = workspace.session.activeTab?.focused else { return false }
            return self.connection?.meta[pane]?.agent != nil && self.connection?.meta[pane]?.cwd == worktree.path
        }
    }

    func testNewWorktreeInAFolderThatIsNoRepositorySaysSoInTheSheet() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window)
        model.newAgent()
        let sheet = try await self.sheet(of: window)
        let label = try await shown("New Worktree", in: sheet)
        let toggle = try XCTUnwrap(
            views(in: sheet).filter { $0 is NSSwitch }.map { $0.convert($0.bounds, to: nil) }.first { abs($0.midY - label.midY) < 20 },
            "the New Worktree switch")
        try await click(toggle, in: sheet)
        try await untilShown("Name and Branch", in: sheet)
        press("\r", modifiers: .command, in: sheet)
        try await until("the sheet says the folder is no repository", timeout: .seconds(5)) {
            ((try? self.words(in: sheet)) ?? []).contains { $0.text.localizedCaseInsensitiveContains("git repository") }
        }
        XCTAssertNotNil(window.attachedSheet, "the sheet stays to say so")
    }

    // MARK: Toasts

    func testAnAgentInAnotherTabToastsAndTheCardAnswersIt() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        let workspace = try XCTUnwrap(model.workspace)
        let home = try XCTUnwrap(workspace.session.activeTab?.id)
        let pane = try await launchAgent(prompt: "")
        try await until("its tab shows") { workspace.session.activeTab?.root.panes.contains(pane) == true }
        model.focus(TabRef(hostId: hostId, tab: home))
        try await until("back on the first tab") { workspace.session.activeTab?.id == home }

        try await LiveAgentFeed.typeWhenReady("fix the parser", pane: pane.rawValue, daemon: try XCTUnwrap(connection))
        try await untilBlocked(pane)
        try await until("a card says it needs you") { model.agentToasts.cards.map(\.kind) == [.needsYou] }
        let buttons = try await cardButtons(in: window)
        try await click(try XCTUnwrap(buttons.last), in: window)
        try await until("approved from the card", timeout: .seconds(20)) { self.state(of: pane) == .done }
        XCTAssertTrue(screen(of: pane).contains("turn 1: Tests pass"), screen(of: pane))

        try await until("a card says it finished") { model.agentToasts.cards.map(\.kind) == [.finished] }
        let open = try await cardButtons(in: window)
        try await click(try XCTUnwrap(open.last), in: window)
        try await until("the card opens the agent's pane") { workspace.session.activeTab?.root.panes.contains(pane) == true }
        XCTAssertTrue(model.agentToasts.cards.isEmpty)
    }

    func testTheCardOffersAlwaysWhenTheAgentDoesAndItAnswersSo() async throws {
        let model = try XCTUnwrap(model), window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        let workspace = try XCTUnwrap(model.workspace)
        let home = try XCTUnwrap(workspace.session.activeTab?.id)
        let pane = try await launchAgent(prompt: "")
        try await until("its tab shows") { workspace.session.activeTab?.root.panes.contains(pane) == true }
        model.focus(TabRef(hostId: hostId, tab: home))
        try await until("back on the first tab") { workspace.session.activeTab?.id == home }

        try await LiveAgentFeed.typeWhenReady("fix the parser", pane: pane.rawValue, daemon: try XCTUnwrap(connection))
        try await untilBlocked(pane)
        try await until("a card says it needs you") { model.agentToasts.cards.map(\.kind) == [.needsYou] }
        let id = try XCTUnwrap(model.agents.items.first { $0.paneId == pane.rawValue }?.id)
        XCTAssertTrue(model.agents.canApproveAlways(id), "the agent offers not to ask again")
        var buttons: [NSRect] = []
        try await until("the card shows Deny, Always and Approve") {
            buttons = self.cardButtonRings(in: window)
            return buttons.count == 3
        }
        try await click(buttons[1], in: window)
        try await until("approved from the card", timeout: .seconds(20)) { self.state(of: pane) == .done }
        XCTAssertTrue(screen(of: pane).contains("updatedPermissions"), screen(of: pane))
    }

    // MARK: Helpers

    /// The newest agent card's buttons, leading to trailing: the lowest row of focus rings in the
    /// content's bottom leading corner (the cards' glass draws nothing into a cached image).
    private func cardButtons(in window: NSWindow) async throws -> [NSRect] {
        var rings: [NSRect] = []
        // Once the card has slid in and holds still.
        try await until("the card's buttons") {
            let now = self.cardButtonRings(in: window)
            defer { rings = now }
            return !now.isEmpty && now == rings
        }
        return rings
    }

    private func cardButtonRings(in window: NSWindow) -> [NSRect] {
        func collect(_ view: NSView) -> [NSRect] {
            let frame = view.convert(view.bounds, to: nil)
            // Cards sit 16 pt above the window's bottom edge; the sidebar's footer below that.
            let own = String(describing: Swift.type(of: view)) == "_FocusRingView" && frame.minY >= 16 && frame.maxY < 250 ? [frame] : []
            return own + view.subviews.flatMap(collect)
        }
        let rings = window.contentView?.superview.map(collect) ?? []
        guard let bottom = rings.map(\.minY).min() else { return [] }
        return rings.filter { $0.minY == bottom }.sorted { $0.minX < $1.minX }
    }

    private func views(in window: NSWindow) -> [NSView] {
        func collect(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(collect) }
        return window.contentView.map(collect) ?? []
    }

    private var connection: DaemonConnection? { hostId.flatMap { AppModel.shared.hosts.connection($0) as? DaemonConnection } }

    /// Starts the stand-in Claude in a tab of its own and returns its pane.
    private func launchAgent(prompt: String) async throws -> PaneId {
        let model = try XCTUnwrap(model), hostId = try XCTUnwrap(hostId), connection = try XCTUnwrap(connection)
        let before = Set(connection.meta.all.keys)
        _ = try await model.agents.launch(AgentLaunchRequest(
            agent: .claude, hostId: hostId, prompt: prompt, worktree: false, branch: nil, name: nil, repo: nil, shell: false, account: nil))
        try await until("the agent's pane") { connection.meta.all.contains { !before.contains($0.key) && $0.value.agent != nil } }
        let pane = try XCTUnwrap(connection.meta.all.first { !before.contains($0.key) && $0.value.agent != nil }?.key)
        return pane
    }

    private func state(of pane: PaneId) -> DesignSystem.AgentState? {
        model?.agents.items.first { $0.paneId == pane.rawValue && !$0.isCommand }?.state
    }

    private func untilBlocked(_ pane: PaneId) async throws {
        try await until("the agent asks", timeout: .seconds(30), screen: { "\(String(describing: self.connection?.meta[pane]?.agent?.state)) \(String(describing: self.model?.toasts.current))\n\(self.screen(of: pane))" }) {
            if case .blocked = self.connection?.meta[pane]?.agent?.state { return true }
            return false
        }
    }

    private func screen(of pane: PaneId) -> String {
        guard let workspace = model?.workspace(ofGroup: hostId ?? ""), let view = workspace.pane(pane)?.view else { return "" }
        return view.surface.terminal.visibleText()
    }

    /// The Inbox's command editor: the one editable field in the window's list.
    private func editField(in window: NSWindow) -> NSTextField? {
        func fields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []).filter(\.isEditable) + view.subviews.flatMap(fields)
        }
        return window.contentView.flatMap { fields($0).first { $0.convert($0.bounds, to: nil).width > 200 } }
    }

    struct Word {
        var text: String
        var frame: NSRect
    }

    /// The words drawn in the window, read off its pixels, in window points.
    private func words(in window: NSWindow) throws -> [Word] {
        let view = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = view.bounds.size
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Word(text: text, frame: NSRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height))
        }
    }

    /// Where `text` is drawn: a line that is it, else the part of a line that starts with it.
    private func shown(_ text: String, in window: NSWindow) async throws -> NSRect {
        var found: NSRect?
        try await until("“\(text)” shows") {
            let lines = (try? self.words(in: window)) ?? []
            if let line = lines.first(where: { $0.text == text }) {
                found = line.frame
            } else if let line = lines.first(where: { $0.text.hasPrefix(text) }) {
                let share = CGFloat(text.count) / CGFloat(max(line.text.count, 1))
                found = NSRect(x: line.frame.minX, y: line.frame.minY, width: line.frame.width * share, height: line.frame.height)
            }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func untilShown(_ text: String, in window: NSWindow) async throws {
        _ = try await shown(text, in: window)
    }

    private func press(_ key: KeyEquivalent, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        let codes: [Character: UInt16] = ["\r": 36, "\u{1B}": 53, "e": 14, "\u{F700}": 126, "\u{F701}": 125]
        let characters = String(key.character)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: codes[key.character] ?? 0)
            else { continue }
            // As a window routes a key: its key equivalents first, then the first responder.
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    private func until(
        _ what: String, timeout: Duration = .seconds(15), screen: () -> String = { "" }, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out: \(what)\n\(screen())")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func sheet(of window: NSWindow) async throws -> NSWindow {
        try await until("the sheet opens") { window.attachedSheet != nil }
        // Its content settles (the form fits itself to its rows).
        try await Task.sleep(for: .seconds(1))
        return try XCTUnwrap(window.attachedSheet)
    }

    /// The focusable controls SwiftUI drew (a key view proxy each), in window points.
    private func controls(in window: NSWindow) -> [NSRect] {
        func collect(_ view: NSView) -> [NSRect] {
            let own = String(describing: Swift.type(of: view)) == "KeyViewProxy" ? [view.convert(view.bounds, to: nil)] : []
            return own + view.subviews.flatMap(collect)
        }
        return window.contentView.map { collect($0.superview ?? $0) } ?? []
    }

    /// The runner picker's segments, leading to trailing: the row of controls at the sheet's top.
    private func runnerSegments(in sheet: NSWindow) async throws -> [NSRect] {
        let top = try XCTUnwrap(controls(in: sheet).map(\.midY).max())
        return controls(in: sheet).filter { abs($0.midY - top) < 1 }.sorted { $0.minX < $1.minX }
    }

    /// Start: the trailing button on the sheet's bottom margin, outside the form's scrolling rows.
    private func startButton(in sheet: NSWindow) throws -> NSRect {
        let scrolling = views(in: sheet).compactMap { $0 as? NSScrollView }
        let footer = views(in: sheet)
            .filter { String(describing: Swift.type(of: $0)) == "KeyViewProxy" && !scrolling.contains(where: $0.isDescendant(of:)) }
            .map { $0.convert($0.bounds, to: nil) }
        let bottom = try XCTUnwrap(footer.map(\.midY).min())
        return try XCTUnwrap(footer.filter { abs($0.midY - bottom) < 1 }.max { $0.minX < $1.minX })
    }

    private func type(_ text: String, intoPromptOf sheet: NSWindow) throws {
        func fields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []).filter(\.isEditable) + view.subviews.flatMap(fields)
        }
        let prompt = try XCTUnwrap(fields(try XCTUnwrap(sheet.contentView)).min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY },
                                   "the prompt is the lowest field")
        sheet.makeFirstResponder(prompt)
        let editor = try XCTUnwrap(prompt.currentEditor())
        editor.insertText(text)
    }

    private func click(_ rect: NSRect, in window: NSWindow, count: Int = 1) async throws {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        for click in 1...count {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 1))
            }
            // The release waits in the queue, where a control tracking the press reads it.
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            window.sendEvent(try event(.leftMouseDown))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(400))
    }
}

/// A test window showing the whole app, offscreen.
@MainActor
enum AgentTestWindow {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    static func open(model: WindowModel, width: CGFloat, height: CGFloat = 800) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: width, height: height)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: ThemedRoot { WindowContent(request: nil, model: model).environment(AppModel.shared) })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }
}

/// Stand-ins for the agents on the test host's `PATH` (and a `gh` that knows no pull requests),
/// in a home of their own so the real ones are never found. The `claude` reports through the
/// real hook shim: it starts at its prompt box, and on each line asks to run `make test`, then
/// ends its turn saying whether it was let.
final class FakeAgents {
    let directory: URL
    let home: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "fake-agents-\(UUID().uuidString)")
        home = directory.appending(path: "home")
        let bin = directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        // The script runs in bash called through a link named `claude`, so the host sees a
        // process of that name in the pane, as it does a real Claude Code.
        let programs = directory.appending(path: "programs")
        try FileManager.default.createDirectory(at: programs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: programs.appending(path: "claude").path, withDestinationPath: "/bin/bash")
        try Self.install(Self.claude(hook: Self.hookBinary.path), as: "claude.sh", in: programs)
        try Self.install("#!/bin/sh\nexec '\(programs.path)/claude' '\(programs.path)/claude.sh' \"$@\"\n", as: "claude", in: bin)
        try Self.install("#!/bin/sh\necho 'gh: not logged in' >&2\nexit 4\n", as: "gh", in: bin)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var environment: [String: String] {
        ["PATH": "\(directory.appending(path: "bin").path):/usr/bin:/bin", "HOME": home.path, "ZDOTDIR": home.path]
    }

    private static func install(_ script: String, as name: String, in bin: URL) throws {
        let file = bin.appending(path: name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static var hookBinary: URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let daemon = ProcessInfo.processInfo.environment["GUDO_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/gudo-hostd")
        return daemon.deletingLastPathComponent().appending(path: "gudo-hook")
    }

    private static func claude(hook: String) -> String {
        #"""
        #!/bin/sh
        case "$1" in --version) echo "1.0.0 (Claude Code)"; exit 0 ;; esac
        hook() {
          '\#(hook)' claude "$1" <<PAYLOAD
        $2
        PAYLOAD
        }
        base="\"session_id\":\"s1\",\"transcript_path\":\"/tmp/s1.jsonl\",\"cwd\":\"$PWD\",\"permission_mode\":\"default\""
        printf '────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  ? for shortcuts\n'
        hook SessionStart "{$base,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
        while IFS= read -r line; do
          hook UserPromptSubmit "{$base,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"task\"}"
          case "$line" in *fail*)
            hook StopFailure "{$base,\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"API Error: rate limited\"}"
            continue ;;
          esac
          answer=$(hook PermissionRequest "{$base,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\",\"description\":\"Run the tests\"},\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"make test\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]}")
          echo "answer: $answer"
          case "$answer" in *'"allow"'*) said="Tests pass";; *) said="Stopped, not allowed";; esac
          turn=$((turn + 1))
          echo "turn $turn: $said"
          hook Stop "{$base,\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"last_assistant_message\":\"$said\"}"
          printf '────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  ? for shortcuts\n'
        done
        """#
    }
}
#endif
