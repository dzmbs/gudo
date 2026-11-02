import Foundation
import ImageIO
import LocalPTY
import QuartzCore
import Synchronization
import TerminalCore
import TerminalRenderer

/// Headless benchmark: drives the same `TerminalSurface` render path as the demo window,
/// with frames paced at 120 Hz by a sleep loop instead of a display link (so it runs with the
/// screen locked or in CI), and writes a rendered PNG. `cat` runs as a real child process on a PTY.
///
///     swift run -c release TerminalBench [--file <big file>] [--png <out.png>] [--glyphs-png <out.png>]
@MainActor
final class Bench {
    static let frameInterval = 1.0 / 120
    let surface: TerminalSurface
    private var deadline = CACurrentMediaTime()
    var terminal: Terminal { surface.terminal }

    init() throws {
        surface = try TerminalSurface(terminal: Terminal(cols: 80, rows: 24) { _ in })
        // Same geometry as the demo window: 900x600 pt on a 2x display.
        surface.layout(size: CGSize(width: 900, height: 600), scale: 2)
        print("shader compile: \(ms(surface.shaderCompileSeconds)) ms, grid: \(surface.grid!)")
    }

    func showcase(png: URL) {
        terminal.write(Array(Self.showcaseText.utf8))
        surface.renderIfDirty(offscreen: true)
        guard let image = surface.snapshot(),
              let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)
        else { return print("snapshot failed") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(png.path) atlas=\(surface.atlasSizes)")
        _ = surface.stats.drain()
    }

    /// Renders `GlyphFixture` (sprites, Nerd Font icons, emoji, CJK) on a cleared screen and writes
    /// it as a PNG.
    func glyphs(png: URL) {
        terminal.write(Array(("\u{1b}[H\u{1b}[2J" + GlyphFixture.text).utf8))
        surface.renderIfDirty(offscreen: true)
        guard let image = surface.snapshot(),
              let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)
        else { return print("snapshot failed") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(png.path) atlas=\(surface.atlasSizes)")
        _ = surface.stats.drain()
    }

    /// A full screen of box drawing, blocks, braille and Powerline that changes on every frame
    /// (a btop/htop-like dashboard redraw): every row rebuilt, every glyph a sprite.
    /// A full screen of text with a selection drag growing and shrinking one cell per frame (each
    /// selection change makes libghostty-vt report the whole viewport dirty), plus a moving
    /// prediction/preedit-style overlay: the worst case for selection rendering.
    func selectionDrag(frames: Int) {
        let grid = surface.grid!
        let cols = Int(grid.cols), rows = Int(grid.rows)
        var screen = "\u{1b}[H"
        for row in 0..<rows {
            var line = ""
            while line.count < cols { line += "selection \u{1b}[1mheavy\u{1b}[0m \u{1b}[4mscreen\u{1b}[0m \u{1b}[38;5;\(row % 200)mrow\(row) " }
            screen += line + (row + 1 < rows ? "\r\n" : "")
        }
        terminal.write(Array(screen.utf8))
        surface.renderIfDirty(offscreen: true)
        _ = surface.stats.drain()
        let top = terminal.screenPoint(fromViewport: GridPoint(x: 0, y: 0))!
        for frame in 0..<frames {
            let cells = (frame * 37) % (cols * rows)
            let head = GridPoint(x: cells % cols, y: top.y + cells / cols)
            terminal.setSelection(Selection(anchor: top, head: head, rectangle: frame % 60 >= 30))
            surface.renderIfDirty(offscreen: true)
            pace()
        }
        terminal.clearSelection()
        report("selection drag (full-screen selection change/frame)")
    }

    func spriteScreen(frames: Int) {
        let grid = surface.grid!
        let cols = Int(grid.cols), rows = Int(grid.rows)
        let ramp = Array("▁▂▃▄▅▆▇█")
        let boxes = Array("─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬━┃┏┓┗┛╭╮╯╰")
        for frame in 0..<frames {
            var screen = "\u{1b}[H"
            for row in 0..<rows {
                var line = "\u{1b}[38;5;\(16 + (row * 7 + frame) % 216)m"
                switch row % 4 {
                case 0:
                    // Braille graph scrolling one dot column per frame.
                    for col in 0..<cols {
                        let leftDots = Int((sin(Double(col * 2 + frame) / 5) + 1) * 1.99)
                        let rightDots = Int((sin(Double(col * 2 + 1 + frame) / 5) + 1) * 1.99)
                        let left: [UInt32] = [0x40, 0x04, 0x02, 0x01], right: [UInt32] = [0x80, 0x20, 0x10, 0x08]
                        line.unicodeScalars.append(Unicode.Scalar(0x2800 + left[leftDots] + right[rightDots])!)
                    }
                case 1:
                    for col in 0..<cols { line.append(ramp[(col + frame) % ramp.count]) }
                case 2:
                    for col in 0..<cols { line.append(boxes[(col * 3 + row + frame) % boxes.count]) }
                default:
                    var segments = ""
                    while segments.count < cols { segments += " cpu \u{E0B0}\u{E0B1}▓▒░ " }
                    line += "\u{1b}[44m" + String(segments.prefix(cols))
                }
                screen += line + "\u{1b}[0m" + (row + 1 < rows ? "\r\n" : "")
            }
            terminal.write(Array(screen.utf8))
            surface.renderIfDirty(offscreen: true)
            pace()
        }
        report("sprite screen (full redraw/frame)")
    }

    /// One character per frame: the partial-dirty path (one row rebuilt, the rest reused).
    func typing(frames: Int) {
        for i in 0..<frames {
            terminal.write(Array((i % 60 == 59 ? "\r\n" : "x").utf8))
            surface.renderIfDirty(offscreen: true)
            pace()
        }
        report("typing (1 char/frame)")
    }

    /// Runs `/bin/cat file` on a PTY, feeding output to the terminal as the demo does, while the
    /// main thread renders at 120 Hz (or not at all, for the throughput baseline).
    func cat(_ file: URL, render: Bool, label: String) throws {
        let done = Flag()
        let terminal = terminal, surface = surface, grid = surface.grid!
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        let pty = try PTY(argv: ["/bin/cat", file.path], environment: [:], cols: grid.cols, rows: grid.rows)
        let start = CACurrentMediaTime()
        pty.start(
            onOutput: { bytes in
                terminal.write(bytes)
                surface.setNeedsRender()
            },
            onExit: { done.set() })
        var frames = 0
        while !done.isSet {
            if render, surface.renderIfDirty(offscreen: true) { frames += 1 }
            pace()
        }
        let seconds = CACurrentMediaTime() - start
        surface.renderIfDirty(offscreen: true)
        print(String(format: "%@: %.1f MB in %.2f s (%.0f MB/s) over a PTY, %d frames",
                     label, Double(size) / 1e6, seconds, Double(size) / 1e6 / seconds, frames))
        report(label)
    }

    /// Scrolls the viewport up and back down one row per frame.
    func scroll(rows: Int) {
        for step in 0..<(2 * rows) {
            surface.scroll(rows: step < rows ? -1 : 1)
            surface.renderIfDirty(offscreen: true)
            pace()
        }
        report("scroll (1 row/frame)")
    }

    /// Sleeps until the next 120 Hz frame deadline.
    private func pace() {
        deadline = max(deadline + Self.frameInterval, CACurrentMediaTime())
        Thread.sleep(forTimeInterval: max(0, deadline - CACurrentMediaTime()))
    }

    private func report(_ name: String) {
        guard let summary = surface.stats.drain() else { return print("\(name): no frames") }
        print("\(name): \(summary)")
    }

    static let showcaseText = [
        "\u{1b}[1;32mme@mac\u{1b}[0m:\u{1b}[1;34m~/projects/gudo\u{1b}[0m$ ./showcase\r\n",
        "\u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[1;3mbold-italic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m ",
        "\u{1b}[9mstrike\u{1b}[0m \u{1b}[7minverse\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m\r\n",
        (0..<16).map { "\u{1b}[48;5;\($0)m   " }.joined() + "\u{1b}[0m\r\n",
        (0..<16).map { "\u{1b}[38;5;\($0)mc\(String($0).padding(toLength: 3, withPad: " ", startingAt: 0))" }.joined() + "\u{1b}[0m\r\n",
        (0..<96).map { i in let red = i * 255 / 95; return "\u{1b}[48;2;\(red);\(255 - red);160m " }.joined() + "\u{1b}[0m\r\n",
        "emoji: 😀 👍🏽 🇩🇪 👨‍👩‍👧   cjk: 漢字かな   symbols: ✓ → ≠ λ ∑   nerd: \u{e0b0} \u{f09b} \u{e7a8} \u{f120}\r\n",
        "box: ┌─┬─┐ │ │ │ └─┴─┘ ═║╔╗ ▀▄█░▒▓ ⣿⠿   ligature-free: -> => != === <= >= :: |||\r\n",
        "\u{1b}[38;2;255;128;0mtruecolor orange\u{1b}[0m \u{1b}[38;2;97;175;239mblue\u{1b}[0m \u{1b}[4;31mred underline\u{1b}[0m\r\n",
        "\r\n",
        "\u{1b}[38;5;245m// libghostty-vt render state -> Metal (Ghostty shaders, JetBrains Mono NF 13pt)\u{1b}[0m\r\n",
        "\u{1b}[35mfunc\u{1b}[0m \u{1b}[34mrenderIfDirty\u{1b}[0m() -> \u{1b}[33mBool\u{1b}[0m {\r\n",
        "    state.\u{1b}[34mupdate\u{1b}[0m(from: terminal)\r\n",
        "    \u{1b}[35mguard\u{1b}[0m state.dirty != .clean \u{1b}[35melse\u{1b}[0m { \u{1b}[35mreturn\u{1b}[0m \u{1b}[33mfalse\u{1b}[0m }\r\n",
        "}\r\n",
        "\r\n",
        "\u{1b}[1;32mme@mac\u{1b}[0m:\u{1b}[1;34m~/projects/gudo\u{1b}[0m$ ",
    ].joined()
}

final class Flag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    func set() { value.store(true, ordering: .releasing) }
}

func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

/// Throughput of the VT parser alone (no PTY, no rendering), for comparison with `cat`.
func baselineThroughput(_ file: URL) throws {
    // The tty line discipline (ONLCR) turns "\n" into "\r\n" before the terminal sees it.
    let data = Data(try Data(contentsOf: file).flatMap { $0 == 0x0A ? [0x0D, 0x0A] : [$0] })
    let terminal = Terminal(cols: 112, rows: 35) { _ in }
    let start = CACurrentMediaTime()
    data.withUnsafeBytes { terminal.write($0) }
    let seconds = CACurrentMediaTime() - start
    print(String(format: "baseline vt_write only: %.0f MB/s", Double(data.count) / 1e6 / seconds))
}

var args = CommandLine.arguments.dropFirst().makeIterator()
var file: URL?
var png = URL(fileURLWithPath: "spike-a-render.png")
var glyphsPng: URL?
while let arg = args.next() {
    switch arg {
    case "--file": file = args.next().map { URL(fileURLWithPath: $0) }
    case "--png": png = URL(fileURLWithPath: args.next() ?? png.path)
    case "--glyphs-png": glyphsPng = args.next().map { URL(fileURLWithPath: $0) }
    default: print("unknown argument \(arg)")
    }
}

let bench = try Bench()
bench.showcase(png: png)
bench.typing(frames: 240)
bench.spriteScreen(frames: 240)
bench.selectionDrag(frames: 240)
if let glyphsPng { bench.glyphs(png: glyphsPng) }
if let file {
    try baselineThroughput(file)
    try bench.cat(file, render: false, label: "cat without rendering")
    try bench.cat(file, render: true, label: "cat with rendering")
    bench.scroll(rows: 600)
}
