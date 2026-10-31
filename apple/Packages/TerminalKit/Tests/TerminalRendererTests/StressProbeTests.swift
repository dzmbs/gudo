import Darwin
import Foundation
import QuartzCore
import Testing
import TerminalCore
@testable import TerminalRenderer

/// Measurements for docs/STRESS.md, printed as "PROBE" lines; slow, so opt-in:
/// `UNNAMED_STRESS=1 swift test -c release -Xswiftc -enable-testing --filter StressProbeTests`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["UNNAMED_STRESS"] != nil))
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
        let t0 = CACurrentMediaTime()
        var cp: UInt32 = 0x4E00
        var worst = 0.0
        while cp < 0x9FFF {
            var s = "\u{1b}[H"
            for _ in 0..<1000 { s.unicodeScalars.append(Unicode.Scalar(cp)!); cp += 1 }
            terminal.write(Array(s.utf8))
            let f0 = CACurrentMediaTime()
            surface.renderIfDirty(offscreen: true)
            worst = max(worst, CACurrentMediaTime() - f0)
        }
        print("PROBE CJK size \(size): atlas \(surface.atlasSizes) footprint +\((footprint() - start) >> 20) MB, \(CACurrentMediaTime() - t0)s, worst frame \(worst)")
    }

    @Test(arguments: [13.0, 48.0]) func probeEmoji(size: Double) throws {
        let terminal = Terminal(cols: 200, rows: 60) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: size)
        surface.layout(size: CGSize(width: 3000, height: 1600), scale: 2)
        let start = footprint()
        let t0 = CACurrentMediaTime()
        let emoji = (0x1F300...0x1FAFF).compactMap { Unicode.Scalar($0) }.filter { $0.properties.isEmojiPresentation }
        var worst = 0.0
        for chunk in stride(from: 0, to: emoji.count, by: 500) {
            var s = "\u{1b}[H"
            for e in emoji[chunk..<min(chunk + 500, emoji.count)] { s.unicodeScalars.append(e) }
            terminal.write(Array(s.utf8))
            let f0 = CACurrentMediaTime()
            surface.renderIfDirty(offscreen: true)
            worst = max(worst, CACurrentMediaTime() - f0)
        }
        print("PROBE emoji(\(emoji.count)) size \(size): atlas \(surface.atlasSizes) footprint +\((footprint() - start) >> 20) MB, \(CACurrentMediaTime() - t0)s worst \(worst)")
    }

    @Test func probeHugeDrawable() throws {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 4)
        surface.layout(size: CGSize(width: 9000, height: 5000), scale: 2)
        terminal.write(Array(String(repeating: "x", count: 5000).utf8))
        let t = CACurrentMediaTime()
        let r = surface.renderIfDirty()
        print("PROBE huge drawable: rendered \(r) grid \(String(describing: surface.grid)) layer \(surface.layer.drawableSize) in \(CACurrentMediaTime() - t)")
        let r2 = surface.renderIfDirty(offscreen: true)
        print("PROBE huge offscreen: \(r2)")
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
            let f0 = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - f0)
        }
        print("PROBE 6K tiny: worst frame \(worst) footprint +\((footprint() - start) >> 20) MB \(surface.stats.drain().map(String.init(describing:)) ?? "")")
    }

    @Test func probeManySurfaces() async throws {
        let start = footprint()
        var surfaces: [TerminalSurface] = []
        let text = (0..<40).map { "line \($0): the quick brown fox ✓ λ → ─│┼ \u{1F600}\r\n" }.joined()
        for i in 0..<120 {
            let terminal = Terminal(cols: 80, rows: 24) { _ in }
            let s = try TerminalSurface(terminal: terminal, fontSize: 13)
            s.layout(size: CGSize(width: 900, height: 600), scale: 2)
            terminal.write(Array(text.utf8))
            if i < 16 { s.renderIfDirty() }
            surfaces.append(s)
        }
        try await Task.sleep(for: .seconds(1))
        let made = footprint()
        var worst = 0.0
        let t0 = CACurrentMediaTime()
        for round in 0..<120 {
            let f0 = CACurrentMediaTime()
            for s in surfaces.prefix(16) {
                s.terminal.write(Array(String(repeating: "round \(round) yes yes yes yes yes yes yes yes\r\n", count: 30).utf8))
                s.renderIfDirty()
            }
            worst = max(worst, CACurrentMediaTime() - f0)
        }
        let elapsed = CACurrentMediaTime() - t0
        try await Task.sleep(for: .seconds(1))
        print("PROBE 120 surfaces: +\((made - start) >> 20) MB made, +\((footprint() - start) >> 20) MB after floods; 16 visible frame worst \(worst)s avg \(elapsed / 120)")
        for s in surfaces { s.releaseGPUResources() }
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
        let t0 = CACurrentMediaTime()
        for i in 0..<200 {
            var a = surface.appearance
            a.fontSize = CGFloat(6 + (i * 7) % 60)
            a.background = RGB(r: UInt8(i % 255), g: 0, b: 0)
            surface.appearance = a
            terminal.write(Array("flood \(i) \(String(repeating: "z", count: 300))\r\n".utf8))
            let f0 = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - f0)
        }
        print("PROBE font storm: worst \(worst) avg \((CACurrentMediaTime() - t0) / 200) footprint +\((footprint() - start) >> 20) MB")
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
            var s = ""
            for _ in 0..<500 {
                s.unicodeScalars.append(Unicode.Scalar(UInt32.random(in: 0x61...0x7A))!)
                for _ in 0..<Int.random(in: 1...4) { s.unicodeScalars.append(Unicode.Scalar(UInt32.random(in: 0x300...0x36F))!) }
            }
            terminal.write(Array(s.utf8))
            let f0 = CACurrentMediaTime()
            surface.renderIfDirty()
            worst = max(worst, CACurrentMediaTime() - f0)
        }
        print("PROBE random bytes: worst \(worst) atlas \(surface.atlasSizes) footprint +\((footprint() - start) >> 20) MB")
    }
}
