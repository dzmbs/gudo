import CGhosttyVt
import Synchronization

/// An sRGB color with 8-bit channels.
public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ c: GhosttyColorRgb) {
        self.init(r: c.r, g: c.g, b: c.b)
    }

    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}

/// A libghostty-vt terminal: VT parser, screens, scrollback and modes.
///
/// libghostty-vt creates no threads and is not internally synchronized. Every access to the
/// handles goes through `lock`, so bytes can be written from an IO thread while the render loop
/// snapshots the terminal into a `RenderState` (only `begin_update` runs under the lock, as Ghostty
/// does). That invariant is what makes the `@unchecked Sendable` sound.
public final class Terminal: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Ghostty's default theme (`background`/`foreground` in `src/config/Config.zig`).
        public var background = RGB(r: 0x28, g: 0x2C, b: 0x34)
        public var foreground = RGB(r: 0xFF, g: 0xFF, b: 0xFF)
        /// Ghostty's default `scrollback-limit` (10 MB).
        public var scrollbackBytes = 10_000_000

        public init() {}
    }

    /// Receives bytes the terminal itself must send back to the PTY (DA/DSR replies, mode reports).
    private final class Effects: Sendable {
        let writePty: @Sendable (UnsafeRawBufferPointer) -> Void

        init(writePty: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
            self.writePty = writePty
        }
    }

    private let lock = Mutex(())
    private let terminal: GhosttyTerminal
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private let effects: Effects

    /// - Parameter writePty: called synchronously from `write(_:)` (on the writer's thread) with
    ///   query replies. Must not call back into this terminal.
    public init(
        cols: UInt16,
        rows: UInt16,
        configuration: Configuration = .init(),
        writePty: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) {
        var terminal: GhosttyTerminal?
        var encoder: GhosttyKeyEncoder?
        var event: GhosttyKeyEvent?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS,
              ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS,
              let terminal, let encoder, let event
        else { fatalError("libghostty-vt allocation failed") }

        effects = Effects(writePty: writePty)
        let userdata = Unmanaged.passUnretained(effects).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)
        let onWritePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data else { return }
            let effects = Unmanaged<Effects>.fromOpaque(userdata).takeUnretainedValue()
            effects.writePty(UnsafeRawBufferPointer(start: data, count: len))
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(onWritePty, to: UnsafeRawPointer.self))

        var bg = configuration.background.ghostty
        var fg = configuration.foreground.ghostty
        var scrollback = configuration.scrollbackBytes
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
        // Ghostty's default `grapheme-width-method = unicode`: mode 2027 on, so emoji ZWJ
        // sequences, flags and skin tones occupy one (wide) cell.
        var graphemeClusters = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemeClusters)

        self.terminal = terminal
        keyEncoder = encoder
        keyEvent = event
    }

    deinit {
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_terminal_free(terminal)
    }

    /// Feeds raw PTY output through the VT parser.
    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        lock.withLock { _ in ghostty_terminal_vt_write(terminal, base, bytes.count) }
    }

    public func write(_ bytes: some Sequence<UInt8>) {
        Array(bytes).withUnsafeBytes { write($0) }
    }

    /// Resizes the grid. Cell pixel sizes feed pixel-size reports (CSI 14/16 t, kitty images).
    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        lock.withLock { _ in _ = ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight) }
    }

    /// Scrolls the viewport through scrollback. Negative values scroll up (towards history).
    public func scrollViewport(by rows: Int) {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = rows
        lock.withLock { _ in ghostty_terminal_scroll_viewport(terminal, scroll) }
    }

    public func scrollToBottom() {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        lock.withLock { _ in ghostty_terminal_scroll_viewport(terminal, scroll) }
    }

    /// Encodes a key event for the PTY using the terminal's current modes (cursor-key mode, kitty
    /// keyboard flags, ...). Returns an empty array for events that produce no input.
    public func encode(_ key: KeyEvent) -> [UInt8] {
        lock.withLock { _ in
            ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
            ghostty_key_event_set_action(keyEvent, key.action.ghostty)
            ghostty_key_event_set_key(keyEvent, key.key.raw)
            ghostty_key_event_set_mods(keyEvent, key.mods.rawValue)
            ghostty_key_event_set_consumed_mods(keyEvent, key.consumedMods.rawValue)
            ghostty_key_event_set_unshifted_codepoint(keyEvent, key.unshiftedCodepoint)
            ghostty_key_event_set_composing(keyEvent, false)

            var buffer = [CChar](repeating: 0, count: 128)
            var written = 0
            let result = key.text.withCString { text in
                // The event borrows `text`, so encode while it is alive.
                ghostty_key_event_set_utf8(keyEvent, key.text.isEmpty ? nil : text, key.text.utf8.count)
                return ghostty_key_encoder_encode(keyEncoder, keyEvent, &buffer, buffer.count, &written)
            }
            guard result == GHOSTTY_SUCCESS else { return [] }
            return buffer.prefix(written).map { UInt8(bitPattern: $0) }
        }
    }

    /// Runs `body` with exclusive access to the raw terminal handle.
    func withHandle<R>(_ body: (GhosttyTerminal) -> R) -> R {
        lock.withLock { _ in body(terminal) }
    }
}
