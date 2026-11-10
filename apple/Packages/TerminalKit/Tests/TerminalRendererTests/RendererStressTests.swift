import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Limits that keep the renderer alive under hostile or extreme content: bounded atlases and
/// caches, a per-frame rasterization budget, oversized views, and GPU memory off screen.
@MainActor @Suite struct RendererStressTests {
    /// A screen of distinct CJK ideographs starting at `first`.
    private func cjkScreen(from first: UInt32, cols: Int, rows: Int) -> String {
        var screen = "\u{1b}[H"
        var cp = first
        for row in 0..<rows {
            for _ in 0..<(cols / 2) {
                screen.unicodeScalars.append(Unicode.Scalar(cp)!)
                cp += 1
            }
            if row < rows - 1 { screen += "\r\n" }
        }
        return screen
    }

    /// Glyph instances (not the cursor) whose atlas regions must match what the grid now holds.
    private func expectFrameMatchesAtlas(_ frame: FrameContents, fonts: FontGrid) {
        for g in frame.text where g.flags & CellText.Flags.isCursorGlyph.rawValue == 0 {
            let size = g.atlas == CellText.Atlas.color.rawValue ? fonts.color.size : fonts.grayscale.size
            #expect(Int(g.glyphPos.x + g.glyphSize.x) < size && Int(g.glyphPos.y + g.glyphSize.y) < size)
        }
    }

    /// Distinct glyphs past the atlas cap make it start over instead of doubling past Metal's
    /// texture limit (before: 20k CJK at 48 pt grew it to 16384², 256 MB on CPU plus GPU, and the
    /// next doubling would fail to allocate and blank every pane with this font).
    @Test func fullAtlasStartsOverAndTheFrameIsRebuilt() {
        let terminal = Terminal(cols: 40, rows: 8) { _ in }
        let fonts = FontGrid(pixelSize: 64, maxAtlasSize: 1024)
        let builder = FrameBuilder()
        let state = RenderState()
        var frame = FrameContents()
        var first: UInt32 = 0x4E00
        for _ in 0..<12 {
            terminal.write(Array(cjkScreen(from: first, cols: 40, rows: 8).utf8))
            first += 160
            state.update(from: terminal)
            _ = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
            state.markClean()
            #expect(fonts.grayscale.size <= 1024)
            #expect(!builder.isIncomplete)
            expectFrameMatchesAtlas(frame, fonts: fonts)
        }
        #expect(fonts.epoch > 0)
        // Every glyph on screen is the one the grid would hand out now (none from before a reset).
        let row = frame.text.filter { $0.gridPos.y == 7 && $0.flags == 0 }
        #expect(row.count == 20)
        let last = first - 160 + 7 * 20
        for (i, g) in row.sorted(by: { $0.gridPos.x < $1.gridPos.x }).enumerated() {
            let glyph = fonts.glyph(for: [last + UInt32(i)], style: .regular, span: 2)
            #expect(glyph?.region.x == Int(g.glyphPos.x) && glyph?.region.y == Int(g.glyphPos.y))
        }
    }

    /// A surface sharing the grid drops its cached rows after another one reset the atlas.
    @Test func otherBuildersRebuildAfterAReset() {
        let fonts = FontGrid(pixelSize: 64, maxAtlasSize: 1024)
        let quiet = Terminal(cols: 20, rows: 4) { _ in }
        quiet.write(Array("quiet pane".utf8))
        let quietState = RenderState()
        let quietBuilder = FrameBuilder()
        var quietFrame = FrameContents()
        quietState.update(from: quiet)
        _ = quietBuilder.build(quietState, fonts: fonts, overlay: FrameOverlay(), into: &quietFrame)
        quietState.markClean()

        let busy = Terminal(cols: 40, rows: 8) { _ in }
        let busyState = RenderState()
        let busyBuilder = FrameBuilder()
        var busyFrame = FrameContents()
        var first: UInt32 = 0x4E00
        while fonts.epoch == 0 {
            busy.write(Array(cjkScreen(from: first, cols: 40, rows: 8).utf8))
            first += 160
            busyState.update(from: busy)
            _ = busyBuilder.build(busyState, fonts: fonts, overlay: FrameOverlay(), into: &busyFrame)
            busyState.markClean()
        }
        quiet.write(Array("!".utf8))
        quietState.update(from: quiet)
        let stats = quietBuilder.build(quietState, fonts: fonts, overlay: FrameOverlay(), into: &quietFrame)
        #expect(stats.rowsReused == 0 && stats.rowsRebuilt == 4)
        expectFrameMatchesAtlas(quietFrame, fonts: fonts)
    }

    /// A frame needing more glyph space than the whole atlas draws what fits and stays
    /// incomplete; it neither loops nor crashes.
    @Test func frameLargerThanTheAtlasDropsGlyphs() {
        let terminal = Terminal(cols: 80, rows: 20) { _ in }
        let fonts = FontGrid(pixelSize: 96, maxAtlasSize: 512)
        let builder = FrameBuilder()
        let state = RenderState()
        var frame = FrameContents()
        terminal.write(Array(cjkScreen(from: 0x4E00, cols: 80, rows: 20).utf8))
        state.update(from: terminal)
        _ = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
        #expect(builder.isIncomplete)
        #expect(fonts.grayscale.size == 512)
        expectFrameMatchesAtlas(frame, fonts: fonts)
    }

    /// Past the deadline no glyph is rasterized or cached as missing; the row is rebuilt later.
    @Test func rasterDeadlineDefersGlyphsToLaterFrames() {
        let terminal = Terminal(cols: 20, rows: 2) { _ in }
        let fonts = FontGrid(pixelSize: 26)
        let builder = FrameBuilder()
        let state = RenderState()
        var frame = FrameContents()
        terminal.write(Array("日本語 abc".utf8))
        state.update(from: terminal)
        fonts.rasterDeadline = 0
        _ = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
        state.markClean()
        #expect(builder.isIncomplete)
        #expect(frame.text.filter { $0.flags == 0 }.isEmpty)

        fonts.rasterDeadline = .infinity
        state.update(from: terminal)
        let stats = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
        #expect(!builder.isIncomplete)
        #expect(stats.rowsRebuilt >= 1)
        #expect(frame.text.filter { $0.flags == 0 }.count == 6)
    }

    /// A screen of new large emoji must not stall the main thread in one frame: each frame
    /// spends a bounded time and the glyphs fill in over the next frames.
    @Test func newGlyphsNeverStallAFrame() throws {
        let terminal = Terminal(cols: 40, rows: 10) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 40)
        surface.layout(size: CGSize(width: 2400, height: 1200), scale: 2)
        let emoji = (0x1F300...0x1F5FF).compactMap(Unicode.Scalar.init).filter(\.properties.isEmojiPresentation)
        var text = "\u{1b}[H"
        for e in emoji.prefix(400) { text.unicodeScalars.append(e) }
        terminal.write(Array(text.utf8))
        var worst = 0.0
        var frames = 0
        repeat {
            let start = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - start)
            frames += 1
        } while surface.builderIsIncomplete && frames < 2000
        #expect(!surface.builderIsIncomplete)
        #expect(frames > 1)
        #expect(worst < 0.2, "worst frame \(worst * 1000) ms")
    }

    /// Panes that cost more main-thread time than the share drop frames, the focused one last,
    /// and render again once time has passed: the main thread is never all rendering.
    @Test func renderBudgetLeavesTheMainThreadTimeAndPrefersTheFocusedPane() {
        var budget = RenderBudget()
        var now = 100.0
        var busy = 0.0
        // 16 flooding panes at 60 Hz, 5 ms each: 480 ms of work asked for per second.
        for _ in 0..<600 {
            for pane in 0..<16 where budget.mayRender(focused: pane == 0, waitingSince: nil, now: now) {
                budget.spend(0.005)
                busy += 0.005
            }
            now += 1.0 / 60
        }
        #expect(busy / 10 <= 0.5 + 0.01)
        #expect(busy / 10 >= 0.45)

        // One huge pane (140 ms frames): it renders, then yields the time back.
        var focused = RenderBudget()
        now = 0
        var frames = 0
        for _ in 0..<600 {
            if focused.mayRender(focused: true, waitingSince: nil, now: now) {
                focused.spend(0.14)
                now += 0.14
                frames += 1
            }
            now += 1.0 / 120
        }
        #expect(frames > 0)
        #expect(Double(frames) * 0.14 / now <= 0.55)
        #expect(!focused.mayRender(focused: false, waitingSince: nil, now: now) || focused.mayRender(focused: true, waitingSince: nil, now: now))
    }

    /// A flooding focused pane never starves the others: a pane waiting past the starvation
    /// limit renders within a few frames of it, and the main thread keeps its share.
    @Test func aFloodingFocusedPaneLeavesTheOthersFrames() {
        var budget = RenderBudget()
        var now = 0.0
        var waitingSince: CFTimeInterval?
        var unfocusedFrames: [CFTimeInterval] = []
        var busy = 0.0
        for tick in 0..<1200 {
            // The focused pane ticks at 120 Hz, the other at 60 Hz; both cost 20 ms a frame.
            if budget.mayRender(focused: true, waitingSince: nil, now: now) {
                budget.spend(0.02)
                busy += 0.02
            }
            if tick % 2 == 0 {
                if budget.mayRender(focused: false, waitingSince: waitingSince, now: now) {
                    budget.spend(0.02)
                    busy += 0.02
                    unfocusedFrames.append(now)
                    waitingSince = nil
                } else if waitingSince == nil {
                    waitingSince = now
                }
            }
            now += 1.0 / 120
        }
        let gaps = zip(unfocusedFrames.dropFirst(), unfocusedFrames).map { $0 - $1 }
        #expect(unfocusedFrames.count >= 25, "\(unfocusedFrames.count) frames in 10 s")
        #expect((gaps.max() ?? 10) < RenderBudget.starvationLimit + 0.1, "longest wait \(gaps.max() ?? 10) s")
        #expect(busy / now <= budget.share + 0.02)
    }

    /// A frame the layer had no drawable for is not lost: the pane stays dirty and draws it on
    /// the next tick.
    @Test func aMissedDrawableKeepsThePaneDirty() throws {
        let terminal = Terminal(cols: 40, rows: 10) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        terminal.write(Array("hello".utf8))
        surface.drawableSource = { _ in nil }
        #expect(surface.renderIfDirty(), "still has a frame to show")
        #expect(!surface.hasPresentedFrame)
        surface.drawableSource = { $0.nextDrawable() }
        #expect(surface.renderIfDirty())
        #expect(surface.hasPresentedFrame)
    }

    /// A memory warning empties grown atlases; the pane still draws every glyph afterwards.
    @Test func memoryWarningReleasesGrownAtlases() throws {
        let terminal = Terminal(cols: 60, rows: 10) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 31)
        surface.layout(size: CGSize(width: 1200, height: 600), scale: 2)
        terminal.write(Array(cjkScreen(from: 0x4E00, cols: 60, rows: 10).utf8))
        surface.renderIfDirty(offscreen: true)
        let fonts = try #require(surface.fonts)
        #expect(fonts.grayscale.size > 512)
        FontGrid.releaseCaches()
        #expect(fonts.grayscale.size == 512 && fonts.grayscaleTexture == nil)
        surface.outputArrived()
        terminal.write(Array("!".utf8))
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(fonts.grayscale.size > 512)
    }

    /// Re-applying the same appearance (a workspace pushes it to every pane) costs no frame.
    @Test func equalAppearanceIsFree() throws {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.layout(size: CGSize(width: 300, height: 100), scale: 2)
        terminal.write(Array("hello".utf8))
        #expect(surface.renderIfDirty(offscreen: true))
        let same = surface.appearance
        surface.appearance = same
        #expect(!surface.renderIfDirty(offscreen: true))
    }

    /// Endless distinct clusters (random combining marks) and glyphless codepoints keep the
    /// lookup caches bounded.
    @Test func lookupCachesStayBounded() {
        let fonts = FontGrid(pixelSize: 26)
        fonts.maxCacheEntries = 500
        for i in 0..<3000 {
            let base = UInt32(0x61 + i % 26)
            _ = fonts.glyph(for: [base, 0x300 + UInt32(i % 112), 0x300 + UInt32(i / 112 % 112)], style: .regular, span: 1)
            _ = fonts.glyph(for: [0xE0000 + UInt32(i)], style: .regular, span: 1)
        }
        #expect(fonts.cacheEntryCounts.resolved <= 500 && fonts.cacheEntryCounts.fast <= 500)
    }

    /// A view whose drawable would pass Metal's 16384 limit draws at a lower scale (at full
    /// scale the layer refuses the size and hands out no drawable).
    @Test func oversizedViewStillDraws() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 9000, height: 5000), scale: 2)
        let size = surface.layer.drawableSize
        #expect(size.width > 0 && size.width <= 16384 && size.height <= 16384)
        #expect(surface.layer.contentsScale == 1.75)
        terminal.write(Array("hello".utf8))
        #expect(surface.renderIfDirty())
        #expect(TerminalSurface.drawableScale(for: CGSize(width: 1000, height: 800), scale: 2) == 2)
    }

    /// Off screen, kitty images leave the GPU with the rest (up to the terminal's whole image
    /// storage per pane stayed resident before).
    @Test func offscreenPanesDropKittyTextures() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        let pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        terminal.write(Array("\u{1b}_Ga=T,f=32,s=64,v=64,i=1,q=2;\(Data(pixels).base64EncodedString())\u{1b}\\".utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(surface.kittyTextures.count == 1)
        surface.releaseGPUResources()
        #expect(surface.kittyTextures.isEmpty)
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(surface.kittyTextures.count == 1)
    }

    /// A full rebuild of a 6K window at a 4 pt font (1201×306 colored cells, every row dirty)
    /// stays within a budget with headroom for a loaded machine: about 10 ms in release and
    /// 235 ms in debug now, against 25 and 410 ms before the data-oriented pass (docs/PERFORMANCE.md).
    @Test func fullRebuildOfA6KGridStaysWithinBudget() {
        let terminal = Terminal(cols: 1201, rows: 306) { _ in }
        let fonts = FontGrid(pixelSize: 8)
        let builder = FrameBuilder()
        let state = RenderState()
        var frame = FrameContents()
        let line = String((0..<1201).map { i in Character(Unicode.Scalar(UInt8(0x21 + i % 94))) })
        var durations: [Double] = []
        for i in 0..<12 {
            terminal.write(Array(("\u{1b}[3\(i % 8)m" + String(repeating: line, count: 320)).utf8))
            state.update(from: terminal)
            let start = CACurrentMediaTime()
            _ = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
            durations.append(CACurrentMediaTime() - start)
            state.markClean()
        }
        #expect(frame.text.count > 1201 * 300)
        let median = durations.dropFirst(2).sorted()[5]
        #if DEBUG
        let budget = 0.6
        #else
        let budget = 0.04
        #endif
        #expect(median < budget, "a full 6K rebuild took \(median * 1000) ms")
    }
}
