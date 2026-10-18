#if !os(macOS)
import Dispatch
import Foundation
import PaneLayout
import Synchronization

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

    private static let prompt = "\u{1b}[1;32m~\u{1b}[0m \u{1b}[1;34m❯\u{1b}[0m "

    init(pane: PaneId) {
        self.pane = pane
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
        let input = Array(bytes)
        queue.async { self.handle(input) }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}

    func terminate() {
        state.withLock { $0.onOutput = nil }
    }

    func foreground() -> PaneForeground? {
        PaneForeground(program: "zsh", directory: NSHomeDirectory())
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
        guard !bytes.isEmpty, let onOutput = state.withLock({ $0.onOutput }) else { return }
        bytes.withUnsafeBytes(onOutput)
    }
}
#endif
