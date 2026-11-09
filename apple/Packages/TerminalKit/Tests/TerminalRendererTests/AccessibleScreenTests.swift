import CoreGraphics
import Foundation
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// The screen text a terminal view hands assistive technologies: cached per change, mapped to
/// the selection, the cursor and cell frames, with change notifications held while output flows.
@MainActor
@Suite struct AccessibleScreenTests {
    private func screen(quietPeriod: Duration = .milliseconds(400)) throws -> AccessibleScreen {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        // The first frame compiles shaders, which can take seconds on a busy machine.
        surface.renderIfDirty(offscreen: true)
        return AccessibleScreen(surface: surface, quietPeriod: quietPeriod)
    }

    private func show(_ output: String, on screen: AccessibleScreen) {
        screen.surface.terminal.write(Array(output.utf8))
        screen.surface.renderIfDirty(offscreen: true)
        screen.frameRendered()
    }

    @Test func textIsReadAgainOnlyAfterAFrameShowsAChange() throws {
        let screen = try screen()
        show("one", on: screen)
        #expect(screen.text.string == "one")
        screen.surface.terminal.write(Array(" two".utf8))
        #expect(screen.text.string == "one")
        screen.surface.renderIfDirty(offscreen: true)
        #expect(screen.text.string == "one two")
    }

    @Test func selectedRangeIsTheSelectionOrTheCursor() throws {
        let screen = try screen()
        show("$ ls\r\nfile\r\n$ ", on: screen)
        #expect(screen.selectedRange == 12..<12)
        screen.surface.terminal.selectWord(atViewport: GridPoint(x: 1, y: 1))
        #expect(screen.selectedRange == 5..<9)
    }

    @Test func selectingARangeSelectsItsTextInTheTerminal() throws {
        let screen = try screen()
        show("$ ls\r\nfile one", on: screen)
        screen.select(2..<7)
        #expect(screen.surface.terminal.selectionText() == "ls\nfi")
        screen.select(3..<3)
        #expect(screen.surface.terminal.selection == nil)
    }

    @Test func frameCoversTheRangeCells() throws {
        let screen = try screen()
        show("ab\r\ncdef", on: screen)
        let cell = try #require(screen.surface.cellSize)
        let frame = screen.frame(for: 1..<5)
        let origin = screen.surface.rect(for: GridPoint(x: 0, y: 0)).origin
        #expect(abs(frame.minX - origin.x) < 0.01)
        #expect(abs(frame.width - 2 * cell.width) < 0.01)
        #expect(abs(frame.height - 2 * cell.height) < 0.01)
        let point = CGPoint(x: origin.x + cell.width * 2.5, y: origin.y + cell.height * 1.5)
        #expect(screen.offset(at: point) == 5)
    }

    @Test func linksAreThoseACommandClickOpensAndFollowTheText() throws {
        let screen = try screen()
        show("\u{1b}]8;;https://example.com\u{1b}\\docs\u{1b}]8;;\u{1b}\\ see /tmp/a.txt", on: screen)
        #expect(screen.links.map(\.range) == [0..<4, 9..<19])
        #expect(screen.links.map(\.link.target) == ["https://example.com", "/tmp/a.txt"])
        #expect(screen.links.map(\.link.isHyperlink) == [true, false])
        #expect(screen.links.first?.link.label == "docs")
        show("\r\nhttps://gudo.dev", on: screen)
        #expect(screen.links.map(\.link.target) == ["https://example.com", "/tmp/a.txt", "https://gudo.dev"])
    }

    @Test func hiddenInputChangesAreReportedOnce() throws {
        let screen = try screen()
        let surface = screen.surface
        var changes: [Bool] = []
        surface.onHiddenInputChanged = { changes.append(surface.isHiddenInput) }
        surface.enablePrediction()
        let password = EchoHint(echo: false, canonical: true, atPrompt: false, altScreen: false)
        let shell = EchoHint(echo: true, canonical: false, atPrompt: true, altScreen: false)
        surface.applyPrediction(.hint(shell))
        surface.applyPrediction(.hint(password))
        surface.applyPrediction(.acknowledged(upTo: 0, hint: password))
        surface.applyPrediction(.hint(shell))
        #expect(changes == [true, false])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aBurstOfChangesIsPostedOnceAQuietPeriodAfterItEnds() async throws {
        let quietPeriod = Duration.milliseconds(300)
        let screen = try screen(quietPeriod: quietPeriod)
        var valueChanges: [ContinuousClock.Instant] = []
        var selectionChanges = 0
        screen.onValueChanged = { valueChanges.append(.now) }
        screen.onSelectedTextChanged = { selectionChanges += 1 }
        for line in 0..<10 {
            show("line \(line)\r\n", on: screen)
        }
        let burstEnd = ContinuousClock.now
        #expect(valueChanges.isEmpty)
        try await waitUntil { !valueChanges.isEmpty }
        try await Task.sleep(for: quietPeriod * 2)
        #expect(valueChanges.count == 1)
        #expect(try #require(valueChanges.first) >= burstEnd + quietPeriod - .milliseconds(5))
        #expect(selectionChanges == 1)
    }

    @Test func aFrameWithoutChangesPostsNothing() async throws {
        let screen = try screen(quietPeriod: .milliseconds(50))
        var valueChanges = 0
        screen.onValueChanged = { valueChanges += 1 }
        show("one", on: screen)
        try await waitUntil { valueChanges > 0 }
        screen.frameRendered()
        try await Task.sleep(for: .milliseconds(300))
        #expect(valueChanges == 1)
    }
}
