import CoreGraphics
import Foundation
import TerminalCore

/// A surface's screen text for assistive technologies, read from the terminal on first use after
/// a frame showed a change, and the change notifications a native text view posts, held until the
/// output has been quiet for `quietPeriod` so a flood of output is never read out.
@MainActor
final class AccessibleScreen {
    private struct Caret: Equatable {
        var selection: Selection?
        var cursor: GridPoint
        var viewportTop: Int
    }

    /// A link on screen as ⌘-click finds it, and its text.
    struct Link: Equatable {
        var range: Range<Int>
        var link: TerminalLink
    }

    let surface: TerminalSurface
    private let quietPeriod: Duration
    private var cachedText: AccessibleScreenText?
    private var cachedGeneration = 0
    private var cachedLinks: (generation: Int, links: [Link])?
    private var observedGeneration = 0
    private var observedCaret: Caret?
    private var hasPendingValueChange = false
    private var hasPendingSelectionChange = false
    private var lastChange = ContinuousClock.now
    private var pendingPost: Task<Void, Never>?
    var onValueChanged: (() -> Void)?
    var onSelectedTextChanged: (() -> Void)?

    init(surface: TerminalSurface, quietPeriod: Duration = .milliseconds(400)) {
        self.surface = surface
        self.quietPeriod = quietPeriod
    }

    var text: AccessibleScreenText {
        if let cachedText, cachedGeneration == surface.contentGeneration { return cachedText }
        let text = surface.terminal.accessibleScreenText()
        cachedText = text
        cachedGeneration = surface.contentGeneration
        return text
    }

    /// Every link on screen in reading order, found again only when the text changes.
    var links: [Link] {
        let text = text
        if let cachedLinks, cachedLinks.generation == cachedGeneration { return cachedLinks.links }
        let links = text.linkRanges().compactMap { range in
            surface.terminal.link(atViewport: text.cell(atOffset: range.lowerBound)).map { Link(range: range, link: $0) }
        }
        cachedLinks = (cachedGeneration, links)
        return links
    }

    /// The selection, or the insertion point at the cursor (the end of the text while the cursor
    /// is out of view).
    var selectedRange: Range<Int> {
        let text = text
        let terminal = surface.terminal
        if let selection = terminal.selection, let range = text.range(of: selection, viewportTop: terminal.viewportTopRow) {
            return range
        }
        let insertionPoint = terminal.viewportPoint(fromActive: terminal.cursorPosition).map(text.offset(of:)) ?? text.length
        return insertionPoint..<insertionPoint
    }

    /// Selects a range's text in the terminal; an empty range clears the selection, since the
    /// cursor belongs to the program.
    func select(_ range: Range<Int>) {
        let terminal = surface.terminal
        terminal.setSelection(text.selection(for: range, viewportTop: terminal.viewportTopRow))
        observedCaret = currentCaret()
        surface.setNeedsRender()
    }

    /// The range's cells in view points.
    func frame(for range: Range<Int>) -> CGRect {
        text.spans(for: range)
            .map { surface.rect(for: GridPoint(x: $0.columns.lowerBound, y: $0.row), span: $0.columns.count) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    func offset(at point: CGPoint) -> Int {
        text.offset(of: surface.cell(at: point))
    }

    /// Notes what the last frame showed; the notifications follow once the screen is quiet.
    func frameRendered() {
        let caret = currentCaret()
        if surface.contentGeneration != observedGeneration { hasPendingValueChange = true }
        if caret != observedCaret { hasPendingSelectionChange = true }
        observedGeneration = surface.contentGeneration
        observedCaret = caret
        guard hasPendingValueChange || hasPendingSelectionChange else { return }
        lastChange = .now
        guard pendingPost == nil else { return }
        pendingPost = Task { [weak self] in
            while let deadline = self?.quietDeadline, deadline > .now {
                guard (try? await Task.sleep(until: deadline)) != nil else { return }
            }
            self?.postPendingChanges()
        }
    }

    private var quietDeadline: ContinuousClock.Instant { lastChange + quietPeriod }

    private func postPendingChanges() {
        pendingPost = nil
        if hasPendingValueChange { onValueChanged?() }
        if hasPendingSelectionChange { onSelectedTextChanged?() }
        hasPendingValueChange = false
        hasPendingSelectionChange = false
    }

    private func currentCaret() -> Caret {
        let terminal = surface.terminal
        return Caret(selection: terminal.selection, cursor: terminal.cursorPosition, viewportTop: terminal.viewportTopRow)
    }
}

extension ImagePlacement {
    /// What VoiceOver reads for a kitty image: the protocol carries no name or description, so
    /// the size of the part shown, in image pixels.
    var accessibilityLabel: String { "Image, \(sourceWidth) by \(sourceHeight)" }
}
