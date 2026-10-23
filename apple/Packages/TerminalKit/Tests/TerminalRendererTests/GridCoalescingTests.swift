import CoreGraphics
import Foundation
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Layout resizes the drawable every frame but the grid (reflow + SIGWINCH) only when the view
/// settles: one grid change per animated layout change, few while a divider is dragged.
@MainActor
@Suite(.serialized) struct GridCoalescingTests {
    private func surface(_ terminal: Terminal, width: CGFloat) throws -> (TerminalSurface, () -> [TerminalSurface.Grid]) {
        var appearance = TerminalAppearance()
        appearance.fontSize = 12
        appearance.padding = 4
        let surface = try TerminalSurface(terminal: terminal, appearance: appearance)
        surface.layout(size: CGSize(width: width, height: 200), scale: 2)
        var changes: [TerminalSurface.Grid] = []
        surface.onGridChange = { changes.append($0) }
        return (surface, { changes })
    }

    /// The frames of a 0.28 s animation at 120 Hz from one width to another, held throughout
    /// however slowly a busy test host runs it.
    private func animate(_ surface: TerminalSurface, from start: CGFloat, to end: CGFloat, during: (() -> Void)? = nil) async throws {
        let frames = 34
        defer { TerminalSurface.gridHoldUntil = .now }
        for frame in 1...frames {
            TerminalSurface.holdGrids(for: .seconds(10))
            let t = Double(frame) / Double(frames)
            let eased = 1 - pow(1 - t, 3)
            surface.layout(size: CGSize(width: start + (end - start) * eased, height: 200), scale: 2)
            during?()
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    /// Waits out the hold for the one change.
    private func settle(_ changes: () -> [TerminalSurface.Grid]) async throws {
        let start = ContinuousClock.now
        while changes().isEmpty, ContinuousClock.now - start < .seconds(3) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func anAnimatedSplitChangesTheGridOnceAtTheEnd() async throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        terminal.write(Array("$ echo a long line that wraps when narrow\r\n$ ".utf8))
        let (surface, changes) = try surface(terminal, width: 800)
        let before = try #require(surface.grid)
        let text = terminal.visibleText()
        let origin = surface.rect(for: GridPoint(x: 0, y: 0)).origin

        try await animate(surface, from: 800, to: 400) {
            // Nothing reflows or moves while the view resizes.
            #expect(terminal.size.cols == Int(before.cols))
            #expect(terminal.visibleText() == text)
            #expect(surface.rect(for: GridPoint(x: 0, y: 0)).origin == origin)
        }
        #expect(changes().isEmpty)
        try await settle(changes)

        let after = try #require(surface.grid)
        #expect(changes() == [after])
        #expect(after.cols < before.cols)
        #expect(terminal.size.cols == after.cols)
        #expect(surface.pendingGridSize == nil)
    }

    @Test func aViewThatReturnsToItsSizeKeepsItsGrid() async throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let (surface, changes) = try surface(terminal, width: 800)
        try await animate(surface, from: 800, to: 500)
        try await animate(surface, from: 500, to: 800)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes().isEmpty)
    }

    @Test func aDragChangesTheGridAtMostEveryIntervalAndEndsAtItsSize() async throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let (surface, changes) = try surface(terminal, width: 800)
        let start = ContinuousClock.now
        var width: CGFloat = 800
        while ContinuousClock.now - start < .milliseconds(600) {
            width -= 3
            surface.layout(size: CGSize(width: width, height: 200), scale: 2)
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(150))
        // 600 ms at one change per 100 ms, the first at once, plus the release.
        #expect(changes().count >= 2)
        #expect(changes().count <= 8)
        let final = try #require(surface.grid)
        #expect(changes().last == final)
        surface.layout(size: CGSize(width: width, height: 200), scale: 2)
        #expect(surface.grid == final)
    }

    @Test func aOneOffResizeAppliesAtOnce() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let (surface, changes) = try surface(terminal, width: 800)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        #expect(changes().count == 1)
        #expect(terminal.size.cols == surface.grid.map { Int($0.cols) })
    }
}
