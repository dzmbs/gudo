import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import TerminalCore
import Testing
import GudoCore

/// The client under connection churn: many hosts at once, hosts that freeze, die and come
/// back, a resume with a big backlog, and connections and panes opened and closed over and
/// over. Each prints its peaks and checks that what the client shows converges with the host.
@MainActor
@Suite(.serialized, .enabled(if: stressEnabled)) struct ConnectionChurnTests {
    let stress = ClientStressTests()

    func ticker(_ pane: MirrorPane) {
        // A child shell, so ^C ends the whole loop (an interactive sh only ends the sleep).
        pane.type("sh -c 'i=0; while :; do i=$((i+1)); echo tick $i; sleep 0.02; done'\r")
    }

    /// A second device's fresh view of a pane: what the host has, to compare with.
    func freshView(_ ticket: String, pane: PaneId) async throws -> (HostsModel, DaemonConnection, MirrorPane) {
        let model = stress.makeModel()
        let (connection, _) = try await stress.host(ticket, model: model)
        let view = MirrorPane(try connection.makeBackend(for: pane))
        try await eventually("fresh view", timeout: .seconds(10)) { view.snapshots > 0 }
        try await stress.quiesce(view)
        return (model, connection, view)
    }

    @Test func manyHostsInOneWindow() async throws {
        let count = heavyStress ? 20 : 8
        let baseline = (Gauge.footprint(), Gauge.threads(), Gauge.fds())
        let model = stress.makeModel()
        var daemons: [LocalDaemon] = []
        var hosts: [(DaemonConnection, MirrorPane)] = []
        let window = NSObject()
        for _ in 0..<count {
            let daemon = try LocalDaemon()
            daemons.append(daemon)
            let (connection, panes) = try await stress.host(try await daemon.ticket(), model: model)
            let pane = MirrorPane(try connection.makeBackend(for: panes[0]))
            connection.setWindowView(window, focused: panes[0], visible: panes)
            hosts.append((connection, pane))
        }
        try await eventually("all panes up", timeout: .seconds(20)) { hosts.allSatisfy { $0.1.snapshots > 0 } }
        let connected = (Gauge.footprint(), Gauge.threads(), Gauge.fds())
        let peaks = Peaks()
        // A quarter flood, a quarter tick, the rest idle; the last takes probe keystrokes.
        for (i, host) in hosts.enumerated() where i < count - 1 {
            if i % 4 == 0 { host.1.type("yes\r") } else if i % 4 == 1 { ticker(host.1) }
        }
        let probe = hosts[count - 1].1
        let letters = Array("abcdefghijklmnopqrstuvwxz".utf8)
        let start = ContinuousClock.now
        var i = 0
        while ContinuousClock.now - start < .seconds(heavyStress ? 60 : 10) {
            try await Task.sleep(for: .milliseconds(100))
            if probe.outstandingProbes == 0 {
                probe.type("\u{7f}")
                probe.probe(letters[i % letters.count])
                i += 1
            }
        }
        for host in hosts { host.1.type("\u{03}") }
        let during = peaks.stop()
        for host in hosts { try await stress.quiesce(host.1) }
        let ids = model.records.map(\.id)
        for host in hosts { host.1.backend.terminate() }
        for id in ids { model.disconnect(id) }
        hosts.removeAll()
        try await Task.sleep(for: .seconds(3))
        let closed = (Gauge.footprint(), Gauge.threads(), Gauge.fds())
        print("""
            [stress] \(count) hosts: before \(Gauge.mb(baseline.0)) / \(baseline.1) threads / \(baseline.2) fds; connected \(Gauge.mb(connected.0)) / \(connected.1) / \(connected.2); closed \(Gauge.mb(closed.0)) / \(closed.1) / \(closed.2)
              peaks: \(during)
              probe echo on host \(count): \(probe.latencies.summary)
            """)
        #expect(during.hangMs < 250)
        // The core's runtime keeps a few of its own once started (about 6); each host held ~3.
        #expect(closed.2 <= baseline.2 + 8, "fds left behind: \(closed.2) vs \(baseline.2)")
        for daemon in daemons { daemon.kill() }
    }

    /// The host freezes for a second at a time, then for longer than the idle timeout, then
    /// is killed and restarted over and over. Afterwards the client shows what the host has
    /// and typing works.
    @Test func flappingHost() async throws {
        let daemon = try LocalDaemon()
        let model = stress.makeModel()
        let (connection, panes) = try await stress.host(try await daemon.ticket(), model: model)
        let window = NSObject()
        connection.setWindowView(window, focused: panes[0], visible: panes)
        let pane = MirrorPane(try connection.makeBackend(for: panes[0]))
        try await eventually("prompt", timeout: .seconds(10)) { pane.snapshots > 0 }
        ticker(pane)
        try await Task.sleep(for: .seconds(1))
        let baseline = (Gauge.threads(), Gauge.fds())
        let stats = { (connection.client as? DaemonClient)?.stats().connections ?? 0 }
        let peaks = Peaks()
        for _ in 0..<(heavyStress ? 60 : 10) {
            daemon.send(SIGSTOP)
            try await Task.sleep(for: .seconds(1))
            daemon.send(SIGCONT)
            try await Task.sleep(for: .seconds(1))
        }
        let afterFlaps = stats()
        daemon.send(SIGSTOP)
        try await Task.sleep(for: .seconds(heavyStress ? 60 : 25))
        let stalled = connection.status
        daemon.send(SIGCONT)
        try await eventually("back after a long freeze", timeout: .seconds(30)) { connection.status.isLive && pane.connection == .live }
        let afterFreeze = stats()
        for _ in 0..<(heavyStress ? 20 : 5) {
            daemon.kill()
            try await Task.sleep(for: .milliseconds(500))
            try daemon.start()
            try await Task.sleep(for: .seconds(2))
        }
        try await eventually("live after restarts", timeout: .seconds(30)) { connection.status.isLive && pane.connection == .live }
        let during = peaks.stop()
        try await Task.sleep(for: .seconds(2))
        let after = (Gauge.threads(), Gauge.fds())
        // The shell restarted with the daemon: type, then compare with a fresh device's view.
        pane.type("echo flap-$((5*5))\r")
        try await eventually("typing works", timeout: .seconds(15)) { pane.tail.contains("flap-25") }
        try await stress.quiesce(pane)
        let (otherModel, other, view) = try await freshView(try await daemon.ticket(), pane: panes[0])
        print("""
            [stress] flapping host: connections \(afterFlaps) after 1 s freezes, \(afterFreeze) after a long freeze (status then: \(stalled)), \(stats()) after restarts
              peaks: \(during); threads \(baseline.0)→\(after.0), fds \(baseline.1)→\(after.1)
            """)
        #expect(pane.terminal.visibleText() == view.terminal.visibleText(), "the client shows what the host has")
        #expect(after.1 <= baseline.1 + 4, "fds left behind")
        view.backend.terminate()
        other.close()
        _ = otherModel
        pane.backend.terminate()
        connection.close()
    }

    /// The app is away (suspended) while the pane prints a lot, then comes back.
    @Test func resumeWithABigBacklog() async throws {
        let daemon = try LocalDaemon()
        let model = stress.makeModel()
        let inputs = try ClientStressTests.floodInputs()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let (connection, panes) = try await stress.host(try await daemon.ticket(), model: model)
        let window = NSObject()
        connection.setWindowView(window, focused: panes[0], visible: panes)
        let pane = MirrorPane(try connection.makeBackend(for: panes[0]))
        try await eventually("prompt", timeout: .seconds(10)) { pane.snapshots > 0 }
        connection.background()
        pane.type(ClientStressTests.Flood.text.command(inputs) + "\r")  // queued, sent on resume
        connection.foreground()
        try await eventually("flooding", timeout: .seconds(10)) { pane.bytes > 1 << 20 }
        connection.background()
        try await Task.sleep(for: .seconds(heavyStress ? 60 : 15))
        let peaks = Peaks()
        let resumed = ContinuousClock.now
        let before = (pane.bytes, pane.snapshots)
        connection.foreground()
        try await eventually("live", timeout: .seconds(20)) { connection.status.isLive && pane.connection == .live }
        let live = ContinuousClock.now - resumed
        try await eventually("caught up", timeout: .seconds(20)) { pane.snapshots > before.1 || pane.bytes > before.0 }
        let firstPaint = ContinuousClock.now - resumed
        #expect(live < .seconds(3), "live \(live) after resuming over a backlog")
        #expect(firstPaint < .seconds(3), "first paint \(firstPaint) after resuming over a backlog")
        pane.type("\u{03}")
        try await stress.quiesce(pane)
        let during = peaks.stop()
        pane.type("clear; echo resumed-$((8*8))\r")
        try await eventually("typing works", timeout: .seconds(15)) { pane.tail.contains("resumed-64") }
        try await stress.quiesce(pane)
        let (otherModel, other, view) = try await freshView(try await daemon.ticket(), pane: panes[0])
        print("""
            [stress] resume after \(heavyStress ? 60 : 15) s away mid-flood: live in \(live), first new paint in \(firstPaint), \(pane.snapshots - before.1) snapshots and \(Gauge.mb(UInt64(pane.bytes - before.0))) of bytes after resuming
              peaks: \(during)
            """)
        #expect(pane.terminal.visibleText() == view.terminal.visibleText(), "the client shows what the host has")
        view.backend.terminate()
        other.close()
        _ = otherModel
        pane.backend.terminate()
        connection.close()
    }

    /// Waits for `marker` in a pane's output; on timeout says what the pane got.
    func waitForEcho(_ pane: MirrorPane, _ marker: String) async throws {
        do {
            // Bytes, or a snapshot taken after the echo.
            try await eventually(marker, timeout: .seconds(10)) { pane.tail.contains(marker) || pane.terminal.visibleText().contains("\n\(marker)\n") }
        } catch {
            throw TestError("no echo of \(marker): \(pane.snapshots) snapshots, \(pane.bytes) bytes, \(String(describing: pane.connection)), screen \(pane.terminal.visibleText().debugDescription)")
        }
    }

    /// Panes and connections opened and closed over and over: memory, threads and fds level
    /// off instead of growing with the count.
    @Test func openAndCloseRepeatedly() async throws {
        let daemon = try LocalDaemon()
        let model = stress.makeModel()
        let ticket = try await daemon.ticket()
        let (connection, panes) = try await stress.host(ticket, model: model)
        let window = NSObject()
        connection.setWindowView(window, focused: panes[0], visible: panes)
        let rounds = heavyStress ? 200 : 30
        var samples: [String] = []
        var first: (UInt64, Int, Int)?
        for round in 1...rounds {
            let base = try #require(connection.layout.session.activeTab?.focused)
            let count = connection.layout.session.panes.count
            connection.layout.apply(.split(base, .horizontal))
            try await eventually("split", timeout: .seconds(10)) { connection.layout.session.panes.count > count }
            let new = try #require(connection.layout.session.panes.subtracting([base]).first)
            let pane = MirrorPane(try connection.makeBackend(for: new))
            pane.type("echo round-\(round)\r")
            try await waitForEcho(pane, "round-\(round)")
            connection.layout.apply(.close(new))
            try await eventually("closed", timeout: .seconds(10)) { connection.layout.session.panes.count == count }
            pane.backend.terminate()
            if round == 5 { first = (Gauge.footprint(), Gauge.threads(), Gauge.fds()) }
            if round % 10 == 0 { samples.append("\(round): \(Gauge.mb(Gauge.footprint())) \(Gauge.threads())t \(Gauge.fds())fd") }
        }
        let panesDone = (Gauge.footprint(), Gauge.threads(), Gauge.fds())
        // Connections: reconnect the same host over and over, a pane on screen each time.
        let hostId = try #require(model.records.first?.id)
        model.disconnect(hostId)
        for round in 1...(heavyStress ? 100 : 15) {
            let conn = try #require(try model.open(hostId) as? DaemonConnection)
            try await eventually("live", timeout: .seconds(15)) { conn.status.isLive && conn.layout.hasLayout }
            let focused = try #require(conn.layout.session.activeTab?.focused)
            let pane = MirrorPane(try conn.makeBackend(for: focused))
            pane.type("echo conn-\(round)\r")
            try await waitForEcho(pane, "conn-\(round)")
            pane.backend.terminate()
            model.disconnect(hostId)
            if round % 5 == 0 { samples.append("conn \(round): \(Gauge.mb(Gauge.footprint())) \(Gauge.threads())t \(Gauge.fds())fd") }
        }
        try await Task.sleep(for: .seconds(3))
        let end = (Gauge.footprint(), Gauge.threads(), Gauge.fds())
        print("""
            [stress] open/close: \(rounds) panes then connections; at round 5 \(first.map { "\(Gauge.mb($0.0)) \($0.1)t \($0.2)fd" } ?? "-"), after panes \(Gauge.mb(panesDone.0)) \(panesDone.1)t \(panesDone.2)fd, end \(Gauge.mb(end.0)) \(end.1)t \(end.2)fd
              \(samples.joined(separator: "\n  "))
            """)
        if let pause = ProcessInfo.processInfo.environment["GUDO_STRESS_PAUSE"].flatMap(Int.init) {
            // Time to look at the process from outside: leaks, vmmap --summary, lsof -p.
            print("[stress] pid \(getpid()) paused for \(pause) s")
            if let file = ProcessInfo.processInfo.environment["GUDO_STRESS_PID_FILE"] {
                try "\(getpid())\n".write(toFile: file, atomically: true, encoding: .utf8)
            }
            try await Task.sleep(for: .seconds(pause))
        }
        if let first {
            #expect(end.2 <= first.2 + 4, "fds grow with connections: \(first.2) → \(end.2)")
            #expect(end.1 <= first.1 + 8, "threads grow: \(first.1) → \(end.1)")
        }
    }
}
