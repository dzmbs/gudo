import Synchronization

/// Echo-prediction facts for a byte-stream backend that cannot read the remote PTY's termios or
/// acknowledge inputs: a plain-SSH pane (the daemon's rules, inferred instead of read).
///
/// The daemon tells the predictor whether the pane echoes (`tcgetattr` on the PTY master); over
/// plain SSH nobody can. So echo is *observed*: a keystroke counts as echoed when the output that
/// follows it shows that character (escape sequences and control bytes aside, so a line editor's
/// redraw around it still counts). Prediction is allowed only after `verifiedEchoes` keystrokes
/// in a row were echoed, and stops at once when:
/// - a keystroke's output does not show it, or nothing shows it within `echoTimeout`
///   (hidden input: a password prompt prints nothing, so it is never predicted);
/// - anything other than a printable character, Backspace or an arrow is typed (Enter, Tab,
///   control keys: the program may change how it reads, e.g. `sudo` asking for a password);
/// - with shell integration (OSC 133 in the stream), a command starts (`C`); prediction then
///   resumes at the next prompt (`B`) without waiting, if the shell's echo was verified before.
///
/// The predictor runs in its no-acknowledgement mode (no `.acknowledged`); `.rtt` comes from the
/// observed keystroke-to-echo times. Thread-safe: input and output may come from different
/// threads; deliver the updates `output(_:)` returns after the output itself.
public final class StreamEchoInference: Sendable {
    public struct Configuration: Sendable {
        /// Keystrokes in a row that must be seen echoed before anything is predicted.
        public var verifiedEchoes = 2
        /// A keystroke with no echo for this long (or three round trips, if longer) means the
        /// program is not echoing.
        public var echoTimeout: Double = 1.0
        public init() {}
    }

    private struct Pending {
        var byte: UInt8
        var sentAt: Double
    }

    private enum Prompt { case unknown, editing, running }

    private struct State {
        var pending: [Pending] = []
        /// Keystrokes in a row seen echoed.
        var streak = 0
        var prompt = Prompt.unknown
        /// The shell's line editor was seen echoing at a prompt (OSC 133): later prompts start
        /// verified.
        var shellEchoes = false
        var rtt: Double?
        var lastHint: EchoHint?? = .none
        /// An unfinished escape sequence at the end of the last output chunk.
        var escape = EscapeScanner()
    }

    public let configuration: Configuration
    private let now: @Sendable () -> Double
    private let state = Mutex(State())

    public init(configuration: Configuration = .init(), now: (@Sendable () -> Double)? = nil) {
        self.configuration = configuration
        if let now {
            self.now = now
        } else {
            let start = ContinuousClock.now
            self.now = { (ContinuousClock.now - start) / .seconds(1) }
        }
    }

    /// The hint the predictor should have now (nil: do not predict).
    public var hint: EchoHint? {
        state.withLock { Self.hint($0, configuration) }
    }

    /// A user keystroke about to be sent. Returns updates for the predictor (deliver them before
    /// the keystroke is predicted, so an Enter stops prediction first).
    public func input(_ bytes: [UInt8]) -> [PredictionUpdate] {
        let time = now()
        return state.withLock { state in
            expire(&state, at: time)
            switch PredictedInput(bytes: bytes) {
            case .text:
                // One printable character (ASCII echoes byte for byte; anything wider is
                // checked by its last byte, which no escape sequence ends with).
                state.pending.append(Pending(byte: bytes.last!, sentAt: time))
            case .backspace, .cursorLeft, .cursorRight:
                // Echoed as cursor motion and erases, not as the key: not judged. Earlier
                // keystrokes stay pending, but their echo may now come mixed with this one's.
                state.pending.removeAll()
            case .other:
                state.pending.removeAll()
                state.streak = 0
            }
            return changes(&state)
        }
    }

    /// Output from the remote, in order. Returns updates to deliver after it.
    public func output(_ bytes: some Sequence<UInt8>) -> [PredictionUpdate] {
        let time = now()
        return state.withLock { state in
            var updates: [PredictionUpdate] = []
            var matched = false
            for event in state.escape.scan(bytes) {
                switch event {
                case .printable(let byte):
                    // In order, other text in between allowed (a line editor's redraw).
                    guard let first = state.pending.first else { continue }
                    if byte == first.byte {
                        matched = true
                        state.pending.removeFirst()
                        state.streak += 1
                        if state.prompt == .editing, state.streak >= configuration.verifiedEchoes { state.shellEchoes = true }
                        let sample = time - first.sentAt
                        state.rtt = state.rtt.map { 0.875 * $0 + 0.125 * sample } ?? sample
                        updates.append(.rtt(state.rtt!))
                    }
                case .prompt(let mark):
                    switch mark {
                    case "A", "B":
                        state.prompt = .editing
                        if mark == "B", state.shellEchoes { state.streak = max(state.streak, configuration.verifiedEchoes) }
                    case "C":
                        state.prompt = .running
                        state.streak = 0
                        state.pending.removeAll()
                    case "D":
                        state.prompt = .running
                    default:
                        break
                    }
                }
            }
            // Text arrived a round trip after a keystroke, and the keystroke is not in it: the
            // program printed something else instead of echoing. (Sooner, the text may be an
            // earlier keystroke's doing; a wrong call here only pauses prediction.)
            if !matched, state.escape.sawPrintable, let first = state.pending.first, let rtt = state.rtt, time - first.sentAt >= rtt {
                if state.prompt == .editing { state.shellEchoes = false }
                state.streak = 0
                state.pending.removeAll()
            }
            expire(&state, at: time)
            return updates + changes(&state)
        }
    }

    /// Whether keystrokes wait for their echo: `tick()` has something to judge.
    public var isWaiting: Bool {
        state.withLock { !$0.pending.isEmpty }
    }

    /// Judges keystrokes whose echo never came.
    public func tick() -> [PredictionUpdate] {
        let time = now()
        return state.withLock { state in
            expire(&state, at: time)
            return changes(&state)
        }
    }

    private func expire(_ state: inout State, at time: Double) {
        let limit = max(configuration.echoTimeout, 3 * (state.rtt ?? 0))
        guard let first = state.pending.first, time - first.sentAt > limit else { return }
        state.pending.removeAll()
        state.streak = 0
        if state.prompt == .editing { state.shellEchoes = false }
    }

    private func changes(_ state: inout State) -> [PredictionUpdate] {
        let hint = Self.hint(state, configuration)
        if case .some(let last) = state.lastHint, last == hint { return [] }
        state.lastHint = .some(hint)
        return [.hint(hint)]
    }

    private static func hint(_ state: State, _ configuration: Configuration) -> EchoHint? {
        guard state.streak >= configuration.verifiedEchoes, state.prompt != .running else { return nil }
        // Raw mode at a prompt being edited (zsh ZLE, readline, fish) when the shell marks its
        // prompts; otherwise "cooked with echo", the only other state prediction allows.
        return state.prompt == .editing
            ? EchoHint(echo: true, canonical: false, atPrompt: true, altScreen: false)
            : EchoHint(echo: true, canonical: true, atPrompt: false, altScreen: false)
    }
}

/// Splits output into printable bytes and OSC 133 marks, skipping escape sequences and control
/// bytes, across chunk boundaries.
struct EscapeScanner: Sendable {
    enum Event: Equatable {
        case printable(UInt8)
        /// OSC 133;<mark>
        case prompt(Character)
    }

    private enum Mode { case ground, escape, csi, osc, oscEscape, string, stringEscape }

    private var mode = Mode.ground
    private var osc: [UInt8] = []
    /// The last `scan` saw a printable byte.
    private(set) var sawPrintable = false

    mutating func scan(_ bytes: some Sequence<UInt8>) -> [Event] {
        var events: [Event] = []
        sawPrintable = false
        for byte in bytes {
            switch mode {
            case .ground:
                if byte == 0x1B {
                    mode = .escape
                } else if byte >= 0x20 && byte != 0x7F {
                    sawPrintable = true
                    events.append(.printable(byte))
                }
            case .escape:
                switch byte {
                case 0x5B: mode = .csi  // [
                case 0x5D: mode = .osc; osc.removeAll()  // ]
                case 0x50, 0x58, 0x5E, 0x5F: mode = .string  // DCS, SOS, PM, APC
                case 0x20...0x2F: break  // intermediates (ESC ( B …)
                default: mode = .ground
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { mode = .ground }
            case .osc:
                if byte == 0x07 {
                    finishOSC(&events)
                } else if byte == 0x1B {
                    mode = .oscEscape
                } else if osc.count < 16 {
                    osc.append(byte)
                }
            case .oscEscape:
                if byte == 0x5C { finishOSC(&events) } else { mode = .osc }
            case .string:
                if byte == 0x1B { mode = .stringEscape } else if byte == 0x07 { mode = .ground }
            case .stringEscape:
                mode = byte == 0x5C ? .ground : .string
            }
        }
        return events
    }

    private mutating func finishOSC(_ events: inout [Event]) {
        mode = .ground
        // "133;A", "133;B;…", "133;D;0"
        guard osc.count >= 5, osc.starts(with: Array("133;".utf8)) else { return }
        events.append(.prompt(Character(UnicodeScalar(osc[4]))))
    }
}
