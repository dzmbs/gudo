import Darwin
import Foundation
import LocalPTY
import Testing

/// Collects a PTY's output and waits for text to show up in it.
private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ bytes: UnsafeRawBufferPointer) {
        lock.withLock { text += String(decoding: bytes, as: UTF8.self) }
    }

    func waitFor(_ needle: String, seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if lock.withLock({ text.contains(needle) }) { return true }
            usleep(20_000)
        }
        return false
    }
}

private func shell() throws -> (PTY, Output) {
    let pty = try PTY(argv: ["/bin/sh"], environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "], cols: 80, rows: 24)
    let output = Output()
    pty.start(onOutput: { output.append($0) }, onExit: {})
    return (pty, output)
}

private func send(_ pty: PTY, _ text: String) {
    Array(text.utf8).withUnsafeBytes { pty.write($0) }
}

@Test func controlCInterruptsTheForegroundJob() throws {
    let (pty, output) = try shell()
    defer { pty.terminate() }
    send(pty, "tty; sleep 30; echo after-$((6*7))\n")
    #expect(output.waitFor("/dev/ttys"))
    usleep(200_000)
    let started = Date()
    send(pty, "\u{03}")
    #expect(output.waitFor("after-42", seconds: 3))
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func controlZStopsTheForegroundJob() throws {
    let (pty, output) = try shell()
    defer { pty.terminate() }
    send(pty, "sleep 30\n")
    usleep(300_000)
    send(pty, "\u{1a}")
    send(pty, "jobs; echo jobs-$((2+3))\n")
    #expect(output.waitFor("jobs-5"))
    #expect(output.waitFor("Stopped") || output.waitFor("Suspended"))
}

private func running(_ pattern: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "^\(pattern)$"]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Closing a tab (`terminate`) ends the shell and its jobs, foreground and background, as the
/// app's login shell runs them (zsh with job control).
@Test func terminateEndsTheShellAndItsJobs() throws {
    let marker = Int.random(in: 40000...49999)
    let pty = try PTY(argv: ["/bin/zsh", "-f"], environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "], cols: 80, rows: 24)
    let output = Output()
    pty.start(onOutput: { output.append($0) }, onExit: {})
    send(pty, "sleep \(marker + 1) &\nsleep \(marker)\n")
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !(running("sleep \(marker)") && running("sleep \(marker + 1)")) { usleep(50_000) }
    #expect(running("sleep \(marker)"), "foreground job runs")
    #expect(running("sleep \(marker + 1)"), "background job runs")
    pty.terminate()
    let gone = Date().addingTimeInterval(5)
    while Date() < gone, running("sleep \(marker)") || running("sleep \(marker + 1)") { usleep(50_000) }
    #expect(!running("sleep \(marker)"), "foreground job ended with the tab")
    #expect(!running("sleep \(marker + 1)"), "background job ended with the tab")
}
