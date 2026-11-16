import Testing
@testable import TerminalCore

/// The cursor settings reach a running terminal, and a program's own cursor (DECSCUSR) still wins
/// until it resets to the default.
@MainActor
@Suite struct CursorSettingsTests {
    private func cursor(of terminal: Terminal) -> RenderState.Cursor {
        let state = RenderState()
        state.update(from: terminal)
        return state.cursor
    }

    @Test func aStyleChangedInSettingsReachesARunningTerminal() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("$ ".utf8))
        #expect(cursor(of: terminal).style == .block)
        var configuration = Terminal.Configuration()
        configuration.cursorStyle = .bar
        configuration.cursorBlink = false
        terminal.setDefaults(configuration)
        #expect(cursor(of: terminal).style == .bar)
        #expect(!cursor(of: terminal).blinking)
        configuration.cursorStyle = .underline
        configuration.cursorBlink = true
        terminal.setDefaults(configuration)
        #expect(cursor(of: terminal).style == .underline)
        #expect(cursor(of: terminal).blinking)
    }

    @Test func aProgramsCursorWinsUntilItResets() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("\u{1b}[6 q".utf8))
        var configuration = Terminal.Configuration()
        configuration.cursorStyle = .underline
        terminal.setDefaults(configuration)
        #expect(cursor(of: terminal).style == .bar)
        terminal.write(Array("\u{1b}[0 q".utf8))
        #expect(cursor(of: terminal).style == .underline)
    }
}
