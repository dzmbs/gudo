import Synchronization
import Testing
@testable import TerminalCore

private func makeTerminal() -> Terminal {
    Terminal(cols: 80, rows: 24) { _ in }
}

private let esc = "\u{1b}"
private let bel = "\u{07}"

/// What a zsh with Ghostty's integration writes at a prompt: the end of the last command, the
/// directory, its title and the prompt marks.
private func zshPrompt(_ directory: String) -> String {
    "\(esc)]133;D;0\(bel)\(esc)]7;kitty-shell-cwd://host/Users/me/\(directory)\(bel)\(esc)]2;~/\(directory)\(bel)"
        + "\r\(esc)[J\(esc)]133;A;cl=line\(bel)~/\(directory) % \(esc)]133;B\(bel)\(esc)[5 q"
}

/// `ls` in zsh as it reaches a terminal: the typed line, preexec (output mark, then the command
/// as the title), the listing, then precmd and the next prompt.
private let zshQuickCommand =
    "ls" + "\(esc)[?2004l\r\r\n" + "\(esc)]133;C\(bel)" + "\(esc)]2;ls\(bel)" + "\(esc)[0 q"
    + "Cargo.toml\t\tREADME.md\t\tcrates\r\n"
    + zshPrompt("src")

/// The same in bash, whose preexec sets the title before the output mark, and whose prompt
/// sets it after the input mark.
private let bashQuickCommand =
    "ls\r\n" + "\(esc)]2;ls\(bel)" + "\(esc)]133;C;\(bel)"
    + "Cargo.toml  README.md  crates\r\n"
    + "\(esc)]133;D;0;aid=42\(bel)\(esc)]133;A;redraw=last;cl=line;aid=42\(bel)"
    + "\(esc)]133;P;k=i\(bel)me@host:~/src$ \(esc)]133;B\(bel)\(esc)[5 q\(esc)]2;~/src\(bel)"

/// Feeds `stream` one byte at a time (every way the stream can be cut into reads) and returns
/// each title shown along the way.
private func shownTitles(_ terminal: Terminal, _ stream: String) -> [String] {
    Array(stream.utf8).map { byte in
        terminal.write([byte])
        return terminal.shownTitle
    }
}

@Test(arguments: [("zsh", zshQuickCommand), ("bash", bashQuickCommand)])
func aQuickCommandNeverChangesTheShownTitle(shell: String, stream: String) {
    let terminal = makeTerminal()
    terminal.write(Array(zshPrompt("src").utf8))
    let before = terminal.shownTitle
    let titles = shownTitles(terminal, stream + stream)
    #expect(Set(titles) == [before], "\(shell)")
    #expect(terminal.title == "~/src", "\(shell)")
}

@Test func aFullScreenProgramShowsItsTitleWhileItRuns() {
    let terminal = makeTerminal()
    terminal.write(Array(zshPrompt("src").utf8))
    #expect(terminal.shownTitle == "")

    terminal.write(Array("vim notes.md\r\n\(esc)]133;C\(bel)\(esc)]2;vim notes.md\(bel)".utf8))
    #expect(terminal.shownTitle == "")
    terminal.write(Array("\(esc)[?1049h\(esc)[H\(esc)[2Jnotes".utf8))
    #expect(terminal.shownTitle == "vim notes.md")
    terminal.write(Array("\(esc)]2;notes.md - VIM\(bel)".utf8))
    #expect(terminal.shownTitle == "notes.md - VIM")

    terminal.write(Array("\(esc)[?1049l".utf8))
    #expect(terminal.shownTitle == "")
    terminal.write(Array(zshPrompt("src").utf8))
    #expect(terminal.shownTitle == "")
}

@Test func enteringAndLeavingTheAlternateScreenReportsATitleChange() {
    let terminal = makeTerminal()
    let changes = Mutex(0)
    var events = Terminal.Events()
    events.titleChanged = { changes.withLock { $0 += 1 } }
    terminal.setEvents(events)
    terminal.write(Array("\(esc)]133;A\(bel)$ \(esc)]133;B\(bel)htop\r\n\(esc)]133;C\(bel)".utf8))
    let afterStart = changes.withLock { $0 }
    terminal.write(Array("\(esc)[?1049h".utf8))
    #expect(changes.withLock { $0 } == afterStart + 1)
    terminal.write(Array("\(esc)[?1049l".utf8))
    #expect(changes.withLock { $0 } == afterStart + 2)
}

@Test func withoutShellIntegrationTheTitleShowsAsSet() {
    let terminal = makeTerminal()
    terminal.write(Array("\(esc)]2;make release\(bel)building\r\n".utf8))
    #expect(terminal.shownTitle == "make release")
    terminal.write(Array("\(esc)[?1049h".utf8))
    #expect(terminal.shownTitle == "make release")
}

@Test func aRestoredScreenAtAPromptKeepsFollowingTheShell() throws {
    let source = makeTerminal()
    source.write(Array((zshPrompt("src") + "\(esc)]2;ls\(bel)").utf8))
    let snapshot = try #require(source.encodeSnapshot())
    let (ready, _) = try #require(Terminal.splitSnapshot(snapshot))

    let restored = makeTerminal()
    try restored.restore(snapshot: ready)
    #expect(restored.title == "ls")
    #expect(restored.shownTitle == "")
}
