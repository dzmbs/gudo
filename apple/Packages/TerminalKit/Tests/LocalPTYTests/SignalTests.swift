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
