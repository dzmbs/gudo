#if os(macOS)
import AppKit
import TerminalCore

/// AppKit host for a `TerminalSurface`: backs the view with the surface's `CAMetalLayer` and turns
/// input into terminal bytes.
/// - Keys go through `NSTextInputClient` (`interpretKeyEvents`), so IMEs compose with marked text
///   drawn inline at the cursor; plain keys encode with their physical key (kitty protocol safe).
///   Option acts as Meta per side when `optionAsMeta` says so; ⌘ chords stay with the menus.
/// - Mouse: click-drag selects (double/triple click word/line, ⌥ block, ⇧-click extends, edge
///   auto-scroll); with mouse tracking on, events go to the program unless ⇧ is held. ⌘-click
///   opens an OSC 8 link after confirmation; hovering underlines it.
/// - The wheel scrolls scrollback, or becomes wheel reports / alt-screen arrow keys.
/// - Copy (plain text, soft wraps joined) and bracketed paste through the Edit menu.
public final class TerminalView: NSView, @MainActor NSTextInputClient, @MainActor NSMenuItemValidation {
    public let surface: TerminalSurface
    /// Bytes to write to the PTY (encoded keys, mouse and focus reports).
    public var onInput: (([UInt8]) -> Void)?
    /// Called when the view becomes first responder (a click, or a programmatic focus change).
    public var onFocus: (() -> Void)?
    /// Which Option keys act as Meta (Ghostty's `macos-option-as-alt`).
    public var optionAsMeta = OptionAsMeta.none
    /// Opens a ⌘-clicked link; the default asks for confirmation and uses `NSWorkspace`.
    public var onOpenLink: ((URL) -> Void)?

    private var scrollRemainder: CGFloat = 0
    private lazy var selectionGesture = SelectionGesture(terminal: surface.terminal)
    private var mouseReporting = false
    private var autoscrollTimer: Timer?
    private var lastDragPoint = CGPoint.zero
    private var dragRectangle = false
    private let bellLayer = CALayer()

    // NSTextInputClient state.
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    public init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        bellLayer.backgroundColor = NSColor.white.cgColor
        bellLayer.opacity = 0
        surface.layer.addSublayer(bellLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func makeBackingLayer() -> CALayer { surface.layer }
    /// Top-left origin, like the surface's cell geometry.
    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        surface.isFocused = true
        emit(surface.terminal.encodeFocus(true))
        onFocus?()
        return true
    }

    override public func resignFirstResponder() -> Bool {
        surface.isFocused = false
        emit(surface.terminal.encodeFocus(false))
        unmarkText()
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

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func relayout() {
        guard let window else { return }
        bellLayer.frame = CGRect(origin: .zero, size: bounds.size)
        surface.layout(size: bounds.size, scale: window.backingScaleFactor)
    }

    private func emit(_ bytes: [UInt8]) {
        if !bytes.isEmpty { onInput?(bytes) }
    }

    /// Sends a key as if typed here.
    public func send(_ key: KeyEvent) {
        emit(surface.encode(key))
    }

    /// BEL: a short flash (macOS has no haptics for this).
    public func ringBell() {
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.25
        flash.toValue = 0
        flash.duration = 0.3
        bellLayer.add(flash, forKey: "bell")
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    // MARK: Accessibility

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override public func accessibilityLabel() -> String? { "Terminal" }
    /// The visible screen as text (or the IME composition while composing).
    override public func accessibilityValue() -> Any? {
        hasMarkedText() ? "composing \(markedText.string)" : surface.terminal.visibleText()
    }

    // MARK: Mouse

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        let flags = event.modifierFlags
        mouseReporting = surface.reportsMouse(shift: flags.contains(.shift))
        if mouseReporting {
            emit(surface.mouse(.press, button: .left, at: p, mods: KeyModifiers(flags)))
            return
        }
        if flags.contains(.command), let link = surface.link(at: p), let url = URL(string: link.url) {
            return openLink(url)
        }
        if flags.contains(.shift), let selection = surface.terminal.selection,
           let head = surface.terminal.screenPoint(fromViewport: surface.cell(at: p))
        {
            surface.terminal.setSelection(Selection(anchor: selection.anchor, head: head, rectangle: selection.rectangle))
            surface.setNeedsRender()
            return
        }
        surface.terminal.clearSelection()
        let px = surface.pixels(p)
        selectionGesture.press(cell: surface.cell(at: p), x: px.x, y: px.y, time: event.timestamp)
        surface.setNeedsRender()
    }

    override public func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if mouseReporting {
            emit(surface.mouse(.motion, button: .left, at: p, mods: KeyModifiers(event.modifierFlags)))
            return
        }
        lastDragPoint = p
        dragRectangle = event.modifierFlags.contains(.option)
        let px = surface.pixels(p)
        selectionGesture.drag(cell: surface.cell(at: p), x: px.x, y: px.y, rectangle: dragRectangle, geometry: surface.selectionGeometry)
        surface.setNeedsRender()
        updateAutoscroll()
    }

    override public func mouseUp(with event: NSEvent) {
        let p = point(event)
        if mouseReporting {
            emit(surface.mouse(.release, button: .left, at: p, mods: KeyModifiers(event.modifierFlags)))
            mouseReporting = false
            return
        }
        selectionGesture.release(cell: surface.cell(at: p))
        stopAutoscroll()
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard surface.reportsMouse(shift: event.modifierFlags.contains(.shift)) else { return super.rightMouseDown(with: event) }
        emit(surface.mouse(.press, button: .right, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func rightMouseUp(with event: NSEvent) {
        guard surface.reportsMouse(shift: event.modifierFlags.contains(.shift)) else { return super.rightMouseUp(with: event) }
        emit(surface.mouse(.release, button: .right, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func otherMouseDown(with event: NSEvent) {
        guard surface.reportsMouse(shift: false) else { return }
        emit(surface.mouse(.press, button: .middle, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard surface.reportsMouse(shift: false) else { return }
        emit(surface.mouse(.release, button: .middle, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func mouseMoved(with event: NSEvent) {
        let p = point(event)
        if let link = surface.link(at: p) {
            surface.setHoveredLink((link.row, link.columns))
            NSCursor.pointingHand.set()
        } else {
            surface.setHoveredLink(nil)
            NSCursor.iBeam.set()
        }
        if surface.reportsMouse(shift: event.modifierFlags.contains(.shift)) {
            emit(surface.mouse(.motion, button: nil, at: p, mods: KeyModifiers(event.modifierFlags)))
        }
    }

    override public func mouseExited(with event: NSEvent) {
        surface.setHoveredLink(nil)
    }

    private func updateAutoscroll() {
        let direction = lastDragPoint.y < 0 ? -1 : lastDragPoint.y > bounds.height ? 1 : 0
        guard direction != 0 else { return stopAutoscroll() }
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let direction = self.lastDragPoint.y < 0 ? -1 : 1
                self.surface.scroll(rows: direction)
                let edge = CGPoint(x: self.lastDragPoint.x, y: direction < 0 ? 0 : self.bounds.height - 1)
                let px = self.surface.pixels(self.lastDragPoint)
                self.selectionGesture.autoscrollTick(
                    cell: self.surface.cell(at: edge), x: px.x, y: px.y, rectangle: self.dragRectangle,
                    geometry: self.surface.selectionGeometry)
                self.surface.setNeedsRender()
            }
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    private func openLink(_ url: URL) {
        if let onOpenLink { return onOpenLink(url) }
        let alert = NSAlert()
        alert.messageText = "Open Link?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    // MARK: Scrolling

    override public func scrollWheel(with event: NSEvent) {
        guard let cellHeight = surface.cellSize?.height else { return }
        // Trackpads report points (with system momentum); wheels report lines (Ghostty: x3).
        let rows = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY * 3
        scrollRemainder += rows
        let whole = Int(scrollRemainder.rounded(.towardZero))
        scrollRemainder -= CGFloat(whole)
        emit(surface.wheel(rows: -whole, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    // MARK: Copy / paste

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): surface.terminal.selection != nil
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)): true
        default: true
        }
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = surface.terminal.selectionText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(text)
    }

    @objc override public func selectAll(_ sender: Any?) {
        surface.terminal.selectAll()
        surface.setNeedsRender()
    }

    /// Bracketed when enabled; an unbracketed multi-line paste asks first.
    public func pasteText(_ text: String) {
        surface.terminal.clearSelection()
        guard surface.paste(text) == .needsConfirmation else { return }
        let alert = NSAlert()
        alert.messageText = "Paste \(text.split(whereSeparator: \.isNewline).count) Lines?"
        alert.informativeText = "The program did not enable bracketed paste, so each line may run as a command."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { _ = surface.paste(text, allowUnsafe: true) }
    }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        if surface.terminal.selection != nil { surface.terminal.clearSelection() }
        let action: KeyEvent.Action = event.isARepeat ? .repeat : .press
        if !hasMarkedText(), let meta = metaEvent(event, action: action) {
            send(meta)
            return
        }
        // Let the input method see the key: it may compose (marked text), commit text, or do
        // nothing special, in which case the key is encoded from its physical key.
        let wasComposing = hasMarkedText()
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let committed = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        if hasMarkedText() || (wasComposing && committed.isEmpty) { return }
        let plain = Self.printableText(event.characters)
        if committed.isEmpty || (!wasComposing && committed == [plain]) {
            send(keyEvent(event, action: action))
        } else {
            for text in committed { send(.typing(text)) }
        }
    }

    override public func keyUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), !hasMarkedText() else { return }
        send(keyEvent(event, action: .release))
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

    private func keyEvent(_ event: NSEvent, action: KeyEvent.Action) -> KeyEvent {
        let key = PhysicalKey(macKeyCode: event.keyCode) ?? .unidentified
        let mods = KeyModifiers(event.modifierFlags)
        let text = Self.printableText(event.characters)
        // macOS layouts consume shift and (with option-as-alt off, Ghostty's default) option to
        // produce text, so those must not be re-encoded as modifiers.
        let consumed = text.isEmpty ? [] : mods.intersection([.shift, .alt])
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        return KeyEvent(key: key, action: action, mods: mods, consumedMods: consumed, text: text, unshiftedCodepoint: unshifted)
    }

    /// Option held on a side configured as Meta: encode with Alt and the text without Option.
    private func metaEvent(_ event: NSEvent, action: KeyEvent.Action) -> KeyEvent? {
        let raw = event.modifierFlags.rawValue
        // NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK.
        let left = raw & 0x20 != 0, right = raw & 0x40 != 0
        guard event.modifierFlags.contains(.option), optionAsMeta.applies(leftHeld: left, rightHeld: right),
              let key = PhysicalKey(macKeyCode: event.keyCode) else { return nil }
        var withoutOption = event.modifierFlags
        withoutOption.remove(.option)
        let text = Self.printableText(event.characters(byApplyingModifiers: withoutOption.intersection([.shift, .capsLock])))
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        return optionAsMeta.metaEvent(
            key: key, action: action, mods: KeyModifiers(event.modifierFlags), textWithoutOption: text, unshiftedCodepoint: unshifted)
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

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        guard !text.isEmpty else { return }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            // Not from a key press: the character palette, dictation, services.
            _ = surface.paste(text, source: .text, allowUnsafe: true)
        }
    }

    override public func doCommand(by selector: Selector) {
        // Keys like arrows and Return map to commands; the terminal encodes the key itself.
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString(string: text)
        surface.preedit = text.isEmpty ? nil : TerminalSurface.Preedit(text: text)
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        surface.preedit = nil
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The IME candidate window sits under the composition, at the terminal cursor.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let cursor = surface.cursorRect else { return .zero }
        return window.convertToScreen(convert(cursor, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
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
