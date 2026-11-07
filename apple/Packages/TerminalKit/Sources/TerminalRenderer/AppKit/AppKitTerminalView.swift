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
public final class TerminalView: NSView, @MainActor NSTextInputClient, @MainActor NSMenuItemValidation, @MainActor NSDraggingSource {
    public let surface: TerminalSurface
    /// Bytes to write to the PTY (encoded keys, mouse and focus reports).
    public var onInput: (([UInt8]) -> Void)?
    public var onGeneratedInput: (([UInt8]) -> Void)?
    /// Sees each key event before it is encoded; returning true consumes it (the app's
    /// hold-to-talk chord).
    public var keyInterceptor: ((KeyEvent) -> Bool)?
    /// Called when the view becomes first responder (a click, or a programmatic focus change).
    public var onFocus: (() -> Void)?
    /// Which Option keys act as Meta (Ghostty's `macos-option-as-alt`).
    public var optionAsMeta = OptionAsMeta.none
    /// Opens a ⌘-clicked link (an OSC 8 hyperlink, or a URL or path printed as text); the
    /// default asks for confirmation and uses `NSWorkspace`.
    public var onOpenLink: ((TerminalLink) -> Void)?
    /// The link under the pointer changed (nil: none), for a status line showing its target.
    public var onHoverLink: ((TerminalLink?) -> Void)?
    /// The pointer over the terminal (view points), nil when it leaves: hover affordances
    /// drawn by the host (a command's ✓/✗ and run time).
    public var onPointerMoved: ((CGPoint?) -> Void)?
    private var hoveredLinkTarget: TerminalLink?
    private var lastMousePoint: CGPoint?

    private var scrollRemainder: CGFloat = 0
    private lazy var selectionGesture = SelectionGesture(terminal: surface.terminal)
    private var mouseReporting = false
    private var autoscrollTimer: Timer?
    private var lastDragPoint = CGPoint.zero
    private var dragRectangle = false
    /// A press on the selection: dragging it carries the text out.
    private var dragOutStart: NSEvent?
    /// The kitty image a press started on: dragging lifts it out as a PNG.
    private var dragOutImage: (placement: ImagePlacement, rect: CGRect)?

    // NSTextInputClient state.
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    /// First responder of its window (AppKit sets `firstResponder` only after
    /// `becomeFirstResponder` returns, so the view tracks it itself).
    private var hasKeyboard = false
    private var keyObservers: [NSObjectProtocol] = []

    public init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // A frame held through a layout motion stays at the top left as the view resizes.
        layerContentsPlacement = .topLeft
        // Off screen the surface swaps in a fresh layer to give back its drawables; set after
        // `wantsLayer`, it stays this view's backing layer.
        surface.onLayerReplaced = { [weak self] _, new in
            self?.layer = new
            self?.layerContentsPlacement = .topLeft
        }
        // Off screen until it is first responder of a key window: a hollow, steady cursor.
        surface.isFocused = false
        registerForDraggedTypes([.string, .fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func makeBackingLayer() -> CALayer { surface.layer }
    /// Top-left origin, like the surface's cell geometry.
    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        hasKeyboard = true
        updateFocus()
        emitGenerated(surface.terminal.encodeFocus(true))
        onFocus?()
        return true
    }

    override public func resignFirstResponder() -> Bool {
        hasKeyboard = false
        updateFocus()
        emitGenerated(surface.terminal.encodeFocus(false))
        unmarkText()
        return true
    }

    /// Ghostty's focus: a solid, blinking cursor only as first responder of the key window;
    /// otherwise (another split, another window or app in front) a hollow, steady one.
    private func updateFocus() {
        surface.isFocused = hasKeyboard && window?.isKeyWindow == true
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFocus() }
            })
        }
        // A window nobody can see (covered, minimized, another Space) draws nothing: give back
        // the GPU memory until it shows again.
        keyObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: .main
        ) { [weak self, weak newWindow] _ in
            MainActor.assumeIsolated {
                guard let self, let newWindow else { return }
                guard self.window === newWindow else { return }
                if newWindow.occlusionState.contains(.visible) {
                    self.surface.startDisplayLink { target, selector in self.displayLink(target: target, selector: selector) }
                } else {
                    self.surface.stopDisplayLink()
                    self.surface.releaseGPUResources()
                }
            }
        })
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasKeyboard = window?.firstResponder === self
        updateFocus()
        guard window != nil else {
            surface.stopDisplayLink()
            surface.releaseGPUResources()
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
        surface.layout(size: bounds.size, scale: window.backingScaleFactor)
    }

    private func emit(_ bytes: [UInt8]) {
        if !bytes.isEmpty { onInput?(bytes) }
    }

    private func emitGenerated(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        (onGeneratedInput ?? onInput)?(bytes)
    }

    /// Sends a key as if typed here.
    public func send(_ key: KeyEvent) {
        let bytes = surface.encode(key)
        if case .release = key.action { emitGenerated(bytes) }
        else { emit(bytes) }
    }

    /// BEL: the system alert sound, Ghostty's macOS default (`bell-features = system`). Never a
    /// flash over the output: the visual bell is the opt-in border the app draws.
    public func ringBell() {
        NSSound.beep()
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
        let location = point(event)
        let flags = event.modifierFlags
        mouseReporting = surface.reportsMouse(shift: flags.contains(.shift))
        if mouseReporting {
            emitGenerated(surface.mouse(.press, button: .left, at: location, mods: KeyModifiers(flags)))
            return
        }
        if flags.contains(.command), let link = surface.link(at: location) {
            return openLink(link)
        }
        if flags.contains(.shift), let selection = surface.terminal.selection,
           let head = surface.terminal.screenPoint(fromViewport: surface.cell(at: location))
        {
            surface.terminal.setSelection(Selection(anchor: selection.anchor, head: head, rectangle: selection.rectangle))
            surface.setNeedsRender()
            return
        }
        if event.clickCount == 1, surface.terminal.selection == nil, let image = surface.kittyImage(at: location) {
            dragOutStart = event
            dragOutImage = image
            return
        }
        if event.clickCount == 1, let selection = surface.terminal.selection,
           let cell = surface.terminal.screenPoint(fromViewport: surface.cell(at: location)), selection.contains(cell)
        {
            dragOutStart = event
            return
        }
        surface.terminal.clearSelection()
        let px = surface.pixels(location)
        let cell = surface.cell(at: location)
        if selectionGesture.press(cell: cell, x: px.x, y: px.y, time: event.timestamp) != nil, selectionGesture.clickCount == 2 {
            surface.terminal.selectLinkOrWord(atViewport: cell)
        }
        surface.setNeedsRender()
    }

    override public func mouseDragged(with event: NSEvent) {
        let location = point(event)
        if mouseReporting {
            emitGenerated(surface.mouse(.motion, button: .left, at: location, mods: KeyModifiers(event.modifierFlags)))
            return
        }
        if let start = dragOutStart, let image = dragOutImage {
            let origin = point(start)
            guard hypot(location.x - origin.x, location.y - origin.y) > 4 else { return }
            dragOutStart = nil
            dragOutImage = nil
            guard let png = surface.terminal.kittyPNG(image.placement) else { return }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(png, forType: .png)
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
            item.setDraggingFrame(image.rect, contents: NSImage(data: png))
            beginDraggingSession(with: [item], event: start, source: self)
            return
        }
        if let start = dragOutStart {
            let origin = point(start)
            guard hypot(location.x - origin.x, location.y - origin.y) > 4, let text = surface.terminal.selectionText() else { return }
            dragOutStart = nil
            let item = NSDraggingItem(pasteboardWriter: text as NSString)
            item.setDraggingFrame(CGRect(origin: origin, size: CGSize(width: 1, height: 1)), contents: nil)
            beginDraggingSession(with: [item], event: start, source: self)
            return
        }
        lastDragPoint = location
        dragRectangle = event.modifierFlags.contains(.option)
        let px = surface.pixels(location)
        selectionGesture.drag(cell: surface.cell(at: location), x: px.x, y: px.y, rectangle: dragRectangle, geometry: surface.selectionGeometry)
        surface.setNeedsRender()
        updateAutoscroll()
    }

    override public func mouseUp(with event: NSEvent) {
        let location = point(event)
        if mouseReporting {
            emitGenerated(surface.mouse(.release, button: .left, at: location, mods: KeyModifiers(event.modifierFlags)))
            mouseReporting = false
            return
        }
        if dragOutStart != nil, dragOutImage != nil {
            // A click on an image without a drag: nothing to select.
            dragOutStart = nil
            dragOutImage = nil
            return
        }
        if dragOutStart != nil {
            // A click on the selection without a drag: a plain click, which clears it.
            dragOutStart = nil
            surface.terminal.clearSelection()
            selectionGesture.reset()
            surface.setNeedsRender()
            return
        }
        selectionGesture.release(cell: surface.cell(at: location))
        stopAutoscroll()
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard surface.reportsMouse(shift: event.modifierFlags.contains(.shift)) else { return super.rightMouseDown(with: event) }
        emitGenerated(surface.mouse(.press, button: .right, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func rightMouseUp(with event: NSEvent) {
        guard surface.reportsMouse(shift: event.modifierFlags.contains(.shift)) else { return super.rightMouseUp(with: event) }
        emitGenerated(surface.mouse(.release, button: .right, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    /// Menu items about the rows under a point (view coordinates), for the right-click menu: a
    /// shell command's Copy Output, Re-run… Empty for nothing.
    public var contextActions: ((CGPoint) -> [NSMenuItem])?

    /// The right-click menu (when the program does not take the right button): Copy, what the
    /// rows under the pointer offer, Paste.
    override public func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if surface.terminal.selection != nil {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        let extra = contextActions?(point(event)) ?? []
        if !extra.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            extra.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        for item in menu.items where item.action == #selector(copy(_:)) || item.action == #selector(paste(_:)) || item.action == #selector(selectAll(_:)) {
            item.target = self
        }
        return menu
    }

    override public func otherMouseDown(with event: NSEvent) {
        guard surface.reportsMouse(shift: false) else { return }
        emitGenerated(surface.mouse(.press, button: .middle, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard surface.reportsMouse(shift: false) else { return }
        emitGenerated(surface.mouse(.release, button: .middle, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    override public func mouseMoved(with event: NSEvent) {
        // The tracking area reports moves under views drawn over this one too (a divider's
        // resize zone): those keep their own pointer.
        guard isUnderPointer(event) else {
            if lastMousePoint != nil { mouseExited(with: event) }
            return
        }
        let location = point(event)
        lastMousePoint = location
        onPointerMoved?(location)
        updateHoverLink(at: location, flags: event.modifierFlags)
        if surface.reportsMouse(shift: event.modifierFlags.contains(.shift)) {
            emitGenerated(surface.mouse(.motion, button: nil, at: location, mods: KeyModifiers(event.modifierFlags)))
        }
    }

    /// Whether a click at the event's location would land on this view.
    private func isUnderPointer(_ event: NSEvent) -> Bool {
        guard let frameView = window?.contentView?.superview, let hit = frameView.hitTest(event.locationInWindow) else { return true }
        return hit === self || hit.isDescendant(of: self)
    }

    override public func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        onPointerMoved?(nil)
        setHoverLink(nil)
    }

    override public func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Pressing ⌘ over a printed URL underlines it.
        if let location = lastMousePoint { updateHoverLink(at: location, flags: event.modifierFlags) }
    }

    /// Ghostty: an OSC 8 hyperlink underlines on hover; a URL or path printed as text only
    /// while ⌘ is held, since only a ⌘-click opens it.
    private func updateHoverLink(at location: CGPoint, flags: NSEvent.ModifierFlags) {
        var link = surface.reportsMouse(shift: flags.contains(.shift)) && !flags.contains(.command) ? nil : surface.link(at: location)
        if link?.isHyperlink == false, !flags.contains(.command) { link = nil }
        setHoverLink(link)
        if link != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    private func setHoverLink(_ link: TerminalLink?) {
        surface.setHoveredLink(link.map { ($0.row, $0.columns) })
        guard link?.target != hoveredLinkTarget?.target else { return }
        hoveredLinkTarget = link
        onHoverLink?(link)
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

    private func openLink(_ link: TerminalLink) {
        if let onOpenLink { return onOpenLink(link) }
        guard let url = link.url() else { return }
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
        emitGenerated(surface.wheel(rows: -whole, at: point(event), mods: KeyModifiers(event.modifierFlags)))
    }

    // MARK: Copy / paste

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): surface.terminal.selection != nil
        case #selector(paste(_:)):
            Self.hasDroppableText(NSPasteboard.general)
        case #selector(selectAll(_:)): true
        default: true
        }
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = surface.terminal.selectionText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) { paste(from: .general) }

    func paste(from board: NSPasteboard) {
        guard let text = Self.droppedText(board) else { return }
        pasteText(text)
    }

    // MARK: Attachments (images, .excalidraw files)

    /// Explicit clipboard attachment placement; ordinary terminal paste never invokes it.
    public var onPasteAttachment: ((NSPasteboard) -> Bool)?

    /// Handles images and files dropped on the view at a point; returns whether it took them.
    /// What it leaves pastes: text as is, files as their shell-quoted paths.
    public var onDropAttachment: ((NSPasteboard, CGPoint) -> Bool)?

    static func hasAttachment(_ pasteboard: NSPasteboard) -> Bool {
        // Files (the host decides which it takes), or an image with no text alongside.
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.string(forType: .string) == nil && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Type identifiers of the app's own drags that carry text without being text to paste (a
    /// tab dragged onto a pane's edge): over the view, they go to the nearest view around it
    /// that takes drops.
    public var unpastedDragTypes: [String] = []

    private func isUnpasted(_ sender: any NSDraggingInfo) -> Bool {
        let types = unpastedDragTypes.map { NSPasteboard.PasteboardType($0) }
        return !types.isEmpty && sender.draggingPasteboard.availableType(from: types) != nil
    }

    /// The nearest view around this one that takes drops: where unpasted drags go.
    private var dropTargetAround: NSView? {
        superview.flatMap { sequence(first: $0) { $0.superview }.first { !$0.registeredDraggedTypes.isEmpty } }
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isUnpasted(sender) { return dropTargetAround?.draggingEntered(sender) ?? [] }
        // Its own selection dropped back on it is a slip, not a paste.
        if sender.draggingSource as? TerminalView === self { return [] }
        let board = sender.draggingPasteboard
        if onDropAttachment != nil, Self.hasAttachment(board) { return .copy }
        // Asked on every move of the drag: look at the types, never read the text itself.
        return Self.hasDroppableText(board) ? .copy : []
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isUnpasted(sender) { return dropTargetAround?.draggingUpdated(sender) ?? [] }
        return draggingEntered(sender)
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender, isUnpasted(sender) { dropTargetAround?.draggingExited(sender) }
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isUnpasted(sender) { return dropTargetAround?.performDragOperation(sender) ?? false }
        let board = sender.draggingPasteboard
        if let onDropAttachment, Self.hasAttachment(board), onDropAttachment(board, convert(sender.draggingLocation, from: nil)) {
            return true
        }
        guard let text = Self.droppedText(board) else { return false }
        window?.makeFirstResponder(self)
        pasteText(text)
        return true
    }

    static func hasDroppableText(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.string]) != nil
    }

    /// Files as shell-quoted paths separated by spaces (as Terminal and Ghostty do), else text.
    static func droppedText(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { shellQuoted($0.path) }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    @objc override public func selectAll(_ sender: Any?) {
        surface.terminal.selectAll()
        surface.setNeedsRender()
    }

    /// Bracketed when enabled; an unbracketed multi-line paste asks first.
    public func pasteText(_ text: String) {
        surface.terminal.clearSelection()
        switch surface.paste(text) {
        case .needsConfirmation:
            let alert = NSAlert()
            alert.messageText = "Paste \(Terminal.pasteLineCount(text)) Lines?"
            alert.informativeText = "The program did not enable bracketed paste, so each line may run as a command."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { _ = surface.paste(text, allowUnsafe: true) }
        case .tooLarge:
            let alert = NSAlert()
            alert.messageText = PasteLimit.title
            alert.informativeText = PasteLimit.message(bytes: text.utf8.count)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        default:
            break
        }
    }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        let action: KeyEvent.Action = event.isARepeat ? .repeat : .press
        if !hasMarkedText(), keyInterceptor?(keyEvent(event, action: action)) == true { return }
        if surface.terminal.selection != nil { surface.terminal.clearSelection() }
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
        if keyInterceptor?(keyEvent(event, action: .release)) == true { return }
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
