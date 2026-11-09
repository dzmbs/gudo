#if os(macOS)
import AppKit
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// The Mac terminal view as a VoiceOver text area: its text, lines, selection, insertion point,
/// character frames and links.
@MainActor
@Suite(.serialized) struct AppKitAccessibilityTests {
    private func makeView(_ output: String) -> (TerminalView, NSWindow)? {
        _ = NSApplication.shared
        let terminal = Terminal(cols: 40, rows: 5) { _ in }
        guard let surface = try? TerminalSurface(terminal: terminal) else { return nil }
        let view = TerminalView(surface: surface)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        show(output, in: view)
        return (view, window)
    }

    private func show(_ output: String, in view: TerminalView) {
        view.surface.terminal.write(Array(output.utf8))
        view.surface.renderIfDirty(offscreen: true)
    }

    @Test func valueAndLinesFollowTheScreen() throws {
        let (view, window) = try #require(makeView("one\r\ntwo"))
        #expect(view.accessibilityValue() as? String == "one\ntwo")
        #expect(view.accessibilityNumberOfCharacters() == 7)
        #expect(view.accessibilityVisibleCharacterRange() == NSRange(location: 0, length: 7))
        #expect(view.accessibilityRange(forLine: 1) == NSRange(location: 4, length: 3))
        #expect(view.accessibilityLine(for: 5) == 1)
        #expect(view.accessibilityString(for: NSRange(location: 4, length: 3)) == "two")
        show("\r\nthree", in: view)
        #expect(view.accessibilityValue() as? String == "one\ntwo\nthree")
        withExtendedLifetime(window) {}
    }

    @Test func softWrappedRowsJoinWithoutALineBreak() throws {
        let (view, window) = try #require(makeView(""))
        let cols = Int(try #require(view.surface.grid).cols)
        show(String(repeating: "a", count: cols + 3), in: view)
        #expect(view.accessibilityValue() as? String == String(repeating: "a", count: cols + 3))
        #expect(view.accessibilityLine(for: cols + 1) == 1)
        withExtendedLifetime(window) {}
    }

    @Test func insertionPointIsAtTheCursor() throws {
        let (view, window) = try #require(makeView("$ ls\r\n$ "))
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 7, length: 0))
        #expect(view.accessibilitySelectedText() == "")
        #expect(view.accessibilityInsertionPointLineNumber() == 1)
        withExtendedLifetime(window) {}
    }

    @Test func selectionMapsBothWays() throws {
        let (view, window) = try #require(makeView("hello world"))
        view.surface.terminal.selectWord(atViewport: GridPoint(x: 1, y: 0))
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 0, length: 5))
        #expect(view.accessibilitySelectedText() == "hello")
        view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 5))
        #expect(view.surface.terminal.selectionText() == "world")
        #expect(view.accessibilitySelectedTextRanges() == [NSValue(range: NSRange(location: 6, length: 5))])
        withExtendedLifetime(window) {}
    }

    @Test func characterFramesAreOnScreenCells() throws {
        let (view, window) = try #require(makeView("ab"))
        let cell = try #require(view.surface.cellSize)
        let frame = view.accessibilityFrame(for: NSRange(location: 1, length: 1))
        #expect(abs(frame.width - cell.width) < 0.01)
        #expect(abs(frame.height - cell.height) < 0.01)
        #expect(view.accessibilityRange(for: NSPoint(x: frame.midX, y: frame.midY)) == NSRange(location: 1, length: 1))
        withExtendedLifetime(window) {}
    }

    @Test func hyperlinksAreLinksInTheAttributedText() throws {
        let (view, window) = try #require(makeView("see \u{1b}]8;;https://example.com\u{1b}\\docs\u{1b}]8;;\u{1b}\\ now"))
        let attributed = try #require(view.accessibilityAttributedString(for: NSRange(location: 2, length: 6)))
        #expect(attributed.string == "e docs")
        var linkRange = NSRange()
        let link = attributed.attribute(.link, at: 3, effectiveRange: &linkRange) as? URL
        #expect(link == URL(string: "https://example.com"))
        #expect(linkRange == NSRange(location: 2, length: 4))
        withExtendedLifetime(window) {}
    }

    private func children(_ view: TerminalView, role: NSAccessibility.Role) -> [NSAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == role }
    }

    @Test func linksAreChildLinksThatOpenLikeACommandClick() throws {
        let (view, window) = try #require(makeView("\u{1b}]8;;https://example.com\u{1b}\\docs\u{1b}]8;;\u{1b}\\ and https://gudo.dev"))
        var opened: [TerminalLink] = []
        view.onOpenLink = { opened.append($0) }
        let links = children(view, role: .link)
        #expect(links.map { $0.accessibilityLabel() } == ["docs", "https://gudo.dev"])
        #expect(links.map { $0.accessibilityURL() } == [URL(string: "https://example.com"), URL(string: "https://gudo.dev")])
        let first = try #require(links.first)
        #expect(first.accessibilityFrame() == view.accessibilityFrame(for: NSRange(location: 0, length: 4)))
        #expect(first.accessibilityParent() as? TerminalView === view)
        #expect(first.accessibilityPerformPress())
        #expect(opened.map(\.target) == ["https://example.com"])
        let attributed = try #require(view.accessibilityAttributedString(for: NSRange(location: 0, length: 4)))
        #expect(attributed.attribute(.accessibilityLink, at: 0, effectiveRange: nil) as? NSAccessibilityElement === first)
        #expect(children(view, role: .link).first === first)
        withExtendedLifetime(window) {}
    }

    @Test func printedPathsAreLinksOnlyWhenTheyAreUnderlined() throws {
        let (view, window) = try #require(makeView("/tmp/kept.txt /tmp/gone.txt"))
        view.underlinesPath = { $0.target == "/tmp/kept.txt" }
        #expect(children(view, role: .link).map { $0.accessibilityLabel() } == ["/tmp/kept.txt"])
        withExtendedLifetime(window) {}
    }

    @Test func passwordPromptIsASecureFieldThatDoesNotReadTyping() throws {
        let (view, window) = try #require(makeView("Password: "))
        #expect(view.accessibilitySubrole() == nil)
        view.surface.enablePrediction()
        view.surface.applyPrediction(.hint(EchoHint(echo: false, canonical: true, atPrompt: false, altScreen: false)))
        #expect(view.accessibilitySubrole() == .secureTextField)
        view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.accessibilityValue() as? String == "")
        withExtendedLifetime(window) {}
    }
}
#endif
