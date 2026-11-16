import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import Testing
import GudoCore

/// A daemon pane learns what runs in front of its terminal from the daemon's pushes, in each
/// window's tap, until the tap ends.
struct ForegroundProgramTests {
    private nonisolated final class Seen: Sendable {
        private let programs = Mutex<[ForegroundProgram?]>([])
        var all: [ForegroundProgram?] { programs.withLock { $0 } }
        func append(_ program: ForegroundProgram?) { programs.withLock { $0.append(program) } }
    }

    private nonisolated final class Quiet: ClientEventListener {
        func onEvent(event: ClientEvent) {}
    }

    private func foreground(_ pane: UInt64, _ argv: [String]) -> Foreground {
        Foreground(paneId: pane, pid: 42, name: argv.first ?? "", argv: argv, profile: .other, sinceMs: 0)
    }

    @Test func pushesReachEveryTapOfThePaneUntilItEnds() {
        let client = FakeClient(listener: Quiet())
        let router = PaneRouter()
        let first = DaemonPaneBackend(pane: PaneId(7), client: client, router: router)
        let second = DaemonPaneBackend(pane: PaneId(7), client: client, router: router)
        let other = DaemonPaneBackend(pane: PaneId(8), client: client, router: router)
        let (seenFirst, seenSecond, seenOther) = (Seen(), Seen(), Seen())
        first.onForegroundProgramChange { seenFirst.append($0) }
        second.onForegroundProgramChange { seenSecond.append($0) }
        other.onForegroundProgramChange { seenOther.append($0) }

        let argv = ["node", "/opt/pi/node_modules/.bin/pi", "--continue"]
        client.push(foreground(7, argv))
        let pi = ForegroundProgram(name: "node", arguments: argv)
        #expect(seenFirst.all == [pi])
        #expect(seenSecond.all == [pi])
        #expect(seenOther.all.isEmpty)

        first.terminate()
        client.push(foreground(7, ["vim", "README.md"]))
        #expect(seenFirst.all == [pi])
        #expect(seenSecond.all == [pi, ForegroundProgram(name: "vim", arguments: ["vim", "README.md"])])
    }

    @Test func aTapStartsFromWhatTheConnectionKnowsElseAsksOnce() async throws {
        let client = FakeClient(listener: Quiet())
        client.push(foreground(7, ["htop"]))
        let router = PaneRouter()
        let seen = Seen()
        DaemonPaneBackend(pane: PaneId(7), client: client, router: router).onForegroundProgramChange { seen.append($0) }
        #expect(seen.all == [ForegroundProgram(name: "htop", arguments: ["htop"])])
        #expect(client.assist.withLock { $0.asked }.isEmpty)

        DaemonPaneBackend(pane: PaneId(9), client: client, router: router).onForegroundProgramChange { _ in }
        for _ in 0..<500 where client.assist.withLock({ $0.asked }).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.assist.withLock { $0.asked } == [9])
    }
}
