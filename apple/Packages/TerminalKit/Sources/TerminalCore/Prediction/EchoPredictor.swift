/// The screen as the prediction engine reads it: the terminal's real (confirmed) state. Coordinates
/// are in the active area (row 0 is the top of the screen the cursor moves in, not of scrollback).
public protocol PredictionScreen {
    var cols: Int { get }
    var cursor: (x: Int, y: Int) { get }
    var isAlternateScreen: Bool { get }
    /// The grapheme in the cell, or "" for an empty cell (and for the tail of a wide character).
    func text(atX x: Int, y: Int) -> String
    /// The cell holds the first half of a wide character.
    func isWide(atX x: Int, y: Int) -> Bool
}

extension PredictionScreen {
    public func isWide(atX x: Int, y: Int) -> Bool { false }
}

/// A keystroke as far as prediction cares. Every input sent to the pane goes through
/// `EchoPredictor.predict(_:screen:)`, predictable or not, so input sequence numbers stay aligned
/// with the backend's.
public enum PredictedInput: Equatable, Sendable {
    /// One printable, single-cell grapheme.
    case text(String)
    case backspace
    case cursorLeft
    case cursorRight
    /// Anything else: Enter, Tab, control keys, other escape sequences, pastes.
    case other

    /// Classifies bytes an encoder produced for one key press.
    public init(bytes: [UInt8]) {
        switch bytes {
        case [0x7F], [0x08]: self = .backspace
        case [0x1B, 0x5B, 0x44], [0x1B, 0x4F, 0x44]: self = .cursorLeft
        case [0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43]: self = .cursorRight
        default:
            if let text = String(validating: bytes, as: UTF8.self), Self.isPredictableText(text) {
                self = .text(text)
            } else {
                self = .other
            }
        }
    }

    /// One scalar that occupies exactly one cell: printable, not combining, and below the ranges
    /// where East Asian wide characters and emoji start (conservative on purpose).
    static func isPredictableText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        let value = scalar.value
        guard value >= 0x20, value != 0x7F, !(0x80..<0xA0).contains(value), value < 0x1100 else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark, .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }
}

/// A speculative cell drawn over the terminal's own content. `text` "" means "draw this cell
/// blank" (a predicted erase).
public struct PredictedCell: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var text: String
    /// Unconfirmed for longer than the grace period on a slow link: draw with a subtle underline.
    public var underlined: Bool

    public init(x: Int, y: Int, text: String, underlined: Bool) {
        self.x = x
        self.y = y
        self.text = text
        self.underlined = underlined
    }
}

public struct PredictionStats: Equatable, Sendable {
    /// Inputs seen (predicted or not).
    public var inputs = 0
    /// Inputs that produced a prediction.
    public var predicted = 0
    /// Predicted cells the screen confirmed.
    public var confirmed = 0
    /// Predicted cells the screen contradicted.
    public var mispredicted = 0
    /// Predicted cells dropped unjudged because an unpredictable input (Enter, ...) followed.
    public var abandoned = 0
    /// Times every prediction was discarded at once (misprediction, hint change, alt screen).
    public var flushes = 0
    /// Prediction epochs started after a misprediction (mosh's epoch).
    public var epochs = 0
    /// Time from showing a predicted cell to the screen confirming it: the latency hidden.
    public var latencySavedTotal: Double = 0
    public var latencySavedMax: Double = 0
    public var latencySamples = 0

    public var latencySavedAverage: Double { latencySamples == 0 ? 0 : latencySavedTotal / Double(latencySamples) }

    public init() {}
}

///
/// The backend feeds it `EchoHint`s, the round-trip time and (optionally) input acknowledgements;
/// the view calls `predict` for every keystroke before sending it and `reconcile` after output was
/// applied to the terminal. Predictions are an overlay only: they never enter the terminal state.
///
/// Rules:
/// - Predict only when the hint allows it (`EchoHint.allowsPrediction`), not on the alt screen, not
///   during the suppression epoch after a misprediction, and not while an earlier unpredictable
///   input (Enter, Tab, ...) is still unprocessed.
/// - Printable single-cell characters at the cursor (inserting in the middle of the line shifts the
///   rest right), and Backspace / ← / → inside the predicted run. Never the last column (wrap).
/// - S6 residual race: while earlier keystrokes are outstanding and no output arrived for
///   `idleOutputLimit`, stop predicting (a program may have gone silent into hidden input).
/// - A cell is confirmed when the screen shows it (a cell that already showed the predicted text
///   waits until the echo caught up with the cursor, so it cannot confirm before its input ran). A
///   cell that disagrees once its input was acknowledged, or after `2·RTT + confirmGrace`, flushes
///   every prediction and suspends prediction for one RTT.
///
/// Not thread-safe: use from one actor (the main actor in the app).
public final class EchoPredictor {
    public struct Configuration: Sendable {
        public var enabled = true
        /// Above this RTT, cells unconfirmed for `underlineGrace` are underlined.
        public var underlineRTT: Double = 0.080
        public var underlineGrace: Double = 0.050
        /// Below this RTT nothing is drawn (the echo arrives before the next frame anyway).
        public var minimumDisplayRTT: Double = 0
        /// Added to 2·RTT before an unacknowledged mismatch counts as a misprediction.
        public var confirmGrace: Double = 0.250
        /// S6 mitigation: no output for this long with keystrokes outstanding stops prediction.
        public var idleOutputLimit: Double = 1.0
        /// RTT assumed until the backend reports one.
        public var defaultRTT: Double = 0.150
        /// Shortest prediction pause after a misprediction.
        public var minimumSuppression: Double = 0.050

        public init() {}
    }

    private struct Expectation {
        var text: String
        /// What the screen showed when the prediction was made.
        var original: String
        var seq: UInt64
        var createdAt: Double
    }

    private struct Run {
        var y: Int
        /// Leftmost column the run may edit (Backspace / ← stop here).
        var startX: Int
        /// One past the rightmost column the cursor reached (→ stops here).
        var endX: Int
        var cursorX: Int
        var cursorSeq: UInt64
        var cursorAt: Double
        var lastInputAt: Double
        var cells: [Int: Expectation] = [:]
    }

    private struct Abandoned {
        var x: Int
        var y: Int
        var expectation: Expectation
        var abandonedAt: Double
    }

    public var configuration: Configuration
    public private(set) var stats = PredictionStats()
    public private(set) var hint: EchoHint?
    /// The latest round-trip estimate in seconds, nil until the backend reports one.
    public private(set) var rtt: Double?
    /// Sequence number of the most recent input (1-based; the first input is 1).
    public private(set) var lastInputSeq: UInt64 = 0
    /// Highest input sequence the backend acknowledged.
    public private(set) var acknowledgedSeq: UInt64 = 0

    private let now: () -> Double
    private var run: Run?
    private var abandoned: [Abandoned] = []
    private var suppressedUntil = -Double.infinity
    private var blocked: (seq: UInt64, at: Double)?
    private var lastOutputAt = -Double.infinity
    private var acknowledgementsSupported = false

    /// - Parameter now: a monotonic clock in seconds (injectable for tests).
    public init(configuration: Configuration = .init(), now: (() -> Double)? = nil) {
        self.configuration = configuration
        if let now {
            self.now = now
        } else {
            let start = ContinuousClock.now
            self.now = { (ContinuousClock.now - start) / .seconds(1) }
        }
    }

    // MARK: Backend feed

    /// A new echo/prompt state from the backend. A state that forbids prediction (hidden input,
    /// alt screen, a command started) discards every prediction at once.
    public func update(hint: EchoHint?) {
        self.hint = hint
        if hint?.allowsPrediction != true { discardAll() }
    }

    public func updateRTT(seconds: Double) {
        rtt = max(0, seconds)
    }

    /// The backend processed inputs up to `seq`, and the output they produced has been applied to
    /// the terminal before this call. `hint` is the echo state the backend read just before writing
    public func acknowledge(upTo seq: UInt64, hint: EchoHint? = nil) {
        acknowledgementsSupported = true
        acknowledgedSeq = max(acknowledgedSeq, seq)
        if let hint { update(hint: hint) }
    }

    /// Drops all predictions without judging them (resize, reset, screen switch).
    public func reset() {
        run = nil
        abandoned.removeAll()
        blocked = nil
    }

    // MARK: Input

    /// Registers one input about to be sent and predicts its echo if allowed. Returns whether a
    /// prediction was made; the input's sequence number is `lastInputSeq` afterwards.
    @discardableResult
    public func predict(_ input: PredictedInput, screen: some PredictionScreen) -> Bool {
        lastInputSeq += 1
        let seq = lastInputSeq
        let t = now()
        stats.inputs += 1
        if canPredict(screen: screen, at: t, seq: seq), apply(input, screen: screen, seq: seq, at: t) {
            stats.predicted += 1
            return true
        }
        // The program's reaction to this input is unknown, so nothing after it can be predicted
        // until it has been processed.
        abandonRun(at: t)
        blocked = (seq, t)
        return false
    }

    private var effectiveRTT: Double { rtt ?? configuration.defaultRTT }

    private func canPredict(screen: some PredictionScreen, at t: Double, seq: UInt64) -> Bool {
        guard configuration.enabled, hint?.allowsPrediction == true, !screen.isAlternateScreen, t >= suppressedUntil
        else { return false }
        if let blocked {
            let processed = acknowledgementsSupported
                ? acknowledgedSeq >= blocked.seq
                : lastOutputAt > blocked.at && t - blocked.at >= effectiveRTT
            guard processed else { return false }
            self.blocked = nil
        }
        let outstanding = run != nil || (acknowledgementsSupported && seq - 1 > acknowledgedSeq)
        if outstanding, t - lastOutputAt > configuration.idleOutputLimit { return false }
        return true
    }

    private func apply(_ input: PredictedInput, screen: some PredictionScreen, seq: UInt64, at t: Double) -> Bool {
        let cols = screen.cols
        let y = run?.y ?? screen.cursor.y
        let x = run?.cursorX ?? screen.cursor.x
        guard cols > 1, x >= 0, x < cols else { return false }
        var run = self.run ?? Run(y: y, startX: x, endX: x, cursorX: x, cursorSeq: seq, cursorAt: t, lastInputAt: t)

        func current(_ column: Int) -> String {
            run.cells[column]?.text ?? screen.text(atX: column, y: y)
        }
        func isWide(_ column: Int) -> Bool {
            run.cells[column] == nil && screen.isWide(atX: column, y: y)
        }
        func set(_ column: Int, _ text: String) {
            let original = run.cells[column]?.original ?? screen.text(atX: column, y: y)
            run.cells[column] = Expectation(text: text, original: original, seq: seq, createdAt: t)
        }

        switch input {
        case .text(let text):
            guard PredictedInput.isPredictableText(text), x < cols - 1 else { return false }
            let rest = Array(x..<cols)
            guard !rest.contains(where: isWide) else { return false }
            let old = rest.map(current)
            if old.contains(where: { !$0.isEmpty }) {
                // Inserting in the middle of the line: the rest moves right, and must not fall off.
                guard old.last == "" else { return false }
                for column in stride(from: cols - 1, to: x, by: -1) where old[column - x] != old[column - 1 - x] {
                    set(column, old[column - 1 - x])
                }
            }
            set(x, text)
            run.cursorX = x + 1
            let rightmost = run.cells.filter { !$0.value.text.isEmpty }.keys.max() ?? x
            run.endX = max(run.endX, rightmost + 1)
        case .backspace:
            guard self.run != nil, x > run.startX else { return false }
            let target = x - 1
            let rest = Array(target..<cols)
            guard !rest.contains(where: isWide) else { return false }
            let old = rest.map(current)
            for column in target..<cols {
                let next = column + 1 < cols ? old[column + 1 - target] : ""
                if next != old[column - target] { set(column, next) }
            }
            run.cursorX = target
        case .cursorLeft:
            guard self.run != nil, x > run.startX else { return false }
            run.cursorX = x - 1
        case .cursorRight:
            guard self.run != nil, x < run.endX else { return false }
            run.cursorX = x + 1
        case .other:
            return false
        }
        run.cursorSeq = seq
        run.cursorAt = t
        run.lastInputAt = t
        self.run = run
        return true
    }

    // MARK: Reconciliation

    /// Compares predictions with the real screen. Call after output was applied
    /// (`outputArrived: true`) and periodically while predictions are shown (`false`), so timeouts
    /// fire without output.
    public func reconcile(screen: some PredictionScreen, outputArrived: Bool = true) {
        let t = now()
        if outputArrived { lastOutputAt = t }
        if screen.isAlternateScreen {
            discardAll()
            return
        }
        let timeout = 2 * effectiveRTT + configuration.confirmGrace

        abandoned.removeAll { item in
            let e = item.expectation
            return screen.text(atX: item.x, y: item.y) == e.text
                || (acknowledgementsSupported && e.seq <= acknowledgedSeq)
                || (outputArrived && t > item.abandonedAt)
                || t - e.createdAt >= timeout
        }

        guard var run else { return }
        var mismatched = 0
        for (x, e) in run.cells.sorted(by: { $0.key < $1.key }) {
            let judged = (acknowledgementsSupported && e.seq <= acknowledgedSeq) || t - e.createdAt >= timeout
            if screen.text(atX: x, y: run.y) == e.text {
                if judged || e.text != e.original {
                    confirm(&run, x, at: t)
                }
            } else if judged {
                mismatched += 1
            }
        }
        if mismatched > 0 { return mispredict(mismatched, at: t) }

        let cursorMatches = screen.cursor.x == run.cursorX && screen.cursor.y == run.y
        // The echo caught up: some output arrived after the last keystroke, every changing cell is
        // shown, and the cursor is where we predicted. Cells that already showed their predicted
        // text are judged now.
        if cursorMatches, lastOutputAt >= run.lastInputAt, !run.cells.values.contains(where: { $0.text != $0.original }) {
            for (x, e) in run.cells {
                if screen.text(atX: x, y: run.y) == e.text {
                    confirm(&run, x, at: t)
                } else {
                    mismatched += 1
                }
            }
            if mismatched > 0 { return mispredict(mismatched, at: t) }
        }

        let cursorJudged = (acknowledgementsSupported && run.cursorSeq <= acknowledgedSeq) || t - run.cursorAt >= timeout
        if run.cells.isEmpty, cursorMatches {
            self.run = nil
        } else if cursorJudged, !cursorMatches {
            mispredict(1, at: t)
        } else {
            self.run = run
        }
    }

    private func confirm(_ run: inout Run, _ x: Int, at t: Double) {
        guard let e = run.cells.removeValue(forKey: x) else { return }
        stats.confirmed += 1
        let saved = t - e.createdAt
        stats.latencySavedTotal += saved
        stats.latencySavedMax = max(stats.latencySavedMax, saved)
        stats.latencySamples += 1
    }

    private func mispredict(_ cells: Int, at t: Double) {
        stats.mispredicted += cells
        stats.flushes += 1
        stats.epochs += 1
        run = nil
        abandoned.removeAll()
        suppressedUntil = t + max(effectiveRTT, configuration.minimumSuppression)
    }

    private func abandonRun(at t: Double) {
        guard let run else { return }
        for (x, e) in run.cells {
            abandoned.append(Abandoned(x: x, y: run.y, expectation: e, abandonedAt: t))
        }
        stats.abandoned += run.cells.count
        self.run = nil
    }

    private func discardAll() {
        if run != nil || !abandoned.isEmpty { stats.flushes += 1 }
        run = nil
        abandoned.removeAll()
    }

    // MARK: Display

    /// Cells to draw over the terminal, sorted by row then column.
    public var overlay: [PredictedCell] {
        let rtt = effectiveRTT
        guard rtt >= configuration.minimumDisplayRTT else { return [] }
        let t = now()
        func cell(_ x: Int, _ y: Int, _ e: Expectation) -> PredictedCell {
            PredictedCell(
                x: x, y: y, text: e.text,
                underlined: rtt > configuration.underlineRTT && t - e.createdAt >= configuration.underlineGrace)
        }
        var cells = abandoned.map { cell($0.x, $0.y, $0.expectation) }
        if let run {
            cells += run.cells.map { cell($0.key, run.y, $0.value) }
        }
        return cells.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// Where to draw the cursor while predictions are outstanding, or nil to use the terminal's.
    public var predictedCursor: (x: Int, y: Int)? {
        guard let run, effectiveRTT >= configuration.minimumDisplayRTT else { return nil }
        return (run.cursorX, run.y)
    }

    /// Whether anything is shown or pending, so the caller knows to keep calling
    /// `reconcile(screen:outputArrived: false)` for timeouts and underlines.
    public var isActive: Bool { run != nil || !abandoned.isEmpty }
}
