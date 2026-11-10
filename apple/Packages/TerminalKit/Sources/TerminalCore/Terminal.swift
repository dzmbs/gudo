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

    init(_ color: GhosttyColorRgb) {
        self.init(r: color.r, g: color.g, b: color.b)
    }

    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}

/// Text cursor shapes (DECSCUSR), as in Ghostty's `cursor-style`.
public enum CursorShape: Sendable {
    case block, bar, underline, blockHollow

    var ghostty: GhosttyCursorStyle {
        switch self {
        case .block: GHOSTTY_CURSOR_STYLE_BLOCK
        case .bar: GHOSTTY_CURSOR_STYLE_BAR
        case .underline: GHOSTTY_CURSOR_STYLE_UNDERLINE
        case .blockHollow: GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW
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
    public struct Configuration: Sendable, Equatable {
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
        /// OSC 0/2 changed the title, or the alternate screen was entered or left in a terminal
        /// with shell integration (which decides `shownTitle`).
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
        let writeInput: @Sendable (UnsafeRawBufferPointer) -> Void
        let isPasting = Atomic<Bool>(false)
        let events = Mutex(Events())
        /// Whether query replies produced while writing output go to `writePty`.
        let answersQueries = Atomic<Bool>(true)
        /// Set while output is being parsed: whatever `writePty` gets then is a reply.
        let parsing = Atomic<Bool>(false)
        /// Kitty image storage per screen, for every handle (restored ones included).
        let imageStorageLimit = Atomic<UInt64>(KittyGraphics.storageLimit)
        /// The shell marks its prompts and commands (OSC 133).
        let shellIntegrated = Atomic<Bool>(false)
        /// The alternate screen was active after the last parse.
        let altScreen = Atomic<Bool>(false)
        /// The theme's background is dark: the color scheme programs are told.
        let darkScheme = Atomic<Bool>(true)

        init(writeInput: (@Sendable (UnsafeRawBufferPointer) -> Void)?, writePty: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
            self.writePty = writePty
            self.writeInput = writeInput ?? writePty
        }

        static func from(_ userdata: UnsafeMutableRawPointer?) -> Effects? {
            userdata.map { Unmanaged<Effects>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    let lock = Mutex(())
    /// Replaced (under `lock`) when a snapshot is restored; see `Terminal+Snapshot.swift`.
    var terminal: GhosttyTerminal
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    let mouseEncoder: GhosttyMouseEncoder
    let mouseEvent: GhosttyMouseEvent
    /// The cell of the last reported motion, so motion within one cell is not re-sent.
    let lastMouseCell = Mutex<GridPoint?>(nil)
    let effects: Effects
    /// Guarded by `lock` (a theme change replaces it while output arrives).
    private(set) var configuration: Configuration
    /// The decoder of the last restored snapshot while its history is still arriving (guarded by
    /// `lock`); see `Terminal+Snapshot.swift`.
    var restoreState: SnapshotRestore?
    /// Output of a synchronized update not parsed yet (guarded by `lock`).
    var synchronizedOutput = SynchronizedOutput()

    /// - Parameter writePty: called synchronously with generated replies, or paste bytes when
    ///   `writeInput` is absent. Neither callback may call back into this terminal.
    /// - Parameter writeInput: user paste bytes, separate from replies so input ownership is retained.
    public init(
        cols: UInt16,
        rows: UInt16,
        configuration: Configuration = .init(),
        writeInput: (@Sendable (UnsafeRawBufferPointer) -> Void)? = nil,
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

        effects = Effects(writeInput: writeInput, writePty: writePty)
        self.configuration = configuration
        Self.configure(terminal, effects: effects, configuration: configuration)

        self.terminal = terminal
        keyEncoder = encoder
        keyEvent = event
        self.mouseEncoder = mouseEncoder
        self.mouseEvent = mouseEvent
    }

    /// Applies the callbacks and options every terminal handle of this `Terminal` carries (the
    /// initial one and any restored from a snapshot).
    static func configure(_ terminal: GhosttyTerminal, effects: Effects, configuration: Configuration) {
        let userdata = Unmanaged.passUnretained(effects).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)
        let onWritePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let data, let effects = Effects.from(userdata) else { return }
            if effects.parsing.load(ordering: .relaxed), !effects.answersQueries.load(ordering: .relaxed) { return }
            let bytes = UnsafeRawBufferPointer(start: data, count: len)
            if effects.isPasting.load(ordering: .relaxed) { effects.writeInput(bytes) }
            else { effects.writePty(bytes) }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(onWritePty, to: UnsafeRawPointer.self))
        Self.installEventCallbacks(terminal)
        Self.installQueryReplies(terminal)
        effects.darkScheme.store(isDark(configuration.background), ordering: .relaxed)

        var scrollback = configuration.scrollbackBytes
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
        _ = KittyGraphics.installPNGDecoder
        var images = effects.imageStorageLimit.load(ordering: .relaxed)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &images)
        applyDefaults(terminal, configuration)
        // Ghostty's default `grapheme-width-method = unicode`: mode 2027 on, so emoji ZWJ
        // sequences, flags and skin tones occupy one (wide) cell.
        var graphemeClusters = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemeClusters)
    }

    /// The colors and cursor that programs' OSC overrides and DECSCUSR 0 fall back to. A nil
    /// palette or cursor color resets it to the built-in default.
    private static func applyDefaults(_ terminal: GhosttyTerminal, _ configuration: Configuration) {
        var bg = configuration.background.ghostty
        var fg = configuration.foreground.ghostty
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        if let palette = configuration.palette, palette.count == 256 {
            var colors = palette.map(\.ghostty)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &colors)
        } else {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil)
        }
        if var cursor = configuration.cursorColor?.ghostty {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
        } else {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
        var cursorStyle = configuration.cursorStyle.ghostty
        var cursorBlink = configuration.cursorBlink
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink)
    }

    /// Replaces the default colors and cursor of a running terminal (a theme change); the next
    /// render redraws every row, and a program that asked for color scheme reports (mode 2031)
    /// hears of a switch between light and dark. The scrollback limit stays the one it was
    /// created with.
    public func setDefaults(_ configuration: Configuration) {
        lock.withLock { _ in
            let scrollbackBytes = self.configuration.scrollbackBytes
            self.configuration = configuration
            self.configuration.scrollbackBytes = scrollbackBytes
            Self.applyDefaults(terminal, configuration)
            let dark = Self.isDark(configuration.background)
            guard effects.darkScheme.exchange(dark, ordering: .relaxed) != dark, answersQueries else { return }
            var reports = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2031, false), value: false)
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &reports) == GHOSTTY_SUCCESS, reports.value else { return }
            Array((dark ? "\u{1B}[?997;1n" : "\u{1B}[?997;2n").utf8).withUnsafeBytes { effects.writePty($0) }
        }
    }

    deinit {
        restoreState?.free()
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
            guard let effects = Effects.from(userdata) else { return }
            effects.shellIntegrated.store(true, ordering: .relaxed)
            guard let event, let handler = effects.events.withLock({ $0.semanticPrompt }) else { return }
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

    /// Whether the terminal answers the program's queries (device attributes, cursor reports,
    /// kitty graphics replies) through `writePty`. Off for a mirror of a remote pane, whose host
    /// VT already answers: the program would get every reply twice. Pastes still go out.
    public var answersQueries: Bool {
        get { effects.answersQueries.load(ordering: .relaxed) }
        set { effects.answersQueries.store(newValue, ordering: .relaxed) }
    }

    /// Kitty image storage per screen in bytes. A mirror of a remote pane keeps its host's
    /// (`DaemonPaneBackend.imageStorageLimit`): with less it would evict an image the host
    /// still places, with more keep one the host dropped. Applies at once and to snapshots
    /// restored later.
    public var kittyImageStorageLimit: UInt64 {
        get { effects.imageStorageLimit.load(ordering: .relaxed) }
        set {
            lock.withLock { _ in
                guard effects.imageStorageLimit.exchange(newValue, ordering: .relaxed) != newValue else { return }
                var images = newValue
                ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &images)
            }
        }
    }

    /// Replaces the event handlers. Safe from any thread.
    public func setEvents(_ events: Events) {
        effects.events.withLock { $0 = events }
    }

    /// Feeds raw PTY output through the VT parser. A synchronized update (mode 2026) is parsed
    /// once it is complete (`SynchronizedOutput`).
    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let answersQueries = answersQueries
        lock.withLock { _ in
            synchronizedOutput.take(
                UnsafeBufferPointer(start: base, count: bytes.count), answersQueries: answersQueries, now: { .now },
                parse: parseLocked)
        }
    }

    /// Whether output of an unfinished synchronized update is waiting.
    public var isHoldingOutput: Bool {
        lock.withLock { _ in synchronizedOutput.isHolding }
    }

    /// Parses a synchronized update that has waited too long for its end. Returns whether the
    /// screen may have changed.
    @discardableResult
    public func releaseExpiredHeldOutput(now: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock { _ in synchronizedOutput.releaseIfExpired(now: now, parseLocked) }
    }

    /// Parses `bytes`; the caller holds `lock`.
    func parseLocked(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        effects.parsing.store(true, ordering: .relaxed)
        ghostty_terminal_vt_write(terminal, base, bytes.count)
        effects.parsing.store(false, ordering: .relaxed)
        let altScreen = Self.isAltScreen(terminal)
        if effects.altScreen.exchange(altScreen, ordering: .relaxed) != altScreen,
           effects.shellIntegrated.load(ordering: .relaxed)
        {
            effects.events.withLock { $0.titleChanged }?()
        }
    }

    public func write(_ bytes: some Sequence<UInt8>) {
        Array(bytes).withUnsafeBytes { write($0) }
    }

    /// Resizes the grid. Cell pixel sizes feed pixel-size reports (CSI 14/16 t) and size kitty
    /// images; a mirror of a remote pane uses the host's, so images move the cursor alike.
    /// A held synchronized update is parsed first, at the size it was written for (a resize ends
    /// the update, as in Ghostty).
    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        lock.withLock { _ in
            if synchronizedOutput.isHolding { synchronizedOutput.release(parseLocked) }
            _ = ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight)
        }
    }

    /// Scrolls the viewport through scrollback. Negative values scroll up (towards history).
    public func scrollViewport(by rows: Int) {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = rows
        lock.withLock { _ in ghostty_terminal_scroll_viewport(terminal, scroll) }
    }

    public func scrollToBottom() {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        lock.withLock { _ in ghostty_terminal_scroll_viewport(terminal, scroll) }
    }

    /// Encodes a key event for the PTY using the terminal's current modes (cursor-key mode, kitty
    /// keyboard flags, ...). Returns an empty array for events that produce no input.
    public func encode(_ key: KeyEvent) -> [UInt8] {
        lock.withLock { _ in
            ghostty_key_encoder_set_from_terminal(keyEncoder, terminal)
            ghostty_key_event_set_action(keyEvent, key.action.ghostty)
            ghostty_key_event_set_key(keyEvent, key.key.raw)
            ghostty_key_event_set_mods(keyEvent, key.mods.rawValue)
            ghostty_key_event_set_consumed_mods(keyEvent, key.consumedMods.rawValue)
            ghostty_key_event_set_unshifted_codepoint(keyEvent, key.unshiftedCodepoint)
            ghostty_key_event_set_composing(keyEvent, false)

            var buffer = [UInt8](repeating: 0, count: 128)
            var written = 0
            var text = key.text
            let result = text.withUTF8 { utf8 in
                // The event borrows `utf8`, so encode while it is alive.
                ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: utf8.baseAddress, len: utf8.count))
                defer { ghostty_key_event_set_utf8(keyEvent, GhosttyString()) }
                return ghostty_key_encoder_encode(keyEncoder, keyEvent, &buffer, buffer.count, &written)
            }
            guard result == GHOSTTY_SUCCESS else { return [] }
            return Array(buffer.prefix(written))
        }
    }

    /// Runs `body` with exclusive access to the raw terminal handle.
    func withHandle<R>(_ body: (GhosttyTerminal) -> R) -> R {
        lock.withLock { _ in body(terminal) }
    }
}
