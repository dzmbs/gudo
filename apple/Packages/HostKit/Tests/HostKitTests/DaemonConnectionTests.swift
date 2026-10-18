import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import Testing
import UnnamedCore

/// The connection state machine and pane routing against a fake client (04-mobile-ux R1–R12).
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

    @Test func connectAttachAndShowTheLayout() async throws {
        let (connection, client) = try makeConnection()
        #expect(connection.status == .connecting)
        #expect(!connection.isReady)

        client().send(.connected(epoch: 1, resumed: false))
        try await eventually("connected") { connection.status.isLive }
        #expect(client().calls.contains(.attach(7)), "attaches the saved session")

        client().send(.layout(layout: sampleLayout()))
        try await eventually("layout") { connection.isReady }
        #expect(connection.layout.session.panes.count == 3)
        try await eventually("view pushed") { client().calls.contains(.setView(3, [1, 2, 3])) }

        // Layout ops go to the daemon.
        connection.layout.apply(.split(PaneId(3), .horizontal))
        #expect(client().calls.last == .op(.split(paneId: 3, axis: .horizontal, launch: .shell(cwd: nil))))
    }

    @Test func paneOutputInputAndHistory() async throws {
        let (connection, client) = try makeConnection()
        let backend = try connection.makeBackend(for: PaneId(3))
        // Output that arrives before the view starts is buffered (R12).
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

        // Input goes out; its echo and ack give round trips.
        Array("ls\r".utf8).withUnsafeBytes { backend.write($0) }
        #expect(client().calls.last == .input(3, Data("ls\r".utf8)))
        client().send(.paneBytes(paneId: 3, seq: 102, data: Data("ls\r\n".utf8)))
        client().send(.inputAck(paneId: 3, inputSeq: 1, atSeq: 102))
        guard case .inputAck(102, let rtt)? = sink.all.last else { Issue.record("no ack: \(sink.all)"); return }
        #expect(rtt != nil)
        try await eventually("echo rtt") { connection.echoRoundTrip != nil }

        backend.paste("multi\nline")
        #expect(client().calls.last == .paste(3, "multi\nline"))

        // History extends the current snapshot only.
        #expect(backend.requestHistory())
        client().send(.paneHistory(paneId: 3, snapshotSeq: 99, data: Data("old".utf8), rows: 0, done: false))
        client().send(.paneHistory(paneId: 3, snapshotSeq: 100, data: Data("page".utf8), rows: 0, done: true))
        #expect(sink.all.filter { if case .history = $0 { true } else { false } } == [.history(Data("page".utf8), done: true)])

        // Echo hints and in-band resizes reach the pane.
        client().send(.echoHint(hint: EchoHint(paneId: 3, echo: true, icanon: false, altScreen: false, atPrompt: true, atSeq: 104, prediction: .allow)))
        #expect(sink.all.last == .echo(EchoState(echo: true, canonical: false, alternateScreen: false, atPrompt: true, predict: true, atSeq: 104)))
        client().send(.paneResized(paneId: 3, seq: 105, size: PaneSize(cols: 100, rows: 30, widthPx: 0, heightPx: 0)))
        #expect(sink.all.last == .resized(cols: 100, rows: 30))

        backend.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        #expect(client().calls.last == .resize(3, PaneSize(cols: 120, rows: 40, widthPx: 1200, heightPx: 800)))

        backend.terminate()
        #expect(client().calls.last == .unsubscribe(3))
        client().send(.paneBytes(paneId: 3, seq: 200, data: Data("late".utf8)))
        #expect(!sink.output.contains("late"))
    }

    /// Never blank, never silently dead: a drop dims the pane and the status says why; the
    /// reconnect brings it back; background suspends and foreground resumes (R5, R10).
    @Test func dropReconnectSuspendResume() async throws {
        let (connection, client) = try makeConnection()
        let sink = EventSink()
        try connection.makeBackend(for: PaneId(1)).start(events: sink.handler)
        #expect(sink.lastConnection == .stale(reason: "Connecting…"))

        client().send(.connected(epoch: 1, resumed: false))
        #expect(sink.lastConnection == .live)
        client().send(.layout(layout: sampleLayout(revision: 9)))
        try await eventually("ready") { connection.isReady }

        client().send(.disconnected(reason: "timed out"))
        #expect(sink.lastConnection == .stale(reason: "timed out"))
        try await eventually("reconnecting") { connection.status == .reconnecting(attempt: 1, reason: "timed out") }
        #expect(connection.status.summary.contains("timed out"))

        client().send(.connected(epoch: 1, resumed: true))
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
        #expect(connection.status == .connecting)
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
}
