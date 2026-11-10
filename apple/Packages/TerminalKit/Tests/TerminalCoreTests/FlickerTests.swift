import Synchronization
import Testing
@testable import TerminalCore

/// Byte streams as shells and TUIs write them, cut at every possible place the way PTY reads and
/// network packets cut them. After every piece, the frame a renderer would present (the screen,
/// with echo predictions drawn over it) must be one the program meant to show.

private let esc = "\u{1B}"

private final class Clock {
    var t: Double = 100
}

/// The screen's row `y`, with prediction cells drawn over it, trailing blanks trimmed.
private func presentedRow(_ terminal: Terminal, _ predictor: EchoPredictor? = nil, row y: Int) -> String {
    let overlay = predictor?.overlay.filter { $0.y == y } ?? []
    var line = ""
    for x in 0..<terminal.size.cols {
        let text = overlay.first { $0.x == x }?.text ?? terminal.text(atActive: GridPoint(x: x, y: y))
        line += text.isEmpty ? " " : text
    }
    while line.hasSuffix(" ") { line.removeLast() }
    return line
}

private func screen(_ terminal: Terminal) -> [String] {
    (0..<terminal.size.rows).map { presentedRow(terminal, row: $0) }
}

/// Every way to cut `bytes` in two.
private func splits(_ bytes: [UInt8]) -> [[[UInt8]]] {
    (0...bytes.count).map { [Array(bytes[..<$0]), Array(bytes[$0...])] }
}

// MARK: zsh line editing with syntax highlighting and autosuggestions

/// What zsh (with zsh-syntax-highlighting and zsh-autosuggestions) writes when `typed` became the
/// buffer by one more keystroke and history suggests `suggestion`: the key's echo, then the whole
/// buffer rewritten in its highlight color, the suggestion's rest in gray, and the cursor moved
/// back to the end of the buffer.
private func zshEcho(typed: String, suggestion: String) -> [UInt8] {
    let rest = String(suggestion.dropFirst(typed.count))
    let color = typed == suggestion ? "32" : "31"
    var out = String(typed.last!)
    out += "\(esc)[\(typed.count)D\(esc)[\(color)m\(typed)\(esc)[39m"
    if !rest.isEmpty { out += "\(esc)[38;5;8m\(rest)\(esc)[39m\(esc)[\(rest.count)D" }
    return Array(out.utf8)
}

/// Types `command` at a zsh prompt over a link with `rtt`, the echo of every key cut at `cut`
/// bytes (clamped), and checks every presented frame.
private func typeAtZshPrompt(_ command: String, rtt: Double, cut: Int, acknowledged: Bool) {
    let clock = Clock()
    let terminal = Terminal(cols: 30, rows: 3) { _ in }
    let predictor = EchoPredictor(now: { clock.t })
    predictor.update(hint: EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: false))
    predictor.updateRTT(seconds: rtt)
    terminal.write(Array("% ".utf8))
    predictor.reconcile(screen: terminal)

    var typed = ""
    for character in command {
        typed.append(character)
        predictor.predict(.text(String(character)), screen: terminal)
        let seq = predictor.lastInputSeq
        check(typed: typed, echoed: typed.count - 1)
        clock.t += rtt
        let echo = zshEcho(typed: typed, suggestion: command)
        let at = min(cut, echo.count)
        for piece in [Array(echo[..<at]), Array(echo[at...])] {
            terminal.write(piece)
            predictor.reconcile(screen: terminal)
            check(typed: typed, echoed: typed.count - 1)
        }
        if acknowledged {
            predictor.acknowledge(upTo: seq)
            predictor.reconcile(screen: terminal)
        }
        check(typed: typed, echoed: typed.count)
    }
    #expect(predictor.stats.mispredicted == 0)
    #expect(presentedRow(terminal, row: 0) == "% \(command)")

    func check(typed: String, echoed: Int) {
        let line = presentedRow(terminal, predictor, row: 0)
        // The buffer and its suggestion, never a doubled or shifted letter.
        #expect("% \(command)".hasPrefix(line), "presented \(line.debugDescription) after typing \(typed.debugDescription)")
        let echoedLine = echoed == 0 ? "%" : "% \(typed.prefix(echoed))"
        #expect(line.hasPrefix(echoedLine), "presented \(line.debugDescription) lost echoed text")
        let underlined = predictor.overlay.contains { $0.underlined }
        #expect(!underlined, "an on-time echo was underlined")
    }
}

@Suite("No flicker: zsh line editing")
struct ZshLineEditingTests {
    @Test(arguments: [0.005, 0.1, 0.3])
    func typingClearWithHighlightingAndAutosuggestions(rtt: Double) {
        for cut in 0...40 {
            typeAtZshPrompt("clear", rtt: rtt, cut: cut, acknowledged: false)
            typeAtZshPrompt("clear", rtt: rtt, cut: cut, acknowledged: true)
        }
    }

    @Test func clearScreenCutAnywhereNeverPrintsItsBytes() {
        let output = Array("\r\n\(esc)[H\(esc)[2J\(esc)[3J% ".utf8)
        for pieces in splits(output) {
            let terminal = Terminal(cols: 30, rows: 3) { _ in }
            terminal.write(Array("% clear".utf8))
            for piece in pieces {
                terminal.write(piece)
                let rows = screen(terminal)
                #expect(rows == ["% clear", "", ""] || rows == ["", "", ""] || rows == ["%", "", ""], "\(rows)")
            }
        }
    }
}

// MARK: zsh right prompt (RPROMPT) with powerline glyphs

/// What zsh writes, as captured from zsh 5.9 in a 40-column PTY: a powerline left prompt, the
/// right prompt drawn at the right edge (one column of indent), and the cursor moved back after
/// the left prompt.
private let rightPromptCols: UInt16 = 40
private let leftPrompt = "/ \u{E0B0} "
private let leftPromptWidth = 4

private struct RightPrompt: CustomTestStringConvertible {
    var text: String
    var width: Int

    var start: Int { Int(rightPromptCols) - 1 - width }
    var draw: String {
        "\(esc)[J\(leftPrompt)\(esc)[K\(esc)[\(start - leftPromptWidth)C\(text)\(esc)[\(start + width - leftPromptWidth)D"
    }
    var testDescription: String { text }

    /// A separator, ✓, the time and a wide clock emoji.
    static let withClock = RightPrompt(text: "\u{E0B2} \u{2713} 10:09 \u{1F558}", width: 12)
    /// Powerline separators and narrow text only.
    static let narrow = RightPrompt(text: "\u{E0B2} \u{2713} \u{E0B3} 10:09", width: 11)
}

/// zsh's echo of one typed character at column `x`: the character, and once the buffer reaches
/// the cell before the right prompt, an erase of the rest of the line, which removes it.
private func zshRightPromptEcho(_ character: Character, at x: Int, prompt: RightPrompt) -> [UInt8] {
    Array((String(character) + (x >= prompt.start - 1 ? "\(esc)[K" : "")).utf8)
}

/// Types `command` toward the right prompt over a link with `rtt`, the echo cut at `cut` bytes,
/// and checks every presented frame: the buffer typed so far, then blanks, then either the whole
/// right prompt where zsh drew it or nothing; never a moved separator or half a prompt.
private func typeTowardRightPrompt(_ command: String, prompt: RightPrompt, rtt: Double, cut: Int, acknowledged: Bool) {
    let clock = Clock()
    let terminal = Terminal(cols: rightPromptCols, rows: 2) { _ in }
    let predictor = EchoPredictor(now: { clock.t })
    predictor.update(hint: EchoHint(echo: false, canonical: false, atPrompt: true, altScreen: false))
    predictor.updateRTT(seconds: rtt)
    terminal.write(Array(prompt.draw.utf8))
    predictor.reconcile(screen: terminal)
    let leftWidth = leftPromptWidth
    let rightPromptStart = prompt.start
    let rightPrompt = prompt.text
    #expect(presentedRow(terminal, row: 0) == leftPrompt + String(repeating: " ", count: rightPromptStart - leftWidth) + rightPrompt)

    var typed = ""
    for character in command {
        let x = leftWidth + typed.count
        typed.append(character)
        predictor.predict(.text(String(character)), screen: terminal)
        let seq = predictor.lastInputSeq
        check(typed)
        clock.t += rtt
        let echo = zshRightPromptEcho(character, at: x, prompt: prompt)
        let at = min(cut, echo.count)
        for piece in [Array(echo[..<at]), Array(echo[at...])] {
            terminal.write(piece)
            predictor.reconcile(screen: terminal)
            check(typed)
        }
        if acknowledged {
            predictor.acknowledge(upTo: seq)
            predictor.reconcile(screen: terminal)
        }
        check(typed)
    }
    #expect(predictor.stats.mispredicted == 0)
    #expect(presentedRow(terminal, row: 0) == leftPrompt + command)

    func check(_ typed: String) {
        let row = presentedRow(terminal, predictor, row: 0)
        let cells = Array(row)
        let left = String(cells.prefix(rightPromptStart))
        let right = String(cells.dropFirst(rightPromptStart))
        var buffer = String(left.dropFirst(leftWidth))
        while buffer.hasSuffix(" ") { buffer.removeLast() }
        #expect(left.hasPrefix(leftPrompt), "the left prompt moved: \(row.debugDescription)")
        #expect(typed.hasPrefix(buffer), "presented \(row.debugDescription) after typing \(typed.debugDescription)")
        let typedPastStart = String(typed.dropFirst(rightPromptStart - leftWidth))
        #expect(right == rightPrompt || right.isEmpty || typedPastStart.hasPrefix(right),
                "the right prompt was cut or moved: \(row.debugDescription)")
    }
}

@Suite("No flicker: zsh right prompt")
struct ZshRightPromptTests {
    @Test(arguments: [RightPrompt.withClock, .narrow], [0.005, 0.1, 0.3])
    fileprivate func typingIntoTheRightPrompt(prompt: RightPrompt, rtt: Double) {
        for cut in 0...4 {
            typeTowardRightPrompt("echo abcdefghijklmnopqrstuvwxyz", prompt: prompt, rtt: rtt, cut: cut, acknowledged: false)
            typeTowardRightPrompt("echo abcdefghijklmnopqrstuvwxyz", prompt: prompt, rtt: rtt, cut: cut, acknowledged: true)
        }
    }
}

// MARK: Synchronized output (mode 2026)

private func frame(_ name: String, rows: Int = 4) -> [String] {
    (0..<rows).map { "\(name) row \($0)" }
}

/// A full-screen redraw as Claude Code or Codex write one: begin synchronized update, home,
/// clear, every row, end.
private func synchronizedFrame(_ name: String, rows: Int = 4) -> [UInt8] {
    var out = "\(esc)[?2026h\(esc)[H\(esc)[2J"
    for (index, row) in frame(name, rows: rows).enumerated() {
        out += "\(esc)[\(index + 1);1H\(esc)[1;3\(index + 1)m\(row)\(esc)[0m"
    }
    out += "\(esc)[?2026l"
    return Array(out.utf8)
}

private func tui() -> Terminal {
    let terminal = Terminal(cols: 20, rows: 4) { _ in }
    terminal.write(synchronizedFrame("A"))
    return terminal
}

@Suite("No flicker: synchronized output")
struct SynchronizedOutputTests {
    @Test func aFrameCutAnywhereIsShownWhole() {
        for pieces in splits(synchronizedFrame("B")) {
            let terminal = tui()
            for piece in pieces {
                terminal.write(piece)
                #expect([frame("A"), frame("B")].contains(screen(terminal)), "\(screen(terminal))")
            }
            #expect(screen(terminal) == frame("B"))
            #expect(!terminal.isHoldingOutput)
        }
    }

    @Test func aFrameInManySmallPiecesIsShownWhole() {
        let terminal = tui()
        for byte in synchronizedFrame("B") {
            terminal.write([byte])
            #expect([frame("A"), frame("B")].contains(screen(terminal)))
        }
        #expect(screen(terminal) == frame("B"))
    }

    /// One piece ends a frame and starts the next: the finished frame is shown, not skipped.
    @Test func consecutiveFramesCutAnywhere() {
        let stream = synchronizedFrame("B") + synchronizedFrame("C")
        for pieces in splits(stream) {
            let terminal = tui()
            var seen: [[String]] = []
            for piece in pieces {
                terminal.write(piece)
                let rows = screen(terminal)
                #expect([frame("A"), frame("B"), frame("C")].contains(rows), "\(rows)")
                seen.append(rows)
            }
            #expect(seen.last == frame("C"))
        }
        let terminal = tui()
        let cut = synchronizedFrame("B").count + 5
        terminal.write(Array(stream[..<cut]))
        #expect(screen(terminal) == frame("B"))
    }

    @Test func outputBeforeTheUpdateIsShownAtOnce() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("before\(esc)[?2026h\(esc)[2Jhalf".utf8))
        #expect(screen(terminal)[0] == "before")
        #expect(terminal.isHoldingOutput)
    }

    @Test func plainOutputIsNotHeld() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("\(esc)[?25l\(esc)[?1049hhi\(esc)]0;title\u{07}".utf8))
        #expect(!terminal.isHoldingOutput)
        #expect(screen(terminal)[0] == "hi")
    }

    @Test func combinedModeParametersCount() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("\(esc)[?25;2026hhalf".utf8))
        #expect(terminal.isHoldingOutput)
        #expect(screen(terminal)[0] == "")
        terminal.write(Array("\(esc)[?2026;25l".utf8))
        #expect(screen(terminal)[0] == "half")
    }

    @Test func anUnfinishedUpdateIsShownAfterTheTimeout() {
        let terminal = tui()
        terminal.write(Array("\(esc)[?2026h\(esc)[Hhalf".utf8))
        #expect(screen(terminal) == frame("A"))
        #expect(!terminal.releaseExpiredHeldOutput(now: .now + .milliseconds(500)))
        #expect(screen(terminal) == frame("A"))
        #expect(!terminal.hasExpiredHeldOutput(now: .now + .milliseconds(500)))
        #expect(terminal.hasExpiredHeldOutput(now: .now + .seconds(2)))
        #expect(screen(terminal) == frame("A"), "asking parses nothing")
        #expect(terminal.releaseExpiredHeldOutput(now: .now + .seconds(2)))
        #expect(screen(terminal)[0].hasPrefix("half"))
        #expect(!terminal.isHoldingOutput)
        // Output after the timeout is shown as it comes, until the next update begins.
        terminal.write(Array("!".utf8))
        #expect(screen(terminal)[0].hasPrefix("half!"))
    }

    @Test func aHugeUpdateIsNotHeldWhole() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("\(esc)[?2026h".utf8))
        terminal.write([UInt8](repeating: UInt8(ascii: "x"), count: SynchronizedOutput.maxHeldBytes + 1))
        #expect(!terminal.isHoldingOutput)
        #expect(screen(terminal)[0] == String(repeating: "x", count: 20))
    }

    @Test func aResizeShowsTheHeldUpdateFirst() {
        let terminal = tui()
        terminal.write(Array("\(esc)[?2026h\(esc)[1;1HB".utf8))
        terminal.resize(cols: 10, rows: 4, cellWidth: 8, cellHeight: 16)
        #expect(!terminal.isHoldingOutput)
        #expect(screen(terminal)[0] == "B row 0")
    }

    @Test func aQueryInsideAnUpdateIsAnsweredWhenTheTerminalAnswers() {
        let replies = Replies()
        let terminal = Terminal(cols: 20, rows: 4) { replies.append(Array($0)) }
        terminal.write(Array("\(esc)[?2026hx\(esc)[6n".utf8))
        #expect(!terminal.isHoldingOutput)
        #expect(!replies.bytes.isEmpty)

        let mirror = Terminal(cols: 20, rows: 4) { _ in }
        mirror.answersQueries = false
        mirror.write(Array("\(esc)[?2026hx\(esc)[6n".utf8))
        #expect(mirror.isHoldingOutput)
    }

    @Test func aSnapshotCarriesTheHeldUpdate() throws {
        let terminal = tui()
        terminal.write(Array("\(esc)[?2026h\(esc)[1;1HB".utf8))
        let snapshot = try #require(terminal.encodeSnapshot())
        let copy = Terminal(cols: 20, rows: 4) { _ in }
        try copy.restore(snapshot: snapshot)
        #expect(screen(copy)[0] == "B row 0")
    }

    @Test func aSnapshotTakenInsideAnUpdateHoldsTheRest() throws {
        // The host's terminal mid-update, as a daemon may snapshot it.
        let host = tui()
        let half = Array("\(esc)[?2026h\(esc)[H\(esc)[2J".utf8)
        host.lock.withLock { _ in half.withUnsafeBufferPointer { host.parseLocked($0) } }
        let snapshot = try #require(host.encodeSnapshot())
        let client = Terminal(cols: 20, rows: 4) { _ in }
        try client.restore(snapshot: snapshot)
        #expect(client.isHoldingOutput)
        client.write(Array("\(esc)[1;1HB\(esc)[?2026l".utf8))
        #expect(!client.isHoldingOutput)
        #expect(screen(client)[0] == "B")
    }
}

private final class Replies: Sendable {
    private let stored = Mutex<[UInt8]>([])
    func append(_ bytes: [UInt8]) { stored.withLock { $0 += bytes } }
    var bytes: [UInt8] { stored.withLock { $0 } }
}
