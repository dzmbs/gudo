import Foundation
@testable import HostKit
import PaneLayout
import Testing

/// Connect, first paint and keystroke echo round trips to a real daemon, through the same
/// HostsModel → DaemonConnection path the app uses. Set `REAL_HOST_TICKET` (a fresh
/// `… pair --json` ticket); skipped otherwise.
@MainActor
@Suite struct RealHostLatencyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_HOST_TICKET"] != nil))
    func keystrokeEcho() async throws {
        // The ticket itself, or a file holding it.
        let value = ProcessInfo.processInfo.environment["REAL_HOST_TICKET"]!
        let ticket = try PairingTicket(value.hasPrefix("/") ? try String(contentsOfFile: value, encoding: .utf8) : value)
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        let started = ContinuousClock.now
        let id = try await model.pair(ticket, name: "real")
        let connection = try #require(model.connection(id) as? DaemonConnection)
        let connected = ContinuousClock.now - started
        let pane = try #require(connection.layout.session.activeTab?.focused)
        let backend = try connection.makeBackend(for: pane)
        let sink = EventSink()
        backend.start(events: sink.handler)
        backend.resize(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        try await eventually("first paint", timeout: .seconds(20)) {
            sink.all.contains { if case .snapshot = $0 { true } else if case .output = $0 { true } else { false } }
        }
        let firstPaint = ContinuousClock.now - started

        // Keystroke → echo: type single characters at a shell prompt, time each one's echo.
        Array("\u{15}".utf8).withUnsafeBytes { backend.write($0) }  // ^U: empty line
        try await Task.sleep(for: .milliseconds(500))
        var samples: [Duration] = []
        for character in "abcdefghijklmnopqrst" {
            let before = sink.output.count
            let sent = ContinuousClock.now
            Array(String(character).utf8).withUnsafeBytes { backend.write($0) }
            try await eventually("echo of \(character)", timeout: .seconds(5)) {
                sink.output.count > before && sink.output.hasSuffix(String(character))
            }
            samples.append(ContinuousClock.now - sent)
            try await Task.sleep(for: .milliseconds(100))
        }
        Array("\u{15}".utf8).withUnsafeBytes { backend.write($0) }
        let sorted = samples.sorted()
        let ms = { (d: Duration) in String(format: "%.1f", d / .milliseconds(1)) }
        print("real host: pair+attach \(ms(connected)) ms, first paint \(ms(firstPaint)) ms, keystroke echo p50 \(ms(sorted[sorted.count / 2])) ms, min \(ms(sorted.first!)) ms, max \(ms(sorted.last!)) ms over \(samples.count)")
        model.disconnect(id)
    }
}
