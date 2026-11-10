import Foundation
import Testing
@testable import TerminalCore

/// URLs and paths in terminal text (`LinkDetector`) and the link under a cell (`Terminal.link`).
@Suite struct LinkTests {
    private func kinds(_ line: String) -> [String] {
        LinkDetector.matches(in: line).map { "\($0.kind == .url ? "url" : "path"):\($0.text)" }
    }

    @Test func findsURLsWithGhosttysTrailingRules() {
        #expect(kinds("  ➜  Local:   http://localhost:5173/") == ["url:http://localhost:5173/"])
        #expect(kinds("see https://example.com/a.") == ["url:https://example.com/a"])
        #expect(kinds("(https://example.com)") == ["url:https://example.com"])
        #expect(kinds("https://en.wikipedia.org/wiki/Rust_(video_game)") == ["url:https://en.wikipedia.org/wiki/Rust_(video_game)"])
        #expect(kinds("[docs](https://x.dev/y), and more") == ["url:https://x.dev/y"])
    }

    @Test func findsPathsWithLineAndColumn() throws {
        let matches = LinkDetector.matches(in: "error[E0308]: src/main.rs:12:5 mismatched types")
        let path = try #require(matches.first)
        #expect(path.kind == .path)
        #expect(path.target == "src/main.rs")
        #expect(path.line == 12)
        #expect(path.column == 5)
        #expect(kinds("  --> /home/me/app/lib.rs:7") == ["path:/home/me/app/lib.rs:7"])
        #expect(kinds("cat ~/notes.md ./run.sh ../up/x") == ["path:~/notes.md", "path:./run.sh", "path:../up/x"])
        #expect(kinds("main.go:42: undefined: foo") == ["path:main.go:42"])
    }

    @Test func wordsWithSlashesAreNotPaths() {
        #expect(kinds("use TCP/IP and/or I/O at 3/4 on 2026/10/20") == [])
        #expect(kinds("version 1.2.3, ratio 0.5") == [])
    }

    @Test func urlsWinOverThePathsInsideThem() {
        #expect(kinds("open https://github.com/org/repo/blob/main/a.rs now") == ["url:https://github.com/org/repo/blob/main/a.rs"])
    }

    @Test func resolvesRelativePathsAgainstTheDirectory() {
        let link = TerminalLink(kind: .path, text: "./src/a.rs", target: "./src/a.rs")
        #expect(link.resolvedPath(relativeTo: "/home/me/app/") == "/home/me/app/src/a.rs")
        let rooted = TerminalLink(kind: .path, text: "/etc/hosts", target: "/etc/hosts")
        #expect(rooted.resolvedPath(relativeTo: "/home") == "/etc/hosts")
    }

    private func located(_ line: String) -> [String] {
        LinkDetector.matches(in: line).map { match in
            [match.target, match.line.map(String.init), match.column.map(String.init)].compactMap { $0 }.joined(separator: " ")
        }
    }

    @Test func findsQuotedPathsWithSpaces() {
        #expect(kinds(#"open "/home/me/My Notes/plan.md" now"#) == ["path:/home/me/My Notes/plan.md"])
        #expect(kinds("saved 'src/app view.swift'") == ["path:src/app view.swift"])
        #expect(kinds("run `./scripts/build.sh` first") == ["path:./scripts/build.sh"])
        #expect(kinds("don't touch it's fine") == [])
        #expect(kinds("say 'hello there' twice") == [])
    }

    @Test func findsEveryLineAndColumnFormat() {
        #expect(located("src/a.ts(12,5): error TS2322") == ["src/a.ts 12 5"])
        #expect(located("lib/b.cs(7): warning") == ["lib/b.cs 7"])
        #expect(located(#"  File "/usr/lib/tool.py", line 42, in main"#) == ["/usr/lib/tool.py 42"])
        #expect(located("app/main.c:10.4: parse error") == ["app/main.c 10 4"])
        #expect(located("main.rs [3, 9] unused import") == ["main.rs 3 9"])
        #expect(located("main.go:42:7: undefined") == ["main.go 42 7"])
        #expect(located("see src/a.rs:12.") == ["src/a.rs 12"])
    }

    @Test func pythonTracebackUnderlinesOnlyThePath() throws {
        let line = #"  File "/srv/app.py", line 3"#
        let match = try #require(LinkDetector.matches(in: line).first)
        #expect(match.text == "/srv/app.py")
        #expect(match.range == 8..<19)
    }

    @Test func resolvingNormalisesDotDot() {
        let link = TerminalLink(kind: .path, text: "../lib/./b.rs", target: "../lib/./b.rs")
        #expect(link.resolvedPath(relativeTo: "/home/me/app/src") == "/home/me/app/lib/b.rs")
        let rooted = TerminalLink(kind: .path, text: "/a/b/../../../c", target: "/a/b/../../../c")
        #expect(rooted.resolvedPath(relativeTo: nil) == "/c")
        let home = TerminalLink(kind: .path, text: "~/x/../y.md", target: "~/x/../y.md")
        #expect(home.resolvedPath(relativeTo: "/tmp") == "~/y.md")
        #expect(TerminalPath.normalized("a/../../b") == "../b")
    }

    @Test func fileURLKeepsItsHost() throws {
        let local = try #require(LinkDetector.matches(in: "at file:///etc/hosts ok").first)
        #expect(local.kind == .path)
        #expect(local.host == nil)
        let remote = try #require(LinkDetector.matches(in: "at file://build-box/etc/hosts ok").first)
        #expect(remote.kind == .path)
        #expect(remote.host == "build-box")
        #expect(remote.target == "/etc/hosts")
        let loopback = try #require(LinkDetector.matches(in: "file://localhost/tmp/a.txt").first)
        #expect(loopback.host == nil)
    }

    @Test func hyperlinkFileURLKeepsItsHost() throws {
        let terminal = Terminal(cols: 40, rows: 3) { _ in }
        terminal.write(Array("\u{1b}]8;;file://other-mac/tmp/a.txt\u{1b}\\a.txt\u{1b}]8;;\u{1b}\\".utf8))
        let link = try #require(terminal.link(atViewport: GridPoint(x: 1, y: 0)))
        #expect(link.kind == .path)
        #expect(link.host == "other-mac")
        #expect(link.target == "/tmp/a.txt")
    }

    // MARK: On a terminal

    @Test func linkUnderACellCoversItsCells() throws {
        let terminal = Terminal(cols: 40, rows: 3) { _ in }
        terminal.write(Array("Local: http://localhost:3000/ ok".utf8))
        let link = try #require(terminal.link(atViewport: GridPoint(x: 12, y: 0)))
        #expect(link.kind == .url)
        #expect(link.target == "http://localhost:3000/")
        #expect(link.columns == 7...28)
        #expect(terminal.link(atViewport: GridPoint(x: 2, y: 0)) == nil)
        #expect(terminal.link(atViewport: GridPoint(x: 31, y: 0)) == nil)
    }

    @Test func wrappedURLIsOneLink() throws {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("go https://example.com/a/very/long/path end".utf8))
        // The URL wraps onto row 1 and row 2; tapping its tail finds the whole thing.
        let link = try #require(terminal.link(atViewport: GridPoint(x: 2, y: 1)))
        #expect(link.target == "https://example.com/a/very/long/path")
        #expect(link.row == 1)
        #expect(link.columns == 0...18)  // "om/a/very/long/path", then a space
    }

    @Test func hyperlinksComeFirst() throws {
        let terminal = Terminal(cols: 40, rows: 3) { _ in }
        terminal.write(Array("\u{1b}]8;;https://ghostty.org\u{1b}\\click here\u{1b}]8;;\u{1b}\\ /tmp/x.txt".utf8))
        let link = try #require(terminal.link(atViewport: GridPoint(x: 3, y: 0)))
        #expect(link.isHyperlink)
        #expect(link.target == "https://ghostty.org")
        #expect(link.columns == 0...9)
        let path = try #require(terminal.link(atViewport: GridPoint(x: 13, y: 0)))
        #expect(path.kind == .path)
        #expect(path.target == "/tmp/x.txt")
    }

    @Test func longHyperlinksAreReadWhole() throws {
        let terminal = Terminal(cols: 40, rows: 3) { _ in }
        // As long as libghostty-vt's OSC parser keeps (2048 bytes with the `8;;` before it).
        let uri = "https://example.com/?q=" + String(repeating: "a", count: 2020)
        terminal.write(Array("\u{1b}]8;;\(uri)\u{1b}\\click here\u{1b}]8;;\u{1b}\\ after".utf8))
        let link = try #require(terminal.link(atViewport: GridPoint(x: 3, y: 0)))
        #expect(link.target == uri)
        #expect(link.columns == 0...9)
        #expect(link.label == "click here")
    }

    @Test func wideCharactersKeepColumnsRight() throws {
        let terminal = Terminal(cols: 40, rows: 3) { _ in }
        terminal.write(Array("你好 ./a.txt:3".utf8))
        // "你好" takes four cells; the path starts at column 5.
        let link = try #require(terminal.link(atViewport: GridPoint(x: 6, y: 0)))
        #expect(link.columns == 5...13)
        #expect(link.line == 3)
    }
}

/// A link's label is what a person could read on screen, so hidden cells cannot make another
/// address look seen (LinkSafety opens only a seen address without asking).
@Suite struct LinkLabelTests {
    private func link(_ output: String) throws -> TerminalLink {
        let terminal = Terminal(cols: 80, rows: 3) { _ in }
        terminal.write(Array(output.utf8))
        return try #require(terminal.link(atViewport: GridPoint(x: 3, y: 0)))
    }

    private func action(_ link: TerminalLink) -> LinkSafety.Action {
        LinkSafety.action(for: URL(string: link.target)!, shown: link.label)
    }

    @Test func hyperlinkLabelIsItsCells() throws {
        let link = try link("\u{1b}]8;;https://evil.example/\u{1b}\\https://github.com/\u{1b}]8;;\u{1b}\\")
        #expect(link.label == "https://github.com/")
        #expect(action(link) == .confirm)
    }

    @Test func hiddenCellsAreNotPartOfWhatWasSeen() throws {
        let tails = [
            "\u{1b}[8m.evil.example/x\u{1b}[28m",  // concealed
            "\u{1b}[38;5;1;48;5;1m.evil.example/x\u{1b}[0m",  // same palette colour
            "\u{1b}[38;2;9;9;9;48;2;9;9;9m.evil.example/x\u{1b}[0m",  // same RGB
            "\u{1b}[38;2;9;9;10;48;2;9;9;9m.evil.example/x\u{1b}[0m",  // all but the same
            "\u{1b}]11;rgb:10/20/30\u{1b}\\\u{1b}[38;2;16;32;48m.evil.example/x\u{1b}[0m",  // the background's colour
            "\u{1b}[7;38;5;4;48;5;4m.evil.example/x\u{1b}[0m",  // inverse of one colour
        ]
        for tail in tails {
            let printed = try link("https://github.com" + tail + " ok")
            #expect(printed.target == "https://github.com.evil.example/x", "\(tail.debugDescription)")
            #expect(printed.label == "https://github.com", "\(tail.debugDescription)")
            #expect(action(printed) == .confirm, "\(tail.debugDescription)")
            let osc8 = try link("\u{1b}]8;;https://github.com.evil.example/x\u{1b}\\https://github.com" + tail + "\u{1b}]8;;\u{1b}\\")
            #expect(action(osc8) == .confirm, "\(tail.debugDescription)")
        }
        // Coloured links are seen.
        #expect(action(try link("\u{1b}[34mhttps://github.com/x\u{1b}[0m")) == .open)
        #expect(action(try link("\u{1b}[44mhttps://github.com/x\u{1b}[0m")) == .open)
    }
}
