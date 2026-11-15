import CoreGraphics
import Foundation
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// A new terminal counts as shown only once a frame draws what the program wrote for the grid
/// the view gives it: not the screen it printed at its starting size, and not the blank screen
/// a resize leaves until the program redraws.
@MainActor @Suite struct SettledFrameTests {
    private func write(_ text: String, to terminal: Terminal, surface: TerminalSurface) {
        terminal.write(Array(text.utf8))
        surface.outputArrived()
    }

    @Test func outputFromBeforeTheFirstLayoutIsNotSettled() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        write("prompt at the starting size $ ", to: terminal, surface: surface)
        surface.layout(size: CGSize(width: 300, height: 120), scale: 2)
        surface.renderIfDirty()
        #expect(surface.hasPresentedFrame)
        #expect(!surface.presentsSettledOutput, "printed for 80 × 24, drawn at another grid")

        write("\r\u{1b}[Jprompt redrawn $ ", to: terminal, surface: surface)
        surface.renderIfDirty()
        #expect(surface.presentsSettledOutput)
    }

    @Test func outputAfterTheFirstLayoutIsSettled() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 300, height: 120), scale: 2)
        surface.renderIfDirty()
        #expect(!surface.presentsSettledOutput, "nothing written yet")
        write("prompt $ ", to: terminal, surface: surface)
        surface.renderIfDirty()
        #expect(surface.presentsSettledOutput)
    }

    @Test func aStreamThatHasNotTakenTheGridIsNotSettled() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.sizeFollowsStream = true
        surface.layout(size: CGSize(width: 300, height: 120), scale: 2)
        write("snapshot at the host's size $ ", to: terminal, surface: surface)
        surface.renderIfDirty()
        #expect(surface.hasPresentedFrame)
        #expect(!surface.presentsSettledOutput, "the host's grid, not this view's")

        let grid = try #require(surface.grid)
        terminal.resize(cols: grid.cols, rows: grid.rows, cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
        surface.streamResized()
        surface.renderIfDirty()
        #expect(!surface.presentsSettledOutput, "resized, the program has not redrawn yet")

        write("\r\u{1b}[Jprompt redrawn $ ", to: terminal, surface: surface)
        surface.renderIfDirty()
        #expect(surface.presentsSettledOutput)
    }
}
