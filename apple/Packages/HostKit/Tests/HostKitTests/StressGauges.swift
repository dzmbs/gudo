import Darwin
import Foundation
import Synchronization
@testable import HostKit
import TerminalCore

/// The test process's own resource use: what the app would pay for the same work.
nonisolated enum Gauge {
    /// `phys_footprint`: the number jetsam and Xcode's memory gauge use.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func threads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    static func fds() -> Int {
        // Without a buffer the call returns a capacity estimate, not the count.
        let capacity = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard capacity > 0 else { return 0 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(capacity) / MemoryLayout<proc_fdinfo>.stride + 16)
        let used = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        return used > 0 ? Int(used) / MemoryLayout<proc_fdinfo>.stride : 0
    }

    /// User plus system CPU time of the process, in seconds.
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
}

/// Peaks of the gauges over a window, sampled on a background thread every `interval`, plus
/// the main thread's worst stall: a ping posted to the main queue that runs late by more than
/// its interval is a hang of that length.
nonisolated final class Peaks: Sendable {
    struct Values: Sendable, CustomStringConvertible {
        var footprint: UInt64 = 0
        var threads = 0
        var fds = 0
        var hangMs = 0.0
        var cpuPercent = 0.0
        var description: String {
            "footprint \(Gauge.mb(footprint)), threads \(threads), fds \(fds), main hang max \(String(format: "%.0f", hangMs)) ms, cpu \(String(format: "%.0f", cpuPercent)) %"
        }
    }

    private let values = Mutex(Values())
    private let running = Atomic<Bool>(true)
    private let started = ContinuousClock.now
    private let cpuStart = Gauge.cpu()

    init(interval: Duration = .milliseconds(20)) {
        let thread = Thread { [self] in
            while running.load(ordering: .relaxed) {
                let posted = ContinuousClock.now
                let ran = Ping()
                DispatchQueue.main.async { ran.at.withLock { $0 = .now } }
                Thread.sleep(forTimeInterval: Double(interval.components.attoseconds) / 1e18)
                // Wait for the ping (or count the wait so far as the hang).
                while running.load(ordering: .relaxed), ran.at.withLock({ $0 }) == nil {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                let lag = (ran.at.withLock { $0 } ?? .now) - posted
                let (footprint, threads, fds) = (Gauge.footprint(), Gauge.threads(), Gauge.fds())
                values.withLock { peak in
                    peak.footprint = max(peak.footprint, footprint)
                    peak.threads = max(peak.threads, threads)
                    peak.fds = max(peak.fds, fds)
                    peak.hangMs = max(peak.hangMs, lag / .milliseconds(1))
                }
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() -> Values {
        running.store(false, ordering: .relaxed)
        var measured = values.withLock { $0 }
        let wall = (ContinuousClock.now - started) / .seconds(1)
        measured.cpuPercent = (Gauge.cpu() - cpuStart) / wall * 100
        return measured
    }
}

private nonisolated final class Ping: Sendable {
    let at = Mutex<ContinuousClock.Instant?>(nil)
}

/// A daemon pane on screen the way the app shows it (`Pane`'s event handling, without the
/// renderer): a real libghostty terminal fed by the backend, query replies going back.
nonisolated final class MirrorPane: Sendable {
    let backend: any PaneBackend
    let terminal: Terminal
    private let state = Mutex(State())

    struct State {
        var bytes = 0
        var snapshots = 0
        var histories = 0
        var connection: PaneConnection?
        /// Probe bytes waiting for their echo: byte → when it was sent.
        var probes: [UInt8: ContinuousClock.Instant] = [:]
        var latencies: [Duration] = []
        var tail = Data()
    }

    init(_ backend: any PaneBackend, scrollbackBytes: Int = 10_000_000) {
        self.backend = backend
        var configuration = Terminal.Configuration()
        configuration.scrollbackBytes = scrollbackBytes
        terminal = Terminal(cols: 120, rows: 40, configuration: configuration) { backend.write($0) }
        terminal.answersQueries = !backend.hostAnswersQueries
        let terminal = terminal
        let handle: @Sendable (PaneEvent) -> Void = { [self] event in
            switch event {
            case .output(let data):
                data.withUnsafeBytes { terminal.write($0) }
                let now = ContinuousClock.now
                self.state.withLock { s in
                    s.bytes += data.count
                    if !s.probes.isEmpty {
                        for (byte, sent) in s.probes where data.contains(byte) {
                            s.latencies.append(now - sent)
                            s.probes[byte] = nil
                        }
                    }
                    s.tail = (s.tail + data).suffix(4096)
                }
            case .snapshot(let ready):
                try? terminal.restore(snapshot: ready)
                self.state.withLock { $0.snapshots += 1 }
            case .history(let records, _):
                _ = try? terminal.appendHistory(records)
                self.state.withLock { $0.histories += 1 }
            case .resized(let cols, let rows, let cellWidth, let cellHeight):
                terminal.resize(cols: cols, rows: rows, cellWidth: max(cellWidth, 8), cellHeight: max(cellHeight, 16))
            case .connection(let connection):
                self.state.withLock { $0.connection = connection }
            case .exited, .sizingChanged:
                break
            }
        }
        if let shared = backend as? any SharedPaneTap {
            shared.start(events: handle) { [weak terminal] in terminal?.seedEvents() ?? [] }
        } else {
            backend.start(events: handle)
        }
        backend.resize(cols: 120, rows: 40, cellWidth: 8, cellHeight: 16)
    }

    var bytes: Int { state.withLock { $0.bytes } }
    var snapshots: Int { state.withLock { $0.snapshots } }
    var connection: PaneConnection? { state.withLock { $0.connection } }
    var tail: String { String(decoding: state.withLock { $0.tail }, as: UTF8.self) }
    var latencies: [Duration] { state.withLock { $0.latencies } }
    var outstandingProbes: Int { state.withLock { $0.probes.count } }

    func type(_ text: String) {
        Array(text.utf8).withUnsafeBytes { backend.write($0) }
    }

    /// Types one byte the output does not otherwise contain and times its echo.
    func probe(_ byte: UInt8) {
        state.withLock { $0.probes[byte] = .now }
        [byte].withUnsafeBytes { backend.write($0) }
    }
}

nonisolated extension Array where Element == Duration {
    func percentile(_ p: Double) -> Duration? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        return sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    var summary: String {
        guard let p50 = percentile(0.5), let p95 = percentile(0.95), let worst = self.max() else { return "no samples" }
        func ms(_ d: Duration) -> String { String(format: "%.1f", d / .milliseconds(1)) }
        return "n=\(count) p50 \(ms(p50)) ms, p95 \(ms(p95)) ms, max \(ms(worst)) ms"
    }
}

/// Counts terminal notifications and hands them to the main actor the way `Pane` does
/// (coalesced).
nonisolated final class NotificationCounts: Sendable {
    let title = Atomic<Int>(0)
    let bell = Atomic<Int>(0)
    let mainCalls: Counter
    private let coalescer: MainActorCoalescer

    final class Counter: Sendable {
        let value = Atomic<Int>(0)
        func load(ordering _: AtomicLoadOrdering) -> Int { value.load(ordering: .relaxed) }
    }

    init() {
        let calls = Counter()
        mainCalls = calls
        coalescer = MainActorCoalescer { calls.value.add(1, ordering: .relaxed) }
    }

    func deliver() {
        coalescer.signal()
    }
}

/// Long stress variants run with `GUDO_STRESS=heavy` (minutes each).
nonisolated let heavyStress = ProcessInfo.processInfo.environment["GUDO_STRESS"] == "heavy"

/// The stress suites run only when asked (`GUDO_STRESS=1`, or `heavy`): they take minutes and
/// measure, so they run alone (`swift test --no-parallel`), not beside the other suites.
nonisolated let stressEnabled = ProcessInfo.processInfo.environment["GUDO_STRESS"] != nil
