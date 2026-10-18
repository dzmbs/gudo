import Testing
@testable import TerminalCore

/// A grid of cells with a cursor, edited the way a line editor echoes.
private final class FakeScreen: PredictionScreen {
    var cells: [[String]]
    var cursor: (x: Int, y: Int) = (0, 0)
    var isAlternateScreen = false
    var wide: Set<Int> = []

    init(cols: Int = 20, rows: Int = 3) {
        cells = Array(repeating: Array(repeating: "", count: cols), count: rows)
    }

    var cols: Int { cells[0].count }
    func text(atX x: Int, y: Int) -> String { cells[y][x] }
    func isWide(atX x: Int, y: Int) -> Bool { y == cursor.y && wide.contains(x) }

    /// Prints a prompt and leaves the cursor after it.
    func prompt(_ text: String, row: Int = 0) {
        for (i, c) in text.enumerated() { cells[row][i] = String(c) }
        cursor = (text.count, row)
    }

    /// Echo of a typed character: insert at the cursor, shifting the rest right.
    func type(_ text: String) {
        var row = cells[cursor.y]
        row.insert(text, at: cursor.x)
        row.removeLast()
        cells[cursor.y] = row
        cursor.x += 1
    }

    func backspace() {
        var row = cells[cursor.y]
        row.remove(at: cursor.x - 1)
        row.append("")
        cells[cursor.y] = row
        cursor.x -= 1
    }

    var line: String { cells[cursor.y].joined() }
}

private final class FakeClock {
    var t: Double = 100
    func advance(_ seconds: Double) { t += seconds }
}

private let shellPrompt = EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: false)

private func makePredictor(_ clock: FakeClock, hint: EchoHint? = shellPrompt, rtt: Double = 0.1) -> EchoPredictor {
    let predictor = EchoPredictor(now: { clock.t })
    predictor.update(hint: hint)
    predictor.updateRTT(seconds: rtt)
    return predictor
}

/// Makes the screen "live": the last output arrived just now.
private func settle(_ predictor: EchoPredictor, _ screen: FakeScreen) {
    predictor.reconcile(screen: screen, outputArrived: true)
}

@Suite("EchoHint rule (spike S6)")
struct EchoHintRuleTests {
    @Test func hiddenInputNeverPredicts() {
        let hidden = EchoHint(echo: false, canonical: true, atPrompt: true, altScreen: false)
        #expect(hidden.isHiddenInput)
        #expect(!hidden.allowsPrediction)
    }

    @Test func rawModeOnlyAtPrompt() {
        #expect(EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: false).allowsPrediction)
        #expect(!EchoHint(echo: false, canonical: false, atPrompt: false, altScreen: false).allowsPrediction)
        #expect(!EchoHint(echo: true, canonical: false, atPrompt: false, altScreen: false).allowsPrediction)
    }

    @Test func cookedWithEchoPredicts() {
        #expect(EchoHint(echo: true, canonical: true, atPrompt: false, altScreen: false).allowsPrediction)
    }

    @Test func altScreenNeverPredicts() {
        #expect(!EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: true).allowsPrediction)
        #expect(!EchoHint(echo: true, canonical: true, atPrompt: false, altScreen: true).allowsPrediction)
    }
}

@Suite("PredictedInput classification")
struct PredictedInputTests {
    @Test func classifiesEncodedKeys() {
        #expect(PredictedInput(bytes: Array("a".utf8)) == .text("a"))
        #expect(PredictedInput(bytes: Array("é".utf8)) == .text("é"))
        #expect(PredictedInput(bytes: [0x7F]) == .backspace)
        #expect(PredictedInput(bytes: [0x1B, 0x5B, 0x44]) == .cursorLeft)
        #expect(PredictedInput(bytes: [0x1B, 0x4F, 0x43]) == .cursorRight)
        #expect(PredictedInput(bytes: [0x0D]) == .other)
        #expect(PredictedInput(bytes: [0x09]) == .other)
        #expect(PredictedInput(bytes: [0x03]) == .other)
        #expect(PredictedInput(bytes: [0x1B, 0x5B, 0x41]) == .other)
        #expect(PredictedInput(bytes: Array("ab".utf8)) == .other)
        #expect(PredictedInput(bytes: Array("漢".utf8)) == .other)
        #expect(PredictedInput(bytes: Array("😀".utf8)) == .other)
        #expect(PredictedInput(bytes: Array("\u{301}".utf8)) == .other)
        #expect(PredictedInput(bytes: [0xFF]) == .other)
    }
}

@Suite("EchoPredictor")
struct EchoPredictorTests {
    @Test func noHintNoPrediction() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock, hint: nil)
        #expect(!p.predict(.text("l"), screen: screen))
        #expect(p.overlay.isEmpty)
        #expect(p.lastInputSeq == 1)
    }

    @Test func hiddenInputNeverPredicts() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("Password: ")
        let p = makePredictor(clock, hint: EchoHint(echo: false, canonical: true, atPrompt: false, altScreen: false))
        settle(p, screen)
        for c in "hunter2" { #expect(!p.predict(.text(String(c)), screen: screen)) }
        #expect(p.overlay.isEmpty)
        #expect(p.stats.predicted == 0)
    }

    @Test func runningRawCommandNeverPredicts() {
        let clock = FakeClock(), screen = FakeScreen()
        let p = makePredictor(clock, hint: EchoHint(echo: false, canonical: false, atPrompt: false, altScreen: false))
        settle(p, screen)
        #expect(!p.predict(.text("x"), screen: screen))
    }

    @Test func altScreenNeverPredicts() {
        let clock = FakeClock(), screen = FakeScreen()
        let p = makePredictor(clock)
        settle(p, screen)
        screen.isAlternateScreen = true
        #expect(!p.predict(.text("j"), screen: screen))
        p.update(hint: EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: true))
        screen.isAlternateScreen = false
        #expect(!p.predict(.text("j"), screen: screen))
    }

    @Test func rawAtPromptPredictsAndConfirms() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)

        #expect(p.predict(.text("l"), screen: screen))
        #expect(p.predict(.text("s"), screen: screen))
        #expect(p.overlay == [
            PredictedCell(x: 2, y: 0, text: "l", underlined: false),
            PredictedCell(x: 3, y: 0, text: "s", underlined: false),
        ])
        #expect(p.predictedCursor! == (4, 0))
        // The predictions are an overlay only.
        #expect(screen.line == "$ ")

        clock.advance(0.1)
        screen.type("l")
        settle(p, screen)
        #expect(p.overlay.map(\.text) == ["s"])
        screen.type("s")
        settle(p, screen)
        #expect(p.overlay.isEmpty)
        #expect(p.predictedCursor == nil)
        #expect(!p.isActive)
        #expect(p.stats.predicted == 2)
        #expect(p.stats.confirmed == 2)
        #expect(p.stats.mispredicted == 0)
        #expect(abs(p.stats.latencySavedAverage - 0.1) < 1e-9)
        #expect(abs(p.stats.latencySavedMax - 0.1) < 1e-9)
    }

    @Test func cookedEchoPredicts() {
        let clock = FakeClock(), screen = FakeScreen()
        let p = makePredictor(clock, hint: EchoHint(echo: true, canonical: true, atPrompt: false, altScreen: false))
        settle(p, screen)
        #expect(p.predict(.text("h"), screen: screen))
        screen.type("h")
        settle(p, screen)
        #expect(p.stats.confirmed == 1)
    }

    @Test func insertingInTheMiddleShiftsTheRest() {
        let clock = FakeClock(), screen = FakeScreen(cols: 10)
        screen.prompt("$ ac")
        screen.cursor.x = 3
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("b"), screen: screen))
        #expect(p.overlay.map(\.text) == ["b", "c"])
        #expect(p.overlay.map(\.x) == [3, 4])
        screen.type("b")
        settle(p, screen)
        #expect(screen.line == "$ abc")
        #expect(p.overlay.isEmpty)
        #expect(p.stats.mispredicted == 0)
    }

    @Test func refusesInsertWhenTheLineIsFull() {
        let clock = FakeClock(), screen = FakeScreen(cols: 4)
        screen.prompt("$ ab")
        screen.cursor.x = 2
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(!p.predict(.text("x"), screen: screen))
    }

    @Test func refusesToShiftWideCharacters() {
        let clock = FakeClock(), screen = FakeScreen(cols: 10)
        screen.prompt("$ 漢")
        screen.wide = [2]
        screen.cursor.x = 2
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(!p.predict(.text("x"), screen: screen))
    }

    @Test func stopsAtTheLastColumn() {
        let clock = FakeClock(), screen = FakeScreen(cols: 5)
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        #expect(p.predict(.text("b"), screen: screen))
        // Column 4 is the last one: typing there wraps, which we do not predict.
        #expect(!p.predict(.text("c"), screen: screen))
        #expect(!p.predict(.text("d"), screen: screen))
    }

    @Test func backspaceAndArrowsWithinTheRun() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)

        // Not before anything was predicted: the prompt is not ours to erase.
        #expect(!p.predict(.backspace, screen: screen))
        clock.advance(0.2)
        settle(p, screen)

        #expect(p.predict(.text("a"), screen: screen))
        #expect(p.predict(.text("c"), screen: screen))
        #expect(p.predict(.cursorLeft, screen: screen))
        #expect(p.predictedCursor! == (3, 0))
        #expect(p.predict(.text("b"), screen: screen))
        #expect(p.overlay.map(\.text) == ["a", "b", "c"])
        #expect(p.predict(.cursorRight, screen: screen))
        #expect(!p.predict(.cursorRight, screen: screen))  // beyond the run; ends it

        let q = makePredictor(clock)
        let s2 = FakeScreen()
        s2.prompt("$ ")
        settle(q, s2)
        #expect(q.predict(.text("x"), screen: s2))
        #expect(q.predict(.text("y"), screen: s2))
        #expect(q.predict(.backspace, screen: s2))
        #expect(q.overlay.map(\.text) == ["x", ""])
        #expect(q.predict(.backspace, screen: s2))
        #expect(!q.predict(.backspace, screen: s2))  // start of the run
    }

    @Test func backspaceDoesNotConfirmBeforeItsEcho() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        clock.advance(0.01)
        #expect(p.predict(.backspace, screen: screen))
        // The cell shows "" both before and after; nothing may confirm while the echo is behind.
        p.reconcile(screen: screen, outputArrived: false)
        #expect(p.isActive)
        clock.advance(0.05)
        screen.type("a")
        settle(p, screen)
        #expect(p.overlay.map(\.text) == [""])
        screen.backspace()
        settle(p, screen)
        #expect(!p.isActive)
        #expect(p.stats.mispredicted == 0)
    }

    @Test func mismatchFlushesAndSuppressesForOneRTT() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock, rtt: 0.1)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        #expect(p.predict(.text("b"), screen: screen))
        // The program echoes something else (e.g. vi-mode swallowed the keys).
        screen.type("X")
        screen.type("Y")
        clock.advance(0.2)
        settle(p, screen)
        #expect(p.isActive)  // not judged yet without acks, before the timeout
        clock.advance(0.3)  // past 2·RTT + grace
        p.reconcile(screen: screen, outputArrived: false)
        #expect(p.overlay.isEmpty)
        #expect(p.stats.mispredicted == 2)
        #expect(p.stats.flushes == 1)
        #expect(p.stats.epochs == 1)
        #expect(!p.predict(.text("c"), screen: screen))  // suppressed for one RTT
        clock.advance(0.11)
        settle(p, screen)
        #expect(p.predict(.text("d"), screen: screen))
    }

    @Test func acknowledgementJudgesImmediately() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        screen.type("Z")
        p.acknowledge(upTo: p.lastInputSeq)
        settle(p, screen)
        #expect(p.stats.mispredicted == 1)
        #expect(p.overlay.isEmpty)
    }

    @Test func acknowledgementWithHiddenHintFlushes() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        p.acknowledge(upTo: 1, hint: EchoHint(echo: false, canonical: true, atPrompt: false, altScreen: false))
        #expect(p.overlay.isEmpty)
        #expect(p.stats.flushes == 1)
        #expect(!p.predict(.text("b"), screen: screen))
    }

    @Test func hintChangeToRunningCommandDiscards() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        p.update(hint: EchoHint(echo: false, canonical: false, atPrompt: false, altScreen: false))
        #expect(p.overlay.isEmpty)
    }

    @Test func enterStopsPredictingUntilProcessed() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock, rtt: 0.1)
        settle(p, screen)
        #expect(p.predict(.text("l"), screen: screen))
        #expect(!p.predict(.other, screen: screen))  // Enter
        #expect(p.stats.abandoned == 1)
        // The typed text stays visible until output arrives, but is never judged.
        #expect(p.overlay.map(\.text) == ["l"])
        #expect(!p.predict(.text("x"), screen: screen))
        clock.advance(0.05)
        screen.type("l")
        screen.prompt("$ ", row: 1)
        settle(p, screen)
        #expect(p.overlay.isEmpty)
        // Less than one RTT after Enter. The unpredicted "x" itself now blocks until processed.
        #expect(!p.predict(.text("x"), screen: screen))
        clock.advance(0.15)
        settle(p, screen)
        #expect(p.predict(.text("y"), screen: screen))
        #expect(p.overlay == [PredictedCell(x: 2, y: 1, text: "y", underlined: false)])
        #expect(p.stats.mispredicted == 0)
    }

    @Test func enterWithAcknowledgementsUnblocksOnAck() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        p.acknowledge(upTo: 0)
        settle(p, screen)
        #expect(!p.predict(.other, screen: screen))
        settle(p, screen)
        #expect(!p.predict(.text("a"), screen: screen))
        p.acknowledge(upTo: p.lastInputSeq)
        settle(p, screen)
        #expect(p.predict(.text("b"), screen: screen))
    }

    @Test func underlinesOnlySlowUnconfirmedCells() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let slow = makePredictor(clock, rtt: 0.2)
        settle(slow, screen)
        #expect(slow.predict(.text("a"), screen: screen))
        #expect(slow.overlay.first?.underlined == false)  // shown instantly
        clock.advance(0.06)
        #expect(slow.overlay.first?.underlined == true)

        let fast = makePredictor(clock, rtt: 0.02)
        settle(fast, screen)
        #expect(fast.predict(.text("a"), screen: screen))
        clock.advance(0.5)
        #expect(fast.overlay.first?.underlined == false)
    }

    @Test func minimumDisplayRTTHidesTheOverlay() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock, rtt: 0.01)
        p.configuration.minimumDisplayRTT = 0.03
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        #expect(p.overlay.isEmpty)
        #expect(p.predictedCursor == nil)
    }

    @Test func idleTerminalPredictsOnlyTheFirstKeystroke() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        clock.advance(5)  // idle prompt: a program may have gone quiet into hidden input
        #expect(p.predict(.text("a"), screen: screen))
        #expect(!p.predict(.text("b"), screen: screen))
        // Once output flows again, prediction resumes.
        clock.advance(0.1)
        screen.type("a")
        screen.type("b")
        settle(p, screen)
        clock.advance(0.2)
        settle(p, screen)
        #expect(p.predict(.text("c"), screen: screen))
    }

    @Test func altScreenSwitchDiscards() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("v"), screen: screen))
        screen.isAlternateScreen = true
        settle(p, screen)
        #expect(p.overlay.isEmpty)
        #expect(p.stats.mispredicted == 0)
    }

    @Test func cursorMismatchAfterTimeoutFlushes() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ab")
        let p = makePredictor(clock, rtt: 0.1)
        settle(p, screen)
        #expect(p.predict(.text("c"), screen: screen))
        #expect(p.predict(.cursorLeft, screen: screen))
        screen.type("c")  // the program ignored ←
        settle(p, screen)
        #expect(p.isActive)
        clock.advance(0.5)
        p.reconcile(screen: screen, outputArrived: false)
        #expect(!p.isActive)
        #expect(p.stats.mispredicted == 1)
    }

    @Test func resetDropsEverythingUnjudged() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        #expect(p.predict(.text("a"), screen: screen))
        p.reset()
        #expect(p.overlay.isEmpty)
        #expect(p.stats.mispredicted == 0)
    }

    @Test func disabledConfigurationNeverPredicts() {
        let clock = FakeClock(), screen = FakeScreen()
        let p = makePredictor(clock)
        p.configuration.enabled = false
        settle(p, screen)
        #expect(!p.predict(.text("a"), screen: screen))
    }

    @Test func statsCountInputsAndPredictions() {
        let clock = FakeClock(), screen = FakeScreen()
        screen.prompt("$ ")
        let p = makePredictor(clock)
        settle(p, screen)
        p.predict(.text("a"), screen: screen)
        p.predict(.text("b"), screen: screen)
        p.predict(.other, screen: screen)
        #expect(p.stats.inputs == 3)
        #expect(p.stats.predicted == 2)
        #expect(p.stats.abandoned == 2)
        #expect(p.lastInputSeq == 3)
    }
}
