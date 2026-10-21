import Synchronization
import Testing
@testable import TerminalCore

/// Plain-SSH echo inference: prediction is allowed only after the remote was seen echoing
/// keystrokes, and stops for hidden input, Enter, a running command and output that is not the echo.
@Suite struct StreamEchoInferenceTests {
    private final class Clock: Sendable {
        let t = Mutex<Double>(0)
        func advance(_ seconds: Double) { t.withLock { $0 += seconds } }
        var now: @Sendable () -> Double { { [self] in t.withLock { $0 } } }
    }

    private let clock = Clock()
    private var inference: StreamEchoInference { StreamEchoInference(now: clock.now) }

    private func key(_ i: StreamEchoInference, _ text: String) -> [PredictionUpdate] {
        i.input(Array(text.utf8))
    }

    private func out(_ i: StreamEchoInference, _ text: String) -> [PredictionUpdate] {
        i.output(Array(text.utf8))
    }

    /// Types `text` with each character echoed after `rtt`.
    private func typeEchoed(_ i: StreamEchoInference, _ text: String, rtt: Double = 0.05) {
        for c in text {
            _ = key(i, String(c))
            clock.advance(rtt)
            _ = out(i, String(c))
        }
    }

    @Test func predictsOnlyAfterTwoEchoes() {
        let i = inference
        #expect(i.hint == nil)
        _ = key(i, "l")
        clock.advance(0.05)
        #expect(out(i, "l").contains(.rtt(0.05)))
        #expect(i.hint == nil, "one echo is not enough")
        _ = key(i, "s")
        clock.advance(0.05)
        let updates = out(i, "s")
        #expect(i.hint?.allowsPrediction == true)
        #expect(updates.contains(.hint(i.hint)))
    }

    @Test func passwordPromptIsNeverPredicted() {
        let i = inference
        typeEchoed(i, "sudo ls")
        #expect(i.hint?.allowsPrediction == true)
        // Enter: the program may read differently now.
        #expect(key(i, "\r") == [.hint(nil)])
        _ = out(i, "\r\n[sudo] password for me: ")
        // Typed into the prompt: nothing comes back, so nothing is ever allowed.
        for c in "hunter2" {
            _ = key(i, String(c))
            clock.advance(0.2)
            _ = i.tick()
            #expect(i.hint == nil)
        }
        clock.advance(2)
        _ = i.tick()
        #expect(i.hint == nil)
    }

    @Test func silenceAfterAKeystrokeStopsPrediction() {
        let i = inference
        typeEchoed(i, "abc")
        #expect(i.hint != nil)
        _ = key(i, "d")
        clock.advance(1.5)
        #expect(i.tick() == [.hint(nil)])
    }

    @Test func otherTextInsteadOfTheEchoStopsPrediction() {
        let i = inference
        typeEchoed(i, "abc")
        _ = key(i, "x")
        clock.advance(0.1)
        // A round trip later, text without the keystroke in it.
        #expect(out(i, "something else").contains(.hint(nil)))
    }

    @Test func lineEditorRedrawsStillCount() {
        let i = inference
        // zsh-syntax-highlighting style: back up, recolor the word, then the new character.
        _ = key(i, "l")
        clock.advance(0.05)
        _ = out(i, "l")
        _ = key(i, "s")
        clock.advance(0.05)
        _ = out(i, "\u{8}\u{1b}[32ml\u{1b}[39ms")
        #expect(i.hint != nil)
        // Echoes split over chunks and batched in one.
        _ = key(i, "a")
        _ = key(i, "b")
        clock.advance(0.05)
        _ = out(i, "a")
        _ = out(i, "\u{1b}[")  // a sequence split across chunks
        _ = out(i, "0mb")
        #expect(i.hint != nil)
    }

    @Test func backspaceAndArrowsAreNotJudged() {
        let i = inference
        typeEchoed(i, "abc")
        _ = key(i, "\u{7f}")
        clock.advance(0.05)
        _ = out(i, "\u{8}\u{1b}[K")
        #expect(i.hint != nil)
        _ = key(i, "\u{1b}[D")
        clock.advance(0.05)
        _ = out(i, "\u{8}")
        #expect(i.hint != nil)
    }

    @Test func shellIntegrationGatesOnThePrompt() {
        let i = inference
        _ = out(i, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        typeEchoed(i, "make")
        #expect(i.hint == EchoHint(echo: true, canonical: false, atPrompt: true, altScreen: false))
        _ = key(i, "\r")
        #expect(i.hint == nil)
        // The command runs: nothing while it does, even if it echoes (cat).
        _ = out(i, "\r\n\u{1b}]133;C\u{7}")
        typeEchoed(i, "xyz")
        #expect(i.hint == nil)
        // Back at a prompt: the shell's echo was verified before, so prediction resumes at once.
        _ = out(i, "\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        #expect(i.hint?.allowsPrediction == true)
    }

    @Test func unverifiedShellDoesNotResumeAtThePrompt() {
        let i = inference
        _ = out(i, "\u{1b}]133;B\u{7}")
        _ = out(i, "\u{1b}]133;C\u{7}\u{1b}]133;D\u{7}\u{1b}]133;B\u{7}")
        #expect(i.hint == nil)
    }

    @Test func emitsOnlyChanges() {
        let i = inference
        typeEchoed(i, "ab")
        _ = key(i, "c")
        clock.advance(0.05)
        #expect(!out(i, "c").contains { if case .hint = $0 { true } else { false } })
    }

    /// With the predictor: the third character of an echoed line is drawn before its echo; a
    /// password typed after Enter never is.
    @Test func drivesThePredictor() {
        let i = inference
        let predictor = EchoPredictor(now: clock.now)
        let screen = Screen()
        func type(_ c: String, echo: Bool) {
            for u in key(i, c) { predictor.apply(u) }
            predictor.predict(PredictedInput(bytes: Array(c.utf8)), screen: screen)
            clock.advance(0.05)
            if echo, c != "\r" { screen.put(c) }
            for u in i.output(echo ? Array(c.utf8) : []) { predictor.apply(u) }
            predictor.reconcile(screen: screen)
        }
        type("l", echo: true)
        type("s", echo: true)
        #expect(predictor.overlay.isEmpty)
        for u in key(i, "x") { predictor.apply(u) }
        #expect(predictor.predict(PredictedInput(bytes: Array("x".utf8)), screen: screen), "predicted before the echo")
        #expect(predictor.overlay.map(\.text) == ["x"])
        clock.advance(0.05)
        screen.put("x")
        for u in i.output(Array("x".utf8)) { predictor.apply(u) }
        predictor.reconcile(screen: screen)

        type("\r", echo: true)
        screen.newline()
        for c in "secret" { type(String(c), echo: false) }
        #expect(predictor.overlay.isEmpty)
        #expect(predictor.stats.predicted == 1)
    }

    private final class Screen: PredictionScreen {
        var row = Array(repeating: "", count: 20)
        var cursor: (x: Int, y: Int) = (0, 0)
        var isAlternateScreen: Bool { false }
        var cols: Int { 20 }
        func text(atX x: Int, y: Int) -> String { y == cursor.y ? row[x] : "" }
        func put(_ c: String) {
            row[cursor.x] = c
            cursor.x += 1
        }
        func newline() {
            row = Array(repeating: "", count: 20)
            cursor = (0, cursor.y + 1)
        }
    }
}
