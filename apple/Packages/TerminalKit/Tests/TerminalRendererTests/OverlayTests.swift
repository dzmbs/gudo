import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Selection colors, decorations, blink phases and overlay cells in `FrameBuilder`.
@MainActor
@Suite struct OverlayTests {
    let fonts = FontGrid(pixelSize: 26)

    private func build(_ input: String, cols: UInt16 = 20, rows: UInt16 = 3, overlay: FrameOverlay = FrameOverlay(),
                       prepare: (Terminal) -> Void = { _ in }) -> FrameContents {
        let terminal = Terminal(cols: cols, rows: rows) { _ in }
        terminal.write(Array(input.utf8))
        prepare(terminal)
        let state = RenderState()
        state.update(from: terminal)
        var frame = FrameContents()
        _ = FrameBuilder().build(state, fonts: fonts, overlay: overlay, into: &frame)
        return frame
    }

    private func glyphs(_ frame: FrameContents, row: Int) -> [CellText] {
        frame.text.filter { Int($0.gridPos.y) == row && $0.flags == 0 }
    }

    @Test func selectedCellsSwapColors() {
        let frame = build("hello world") { $0.selectWord(atViewport: GridPoint(x: 1, y: 0)) }
        // Selected: background takes the (white) foreground; text takes the background color.
        #expect(frame.bgCells[0] == SIMD4(255, 255, 255, 255))
        #expect(frame.bgCells[4] == SIMD4(255, 255, 255, 255))
        #expect(frame.bgCells[5].w == 0)
        let h = glyphs(frame, row: 0).first { $0.gridPos.x == 0 }
        #expect(h?.color == SIMD4(0x28, 0x2C, 0x34, 255))
    }

    @Test func underlineStylesUseDistinctSpritesAndUnderlineColor() {
        let styles = ["4", "4:2", "4:3", "4:4", "4:5"]
        var sizes: Set<[UInt32]> = []
        for style in styles {
            let frame = build("\u{1b}[\(style);58;2;255;0;0mx\u{1b}[0m")
            let decorations = glyphs(frame, row: 0).filter { $0.gridPos.x == 0 }
            #expect(decorations.count == 2, "glyph + underline for SGR \(style)")
            let underline = decorations.last!
            #expect(underline.color == SIMD4(255, 0, 0, 255))
            sizes.insert([underline.glyphSize.x, underline.glyphSize.y, underline.glyphPos.x, underline.glyphPos.y])
        }
        #expect(sizes.count == styles.count)
    }

    @Test func overlineStrikethroughAndInvisible() {
        let frame = build("\u{1b}[53;9ma\u{1b}[0m\u{1b}[8mb\u{1b}[0m")
        #expect(glyphs(frame, row: 0).filter { $0.gridPos.x == 0 }.count == 3)  // glyph, overline, strike
        #expect(glyphs(frame, row: 0).filter { $0.gridPos.x == 1 }.isEmpty)  // invisible
    }

    @Test func faintHalvesAlpha() {
        let frame = build("\u{1b}[2mf")
        #expect(glyphs(frame, row: 0).first?.color.w == 128)
    }

    @Test func blinkingTextHidesInTheOffPhase() {
        var off = FrameOverlay()
        off.textBlinkOn = false
        #expect(glyphs(build("\u{1b}[5mb\u{1b}[0mn"), row: 0).count == 2)
        #expect(glyphs(build("\u{1b}[5mb\u{1b}[0mn", overlay: off), row: 0).count == 1)
    }

    @Test func cursorBlinkOffHidesTheCursorOnlyWhenFocused() {
        var off = FrameOverlay()
        off.cursorBlinkOn = false
        #expect(build("x", overlay: off).text.allSatisfy { $0.flags == 0 })
        off.focused = false
        #expect(build("x", overlay: off).text.contains { $0.flags == CellText.Flags.isCursorGlyph.rawValue })
    }

    @Test func overlayCellsReplaceGridCellsAndMoveTheCursor() {
        var overlay = FrameOverlay()
        overlay.cells = [OverlayCell(x: 1, y: 0, text: "Z", span: 1, underline: .single)]
        overlay.cursorOverride = GridPoint(x: 2, y: 0)
        let plain = build("abc")
        let frame = build("abc", overlay: overlay)
        // "b" is hidden and replaced by "Z" plus an underline; the cell gets an opaque background.
        #expect(glyphs(frame, row: 0).filter { $0.gridPos.x == 1 }.count == 2)
        #expect(frame.bgCells[1].w == 255)
        let original = glyphs(plain, row: 0).first { $0.gridPos.x == 1 }!
        let replaced = glyphs(frame, row: 0).first { $0.gridPos.x == 1 }!
        #expect(original.glyphPos != replaced.glyphPos)
        #expect(frame.blockCursor?.pos == SIMD2(2, 0))
    }

    @Test func preeditWidthCountsWideCharacters() {
        #expect(TerminalSurface.isWide("日"))
        #expect(TerminalSurface.isWide("한"))
        #expect(!TerminalSurface.isWide("a"))
    }

    @Test func hoveredLinkIsUnderlined() {
        var overlay = FrameOverlay()
        overlay.hoveredLink = (row: 0, columns: 0...3)
        let plain = glyphs(build("link"), row: 0).count
        #expect(glyphs(build("link", overlay: overlay), row: 0).count == plain + 4)
    }
}
