import AppKit
import LocalPTY
import TerminalCore
import TerminalRenderer

/// Spike A demo: an AppKit window running /bin/zsh through libghostty-vt and the Metal renderer.
///
///     swift run TerminalDemo [--stats] [--run "<command>"] [--scroll-bench <rows>] [--quit-after <s>]
///
/// --stats prints a frame-time summary to stderr every second; --run types a command into the
/// shell once it starts; --scroll-bench scrolls the viewport up and back down <rows> rows, one row
/// per display frame, starting 3 s after launch.
struct Options {
    var stats = false
    var run: String?
    var scrollBenchRows: Int?
    var quitAfter: TimeInterval?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--stats": stats = true
            case "--run": run = it.next()
            case "--scroll-bench": scrollBenchRows = it.next().flatMap(Int.init)
            case "--quit-after": quitAfter = it.next().flatMap(TimeInterval.init)
            default: FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var window: NSWindow?
    private var timers: [Timer] = []

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        do {
            try launch()
        } catch {
            log("failed to start: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func launch() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TerminalKitDemo"
        let pty = try PTY(argv: ["/bin/zsh", "-l"], environment: environment, cols: 80, rows: 24)
        let terminal = Terminal(cols: 80, rows: 24) { pty.write($0) }
        let surface = try TerminalSurface(terminal: terminal)
        surface.onGridChange = { grid in
            pty.resize(cols: grid.cols, rows: grid.rows,
                       pixelWidth: UInt16(clamping: UInt32(grid.cols) * grid.cellWidth),
                       pixelHeight: UInt16(clamping: UInt32(grid.rows) * grid.cellHeight))
        }

        let view = TerminalView(surface: surface)
        view.onInput = { bytes in bytes.withUnsafeBytes { pty.write($0) } }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TerminalKit — spike A"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        NSApp.activate()

        pty.start(
            onOutput: { bytes in
                terminal.write(bytes)
                surface.setNeedsRender()
            },
            onExit: { Task { @MainActor in NSApp.terminate(nil) } })

        log("window \(window.windowNumber); shaders compiled at runtime in \(String(format: "%.1f", surface.shaderCompileSeconds * 1000)) ms")
        startInstrumentation(surface: surface, pty: pty)
    }

    private func startInstrumentation(surface: TerminalSurface, pty: PTY) {
        if options.stats {
            schedule(every: 1) {
                if let summary = surface.stats.drain() {
                    self.log("\(summary) atlas=\(surface.atlasSizes.grayscale)/\(surface.atlasSizes.color)")
                }
                return true
            }
        }
        if let command = options.run {
            schedule(after: 1) { Array((command + "\n").utf8).withUnsafeBytes { pty.write($0) } }
        }
        if let rows = options.scrollBenchRows {
            schedule(after: 3) {
                self.log("scroll bench: \(rows) rows up, then down")
                var step = 0
                self.schedule(every: 1.0 / 120) {
                    surface.scroll(rows: step < rows ? -1 : 1)
                    step += 1
                    guard step < 2 * rows else {
                        self.log("scroll bench done")
                        return false
                    }
                    return true
                }
            }
        }
        if let seconds = options.quitAfter {
            schedule(after: seconds) { NSApp.terminate(nil) }
        }
    }

    private func schedule(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        timers.append(Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        })
    }

    /// Repeats `body` until it returns false.
    private func schedule(every seconds: TimeInterval, _ body: @escaping @MainActor () -> Bool) {
        let timer = Timer(timeInterval: seconds, repeats: true) { timer in
            if !MainActor.assumeIsolated(body) { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func installMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(message)\n".utf8))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: Options(CommandLine.arguments))
app.delegate = delegate
app.run()
