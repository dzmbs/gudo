import CoreGraphics
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Search matches in a frame: Ghostty's `search-*` colors behind and on the matched cells, the
/// selected match in the stronger pair, and nothing else touched.
@MainActor
@Suite struct SearchHighlightTests {
    let fonts = FontGrid(pixelSize: 26)

    private func frame(_ input: String, highlights: [SearchHighlight]) -> FrameContents {
        let terminal = Terminal(cols: 20, rows: 3) { _ in }
        terminal.write(Array(input.utf8))
        let state = RenderState()
        state.update(from: terminal)
        var overlay = FrameOverlay()
        overlay.searchHighlights = highlights
        var frame = FrameContents()
        _ = FrameBuilder().build(state, fonts: fonts, overlay: overlay, into: &frame)
        return frame
    }

    private func glyph(_ frame: FrameContents, x: Int, y: Int) -> CellText? {
        frame.text.first { Int($0.gridPos.x) == x && Int($0.gridPos.y) == y && $0.flags == 0 }
    }

    @Test func matchesTakeTheSearchColors() throws {
        let f = frame("one two one", highlights: [
            SearchHighlight(row: 0, columns: 0...2, selected: false),
            SearchHighlight(row: 0, columns: 8...10, selected: true),
        ])
        let match = SIMD4<UInt8>(0xFF, 0xE0, 0x82, 255), selected = SIMD4<UInt8>(0xF2, 0xA5, 0x7E, 255)
        #expect(f.bgCells[0] == match)
        #expect(f.bgCells[2] == match)
        #expect(f.bgCells[3].w == 0, "the space after the match keeps the default background")
        #expect(f.bgCells[8] == selected)
        #expect(f.bgCells[10] == selected)
        #expect(try #require(glyph(f, x: 0, y: 0)).color == SIMD4(0, 0, 0, 255))
        #expect(try #require(glyph(f, x: 4, y: 0)).color == SIMD4(255, 255, 255, 255), "text outside matches is untouched")
    }

    @Test func highlightsFollowTheirRowAndClipToTheGrid() {
        let f = frame("aaa\r\nbbb", highlights: [SearchHighlight(row: 1, columns: 1...40, selected: false)])
        #expect(f.bgCells[0].w == 0)
        #expect(f.bgCells[20 + 1] == SIMD4(0xFF, 0xE0, 0x82, 255))
        #expect(f.bgCells[20 + 19] == SIMD4(0xFF, 0xE0, 0x82, 255))
    }

    @Test func overlayEqualityIncludesHighlights() {
        var a = FrameOverlay(), b = FrameOverlay()
        #expect(a == b)
        b.searchHighlights = [SearchHighlight(row: 0, columns: 0...1, selected: false)]
        #expect(a != b)
        a.searchHighlights = b.searchHighlights
        #expect(a == b)
    }

    /// End to end on a surface: setting a search highlights the match in the next frame, and
    /// selecting moves the viewport and reports the status.
    @Test func surfaceSearchesAndReports() throws {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array((0..<12).map { $0 == 2 ? "needle \($0)\r\n" : "row \($0)\r\n" }.joined().utf8))
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 200, height: 80), scale: 2)
        var statuses: [SearchStatus] = []
        surface.onSearchStatus = { statuses.append($0) }
        surface.setSearch("needle")
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(statuses.last?.total == 1)
        #expect(surface.selectMatch(.next))
        #expect(statuses.last?.selected == 0)
        #expect(!terminal.viewportAtBottom, "the match was in scrollback")
        surface.setSearch("")
        #expect(statuses.last == .idle)
    }
}
