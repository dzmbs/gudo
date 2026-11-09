#if os(iOS)
import Testing
import UIKit
@testable import TerminalCore
@testable import TerminalRenderer

/// The iOS terminal for VoiceOver: the screen read line by line, its links, images and password prompts.
@MainActor
@Suite(.serialized) struct UIKitAccessibilityTests {
    private func makeView(_ output: String) throws -> (TerminalView, UIWindow) {
        let terminal = Terminal(cols: 40, rows: 5) { _ in }
        let view = TerminalView(surface: try TerminalSurface(terminal: terminal))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.frame = window.bounds
        window.addSubview(view)
        view.layoutIfNeeded()
        terminal.write(Array(output.utf8))
        view.surface.renderIfDirty(offscreen: true)
        return (view, window)
    }

    private func screenElement(_ view: TerminalView) throws -> UIAccessibilityElement & UIAccessibilityReadingContent {
        let element = view.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement & UIAccessibilityReadingContent }.first
        return try #require(element)
    }

    @Test func screenReadsByLine() throws {
        let (view, window) = try makeView("$ ls\r\nfile one\r\n$ ")
        let element = try screenElement(view)
        #expect(element.accessibilityValue == "$ ls\nfile one\n$ ")
        #expect(element.accessibilityPageContent() == "$ ls\nfile one\n$ ")
        #expect(element.accessibilityContent(forLineNumber: 0) == "$ ls")
        #expect(element.accessibilityContent(forLineNumber: 1) == "file one")
        #expect(element.accessibilityContent(forLineNumber: 3) == nil)
        let cell = try #require(view.surface.cellSize)
        let lineFrame = element.accessibilityFrame(forLineNumber: 1)
        #expect(abs(lineFrame.height - cell.height) < 0.01)
        #expect(abs(lineFrame.width - 8 * cell.width) < 0.01)
        #expect(element.accessibilityLineNumber(for: CGPoint(x: lineFrame.midX, y: lineFrame.midY)) == 1)
        withExtendedLifetime(window) {}
    }

    private func links(_ view: TerminalView) -> [UIAccessibilityElement] {
        (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }.filter { $0.accessibilityTraits.contains(.link) }
    }

    @Test func linksAreLinkElementsThatOpenLikeATap() throws {
        let (view, window) = try makeView("\u{1b}]8;;https://example.com\u{1b}\\docs\u{1b}]8;;\u{1b}\\ and https://gudo.dev")
        var opened: [TerminalLink] = []
        view.onOpenLink = { opened.append($0) }
        let found = links(view)
        #expect(found.map(\.accessibilityLabel) == ["docs", "https://gudo.dev"])
        let first = try #require(found.first)
        let cell = try #require(view.surface.cellSize)
        #expect(abs(first.accessibilityFrameInContainerSpace.width - 4 * cell.width) < 0.01)
        #expect(first.accessibilityActivate())
        #expect(opened.map(\.target) == ["https://example.com"])
        #expect(links(view).first === first)
        withExtendedLifetime(window) {}
    }

    @Test func linksRotorStepsThroughTheLinks() throws {
        let (view, window) = try makeView("https://one.dev https://two.dev")
        let rotor = try #require(view.accessibilityCustomRotors?.first)
        #expect(rotor.systemRotorType == .link)
        let found = links(view)
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = .next
        let first = try #require(rotor.itemSearchBlock(predicate))
        #expect(first.targetElement === found.first)
        predicate.currentItem = first
        let second = try #require(rotor.itemSearchBlock(predicate))
        #expect(second.targetElement === found.last)
        predicate.currentItem = second
        #expect(rotor.itemSearchBlock(predicate) == nil)
        predicate.searchDirection = .previous
        #expect(rotor.itemSearchBlock(predicate)?.targetElement === found.first)
        withExtendedLifetime(window) {}
    }

    @Test func passwordPromptCompositionIsNotRead() throws {
        let (view, window) = try makeView("Password: ")
        view.surface.enablePrediction()
        view.surface.applyPrediction(.hint(EchoHint(echo: false, canonical: true, atPrompt: false, altScreen: false)))
        view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        #expect(try screenElement(view).accessibilityValue == "")
        withExtendedLifetime(window) {}
    }
}
#endif
