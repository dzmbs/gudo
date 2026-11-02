import Darwin
import Foundation
import QuartzCore
import Testing
import TerminalCore
@testable import TerminalRenderer

/// Measurements for docs/STRESS.md, printed as "PROBE" lines; slow, so opt-in:
/// `GUDO_STRESS=1 swift test -c release -Xswiftc -enable-testing --filter StressProbeTests`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GUDO_STRESS"] != nil))
struct StressProbeTests {
    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Int(info.phys_footprint)
    }

    @Test(arguments: [13.0, 48.0]) func probeCJK(size: Double) throws {
        let terminal = Terminal(cols: 200, rows: 60) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: size)
        surface.layout(size: CGSize(width: 3000, height: 1600), scale: 2)
        let start = footprint()
        let startTime = CACurrentMediaTime()
        var cp: UInt32 = 0x4E00
        var worst = 0.0
        while cp < 0x9FFF {
            var text = "\u{1b}[H"
            for _ in 0..<1000 { text.unicodeScalars.append(Unicode.Scalar(cp)!); cp += 1 }
            terminal.write(Array(text.utf8))
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty(offscreen: true)
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        print("PROBE CJK size \(size): atlas \(surface.atlasSizes) footprint +\((footprint() - start) >> 20) MB, \(CACurrentMediaTime() - startTime)s, worst frame \(worst)")
    }

    @Test(arguments: [13.0, 48.0]) func probeEmoji(size: Double) throws {
        let terminal = Terminal(cols: 200, rows: 60) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: size)
        surface.layout(size: CGSize(width: 3000, height: 1600), scale: 2)
        let start = footprint()
        let startTime = CACurrentMediaTime()
        let emoji = (0x1F300...0x1FAFF).compactMap { Unicode.Scalar($0) }.filter { $0.properties.isEmojiPresentation }
        var worst = 0.0
        for chunk in stride(from: 0, to: emoji.count, by: 500) {
            var text = "\u{1b}[H"
            for e in emoji[chunk..<min(chunk + 500, emoji.count)] { text.unicodeScalars.append(e) }
            terminal.write(Array(text.utf8))
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty(offscreen: true)
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        print("PROBE emoji(\(emoji.count)) size \(size): atlas \(surface.atlasSizes) footprint +\((footprint() - start) >> 20) MB, \(CACurrentMediaTime() - startTime)s worst \(worst)")
    }

    @Test func probeHugeDrawable() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 4)
        surface.layout(size: CGSize(width: 9000, height: 5000), scale: 2)
        terminal.write(Array(String(repeating: "x", count: 5000).utf8))
        let probeStart = CACurrentMediaTime()
        let rendered = surface.renderIfDirty()
        print("PROBE huge drawable: rendered \(rendered) grid \(String(describing: surface.grid)) layer \(surface.layer.drawableSize) in \(CACurrentMediaTime() - probeStart)")
        let renderedOffscreen = surface.renderIfDirty(offscreen: true)
        print("PROBE huge offscreen: \(renderedOffscreen)")
    }

    @Test func probeTinyFont6K() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 4)
        surface.layout(size: CGSize(width: 3008, height: 1692), scale: 2)
        print("PROBE 6K tiny grid \(String(describing: surface.grid))")
        let start = footprint()
        var worst = 0.0
        let line = (0..<2000).map { _ in Character(Unicode.Scalar(UInt32.random(in: 0x21...0x7E))!) }
        _ = surface.stats.drain()
        for i in 0..<300 {
            terminal.write(Array(("\u{1b}[3\(i % 8)m" + String(line) + "\r\n").utf8))
            terminal.write(Array(String(repeating: String(line) + "\r\n", count: 50).utf8))
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        print("PROBE 6K tiny: worst frame \(worst) footprint +\((footprint() - start) >> 20) MB \(surface.stats.drain().map(String.init(describing:)) ?? "")")
    }

    @Test func probeManySurfaces() async throws {
        let start = footprint()
        var surfaces: [TerminalSurface] = []
        let text = (0..<40).map { "line \($0): the quick brown fox ✓ λ → ─│┼ \u{1F600}\r\n" }.joined()
        for i in 0..<120 {
            let terminal = Terminal(cols: 80, rows: 24) { _ in }
            let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
            surface.layout(size: CGSize(width: 900, height: 600), scale: 2)
            terminal.write(Array(text.utf8))
            if i < 16 { surface.renderIfDirty() }
            surfaces.append(surface)
        }
        try await Task.sleep(for: .seconds(1))
        let made = footprint()
        var worst = 0.0
        let startTime = CACurrentMediaTime()
        for round in 0..<120 {
            let frameStart = CACurrentMediaTime()
            for text in surfaces.prefix(16) {
                text.terminal.write(Array(String(repeating: "round \(round) yes yes yes yes yes yes yes yes\r\n", count: 30).utf8))
                text.renderIfDirty()
            }
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        let elapsed = CACurrentMediaTime() - startTime
        try await Task.sleep(for: .seconds(1))
        print("PROBE 120 surfaces: +\((made - start) >> 20) MB made, +\((footprint() - start) >> 20) MB after floods; 16 visible frame worst \(worst)s avg \(elapsed / 120)")
        for text in surfaces { text.releaseGPUResources() }
        try await Task.sleep(for: .seconds(2))
        print("PROBE 120 surfaces released: +\((footprint() - start) >> 20) MB")
        surfaces.removeAll()
        try await Task.sleep(for: .seconds(2))
        print("PROBE 120 surfaces freed: +\((footprint() - start) >> 20) MB")
    }

    @Test func probeFontSizeStorm() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 1400, height: 900), scale: 2)
        terminal.write(Array((0..<40).map { "line \($0): the quick brown fox ✓ λ → ─│┼ 日本語 \u{1F600}\r\n" }.joined().utf8))
        let start = footprint()
        var worst = 0.0
        let startTime = CACurrentMediaTime()
        for i in 0..<200 {
            var appearance = surface.appearance
            appearance.fontSize = CGFloat(6 + (i * 7) % 60)
            appearance.background = RGB(r: UInt8(i % 255), g: 0, b: 0)
            surface.appearance = appearance
            terminal.write(Array("flood \(i) \(String(repeating: "z", count: 300))\r\n".utf8))
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        print("PROBE font storm: worst \(worst) avg \((CACurrentMediaTime() - startTime) / 200) footprint +\((footprint() - start) >> 20) MB")
    }

    @Test func probeRandomBytes() throws {
        let terminal = Terminal(cols: 200, rows: 60) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 1800, height: 1000), scale: 2)
        let start = footprint()
        var worst = 0.0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            for i in chunk.indices { chunk[i] = UInt8.random(in: 0...255, using: &rng) }
            terminal.write(chunk)
            // Random combining clusters.
            var text = ""
            for _ in 0..<500 {
                text.unicodeScalars.append(Unicode.Scalar(UInt32.random(in: 0x61...0x7A))!)
                for _ in 0..<Int.random(in: 1...4) { text.unicodeScalars.append(Unicode.Scalar(UInt32.random(in: 0x300...0x36F))!) }
            }
            terminal.write(Array(text.utf8))
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        print("PROBE random bytes: worst \(worst) atlas \(surface.atlasSizes) footprint +\((footprint() - start) >> 20) MB")
    }

    /// Opens, draws, hides and closes 50 panes ten times; footprint per cycle should stay flat.
    /// Waits at the end so `leaks` can inspect the process (probe-leaks.sh).
    @Test func probeSurfaceChurn() async throws {
        weak var lastSurface: TerminalSurface?
        var cycles: [Int] = []
        for cycle in 0..<10 {
            try autoreleasepool {
                var panes: [TerminalSurface] = []
                for i in 0..<50 {
                    let terminal = Terminal(cols: 80, rows: 24) { _ in }
                    let surface = try TerminalSurface(terminal: terminal, fontSize: CGFloat(12 + i % 3))
                    surface.layout(size: CGSize(width: 900, height: 600), scale: 2)
                    terminal.write(Array(String(repeating: "cycle \(cycle) pane \(i) ✓ 日本 😀\r\n", count: 40).utf8))
                    surface.renderIfDirty()
                    panes.append(surface)
                }
                for p in panes { p.releaseGPUResources() }
                lastSurface = panes.last
            }
            try await Task.sleep(for: .milliseconds(500))
            cycles.append(footprint() >> 20)
        }
        print("PROBE churn footprint MB per cycle: \(cycles), last surface freed: \(lastSurface == nil)")
        try await pauseForInspection()
    }

    /// With GUDO_STRESS_SAMPLE=<file>, samples this process for a few seconds in the background.
    func startSampling() {
        guard let file = ProcessInfo.processInfo.environment["GUDO_STRESS_SAMPLE"] else { return }
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(getpid())", "5", "-file", file]
        try? sample.run()
    }

    /// With GUDO_STRESS_PAUSE=<file>, writes the pid there and waits for `leaks`/`vmmap`.
    func pauseForInspection() async throws {
        guard let pidFile = ProcessInfo.processInfo.environment["GUDO_STRESS_PAUSE"] else { return }
        try? "\(getpid())".write(toFile: pidFile, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(40))
    }

    /// Kitty images at their limits: a stream of large images and one at the size cap.
    @Test func probeKittyLimits() async throws {
        let terminal = Terminal(cols: 120, rows: 40) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 1400, height: 900), scale: 2)
        let start = footprint()
        var worst = 0.0
        func send(id: Int, w: Int, h: Int) {
            let pixels = [UInt8](repeating: UInt8(id % 255), count: w * h * 4)
            let b64 = Data(pixels).base64EncodedString()
            var seq: [UInt8] = []
            var i = b64.startIndex
            while i < b64.endIndex {
                let j = b64.index(i, offsetBy: 4096, limitedBy: b64.endIndex) ?? b64.endIndex
                let more = j < b64.endIndex ? 1 : 0
                let head = i == b64.startIndex ? "a=T,f=32,s=\(w),v=\(h),i=\(id),c=20,r=10,q=2,m=\(more)" : "m=\(more)"
                seq += Array("\u{1b}_G\(head);\(b64[i..<j])\u{1b}\\".utf8)
                i = j
            }
            terminal.write(seq)
            surface.outputArrived()
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - frameStart)
        }
        for id in 1...60 { send(id: id, w: 2000, h: 1500) }
        try await Task.sleep(for: .seconds(1))
        print("PROBE kitty 60x 2000x1500: worst frame \(worst), textures \(surface.kittyTextures.count), placements \(surface.kittyPlacements.count), footprint +\((footprint() - start) >> 20) MB")
        worst = 0
        send(id: 999, w: 8000, h: 2000)
        print("PROBE kitty 8000x2000 (64 MB): frame \(worst), textures \(surface.kittyTextures.count), footprint +\((footprint() - start) >> 20) MB")
        try await pauseForInspection()
    }

    /// Scrollback search with a full 10 MB scrollback of matches, during a flood.
    @Test func probeSearchDuringFlood() throws {
        let terminal = Terminal(cols: 160, rows: 50) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 1400, height: 900), scale: 2)
        let line = Array((String(repeating: "the needle e ", count: 12) + "\r\n").utf8)
        var block: [UInt8] = []
        for _ in 0..<1000 { block += line }
        for _ in 0..<120 { terminal.write(block) }  // ~19 MB through a 10 MB scrollback
        surface.renderIfDirty()
        let startTime = CACurrentMediaTime()
        surface.setSearch("e")
        let setCost = CACurrentMediaTime() - startTime
        var worst = 0.0
        var frames = 0
        startSampling()
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 8 {
            terminal.write(Array(line.prefix(80)) + Array("\r\n".utf8))
            surface.outputArrived()
            let frameStart = CACurrentMediaTime()
            surface.renderIfDirty()
            if frames % 10 == 0 { _ = surface.selectMatch(.next) }
            worst = max(worst, CACurrentMediaTime() - frameStart)
            frames += 1
        }
        print("PROBE search during flood: setSearch \(setCost)s, worst frame \(worst)s over \(frames) frames, status \(String(describing: surface.search?.status))")
    }

    /// Reflow of a full scrollback of long wrapped lines on resize (runs on the main thread for
    /// local panes), and an unterminated OSC of 100 MB.
    @Test func probeReflowAndUnterminatedOSC() throws {
        let terminal = Terminal(cols: 200, rows: 50) { _ in }
        let line = Array((String(repeating: "wrapped text 😀 日本 ", count: 60) + "\r\n").utf8)
        var block: [UInt8] = []
        for _ in 0..<500 { block += line }
        for _ in 0..<40 { terminal.write(block) }
        var worst = 0.0
        for i in 0..<20 {
            let probeStart = CACurrentMediaTime()
            terminal.resize(cols: UInt16(80 + (i * 37) % 200), rows: UInt16(30 + i % 20), cellWidth: 10, cellHeight: 20)
            worst = max(worst, CACurrentMediaTime() - probeStart)
        }
        print("PROBE reflow full scrollback: worst resize \(worst)s")
        let start = footprint()
        let startTime = CACurrentMediaTime()
        terminal.write(Array("\u{1b}]2;".utf8))
        let chunk = [UInt8](repeating: 0x41, count: 1 << 20)
        for _ in 0..<100 { terminal.write(chunk) }
        terminal.write(Array("\u{7}after".utf8))
        print("PROBE unterminated OSC 100 MB: \(CACurrentMediaTime() - startTime)s, footprint +\((footprint() - start) >> 20) MB, title length \(terminal.title.count)")
    }
}

