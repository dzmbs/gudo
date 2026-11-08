import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import Testing
import TerminalCore
import GudoCore

/// The connection state machine and pane routing against a fake client.
@MainActor
@Suite struct DaemonConnectionTests {
    /// A connection whose dialer hands out a `FakeClient`.
    private func makeConnection() throws -> (DaemonConnection, () -> FakeClient) {
        let client = Mutex<FakeClient?>(nil)
        let connection = DaemonConnection(hostId: "h", ticket: "t", session: 7) { _, listener in
            let fake = FakeClient(listener: listener)
            client.withLock { $0 = fake }
            return fake
        }
        try connection.connect()
        return (connection, { client.withLock { $0! } })
    }

    @Test func sizingIdentityIsPerPaneAndClearedWhenThePaneOrConnectionEnds() async throws {
        let (connection, client) = try makeConnection()
        let state = PaneSizing(paneId: 3, peer: 42)
        client().send(.paneSizing(state: state))
        try await eventually("sizing identity") { connection.sizing[PaneId(3)] == state }
        client().send(.paneClosed(paneId: 3))
        try await eventually("closed pane has no sizing identity") { connection.sizing.isEmpty }
        client().send(.paneSizing(state: state))
        try await eventually("sizing identity returns") { !connection.sizing.isEmpty }
        client().send(.disconnected(reason: "test"))
        try await eventually("disconnected ownership is not live") { connection.sizing.isEmpty }
    }

    @Test func runAgainOffersFollowTheDaemonAndTypeTheCommand() async throws {
        let (connection, client) = try makeConnection()
        let devServer = RunAgainOffer(paneId: 3, command: "npm run dev")
        client().send(.runAgainOffers(offers: [devServer, RunAgainOffer(paneId: 4, command: "tail -f log")]))
        try await eventually("offers") { connection.runAgain.all.count == 2 }
        connection.runAgain(in: PaneId(3))
        #expect(client().calls.last == .runAgain(3, "npm run dev"))

        client().send(.runAgainOffers(offers: [devServer]))
        try await eventually("withdrawn offer") { connection.runAgain[PaneId(4)] == nil }
        #expect(connection.runAgain[PaneId(3)] == devServer)
        client().send(.paneClosed(paneId: 3))
        try await eventually("closed pane offers nothing") { connection.runAgain.isEmpty }
        connection.runAgain(in: PaneId(3))
        #expect(client().calls.last == .runAgain(3, "npm run dev"), "nothing more is typed")
    }

    @Test func connectAttachAndShowTheLayout() async throws {
        let (connection, client) = try makeConnection()
        #expect(connection.status == .connecting(.dialing))
        #expect(!connection.isReady)

        // Connected is not live yet: there is no session to show until its layout arrives.
        client().send(.connected(epoch: 1, resumed: false))
        try await eventually("opening the session") { connection.status == .connecting(.openingSession) }
        #expect(client().calls.contains(.attach(7)), "attaches the saved session")

        client().send(.attached(sessionId: 7, via: .requested, missing: nil))
        client().send(.layout(layout: sampleLayout()))
        try await eventually("layout") { connection.isReady && connection.status.isLive }
        #expect(connection.notice == nil)
        #expect(connection.layout.session.panes.count == 3)
        try await eventually("view pushed") { client().calls.contains(.setView(3, [1, 2, 3])) }

        // Layout ops go to the daemon.
        connection.layout.apply(.split(PaneId(3), .horizontal))
        #expect(client().calls.last == .op(.split(paneId: 3, axis: .horizontal, launch: .shell(cwd: nil))))
    }

    @Test func aPaneWhoseStreamNeverOpensIsShownLiveAfterTheGrace() async throws {
        let (connection, client) = try makeConnection()
        let sink = EventSink()
        try connection.makeBackend(for: PaneId(3)).start(events: sink.handler)
        client().send(.connected(epoch: 1, resumed: true))
        #expect(sink.lastConnection == .stale(reason: PaneRouter.catchingUp))
        try await eventually("the pane goes live without its stream", timeout: .seconds(6)) {
            sink.lastConnection == .live
        }
    }

    @Test func paneOutputInputAndHistory() async throws {
        let (connection, client) = try makeConnection()
        let backend = try connection.makeBackend(for: PaneId(3))
        // Output that arrives before the view starts is buffered.
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.paneSnapshot(paneId: 3, seq: 100, data: Data("SNAP".utf8)))
        client().send(.paneBytes(paneId: 3, seq: 100, data: Data("$ ".utf8)))
        client().send(.paneBytes(paneId: 9, seq: 0, data: Data("not mine".utf8)))

        let sink = EventSink()
        backend.start(events: sink.handler)
        #expect(client().calls.contains(.subscribe(3)))
        #expect(sink.all.first == .connection(.live))
        #expect(sink.all.contains(.snapshot(Data("SNAP".utf8))))
        #expect(sink.output == "$ ")

        // Input goes out; the daemon's ack reaches the predictor after the echo it implies.
        let predictions = PredictionSink()
        let feed = try #require(backend as? any PredictionFeed)
        feed.startPredictionFeed(predictions.handler)
        #expect(predictions.all == [.hint(nil)], "nothing is predicted before the daemon's first hint")
        Array("l".utf8).withUnsafeBytes { feed.writeInput($0, inputSeq: 1) }
        #expect(client().calls.last == .input(3, Data("l".utf8)))
        client().send(.inputAck(paneId: 3, inputSeq: 1, atSeq: 102))
        #expect(!predictions.all.contains { if case .acknowledged = $0 { true } else { false } }, "waits for the echo")
        client().send(.paneBytes(paneId: 3, seq: 102, data: Data("l".utf8)))
        #expect(predictions.all.last == .acknowledged(upTo: 1, hint: nil))
        #expect(predictions.all.contains { if case .rtt = $0 { true } else { false } })
        try await eventually("echo rtt") { connection.echoRoundTrip != nil }
        // Input that prints nothing is acked after a short grace.
        Array("\u{1b}".utf8).withUnsafeBytes { feed.writeInput($0, inputSeq: 2) }
        client().send(.inputAck(paneId: 3, inputSeq: 2, atSeq: 103))
        try await eventually("grace ack") { predictions.all.last == .acknowledged(upTo: 2, hint: nil) }

        backend.paste("multi\nline")
        #expect(client().calls.last == .paste(3, "multi\nline"))

        // History extends the current snapshot only.
        #expect(backend.requestHistory())
        client().send(.paneHistory(paneId: 3, snapshotSeq: 99, data: Data("old".utf8), rows: 0, done: false))
        client().send(.paneHistory(paneId: 3, snapshotSeq: 100, data: Data("page".utf8), rows: 0, done: true))
        #expect(sink.all.filter { if case .history = $0 { true } else { false } } == [.history(Data("page".utf8), done: true)])

        // Echo hints reach the predictor, in-band resizes the pane.
        client().send(.echoHint(hint: GudoCore.EchoHint(paneId: 3, echo: true, icanon: false, altScreen: false, atPrompt: true, atSeq: 104, prediction: .allow)))
        #expect(predictions.all.last == .hint(TerminalCore.EchoHint(echo: true, canonical: false, atPrompt: true, altScreen: false)))
        client().send(.paneResized(paneId: 3, seq: 105, size: PaneSize(cols: 100, rows: 30, widthPx: 1000, heightPx: 600)))
        #expect(sink.all.last == .resized(cols: 100, rows: 30, cellWidth: 10, cellHeight: 20))

        backend.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        #expect(client().calls.last == .resize(3, PaneSize(cols: 120, rows: 40, widthPx: 1200, heightPx: 800)))

        backend.terminate()
        #expect(client().calls.last == .unsubscribe(3))
        client().send(.paneBytes(paneId: 3, seq: 200, data: Data("late".utf8)))
        #expect(!sink.output.contains("late"))
    }

    /// A link that still says it is up gets checked: when typing gets no ack within a second,
    /// and when the app comes back to the foreground. An acknowledged keystroke checks nothing.
    @Test func aLinkThatLooksUpIsProbed() async throws {
        let (connection, client) = try makeConnection()
        let backend = try connection.makeBackend(for: PaneId(3))
        backend.start(events: EventSink().handler)
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.layout(layout: sampleLayout(revision: 9)))
        try await eventually("live") { connection.status.isLive }

        Array("a".utf8).withUnsafeBytes { backend.write($0) }
        client().send(.inputAck(paneId: 3, inputSeq: 1, atSeq: 1))
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!client().calls.contains(.probe), "an acknowledged keystroke")

        Array("b".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("a keystroke without an ack probes", timeout: .seconds(3)) { client().calls.contains(.probe) }

        client().clear()
        connection.foreground()
        #expect(client().calls == [.probe], "back in front: probed, not redialled")
    }

    /// Never blank, never silently dead: a drop dims the pane and the status says why; the
    /// reconnect brings it back; background suspends and foreground resumes.
    @Test func dropReconnectSuspendResume() async throws {
        let (connection, client) = try makeConnection()
        let sink = EventSink()
        try connection.makeBackend(for: PaneId(1)).start(events: sink.handler)
        #expect(sink.lastConnection == .stale(reason: "Connecting…"))

        client().send(.connected(epoch: 1, resumed: false))
        #expect(sink.lastConnection == .stale(reason: PaneRouter.catchingUp))
        client().send(.paneStreaming(paneId: 1))
        #expect(sink.lastConnection == .live)
        client().send(.layout(layout: sampleLayout(revision: 9)))
        try await eventually("ready") { connection.isReady }

        client().send(.disconnected(reason: "timed out"))
        #expect(sink.lastConnection == .stale(reason: "timed out"))
        try await eventually("reconnecting") { connection.status == .reconnecting(attempt: 1, reason: "timed out") }
        #expect(connection.status.summary.contains("timed out"))

        client().send(.connected(epoch: 1, resumed: true))
        #expect(sink.lastConnection == .stale(reason: PaneRouter.catchingUp), "dimmed until the daemon streams it again")
        client().send(.paneStreaming(paneId: 1))
        #expect(sink.lastConnection == .live)
        try await eventually("live again") { connection.status.isLive }
        #expect(client().calls.filter { $0 == .attach(7) }.count == 1, "client-core re-attaches by itself")

        connection.background()
        #expect(client().calls.last == .suspend)
        #expect(connection.status == .suspended)
        #expect(sink.lastConnection == .stale(reason: "Paused"))
        // The disconnect the suspend causes does not turn into "reconnecting".
        client().send(.disconnected(reason: "suspend"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(connection.status == .suspended)

        connection.foreground()
        #expect(client().calls.last == .reconnect)
        // A daemon restart (new epoch) resets layout revisions.
        client().send(.connected(epoch: 2, resumed: true))
        client().send(.layout(layout: sampleLayout(revision: 1, focused: 1)))
        try await eventually("new layout after restart") { connection.layout.session.activeTab?.focused == PaneId(1) }

        // Refusal needs the user; retry redials.
        client().send(.refused(reason: "device not allowed"))
        try await eventually("needs attention") { connection.status.needsUser }
        connection.retry()
        #expect(client().calls.last == .reconnect)
        #expect(connection.status == .connecting(.dialing))
    }

    /// The remembered session is gone (closed elsewhere, or the daemon's state was reset): the
    /// daemon attaches the most recent one, and the user is told once.
    @Test func goneSessionIsReplacedAndTheUserIsTold() async throws {
        let (connection, client) = try makeConnection()
        var saved: UInt64?
        connection.onAttached = { saved = $0 }
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.attached(sessionId: 2, via: .mostRecent, missing: 7))
        client().send(.layout(layout: sampleLayout()))
        try await eventually("live") { connection.status.isLive }
        #expect(saved == 2, "the host record remembers the new session")
        #expect(connection.notice?.text == "Your previous session ended. Showing the most recent one.")
        connection.dismissNotice()
        #expect(connection.notice == nil)
    }

    /// The attached session closes under the connection (another device, the CLI): its tabs go at
    /// once, with nothing pending replayed over them, and the connection attaches anew.
    @Test func aClosedSessionNeverLeavesItsTabsBehind() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.attached(sessionId: 7, via: .requested, missing: nil))
        client().send(.layout(layout: sampleLayout()))
        try await eventually("live") { connection.isReady && connection.status.isLive }
        let session = try #require(connection.layout.sessionId)
        // A pending optimistic op on a tab of that session.
        connection.layout.apply(.rename(TabId(1), "renamed"))

        client().send(.sessions(sessions: [SessionSummary(sessionId: session, name: "main", tabs: 1, panes: 3, clients: 1)]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!connection.layout.session.tabs.isEmpty, "a list that still has the session changes nothing")

        let attaches = client().calls.filter { if case .attach = $0 { true } else { false } }.count
        client().send(.sessions(sessions: [SessionSummary(sessionId: session + 1, name: "other", tabs: 1, panes: 1, clients: 0)]))
        try await eventually("tabs gone") { connection.layout.session.tabs.isEmpty }
        #expect(connection.layout.sessionId == nil)
        #expect(client().calls.filter { if case .attach = $0 { true } else { false } }.count == attaches + 1)
        #expect(client().calls.contains(.attach(nil)), "attaches whatever the host has now")
    }

    /// Nothing to attach to (a guest whose session ended): needs the user, with words, never
    /// "Connected" with nothing on screen.
    @Test func attachFailureNeedsTheUser() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.attachFailed(code: .notFound, message: "nothing to attach to in this grant's scope"))
        try await eventually("needs attention") { connection.status.needsUser }
        #expect(connection.status == .needsAttention(reason: "The session you were invited to has ended."))
        #expect(!connection.isReady)
    }

    @Test func blockedAgentsAreTracked() async throws {
        let (connection, client) = try makeConnection()
        let meta = PaneMeta(
            paneId: 2, title: "claude", cwd: "/src", exit: nil,
            agent: AgentStatus(kind: "claude", state: .blocked(requestId: 4, summary: "rm -rf build", options: [DecisionOption(id: 1, label: "Allow")])),
            size: PaneSize(cols: 80, rows: 24, widthPx: 0, heightPx: 0), sizePolicy: .lastInput, sizedBy: nil)
        client().send(.paneMeta(meta: meta))
        try await eventually("meta") { connection.blockedAgents.count == 1 }
        connection.decide(requestId: 4, optionId: 1)
        #expect(client().calls.last == .decide(4, 1))
        client().send(.paneClosed(paneId: 2))
        try await eventually("closed") { connection.blockedAgents.isEmpty }
    }

    @Test func programReportsAreTrackedButAreNoApprovals() async throws {
        let (connection, client) = try makeConnection()
        let report = ProgramReport(state: .blocked, kind: .question, app: "pi", message: "Which framework?", progress: nil)
        client().send(.programStatus(paneId: 3, status: report))
        try await eventually("report") { connection.programs[PaneId(3)] == report }
        #expect(connection.blockedAgents.isEmpty)
        client().send(.programStatus(paneId: 3, status: nil))
        try await eventually("cleared") { connection.programs.isEmpty }
        client().send(.programStatus(paneId: 3, status: report))
        try await eventually("again") { connection.programs[PaneId(3)] == report }
        client().send(.paneClosed(paneId: 3))
        try await eventually("closed") { connection.programs.isEmpty }
    }
}
