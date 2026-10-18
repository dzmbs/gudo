/// `EchoHint`/`InputAck` control messages and its RTT estimate; local backends send nothing, so
/// nothing is predicted.
public enum PredictionUpdate: Sendable, Equatable {
    /// The pane's termios/prompt/alt-screen state changed (nil: unknown → never predict).
    case hint(EchoHint?)
    /// The backend has written every input up to `seq` to the PTY and the output those inputs
    /// produced has been delivered before this update. `hint` is the state read just before the
    /// last write (S6 §4 mitigation).
    case acknowledged(upTo: UInt64, hint: EchoHint?)
    /// A new round-trip estimate in seconds.
    case rtt(Double)
}

extension EchoPredictor {
    /// Applies one backend update.
    public func apply(_ update: PredictionUpdate) {
        switch update {
        case .hint(let hint): self.update(hint: hint)
        case .acknowledged(let seq, let hint): acknowledge(upTo: seq, hint: hint)
        case .rtt(let seconds): updateRTT(seconds: seconds)
        }
    }
}

/// The live terminal as the predictor sees it: active-area cells and cursor.
extension Terminal: PredictionScreen {
    public var cols: Int { size.cols }
    public var cursor: (x: Int, y: Int) {
        let p = cursorPosition
        return (p.x, p.y)
    }
    public var isAlternateScreen: Bool { modes.altScreen }
    public func text(atX x: Int, y: Int) -> String { text(atActive: GridPoint(x: x, y: y)) }
    public func isWide(atX x: Int, y: Int) -> Bool { isWide(atActive: GridPoint(x: x, y: y)) }
}
