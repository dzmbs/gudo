#if DEBUG && os(macOS)
import Darwin
import Foundation
import Synchronization

/// Off-main-thread guard for the dogfood runner: measures main-thread stalls (a heartbeat timer on
/// the main run loop) and, if the main thread stops for `hangSeconds` or the whole run exceeds
/// `timeoutSeconds`, writes the partial report, kills the app's child processes and exits 3.
nonisolated final class DogfoodWatchdog: Sendable {
    private struct State {
        var lastBeat = ProcessInfo.processInfo.systemUptime
        var maxGap = 0.0
        var partialReport: Data?
    }

    private let state = Mutex(State())
    private let hangSeconds: Double
    private let deadline: Double
    private let reportURL: URL

    init(hangSeconds: Double, timeoutSeconds: Double, reportURL: URL) {
        self.hangSeconds = hangSeconds
        deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        self.reportURL = reportURL
    }

    @MainActor func start() {
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(timer, forMode: .common)
        let thread = Thread { [self] in loop() }
        thread.name = "dogfood-watchdog"
        thread.start()
    }

    private func beat() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { current in
            current.maxGap = max(current.maxGap, now - current.lastBeat)
            current.lastBeat = now
        }
    }

    /// The longest main-thread gap since the last call, in seconds.
    func takeMaxStall() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { current in
            let gap = max(current.maxGap, now - current.lastBeat)
            current.maxGap = 0
            current.lastBeat = now
            return gap
        }
    }

    func setPartialReport(_ data: Data) {
        state.withLock { $0.partialReport = data }
    }

    private func loop() {
        while true {
            usleep(20_000)
            let now = ProcessInfo.processInfo.systemUptime
            let (gap, report) = state.withLock { current -> (Double, Data?) in
                let gap = now - current.lastBeat
                current.maxGap = max(current.maxGap, gap)
                return (gap, current.partialReport)
            }
            if gap > hangSeconds { abort(reason: "main thread hung for \(Int(gap)) s", report: report) }
            if now > deadline { abort(reason: "scenario exceeded its time limit", report: report) }
        }
    }

    private func abort(reason: String, report: Data?) -> Never {
        var json = (report.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        json["passed"] = false
        json["aborted"] = reason
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL)
        }
        FileHandle.standardError.write(Data("dogfood: ABORT: \(reason)\n".utf8))
        Self.killChildren(signal: SIGKILL)
        _exit(3)
    }

    /// Signals every descendant of this process.
    static func killChildren(signal: Int32) {
        for process in DogfoodProcesses.tree(of: getpid()) where process.pid != getpid() {
            kill(process.pid, signal)
        }
    }
}
#endif
