import Synchronization
import Testing
@testable import TerminalCore

/// The replies coding-agent TUIs (Claude Code, Codex) probe a terminal with, for panes whose
/// program runs on this device: the same as Ghostty's for the same theme, and as a host's
/// daemon gives for its panes (`crates/ghostty-vt/tests/it/queries.rs`).
@Suite struct AgentQueryTests {
    final class Replies: Sendable {
        let bytes = Mutex<[UInt8]>([])
        var text: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
        func clear() { bytes.withLock { $0.removeAll() } }
    }

    private func terminal(_ configuration: Terminal.Configuration = .init()) -> (Terminal, Replies) {
        let replies = Replies()
        let terminal = Terminal(cols: 80, rows: 24, configuration: configuration) { bytes in replies.bytes.withLock { $0 += bytes } }
        terminal.resize(cols: 80, rows: 24, cellWidth: 9, cellHeight: 18)
        return (terminal, replies)
    }

    private func ask(_ terminal: Terminal, _ replies: Replies, _ query: String) -> String {
        replies.clear()
        terminal.write(Array(query.utf8))
        return replies.text
    }

    private var light: Terminal.Configuration {
        var configuration = Terminal.Configuration()
        configuration.background = RGB(r: 0xFA, g: 0xFA, b: 0xFA)
        configuration.foreground = RGB(r: 0x38, g: 0x3A, b: 0x42)
        configuration.cursorColor = RGB(r: 0x52, g: 0x6F, b: 0xFF)
        return configuration
    }

    @Test func identityMatchesGhostty() {
        let (t, replies) = terminal()
        #expect(ask(t, replies, "\u{1b}[c") == "\u{1b}[?62;22;52c")
        #expect(ask(t, replies, "\u{1b}[>c") == "\u{1b}[>1;10;0c")
        #expect(ask(t, replies, "\u{1b}[>q") == "\u{1b}P>|\(Terminal.xtversion)\u{1b}\\")
        #expect(Terminal.xtversion.hasPrefix("ghostty \(Terminal.ghosttyVersion)"))
        #expect(!Terminal.ghosttyVersion.isEmpty)
        let hex = { (text: String) in text.utf8.map { String(format: "%02X", $0) }.joined() }
        #expect(ask(t, replies, "\u{1b}P+q\(hex("TN"))\u{1b}\\") == "\u{1b}P1+r\(hex("TN"))=\(hex("xterm-256color"))\u{1b}\\")
    }

    @Test func modesAgentTUIsProbeMatchGhostty() {
        let (t, replies) = terminal()
        for (mode, state) in [(2026, 2), (2027, 1), (2004, 2), (1004, 2), (1006, 2), (2031, 2)] {
            #expect(ask(t, replies, "\u{1b}[?\(mode)$p") == "\u{1b}[?\(mode);\(state)$y", "mode \(mode)")
        }
        #expect(ask(t, replies, "\u{1b}[?u") == "\u{1b}[?0u")
        #expect(ask(t, replies, "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\") == "\u{1b}_Gi=31;OK\u{1b}\\")
        #expect(ask(t, replies, "\u{1b}]7501;?\u{1b}\\").hasPrefix("\u{1b}]7501;?:states="))
    }

    @Test func sizesAreReported() {
        let (t, replies) = terminal()
        #expect(ask(t, replies, "\u{1b}[18t") == "\u{1b}[8;24;80t")
        #expect(ask(t, replies, "\u{1b}[16t") == "\u{1b}[6;18;9t")
    }

    @Test func colorQueriesAnswerTheTheme() {
        let (dark, darkReplies) = terminal()
        #expect(ask(dark, darkReplies, "\u{1b}]11;?\u{1b}\\") == "\u{1b}]11;rgb:2828/2c2c/3434\u{1b}\\")
        #expect(ask(dark, darkReplies, "\u{1b}[?996n") == "\u{1b}[?997;1n")
        let (t, replies) = terminal(light)
        #expect(ask(t, replies, "\u{1b}]10;?\u{1b}\\") == "\u{1b}]10;rgb:3838/3a3a/4242\u{1b}\\")
        #expect(ask(t, replies, "\u{1b}]11;?\u{1b}\\") == "\u{1b}]11;rgb:fafa/fafa/fafa\u{1b}\\")
        #expect(ask(t, replies, "\u{1b}]12;?\u{1b}\\") == "\u{1b}]12;rgb:5252/6f6f/ffff\u{1b}\\")
        #expect(ask(t, replies, "\u{1b}[?996n") == "\u{1b}[?997;2n")
    }

    @Test func aThemeSwitchIsReportedToProgramsThatAsked() {
        let (t, replies) = terminal()
        _ = ask(t, replies, "\u{1b}[?2031h")
        replies.clear()
        t.setDefaults(light)
        #expect(replies.text == "\u{1b}[?997;2n")
        replies.clear()
        t.setDefaults(light)
        #expect(replies.text.isEmpty)
    }

    @Test func aMirrorOfAHostPaneLeavesAnsweringToTheHost() {
        let (t, replies) = terminal()
        t.answersQueries = false
        #expect(ask(t, replies, "\u{1b}[c\u{1b}[>q\u{1b}]11;?\u{1b}\\").isEmpty)
        _ = ask(t, replies, "\u{1b}[?2031h")
        t.setDefaults(light)
        #expect(replies.text.isEmpty)
    }
}
