import Darwin
import Foundation
import Testing
import TerminalCore
@testable import TerminalRenderer

@MainActor @Suite struct SharedFontGridTests {
    private func surface(fontSize: CGFloat = 13, text: String, offscreen: Bool = true) throws -> TerminalSurface {
        let terminal = Terminal(cols: 100, rows: 30) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: fontSize)
        surface.layout(size: CGSize(width: 900, height: 600), scale: 2)
        terminal.write(Array(text.utf8))
        if offscreen { _ = surface.renderIfDirty(offscreen: true) }
        return surface
    }

    /// Panes with the same font share one set of glyph atlases and their GPU textures: a new
    /// pane must not rasterize and keep its own copy of every glyph.
    @Test func surfacesWithTheSameFontShareAtlases() throws {
        let first = try surface(text: "hello ✓ 日本 😀\r\n")
        let second = try surface(text: "world\r\n")
        let grid = try #require(first.fonts)
        #expect(grid === second.fonts)
        #expect(grid.grayscaleTexture != nil && grid.colorTexture != nil)
        let other = try surface(fontSize: 15, text: "x")
        #expect(other.fonts !== grid)
    }

    /// The shared grid lives as long as a surface uses it.
    @Test func sharedGridIsFreedWithItsLastSurface() async throws {
        weak var grid: FontGrid?
        weak var surf: TerminalSurface?
        try autoreleasepool {
            let first = try surface(fontSize: 17, text: "a")
            grid = first.fonts
            surf = first
            #expect(grid != nil)
        }
        // Pending main-actor work (render wakeups, grid commits) lets go of the surface first.
        try await Task.sleep(for: .milliseconds(300))
        #expect(surf == nil)
        #expect(grid == nil)
    }

    /// Memory a pane costs on screen and once off screen (hidden tab, background, occluded
    /// window), printed for docs/PERFORMANCE.md (run alone for clean numbers). Off screen it
    /// keeps only its terminal: the layer with its drawables and the frame buffers go.
    @Test func offscreenPanesGiveBackGPUMemory() async throws {
        let text = (0..<30).map { "line \($0): the quick brown fox ✓ λ → ─│┼ \u{1F600}\r\n" }.joined()
        let warm = try surface(text: text)  // shaders, shared glyphs
        // Metal and IOSurface memory comes back asynchronously: measure once it settled.
        func settled() async throws -> Int {
            try await Task.sleep(for: .milliseconds(2000))
            return footprint()
        }
        let start = try await settled()
        let panes = try (0..<10).map { _ in try surface(text: text, offscreen: false) }
        let created = try await settled()
        for _ in 0..<3 {
            for pane in panes { pane.setNeedsRender(); _ = pane.renderIfDirty() }
            try await Task.sleep(for: .milliseconds(30))
        }
        let shown = try await settled()
        weak var oldLayer = panes[0].layer
        for pane in panes { pane.releaseGPUResources() }
        let hidden = try await settled()
        // The layer that held the drawables is gone (other suites run in parallel, so the
        // footprint is for reading, not for asserting).
        #expect(oldLayer == nil)
        let mb = { (bytes: Int) in Double(bytes) / Double(panes.count) / 1_048_576 }
        print(String(format: "pane memory (900x600 pt @2x): %.1f MB never drawn, %.1f MB on screen, %.1f MB off screen",
                     mb(created - start), mb(shown - start), mb(hidden - start)))

        // Back on screen it draws at full size again.
        let pane = panes[0]
        #expect(pane.renderIfDirty())
        #expect(pane.layer.drawableSize == CGSize(width: 1800, height: 1200))
        _ = warm
    }

    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
