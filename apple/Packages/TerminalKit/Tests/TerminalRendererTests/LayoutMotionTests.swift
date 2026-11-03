import CoreGraphics
import Foundation
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

extension LayoutHoldTests {
    /// A view carried to a new size by an animated layout change shows its last frame on the way,
    /// changes its grid once (one SIGWINCH, before the motion, so the program's redraw is ready),
    /// and draws again only once it is there and that redraw has come in.
    @MainActor
    @Suite struct LayoutMotionTests {
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

        /// The frames of a 0.3 s animation at up to 120 Hz, as a spring lays the view out: each frame
        /// shows where the clock has the view, so a late frame (a busy test host) is further along
        /// and the view lands on time, as it does under a display link.
        private func animate(_ surface: TerminalSurface, from start: CGFloat, to end: CGFloat, during: ((CGFloat) -> Void)? = nil) async throws {
            let duration = Duration.milliseconds(300)
            let began = ContinuousClock.now
            var t = 0.0
            while t < 1 {
                t = min(1, (ContinuousClock.now - began) / duration)
                let width = start + (end - start) * (1 - pow(1 - t, 3))
                surface.layout(size: CGSize(width: width, height: 200), scale: 2)
                during?(width)
                try await Task.sleep(for: .milliseconds(8))
            }
        }

        private func waitUntilDrawing(_ surface: TerminalSurface) async throws {
            let start = ContinuousClock.now
            while surface.isHoldingFrame, ContinuousClock.now - start < .seconds(3) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        @Test func aZoomChangesTheGridOnceBeforeTheMotionAndHoldsTheFrameUntilItLands() async throws {
            let terminal = Terminal(cols: 20, rows: 6) { _ in }
            terminal.write(Array("$ echo a long line that wraps when narrow\r\n$ ".utf8))
            let (surface, changes) = try surface(terminal, width: 400)
            let before = try #require(surface.grid)

            surface.prepareResize(to: CGSize(width: 800, height: 200), within: .milliseconds(300))
            // The program hears of its new size once, now, while the old frame still shows.
            let after = try #require(surface.grid)
            #expect(changes() == [after])
            #expect(after.cols > before.cols)
            #expect(terminal.size.cols == Int(after.cols))
            #expect(surface.isHoldingFrame)

            try await animate(surface, from: 400, to: 800) { width in
                // Until the last pixels of the way.
                guard 800 - width > 2 else { return }
                #expect(surface.isHoldingFrame, "nothing new is drawn on the way")
                #expect(surface.renderIfDirty(offscreen: true) == false)
            }
            try await waitUntilDrawing(surface)
            #expect(!surface.isHoldingFrame)
            try await Task.sleep(for: .milliseconds(200))
            #expect(changes() == [after], "no grid change at rest: it was made for this size")
            #expect(surface.pendingGridSize == nil)
        }

        @Test func theFrameHoldsUntilTheProgramsRedrawHasComeIn() async throws {
            let terminal = Terminal(cols: 20, rows: 6) { _ in }
            let (surface, _) = try surface(terminal, width: 800)
            surface.prepareResize(to: CGSize(width: 400, height: 200), within: .milliseconds(1000))
            // A slow program is still redrawing as the view lands.
            let redraw = { terminal.write(Array("\r\u{1b}[K$ ".utf8)); surface.outputArrived() }
            try await animate(surface, from: 800, to: 400) { width in
                if width < 420 { redraw() }
            }
            let landed = ContinuousClock.now
            for _ in 0..<4 {
                redraw()
                try await Task.sleep(for: .milliseconds(12))
            }
            let quiet = ContinuousClock.now
            #expect(surface.isHoldingFrame, "held while the redraw comes in")
            try await waitUntilDrawing(surface)
            #expect(ContinuousClock.now - quiet >= TerminalSurface.redrawQuiet - .milliseconds(15))
            #expect(ContinuousClock.now - landed < .milliseconds(600))
        }

        @Test func aViewPreparedForTheSizeItHasKeepsItsGrid() async throws {
            let terminal = Terminal(cols: 20, rows: 6) { _ in }
            let (surface, changes) = try surface(terminal, width: 800)
            surface.prepareResize(to: CGSize(width: 800, height: 200), within: .milliseconds(300))
            #expect(!surface.isHoldingFrame)
            #expect(changes().isEmpty)
        }

        /// A dragged pane's preview moves views about with no known end; where they land decides.
        @Test func aHeldFrameKeepsItsGridUntilToldWhereItLands() async throws {
            let terminal = Terminal(cols: 20, rows: 6) { _ in }
            let (surface, changes) = try surface(terminal, width: 800)
            surface.holdFrame()
            try await animate(surface, from: 800, to: 500)
            try await animate(surface, from: 500, to: 650)
            #expect(surface.isHoldingFrame)
            #expect(changes().isEmpty, "a preview never resizes the program")
            surface.prepareResize(to: CGSize(width: 650, height: 200), within: .milliseconds(300))
            try await waitUntilDrawing(surface)
            try await Task.sleep(for: .milliseconds(150))
            #expect(changes().count == 1)
            #expect(changes().last == surface.grid)
        }

        /// The sidebar: an animation whose end only the layout knows.
        @Test func heldFramesChangeTheGridOnceTheViewSettles() async throws {
            let terminal = Terminal(cols: 20, rows: 6) { _ in }
            let (surface, changes) = try surface(terminal, width: 800)
            defer { TerminalSurface.frameHoldUntil = .now }
            TerminalSurface.holdFrames(for: .milliseconds(250))
            try await animate(surface, from: 800, to: 560) { _ in
                #expect(changes().isEmpty)
            }
            #expect(surface.isHoldingFrame)
            try await waitUntilDrawing(surface)
            try await Task.sleep(for: .milliseconds(150))
            let grid = try #require(surface.grid)
            #expect(changes() == [grid])
            #expect(terminal.size.cols == Int(grid.cols))
        }
    }
}
