import Dispatch
import Foundation
import PaneLayout
import Synchronization
import TerminalCore
import TerminalRenderer

/// Stand-in for a shell on iOS and under `-mock`: a line editor that echoes input and answers each line.
nonisolated final class EchoBackend: PaneBackend {
    private struct State {
        var line: [UInt8] = []
        var onOutput: (@Sendable (UnsafeRawBufferPointer) -> Void)?
        /// A screen `show` was given before the pane started, drawn after its greeting.
        var shown: [UInt8] = []
        var cols = 80
        /// A prompt with a right-aligned part (zsh's RPROMPT), redrawn at each new width.
        var rightPrompt: (left: String, leftWidth: Int, right: String, rightWidth: Int)?
        /// `mouse` turned on SGR mouse reporting: reports arrive as input and are printed.
        var reportsMouse = false
    }

    /// Draws `left` with `right` at the right edge, redrawn after every resize as zsh does on SIGWINCH.
    func showPrompt(_ left: String, width leftWidth: Int, right: String, width rightWidth: Int) {
        let cols = state.withLock { state in
            state.rightPrompt = (left, leftWidth, right, rightWidth)
            return state.cols
        }
        show(Self.promptLine(left, leftWidth, right, rightWidth, cols: cols))
    }

    private static func promptLine(_ left: String, _ leftWidth: Int, _ right: String, _ rightWidth: Int, cols: Int) -> String {
        "\r\u{1b}[J" + left + "\u{1b}[\(max(cols - rightWidth + 1, leftWidth + 2))G" + right + "\u{1b}[\(leftWidth + 1)G"
    }

    private let pane: PaneId
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "echo-backend", qos: .userInteractive)
    /// Simulated one-way network delay (`-echoLatencyMs`), to exercise echo prediction without a daemon.
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
        var banner = "\u{1b}[1m\(Brand.name)\u{1b}[0m \u{1b}[2m· \(pane) · sample shell\u{1b}[0m\r\n\r\n"
        if LaunchArguments().string(forKey: "echoFixture") == "glyphs" { banner = GlyphFixture.text + "\r\n" }
        emit(Array((banner + Self.prompt).utf8))
        emit(state.withLock { state in defer { state.shown = [] }; return state.shown })
    }

    /// Draws `text` as if the shell had printed it, after the greeting.
    func show(_ text: String) {
        let started = state.withLock { state in
            if state.onOutput == nil { state.shown = Array(text.utf8) }
            return state.onOutput != nil
        }
        if started { emit(Array(text.utf8)) }
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
            // Must land after the echo, which `emit` delays by the same latency.
            self.queue.asyncAfter(deadline: .now() + self.latency + 0.001) {
                self.predictionFeed.withLock { $0 }?(.acknowledged(upTo: inputSeq, hint: Self.hint))
            }
        }
    }

    /// Resizes sent to the "shell"; tests expect one per layout change.
    let resizes = Atomic<Int>(0)

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        resizes.add(1, ordering: .relaxed)
        let prompt = state.withLock { state in
            state.cols = Int(cols)
            return state.rightPrompt
        }
        if let prompt { emit(Array(Self.promptLine(prompt.left, prompt.leftWidth, prompt.right, prompt.rightWidth, cols: Int(cols)).utf8)) }
    }

    func terminate() {
        state.withLock { $0.onOutput = nil }
    }

    func foreground() -> PaneForeground? {
        PaneForeground(program: "zsh", directory: NSHomeDirectory())
    }

    private func handle(_ input: [UInt8]) {
        // Escape sequences (arrows, function keys) would move the cursor if echoed; a shell's line
        // editor would interpret them, this stand-in ignores them. Mouse reports show as `cat -v`
        // would print them.
        if input.first == 0x1B {
            if state.withLock({ $0.reportsMouse }) { emit(Array("^[".utf8) + input.dropFirst() + Array("\r\n".utf8)) }
            return
        }
        var output: [UInt8] = []
        state.withLock { state in
            for byte in input {
                switch byte {
                case 0x0D:
                    output += Array("\r\n".utf8)
                    let line = String(decoding: state.line, as: UTF8.self)
                    if state.line.starts(with: Array("title ".utf8)) {
                        // `title <text>` sets the title (OSC 2).
                        output += Array("\u{1b}]2;".utf8) + state.line.dropFirst(6) + [0x07]
                    } else if line.hasPrefix("seq "), let count = Int(line.dropFirst(4)), (1...10_000).contains(count) {
                        output += Array((1...count).map { "row \($0)\r\n" }.joined().utf8)
                    } else if line == "mouse" {
                        state.reportsMouse = true
                        output += Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
                    } else if !state.line.isEmpty {
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
