import GhosttyVt
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

/// Text cursor shapes (DECSCUSR), as in Ghostty's `cursor-style`.
public enum CursorShape: Sendable {
    case block, bar, underline, blockHollow

    var ghostty: GhosttyTerminalCursorStyle {
        switch self {
        case .block: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
        case .bar: GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
        case .underline: GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
        case .blockHollow: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
        }
    }
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
        /// The 256-color palette; nil keeps libghostty-vt's (Ghostty's) default palette.
        public var palette: [RGB]?
        /// `cursor-color`; nil draws the cursor in the foreground color.
        public var cursorColor: RGB?
        /// `cursor-style` and `cursor-style-blink`: what DECSCUSR 0 resets to.
        public var cursorStyle = CursorShape.block
        public var cursorBlink = true
        /// Ghostty's default `scrollback-limit` (10 MB).
        public var scrollbackBytes = 10_000_000

        public init() {}
    }

    /// Notifications from the VT stream. They run synchronously on the thread that called
    /// `write(_:)`, with the terminal locked: they must not call back into the terminal (read the
    /// title or pwd later, e.g. after hopping to the main actor).
    public struct Events: Sendable {
        /// OSC 0/2 changed the title.
        public var titleChanged: (@Sendable () -> Void)?
        /// OSC 7 (or OSC 9 / 1337 CurrentDir) changed the working directory.
        public var pwdChanged: (@Sendable () -> Void)?
        /// BEL.
        public var bell: (@Sendable () -> Void)?
        /// An OSC 133 step.
        public var semanticPrompt: (@Sendable (SemanticPromptStep) -> Void)?

        public init() {}
    }

    /// OSC 133 marks: prompt start (A), input start (B), output start (C), command end (D).
    public enum SemanticPromptStep: Sendable, Equatable {
        case promptStart, inputStart, outputStart
        case commandEnd(exitCode: Int32?)
    }

    /// Receives bytes the terminal itself must send back to the PTY (DA/DSR replies, mode reports,
    /// pastes) and the terminal's notifications.
    final class Effects: Sendable {
        let writePty: @Sendable (UnsafeRawBufferPointer) -> Void
        let events = Mutex(Events())

        init(writePty: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
            self.writePty = writePty
        }

        static func from(_ userdata: UnsafeMutableRawPointer?) -> Effects? {
            userdata.map { Unmanaged<Effects>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    private let lock = Mutex(())
    private let terminal: GhosttyTerminal
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    let mouseEncoder: GhosttyMouseEncoder
    let mouseEvent: GhosttyMouseEvent
    /// The cell of the last reported motion, so motion within one cell is not re-sent.
    let lastMouseCell = Mutex<GridPoint?>(nil)
    private let effects: Effects

    /// - Parameter writePty: called synchronously from `write(_:)` (on the writer's thread) with
    ///   query replies, and from `paste(_:)`. Must not call back into this terminal.
    public init(
        cols: UInt16,
        rows: UInt16,
        configuration: Configuration = .init(),
        writePty: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) {
        var terminal: GhosttyTerminal?
        var encoder: GhosttyKeyEncoder?
        var event: GhosttyKeyEvent?
        var mouseEncoder: GhosttyMouseEncoder?
        var mouseEvent: GhosttyMouseEvent?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS,
              ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS,
              ghostty_mouse_encoder_new(nil, &mouseEncoder) == GHOSTTY_SUCCESS,
              ghostty_mouse_event_new(nil, &mouseEvent) == GHOSTTY_SUCCESS,
              let terminal, let encoder, let event, let mouseEncoder, let mouseEvent
        else { fatalError("libghostty-vt allocation failed") }

        effects = Effects(writePty: writePty)
        let userdata = Unmanaged.passUnretained(effects).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)
        let onWritePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let data, let effects = Effects.from(userdata) else { return }
            effects.writePty(UnsafeRawBufferPointer(start: data, count: len))
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(onWritePty, to: UnsafeRawPointer.self))
        Self.installEventCallbacks(terminal)

        var bg = configuration.background.ghostty
        var fg = configuration.foreground.ghostty
        var scrollback = configuration.scrollbackBytes
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
        if let palette = configuration.palette, palette.count == 256 {
            var colors = palette.map(\.ghostty)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &colors)
        }
        if let cursor = configuration.cursorColor {
            var c = cursor.ghostty
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
        }
        var cursorStyle = configuration.cursorStyle.ghostty
        var cursorBlink = configuration.cursorBlink
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink)
        // Ghostty's default `grapheme-width-method = unicode`: mode 2027 on, so emoji ZWJ
        // sequences, flags and skin tones occupy one (wide) cell.
        var graphemeClusters = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemeClusters)

        self.terminal = terminal
        keyEncoder = encoder
        keyEvent = event
        self.mouseEncoder = mouseEncoder
        self.mouseEvent = mouseEvent
    }

    deinit {
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_terminal_free(terminal)
    }

    private static func installEventCallbacks(_ terminal: GhosttyTerminal) {
        let title: GhosttyTerminalTitleChangedFn = { _, userdata in
            Effects.from(userdata)?.events.withLock { $0.titleChanged }?()
        }
        let pwd: GhosttyTerminalPwdChangedFn = { _, userdata in
            Effects.from(userdata)?.events.withLock { $0.pwdChanged }?()
        }
        let bell: GhosttyTerminalBellFn = { _, userdata in
            Effects.from(userdata)?.events.withLock { $0.bell }?()
        }
        let prompt: GhosttyTerminalSemanticPromptFn = { _, userdata, event in
            guard let event, let handler = Effects.from(userdata)?.events.withLock({ $0.semanticPrompt }) else { return }
            let step: SemanticPromptStep? = switch event.pointee.kind {
            case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START: .promptStart
            case GHOSTTY_SEMANTIC_PROMPT_INPUT_START: .inputStart
            case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START: .outputStart
            case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END: .commandEnd(exitCode: event.pointee.has_exit_code ? event.pointee.exit_code : nil)
            default: nil
            }
            if let step { handler(step) }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwd, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(prompt, to: UnsafeRawPointer.self))
    }

    /// Replaces the event handlers. Safe from any thread.
    public func setEvents(_ events: Events) {
        effects.events.withLock { $0 = events }
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
