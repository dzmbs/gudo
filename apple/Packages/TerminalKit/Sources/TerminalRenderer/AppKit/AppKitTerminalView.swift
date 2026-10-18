#if os(macOS)
import AppKit
import TerminalCore

/// Thin AppKit host for a `TerminalSurface`: backs the view with the surface's `CAMetalLayer` and
/// forwards geometry, focus, the display link, scroll-wheel and keyboard input.
///
/// IME (NSTextInputClient/marked text), mouse selection and paste are not implemented yet.
public final class TerminalView: NSView {
    public let surface: TerminalSurface
    /// Bytes to write to the PTY (encoded keys).
    public var onInput: (([UInt8]) -> Void)?
    /// Called when the view becomes first responder (a click, or a programmatic focus change).
    public var onFocus: (() -> Void)?

    private var scrollRemainder: CGFloat = 0

    public init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func makeBackingLayer() -> CALayer { surface.layer }

    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        surface.isFocused = true
        onFocus?()
        return true
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override public func resignFirstResponder() -> Bool {
        surface.isFocused = false
        return true
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            surface.stopDisplayLink()
            return
        }
        relayout()
        surface.startDisplayLink { target, selector in displayLink(target: target, selector: selector) }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        guard let window else { return }
        surface.layout(size: bounds.size, scale: window.backingScaleFactor)
    }

    // MARK: Scrolling

    override public func scrollWheel(with event: NSEvent) {
        guard let grid = surface.grid else { return }
        // Trackpads report points; wheels report lines (Ghostty multiplies those by 3).
        let rows = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * (window?.backingScaleFactor ?? 1) / CGFloat(grid.cellHeight)
            : event.scrollingDeltaY * 3
        scrollRemainder += rows
        let whole = Int(scrollRemainder.rounded(.towardZero))
        scrollRemainder -= CGFloat(whole)
        surface.scroll(rows: -whole)
    }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
        send(event, action: event.isARepeat ? .repeat : .press)
    }

    override public func keyUp(with event: NSEvent) {
        send(event, action: .release)
    }

    /// Control combos (e.g. ctrl+tab) can arrive here before `keyDown`; route them to the terminal
    /// and leave command shortcuts to the menu.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    private func send(_ event: NSEvent, action: KeyEvent.Action) {
        guard let key = PhysicalKey(macKeyCode: event.keyCode),
              !event.modifierFlags.contains(.command)
        else { return }
        let mods = KeyModifiers(event.modifierFlags)
        let text = Self.printableText(event.characters)
        // macOS layouts consume shift and (with option-as-alt off, Ghostty's default) option to
        // produce text, so those must not be re-encoded as modifiers.
        let consumed = text.isEmpty ? [] : mods.intersection([.shift, .alt])
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        let bytes = surface.encode(KeyEvent(
            key: key, action: action, mods: mods, consumedMods: consumed, text: text, unshiftedCodepoint: unshifted))
        if !bytes.isEmpty { onInput?(bytes) }
    }

    /// The event's text, or "" for C0 controls and AppKit's function-key private-use characters,
    /// which libghostty-vt derives from the physical key instead.
    private static func printableText(_ characters: String?) -> String {
        guard let characters, !characters.isEmpty else { return "" }
        let isControl = characters.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }
        return isControl ? "" : characters
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.alt) }
        if flags.contains(.command) { insert(.super) }
        if flags.contains(.capsLock) { insert(.capsLock) }
    }
}
#endif
