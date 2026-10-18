#if !os(macOS)
import Dispatch
import Foundation
import PaneLayout
import Synchronization
import TerminalCore

/// Stand-in for a remote shell on iOS until the daemon connection exists: a line editor that
/// echoes input and answers each line, so the renderer, keyboard and key bar can be exercised.
/// Output is delivered asynchronously from its own queue, like network bytes.
nonisolated final class EchoBackend: PaneBackend {
    private struct State {
        var line: [UInt8] = []
        var onOutput: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    }

    private let pane: PaneId
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "echo-backend", qos: .userInteractive)
    /// Simulated one-way network delay (the `echoLatencyMs` default, e.g. `-echoLatencyMs 150` as a
    /// launch argument), to exercise echo prediction without a daemon.
    private let latency: Double
    private let predictionFeed = Mutex<(@Sendable (PredictionUpdate) -> Void)?>(nil)

    private static let prompt = "\u{1b}[1;32m~\u{1b}[0m \u{1b}[1;34m❯\u{1b}[0m "
    /// The line editor is like zsh's ZLE at a prompt: raw mode, echo off, between OSC 133 B and C.
    private static let hint = EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: false)

    init(pane: PaneId) {
        self.pane = pane
        latency = Double(UserDefaults.standard.integer(forKey: "echoLatencyMs")) / 1000
    }

    func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) {
        state.withLock { $0.onOutput = onOutput }
        let banner = "\u{1b}[1m\(Brand.name)\u{1b}[0m \u{1b}[2m· \(pane) · local echo (the host daemon connection comes later)\u{1b}[0m\r\n\r\n"
        emit(Array((banner + Self.prompt).utf8))
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        writeInput(bytes, inputSeq: nil)
    }

    private func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64?) {
        let input = Array(bytes)
        // Input travels one way, the echo back the other: the round trip is twice the latency.
        queue.asyncAfter(deadline: .now() + latency) {
            self.handle(input)
            guard let inputSeq else { return }
            // After the echo (which `emit` delays by the same latency).
            self.queue.asyncAfter(deadline: .now() + self.latency + 0.001) {
                self.predictionFeed.withLock { $0 }?(.acknowledged(upTo: inputSeq, hint: Self.hint))
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}

    func terminate() {
        state.withLock { $0.onOutput = nil }
    }

    private func handle(_ input: [UInt8]) {
        // Escape sequences (arrows, function keys) would move the cursor if echoed; a shell's line
        // editor would interpret them, this stand-in ignores them.
        guard input.first != 0x1B else { return }
        var output: [UInt8] = []
        state.withLock { state in
            for byte in input {
                switch byte {
                case 0x0D:
                    output += Array("\r\n".utf8)
                    if !state.line.isEmpty {
                        output += Array("\u{1b}[2mecho:\u{1b}[0m ".utf8) + state.line + Array("\r\n".utf8)
                    }
                    output += Array(Self.prompt.utf8)
                    state.line.removeAll()
                case 0x03:
                    output += Array("^C\r\n\(Self.prompt)".utf8)
                    state.line.removeAll()
                case 0x7F, 0x08:
                    guard !state.line.isEmpty else { continue }
                    // Drop one UTF-8 scalar: continuation bytes, then its lead byte.
                    while let last = state.line.popLast(), last & 0xC0 == 0x80 {}
                    output += Array("\u{8} \u{8}".utf8)
                case 0x20..., 0x09:
                    state.line.append(byte)
                    output.append(byte)
                default:
                    continue
                }
            }
        }
        emit(output)
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let deliver = {
            guard let onOutput = self.state.withLock({ $0.onOutput }) else { return }
            bytes.withUnsafeBytes(onOutput)
        }
        if latency > 0 { queue.asyncAfter(deadline: .now() + latency, execute: deliver) } else { deliver() }
    }
}

extension EchoBackend: PredictionFeed {
    func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
        predictionFeed.withLock { $0 = onUpdate }
        onUpdate(.rtt(max(2 * latency, 0.001)))
        onUpdate(.hint(Self.hint))
    }

    func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64) {
        writeInput(bytes, inputSeq: Optional(inputSeq))
    }
}
#endif
