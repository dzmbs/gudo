import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import TerminalCore
import Testing
import GudoCore

/// Input typed into a pane while its host is down (This Mac's helper starting or started again,
/// a link reconnecting): held in order, within bounds, and sent once the pane is back, only to
/// the pane it was typed into and only once; otherwise dropped with a reason.
@MainActor
struct HeldInputTests {
    private func connection() throws -> (DaemonConnection, () -> FakeClient) {
        let client = Mutex<FakeClient?>(nil)
        let connection = DaemonConnection(hostId: "h", ticket: "t", session: 7) { _, listener in
            let fake = FakeClient(listener: listener)
            client.withLock { $0 = fake }
            return fake
        }
        try connection.connect()
        return (connection, { client.withLock { $0! } })
    }

    /// A pane as the app makes one: its terminal follows the stream, and held input is followed.
    private func pane(
        _ id: UInt64, on connection: DaemonConnection, client: FakeClient, holdLimit: Duration = DaemonPaneBackend.holdLimit
    ) -> (DaemonPaneBackend, HeldStates) {
        let backend = DaemonPaneBackend(pane: PaneId(id), client: client, router: connection.router, holdLimit: holdLimit)
        let screen = Terminal(cols: 80, rows: 24) { _ in }
        let states = HeldStates()
        backend.followHeldInput(screen: { screen.visibleText() }) { state in states.append(state) }
        backend.start { event in
            switch event {
            case .snapshot(let data): try? screen.restore(snapshot: data)
            case .output(let data): data.withUnsafeBytes { screen.write($0) }
            default: break
            }
        }
        return (backend, states)
    }

    private func snapshot(_ lines: [String]) throws -> Data {
        try #require(CachedPane(terminal: terminal(lines), title: "", cwd: nil).screen)
    }

    private func inputs(_ client: FakeClient, pane: UInt64? = nil) -> [String] {
        client.calls.compactMap { call in
            switch call {
            case .input(let id, let data) where pane == nil || id == pane: String(decoding: data, as: UTF8.self)
            case .paste(let id, let text) where pane == nil || id == pane: "paste:" + text
            default: nil
            }
        }
    }

    private func type(_ text: String, into backend: DaemonPaneBackend) {
        Array(text.utf8).withUnsafeBytes { backend.write($0) }
    }

    /// Live on run `epoch`, showing `lines`.
    private func goLive(_ client: FakeClient, epoch: UInt64, resumed: Bool, panes: [UInt64: [String]]) throws {
        client.send(.connected(epoch: epoch, resumed: resumed))
        for (pane, lines) in panes {
            client.send(.paneSnapshot(paneId: pane, seq: 0, data: try snapshot(lines)))
        }
    }

    @Test func inputWhileTheLinkIsDownIsSentOnceWhenThePaneIsBack() async throws {
        let (connection, client) = try connection()
        let (backend, states) = pane(1, on: connection, client: client())
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["$ "]])
        type("a", into: backend)
        #expect(inputs(client()) == ["a"], "live: straight through")

        client().send(.disconnected(reason: "helper stopped"))
        type("ls", into: backend)
        backend.paste(" -la")
        type("\r", into: backend)
        #expect(inputs(client()) == ["a"], "nothing goes to a link that is down")
        #expect(states.all == [.holding(1), .holding(2), .holding(3)])

        // The same run again: its stream resumes where it left off.
        client().send(.connected(epoch: 1, resumed: true))
        client().send(.paneStreaming(paneId: 1))
        try await eventually("sent") { states.all.last == .sent }
        #expect(inputs(client()) == ["a", "ls", "paste: -la", "\r"], "in order, once")
    }

    @Test func aHelperStartedAgainGetsTheInputWhenItsScreenReadsTheSame() async throws {
        let (connection, client) = try connection()
        let (backend, states) = pane(1, on: connection, client: client())
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["$ "]])
        client().send(.disconnected(reason: "helper stopped"))
        type("make\r", into: backend)

        try goLive(client(), epoch: 2, resumed: false, panes: [1: ["$ "]])
        try await eventually("sent") { states.all.last == .sent }
        #expect(inputs(client()) == ["make\r"])
    }

    @Test func aHelperStartedAgainNeverGetsKeysMeantForAScreenItNoLongerShows() async throws {
        let (connection, client) = try connection()
        let (backend, states) = pane(1, on: connection, client: client())
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["Allow rm -rf build? (y/n)"]])
        client().send(.disconnected(reason: "helper stopped"))
        type("y\r", into: backend)

        // The new run's pane shows something else: a stream that resumes is not enough.
        client().send(.connected(epoch: 2, resumed: false))
        client().send(.paneStreaming(paneId: 1))
        #expect(inputs(client()).isEmpty, "the new run's screen is not in yet")
        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try snapshot(["Allow git push --force? (y/n)"])))
        try await eventually("dropped") { states.all.last == .dropped(.screenChanged) }
        #expect(inputs(client()).isEmpty)
    }

    @Test func inputBeforeTheFirstConnectionIsTypeAheadIntoABlankPane() async throws {
        let (connection, client) = try connection()
        let (backend, states) = pane(1, on: connection, client: client())
        type("ls\r", into: backend)
        #expect(inputs(client()).isEmpty)
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["$ "]])
        try await eventually("sent") { states.all.last == .sent }
        #expect(inputs(client()) == ["ls\r"])
    }

    @Test func heldInputGoesOnlyToThePaneItWasTypedInto() async throws {
        let (connection, client) = try connection()
        let (first, firstStates) = pane(1, on: connection, client: client())
        let (second, secondStates) = pane(2, on: connection, client: client())
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["$ "], 2: ["$ "]])
        client().send(.disconnected(reason: "helper stopped"))
        type("one", into: first)
        type("two", into: second)
        client().send(.connected(epoch: 1, resumed: true))
        client().send(.paneStreaming(paneId: 2))
        try await eventually("second sent") { secondStates.all.last == .sent }
        #expect(inputs(client(), pane: 2) == ["two"])
        #expect(inputs(client(), pane: 1).isEmpty, "pane 1 is not back yet")
        client().send(.paneStreaming(paneId: 1))
        try await eventually("first sent") { firstStates.all.last == .sent }
        #expect(inputs(client(), pane: 1) == ["one"])
    }

    @Test func tooMuchTypedWhileDownIsDroppedNotCut() async throws {
        let (connection, client) = try connection()
        let (backend, states) = pane(1, on: connection, client: client())
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["$ "]])
        client().send(.disconnected(reason: "helper stopped"))
        backend.paste(String(repeating: "a", count: DaemonPaneBackend.holdBytes + 1))
        client().send(.connected(epoch: 1, resumed: true))
        client().send(.paneStreaming(paneId: 1))
        try await eventually("dropped") { states.all.last == .dropped(.tooMuch) }
        #expect(inputs(client()).isEmpty)
    }

    @Test func aPaneThatDoesNotComeBackDropsItsInputWithANote() async throws {
        let (connection, client) = try connection()
        let (backend, states) = pane(1, on: connection, client: client(), holdLimit: .milliseconds(200))
        try goLive(client(), epoch: 1, resumed: false, panes: [1: ["$ "]])
        client().send(.disconnected(reason: "helper stopped"))
        type("ls\r", into: backend)
        try await eventually("dropped") { states.all.last == .dropped(.tookTooLong) }

        // Coming back later sends nothing of it.
        client().send(.connected(epoch: 1, resumed: true))
        client().send(.paneStreaming(paneId: 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(inputs(client()).isEmpty)
    }
}
