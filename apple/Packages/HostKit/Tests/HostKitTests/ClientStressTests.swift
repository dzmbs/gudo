import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import TerminalCore
import Testing
import GudoCore

/// Heavy load on the client side of a daemon connection: floods into the client's terminal
/// through `DaemonPaneBackend`, history and view storms, connection churn, many hosts. Each
/// prints its peaks (footprint, threads, fds, main-thread hang, CPU, input latency).
///
/// Run alone against a release daemon: `GUDO_STRESS=1 GUDO_HOSTD_BIN=<release gudo-hostd>
/// swift test --no-parallel --filter 'ClientStressTests|ConnectionChurnTests'`;
/// `GUDO_STRESS=heavy` runs the long variants.
@MainActor
@Suite(.serialized, .enabled(if: stressEnabled)) struct ClientStressTests {
    func makeModel() -> HostsModel {
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        return HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
    }

    /// A paired host with `panes` panes in its first tab.
    func host(_ ticket: String, model: HostsModel, panes: Int = 1) async throws -> (DaemonConnection, [PaneId]) {
        let hostId = try await model.pair(try PairingTicket(ticket), name: "stress")
        let connection = try #require(model.connection(hostId) as? DaemonConnection)
        while connection.layout.session.panes.count < panes {
            let count = connection.layout.session.panes.count
            let focused = try #require(connection.layout.session.activeTab?.focused)
            connection.layout.apply(.split(focused, .horizontal))
            try await eventually("split", timeout: .seconds(10)) { connection.layout.session.panes.count > count }
        }
        return (connection, connection.layout.session.panes.sorted { $0.rawValue < $1.rawValue })
    }

    enum Flood: String, CaseIterable {
        case yes, text, random, cjk

        /// The command that floods, given a scratch directory with the input files.
        func command(_ dir: URL) -> String {
            switch self {
            case .yes: "yes"
            case .text: "while :; do cat \(dir.path)/text; done"
            case .random: "head -c 4000000000 /dev/urandom"
            case .cjk: "while :; do cat \(dir.path)/cjk; done"
            }
        }

        /// Whether probe letters can be told apart from the flood's own output.
        var probesInSamePane: Bool { self == .yes || self == .cjk }
    }

    static func floodInputs() throws -> URL {
        let dir = temporaryDirectory()
        var text = ""
        for i in 0..<4000 { text += "\(i) compiling module_\(i % 97).rs ... ok [\(String(repeating: "=", count: i % 60))]\n" }
        let textData = Data(text.utf8)
        var big = Data()
        while big.count < 32 << 20 { big.append(textData) }
        try big.write(to: dir.appending(path: "text"))
        let line = "漢字かな交じり文😀👩‍👩‍👧‍👦🇯🇵 中文字符测试 한국어 텍스트 ✨🔥🚀 עברית\n"
        var cjk = Data()
        let lineData = Data(line.utf8)
        while cjk.count < 16 << 20 { cjk.append(lineData) }
        try cjk.write(to: dir.appending(path: "cjk"))
        return dir
    }

    /// One pane floods for `seconds` while another takes probe keystrokes (and the flooding
    /// pane too where its output allows). Prints throughput, peaks and echo latency.
    func flood(_ kind: Flood, seconds: Int, focusFlood: Bool) async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let inputs = try Self.floodInputs()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let (connection, panes) = try await host(try await daemon.ticket(), model: model, panes: 2)
        let flooding = MirrorPane(try connection.makeBackend(for: panes[0]))
        let quiet = MirrorPane(try connection.makeBackend(for: panes[1]))
        let window = NSObject()
        connection.setWindowView(window, focused: focusFlood ? panes[0] : panes[1], visible: panes)
        try await eventually("prompts", timeout: .seconds(10)) { flooding.snapshots > 0 && quiet.snapshots > 0 }
        try await Task.sleep(for: .milliseconds(300))
        let baseline = Gauge.footprint()

        let peaks = Peaks()
        flooding.type(kind.command(inputs) + "\r")
        let start = ContinuousClock.now
        let letters = Array("abcdefghijklmnopqrstuvwxz".utf8)
        let sameLetters = Array("QRSTUVWXZ".utf8)
        var i = 0
        while ContinuousClock.now - start < .seconds(seconds) {
            try await Task.sleep(for: .milliseconds(100))
            if quiet.outstandingProbes == 0 {
                quiet.type("\u{7f}")
                quiet.probe(letters[i % letters.count])
            }
            if kind.probesInSamePane, flooding.outstandingProbes == 0 {
                flooding.probe(sameLetters[i % sameLetters.count])
            }
            i += 1
        }
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        let delivered = flooding.bytes
        flooding.type("\u{03}")
        let during = peaks.stop()
        let stopped = ContinuousClock.now
        try await quiesce(flooding)
        let drain = ContinuousClock.now - stopped
        try await Task.sleep(for: .seconds(2))
        let after = Gauge.footprint()
        print("""
            [stress] flood \(kind.rawValue) \(seconds)s, \(focusFlood ? "flooding pane focused" : "quiet pane focused"): \(String(format: "%.1f", Double(delivered) / elapsed / 1_048_576)) MB/s of bytes into the client terminal, \(flooding.snapshots) snapshots
              peaks: \(during)
              drained \(drain) after ^C
              footprint baseline \(Gauge.mb(baseline)), after \(Gauge.mb(after))
              other pane echo: \(quiet.latencies.summary) (unanswered \(quiet.outstandingProbes))
              same pane echo: \(flooding.latencies.summary)
            """)
        #expect(during.hangMs < 250, "main thread stalled \(during.hangMs) ms")
        #expect(quiet.latencies.count > seconds * 3, "the quiet pane kept echoing")
        flooding.backend.terminate()
        quiet.backend.terminate()
        connection.close()
    }

    /// Waits until a pane's output has been quiet for a second.
    func quiesce(_ pane: MirrorPane, timeout: Duration = .seconds(60)) async throws {
        let deadline = ContinuousClock.now + timeout
        var last = (pane.bytes, pane.snapshots)
        var quietSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let now = (pane.bytes, pane.snapshots)
            if now != last { last = now; quietSince = .now }
            if ContinuousClock.now - quietSince > .seconds(1) { return }
        }
        throw TestError("output never stopped")
    }

    @Test(arguments: Flood.allCases, [true, false]) func floodIntoTheClientTerminal(_ kind: Flood, focusFlood: Bool) async throws {
        try await flood(kind, seconds: heavyStress ? 60 : 8, focusFlood: focusFlood)
    }

    /// A program that sets its title and rings the bell as fast as it can, with the terminal's
    /// notifications handed to the main actor the way `Pane` does it.
    @Test func titleAndBellFlood() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var spam = Data()
        for i in 0..<200_000 { spam.append(Data("\u{1b}]0;build step \(i)\u{07}\u{07}".utf8)) }
        try spam.write(to: dir.appending(path: "spam"))
        let (connection, panes) = try await host(try await daemon.ticket(), model: model, panes: 1)
        let window = NSObject()
        connection.setWindowView(window, focused: panes[0], visible: panes)
        let pane = MirrorPane(try connection.makeBackend(for: panes[0]))
        try await eventually("prompt", timeout: .seconds(10)) { pane.snapshots > 0 }
        let counts = NotificationCounts()
        var events = Terminal.Events()
        events.titleChanged = { counts.title.add(1, ordering: .relaxed); counts.deliver() }
        events.bell = { counts.bell.add(1, ordering: .relaxed); counts.deliver() }
        pane.terminal.setEvents(events)
        let baseline = Gauge.footprint()
        let peaks = Peaks()
        pane.type("while :; do cat \(dir.path)/spam; done\r")
        try await Task.sleep(for: .seconds(heavyStress ? 60 : 8))
        pane.type("\u{03}")
        let during = peaks.stop()
        try await quiesce(pane)
        print("""
            [stress] title+bell flood: \(counts.title.load(ordering: .relaxed)) titles, \(counts.bell.load(ordering: .relaxed)) bells, \(counts.mainCalls.load(ordering: .relaxed)) main-actor calls
              peaks: \(during)
              footprint baseline \(Gauge.mb(baseline)), after \(Gauge.mb(Gauge.footprint()))
            """)
        #expect(during.hangMs < 250, "main thread stalled \(during.hangMs) ms")
        pane.backend.terminate()
        connection.close()
    }

    /// While a pane floods with its scrollback full: windows opening and closing on it (each
    /// seeded from another window's terminal), the pane's last view closing and reopening
    /// (a fresh snapshot, then history paged in), and history requests as fast as they go.
    @Test func viewAndHistoryStormDuringAFlood() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let inputs = try Self.floodInputs()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let (connection, panes) = try await host(try await daemon.ticket(), model: model, panes: 1)
        let window = NSObject()
        connection.setWindowView(window, focused: panes[0], visible: panes)
        var main = MirrorPane(try connection.makeBackend(for: panes[0]))
        try await eventually("prompt", timeout: .seconds(10)) { main.snapshots > 0 }
        main.type(Flood.text.command(inputs) + "\r")
        try await Task.sleep(for: .seconds(heavyStress ? 20 : 6))
        let baseline = Gauge.footprint()
        let peaks = Peaks()
        let start = ContinuousClock.now
        var (opened, reopened, requested) = (0, 0, 0)
        var seedWorst = Duration.zero
        while ContinuousClock.now - start < .seconds(heavyStress ? 60 : 10) {
            for _ in 0..<20 where main.backend.requestHistory() { requested += 1 }
            let t = ContinuousClock.now
            let extra = MirrorPane(try connection.makeBackend(for: panes[0]))
            seedWorst = max(seedWorst, ContinuousClock.now - t)
            opened += 1
            try await Task.sleep(for: .milliseconds(20))
            extra.backend.terminate()
            if opened % 10 == 0 {
                main.backend.terminate()
                main = MirrorPane(try connection.makeBackend(for: panes[0]))
                reopened += 1
            }
        }
        main.type("\u{03}")
        let during = peaks.stop()
        try await quiesce(main)
        try await Task.sleep(for: .seconds(2))
        let stats = (connection.client as? DaemonClient)?.stats()
        print("""
            [stress] view/history storm: \(opened) windows opened and closed (seeding took up to \(seedWorst)), \(reopened) resubscribes, \(requested) history pages asked for
              peaks: \(during)
              footprint baseline \(Gauge.mb(baseline)), after \(Gauge.mb(Gauge.footprint()))
              core: \(String(describing: stats))
            """)
        main.type("echo storm-$((6*7))\r")
        try await eventually("typing works after the storm", timeout: .seconds(10)) { main.tail.contains("storm-42") }
        #expect(during.hangMs < 250, "main thread stalled \(during.hangMs) ms")
        main.backend.terminate()
        connection.close()
    }
}
