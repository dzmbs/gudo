#if os(iOS)
import TerminalCore
import UIKit

/// UIKit host for a `TerminalSurface`. It carries the surface's `CAMetalLayer`, paces it with a
/// `CADisplayLink`, and turns input into terminal bytes:
/// - hardware keys (`UIPress`, HID usages through the shared `PhysicalKey` table) with our own
///   hold-to-repeat, Option-as-Meta per side, and ⌘ chords left to the app's key commands;
/// - the software keyboard and IMEs through `UITextInput`. Marked text is drawn inline at the
///   cursor by the renderer and never sent; committed text goes to the PTY at once;
/// - touch: tap focuses (or clicks, or opens a link after confirmation), double/triple tap and
///   long-press select a word/line with drag handles and the edit menu, one or two fingers
///   scroll with momentum (mouse mode: wheel events; alt screen: arrow keys), pinch sets the
///   font size;
/// - pointer (iPad trackpad/mouse): click-drag selects (⌥ for a block, ⇧-click extends, edge
///   auto-scroll), hover underlines links and reports motion in any-event mode, the wheel follows
///   the same mouse-mode routing. Shift always selects instead of reporting.
public final class TerminalView: UIView {
    public let surface: TerminalSurface
    /// Bytes to write to the PTY (encoded keys, mouse reports, focus reports).
    public var onInput: (([UInt8]) -> Void)?
    public var onGeneratedInput: (([UInt8]) -> Void)?
    /// Called when the view becomes first responder (a tap, or a programmatic focus change).
    public var onFocus: (() -> Void)?
    /// Modifiers latched on an on-screen key bar (sticky Ctrl), applied to the next key from the
    /// software keyboard. The provider clears a one-shot latch when it is read.
    public var takeLatchedModifiers: (() -> KeyModifiers)?
    /// Shown above the software keyboard while this view is first responder.
    public var keyBar: UIView?
    /// Shown in place of the software keyboard while set (a keys panel); call
    /// `reloadInputViews()` after changing it.
    public var keyPanel: UIView?
    /// Which Option keys act as Meta (Ghostty's `macos-option-as-alt`).
    public var optionAsMeta = OptionAsMeta.none
    /// Visual flash plus a haptic on BEL.
    public var bellHaptics = true
    /// Opens a link the user tapped (an OSC 8 hyperlink, or a URL or path printed as text); the
    /// default asks for confirmation and opens URLs with `UIApplication.open`.
    public var onOpenLink: ((TerminalLink) -> Void)?
    /// The link under the pointer changed (nil: none), for a status line showing its target.
    public var onHoverLink: ((TerminalLink?) -> Void)?
    /// The pointer over the terminal (view points), nil when it leaves: hover affordances
    /// drawn by the host (a command's ✓/✗ and run time).
    public var onPointerMoved: ((CGPoint?) -> Void)?
    /// The host's focused pane: it draws the focused cursor while its window is key, even with
    /// the software keyboard down (no first responder), since typing goes there next.
    public var isSelected = false {
        didSet { if isSelected != oldValue { updateFocus() } }
    }
    private var focusObservers: [NSObjectProtocol] = []
    private var kittyElements: [UInt32: UIAccessibilityElement] = [:]
    private var hoveredLinkTarget: TerminalLink?
    /// Where the last tap landed (view points), to anchor what it opens (a link's popover).
    public private(set) var lastTapLocation: CGPoint?
    /// Whether Apple Pencil handwriting (Scribble) may type into the terminal. Off: Pencil
    /// strokes over a terminal are drawing or nothing, never text sent to the shell unseen.
    public var allowsHandwriting = false
    /// Extra actions for the edit menu about the rows under a point (view coordinates): a
    /// shell command's Copy Output, Re-run… The menu shows after a long-press, a selection, or
    /// a secondary click; return nil for nothing.
    public var contextActions: ((CGPoint) -> UIMenu?)?

    private let repeater = KeyRepeater()
    private var repeatingKey: UIKeyboardHIDUsage?
    private var heldOptionKeys: Set<UIKeyboardHIDUsage> = []

    // Scrolling
    private var scrollRemainder: CGFloat = 0
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var momentumPoint = CGPoint.zero
    private var lastMomentumTime: CFTimeInterval = 0
    /// The touch that just began stopped a fling: its tap only stops it, like `UIScrollView`.
    private var touchStoppedMomentum = false

    // Pinch
    /// The font sizes pinching may reach, the Settings stepper's range.
    public static let fontSizeRange: ClosedRange<CGFloat> = 8...32
    /// A pinch chose a new font size. The view already draws at it; the host keeps it.
    public var onFontSizeChange: ((CGFloat) -> Void)?
    private var pinchStartSize: CGFloat = 0
    /// The fingers scrolling now zoomed on the way: they lift without a fling.
    private var scrollJoinedPinch = false
    private lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    // Selection
    private lazy var selectionGesture = SelectionGesture(terminal: surface.terminal)
    private let startHandle = SelectionHandle(isStart: true)
    private let endHandle = SelectionHandle(isStart: false)
    private var editMenu: UIEditMenuInteraction?
    /// Where the menu was asked for (long-press, secondary click); nil: at the selection.
    private var menuPoint: CGPoint?
    private var autoscrollTask: Task<Void, Never>?
    private var lastPointerLocation = CGPoint.zero
    private var pointerDragRectangle = false
    /// A long-press began inside the selection: it stays as it is, for a drag out.
    private var pressKeepsSelection = false
    /// The edit menu is up only to offer Paste (the key bar's paste key).
    private var menuOffersPaste = false
    private let toast = CapsuleToast()


    /// IME composition in progress (marked text) and the selection inside it, in UTF-16 units.
    private var markedText: String?
    private var markedSelection = NSRange(location: 0, length: 0)

    public weak var inputDelegate: UITextInputDelegate?
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    public var markedTextStyle: [NSAttributedString.Key: Any]?

    // A terminal wants every keystroke verbatim.
    public var autocapitalizationType = UITextAutocapitalizationType.none
    public var autocorrectionType = UITextAutocorrectionType.no
    public var spellCheckingType = UITextSpellCheckingType.no
    public var smartQuotesType = UITextSmartQuotesType.no
    public var smartDashesType = UITextSmartDashesType.no
    public var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    public var inlinePredictionType = UITextInlinePredictionType.no
    public var keyboardAppearance = UIKeyboardAppearance.dark
    /// `.asciiCapable` keeps the software keyboard on a Latin layout (a user setting).
    public var keyboardType = UIKeyboardType.default

    public init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        layer.addSublayer(surface.layer)
        surface.onLayerReplaced = { [weak self] old, new in
            old.removeFromSuperlayer()
            self?.layer.insertSublayer(new, at: 0)
        }
        backgroundColor = surface.backgroundColor.map(UIColor.init(cgColor:)) ?? .black
        isMultipleTouchEnabled = true
        // Off screen until it is the key window's focused terminal: a hollow, steady cursor.
        surface.isFocused = false


        installGestures()
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            addSubview(handle)
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:))))
        }
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
        // A text input gets Scribble by default, which turned Pencil strokes into shell input.
        addInteraction(UIScribbleInteraction(delegate: self))
        // Selected text drags out to other apps; text and links dropped here paste.
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        addInteraction(drag)
        addInteraction(UIDropInteraction(delegate: self))
        addSubview(toast)
        PasteboardOrigin.observe()
        MemoryPressure.observe()

        surface.onFrameRendered = { [weak self] in self?.layoutSelectionHandles() }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalView, _) in view.setNeedsLayout() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer.frame = bounds
        CATransaction.commit()
        surface.layout(size: bounds.size, scale: traitCollection.displayScale)
        layoutSelectionHandles()
        toast.center = CGPoint(x: bounds.midX, y: bounds.minY + 28)
    }

    /// Ghostty's focus: a solid, blinking cursor only in the focused terminal of the key window
    /// of an active scene; otherwise (another split, another window, the app in the background)
    /// a hollow, steady one.
    private func updateFocus() {
        guard let window else {
            surface.isFocused = false
            return
        }
        let sceneActive = window.windowScene.map { $0.activationState == .foregroundActive } ?? true
        surface.isFocused = (isFirstResponder || isSelected) && window.isKeyWindow && sceneActive
    }

    override public func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        guard let newWindow else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFocus() }
        }
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
            focusObservers.append(center.addObserver(forName: name, object: newWindow, queue: .main, using: update))
        }
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            focusObservers.append(center.addObserver(forName: name, object: newWindow.windowScene, queue: .main, using: update))
        }
        // A backgrounded scene draws nothing: give back the GPU memory until it returns.
        focusObservers.append(center.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: newWindow.windowScene, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.surface.releaseGPUResources() }
        })
        focusObservers.append(center.addObserver(
            forName: UIScene.willEnterForegroundNotification, object: newWindow.windowScene, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.surface.setNeedsRender() }
        })
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        updateFocus()
        guard window != nil else {
            surface.stopDisplayLink()
            surface.releaseGPUResources()
            stopMomentum()
            return
        }
        // The display link of the screen the window is on (an external display has its own
        // refresh rate); the scale follows `traitCollection.displayScale` in `layoutSubviews`.
        let screen = window?.windowScene?.screen
        surface.startDisplayLink { target, selector in
            screen?.displayLink(withTarget: target, selector: selector) ?? CADisplayLink(target: target, selector: selector)
        }
    }

    /// Sends a key as if typed here (key bar, menu actions).
    public func send(_ key: KeyEvent) {
        let bytes = surface.encode(key)
        if case .release = key.action { emitGenerated(bytes) }
        else { emit(bytes) }
    }

    /// Sends text written in a composer: as a paste (bracketed when the program
    /// asked for it, so a multi-line prompt arrives as one), then Return when `submit`.
    public func sendComposedText(_ text: String, submit: Bool = true) {
        _ = surface.paste(text, source: .text, allowUnsafe: true)
        if submit { send(.press(.enter)) }
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onInput?(bytes)
    }

    private func emitGenerated(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        (onGeneratedInput ?? onInput)?(bytes)
    }

    // MARK: Accessibility

    /// The terminal screen as one element (identifier `<view id>-screen`; its value reports IME
    /// composition), next to the selection handles while they show.
    private lazy var screenElement: ScreenElement = {
        let element = ScreenElement(accessibilityContainer: self)
        element.text = { [weak self] in
            guard let self else { return nil }
            return self.markedText.map { "composing \($0)" } ?? self.surface.terminal.visibleText()
        }
        element.accessibilityLabel = "Terminal"
        element.accessibilityTraits = .allowsDirectInteraction
        return element
    }()

    #if DEBUG
    /// Echo prediction as UI tests read it (`<view id>-prediction`): the predictor's counts and
    /// the text drawn ahead of the echo.
    private lazy var predictionElement: ScreenElement = {
        let element = ScreenElement(accessibilityContainer: self)
        element.text = { [weak self] in
            guard let predictor = self?.surface.predictor else { return "off" }
            let stats = predictor.stats
            let ahead = predictor.overlay.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text).joined()
            return "predicted=\(stats.predicted) confirmed=\(stats.confirmed) mispredicted=\(stats.mispredicted) ahead=\(ahead)"
        }
        return element
    }()
    #endif

    override public var accessibilityIdentifier: String? {
        didSet {
            screenElement.accessibilityIdentifier = accessibilityIdentifier.map { "\($0)-screen" }
            #if DEBUG
            predictionElement.accessibilityIdentifier = accessibilityIdentifier.map { "\($0)-prediction" }
            #endif
        }
    }

    override public var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override public var accessibilityElements: [Any]? {
        get {
            screenElement.accessibilityFrameInContainerSpace = bounds
            // Views hosts add over the grid (the draw overlay, placement markers) come first.
            let hosted = subviews.filter { $0 !== startHandle && $0 !== endHandle && !$0.isHidden }.reversed()
            var elements = Array(hosted) + kittyImageElements() + [screenElement] + [startHandle, endHandle].filter { !$0.isHidden }
            #if DEBUG
            predictionElement.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: 1, height: 1)
            elements.append(predictionElement)
            #endif
            return elements
        }
        set {}
    }

    /// One element per kitty image on screen, topmost first, kept per image id so VoiceOver's
    /// focus survives redraws.
    private func kittyImageElements() -> [UIAccessibilityElement] {
        var kept: [UInt32: UIAccessibilityElement] = [:]
        let elements = surface.kittyImageFrames.reversed().map { frame in
            let id = frame.placement.imageID
            let element = kept[id] ?? kittyElements[id] ?? UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = "kitty-image-\(id)"
            element.accessibilityLabel = "Image"
            element.accessibilityHint = "Touch and hold to drag it out"
            element.accessibilityTraits = .image
            element.accessibilityFrameInContainerSpace = frame.rect
            kept[id] = element
            return element
        }
        kittyElements = kept
        return elements
    }

    // MARK: Bell

    /// BEL: a warning haptic (the touch devices' system bell). Never a flash over the output:
    /// Ghostty's visual bell is the opt-in border the app draws (`bell-features = border`).
    public func ringBell() {
        if bellHaptics { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    // MARK: Focus

    override public var canBecomeFirstResponder: Bool { true }

    /// Long enough to reach the keyboard's will-change (seen up to 0.4 s later), which holds
    /// through its slide.
    private static func holdForKeyboard() {
        TerminalSurface.holdGrids(for: .milliseconds(700))
    }
    override public var inputAccessoryView: UIView? { keyBar }
    override public var inputView: UIView? { keyPanel }

    @discardableResult
    override public func becomeFirstResponder() -> Bool {
        // The keyboard and key bar may come with it, and the layout starts making room before
        // UIKit says how much: grids hold from here, so they change once, when it is made.
        Self.holdForKeyboard()
        guard super.becomeFirstResponder() else { return false }
        updateFocus()
        emitGenerated(surface.terminal.encodeFocus(true))
        onFocus?()
        return true
    }

    @discardableResult
    override public func resignFirstResponder() -> Bool {
        Self.holdForKeyboard()
        guard super.resignFirstResponder() else { return false }
        updateFocus()
        emitGenerated(surface.terminal.encodeFocus(false))
        repeater.stop()
        repeatingKey = nil
        heldOptionKeys.removeAll()
        setMarkedText(nil, selectedRange: NSRange())
        return true
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(longPress)

        // Pointer secondary click: the program's right button when it tracks the mouse, else
        // the edit menu at the pointer.
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(secondary)

        // Touch drags and the scroll wheel / two-finger trackpad scroll (no touches).
        scrollGesture.allowedScrollTypesMask = .all
        scrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollGesture.maximumNumberOfTouches = 2
        scrollGesture.delegate = self
        addGestureRecognizer(scrollGesture)

        // With the two-finger scroll: fingers that spread zoom even after they began to scroll.
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        // Pointer click-drag: selection, or mouse drags for the program.
        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointerDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerDrag.allowedScrollTypesMask = []
        addGestureRecognizer(pointerDrag)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStoppedMomentum = momentumLink != nil
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        lastTapLocation = point
        if touchStoppedMomentum {
            touchStoppedMomentum = false
            return
        }
        let shift = tap.modifierFlags.contains(.shift)
        menuPoint = nil
        if !isFirstResponder { becomeFirstResponder() }

        if surface.reportsMouse(shift: shift) {
            let mods = KeyModifiers(tap.modifierFlags)
            emitGenerated(surface.mouse(.press, button: .left, at: point, mods: mods))
            emitGenerated(surface.mouse(.release, button: .left, at: point, mods: mods))
            return
        }
        if shift, let selection = surface.terminal.selection, let head = surface.terminal.screenPoint(fromViewport: surface.cell(at: point)) {
            // ⇧-click extends the selection to the clicked cell.
            surface.terminal.setSelection(Selection(anchor: selection.anchor, head: head, rectangle: selection.rectangle))
            selectionChanged(showMenu: false)
            return
        }
        // Repeated taps select a word (2) or line (3) through Ghostty's click counter.
        let px = surface.pixels(point)
        let cell = surface.cell(at: point)
        let selected = selectionGesture.press(cell: cell, x: px.x, y: px.y, time: CACurrentMediaTime())
        selectionGesture.release(cell: cell)
        if selected != nil {
            if selectionGesture.clickCount == 2 { surface.terminal.selectLinkOrWord(atViewport: cell) }
            selectionChanged(showMenu: true)
            return
        }
        if surface.terminal.selection != nil {
            clearSelection()
            return
        }
        if let link = surface.link(at: point) {
            openLink(link)
        }
    }

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: self)
        switch press.state {
        case .began:
            menuPoint = point
            // Inside the selection or on an image: keep it (a drag carries it out).
            pressKeepsSelection = isSelected(point) || surface.kittyImage(at: point) != nil
            if pressKeepsSelection { return }
            // Long-press selects even when the program tracks the mouse.
            if surface.terminal.selectLinkOrWord(atViewport: surface.cell(at: point)) != nil {
                UISelectionFeedbackGenerator().selectionChanged()
                selectionChanged(showMenu: false)
            }
        case .changed:
            guard !pressKeepsSelection, let selection = surface.terminal.selection,
                  let head = surface.terminal.screenPoint(fromViewport: surface.cell(at: point)) else { return }
            surface.terminal.setSelection(Selection(anchor: selection.start, head: head))
            selectionChanged(showMenu: false)
            updateAutoscroll(at: point, extend: true)
        case .ended:
            stopAutoscroll()
            showEditMenu()
        default:
            stopAutoscroll()
        }
    }

    @objc private func secondaryClicked(_ click: UITapGestureRecognizer) {
        let point = click.location(in: self)
        if surface.reportsMouse(shift: click.modifierFlags.contains(.shift)) {
            let mods = KeyModifiers(click.modifierFlags)
            emitGenerated(surface.mouse(.press, button: .right, at: point, mods: mods))
            emitGenerated(surface.mouse(.release, button: .right, at: point, mods: mods))
            return
        }
        if !isFirstResponder { becomeFirstResponder() }
        menuPoint = point
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    /// A touch drag (one or two fingers) and the trackpad or wheel scroll, never a mouse drag:
    /// a program tracking the mouse gets wheel events, the alt screen arrow keys, the shell's
    /// screen its scrollback (`TerminalSurface.wheel`). Selecting is a long-press, and the
    /// pointer's click-drag. Ends with momentum, like `UIScrollView`.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        let mods = KeyModifiers(pan.modifierFlags)
        if pinchGesture.state == .began || pinchGesture.state == .changed {
            scrollJoinedPinch = true
            pan.setTranslation(.zero, in: self)
            return
        }
        switch pan.state {
        case .began:
            stopMomentum()
            scrollJoinedPinch = false
            fallthrough
        case .changed:
            scroll(points: pan.translation(in: self).y, at: point, mods: mods)
            pan.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            scroll(points: pan.translation(in: self).y, at: point, mods: mods)
            let velocity = pan.velocity(in: self).y
            if pan.state == .ended, !scrollJoinedPinch, abs(velocity) > 80 { startMomentum(velocity: velocity, at: point) }
            else { scrollRemainder = 0 }
        default:
            break
        }
    }

    /// Dragging content down reveals history, which is a negative (upward) viewport scroll.
    private func scroll(points dy: CGFloat, at point: CGPoint, mods: KeyModifiers) {
        guard let cellHeight = surface.cellSize?.height, dy != 0 else { return }
        scrollRemainder += dy / cellHeight
        let whole = Int(scrollRemainder.rounded(.towardZero))
        guard whole != 0 else { return }
        scrollRemainder -= CGFloat(whole)
        emitGenerated(surface.wheel(rows: -whole, at: point, mods: mods))
    }

    /// Zooms the drawn grid with the fingers and settles on a whole point size when they lift,
    /// so the program sees one resize, not one per step.
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            stopMomentum()
            scrollJoinedPinch = true
            pinchStartSize = surface.fontSize
            clipsToBounds = true
            fallthrough
        case .changed:
            let size = Self.fontSize(pinching: pinchStartSize, scale: pinch.scale)
            let zoom = size / surface.fontSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.anchorPoint = .zero
            surface.layer.position = bounds.origin
            surface.layer.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
            CATransaction.commit()
            toast.show("\(Int(size)) pt", symbol: "textformat.size", lingering: true)
        case .ended, .cancelled, .failed:
            let size = Self.fontSize(pinching: pinchStartSize, scale: pinch.scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.setAffineTransform(.identity)
            surface.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            surface.layer.frame = bounds
            CATransaction.commit()
            clipsToBounds = false
            guard pinch.state == .ended, size != surface.fontSize else { return toast.hide() }
            toast.show("\(Int(size)) pt", symbol: "textformat.size")
            surface.appearance.fontSize = size
            onFontSizeChange?(size)
        default:
            break
        }
    }

    /// The whole point size a pinch from `start` by `scale` reaches, within `fontSizeRange`.
    static func fontSize(pinching start: CGFloat, scale: CGFloat) -> CGFloat {
        min(max((start * scale).rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    private func startMomentum(velocity: CGFloat, at point: CGPoint) {
        momentumVelocity = velocity
        momentumPoint = point
        lastMomentumTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastMomentumTime
        lastMomentumTime = now
        // UIScrollView.DecelerationRate.normal: velocity decays by 0.998 per millisecond.
        momentumVelocity *= pow(UIScrollView.DecelerationRate.normal.rawValue, dt * 1000)
        scroll(points: momentumVelocity * dt, at: momentumPoint, mods: [])
        if abs(momentumVelocity) < 20 { stopMomentum() }
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        scrollRemainder = 0
    }

    @objc private func pointerDragged(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        let flags = pan.modifierFlags
        let mods = KeyModifiers(flags)
        lastPointerLocation = point
        let start = CGPoint(x: point.x - pan.translation(in: self).x, y: point.y - pan.translation(in: self).y)
        if surface.reportsMouse(shift: flags.contains(.shift)) {
            switch pan.state {
            case .began:
                emitGenerated(surface.mouse(.press, button: .left, at: start, mods: mods))
                emitGenerated(surface.mouse(.motion, button: .left, at: point, mods: mods))
            case .changed: emitGenerated(surface.mouse(.motion, button: .left, at: point, mods: mods))
            case .ended, .cancelled: emitGenerated(surface.mouse(.release, button: .left, at: point, mods: mods))
            default: break
            }
            return
        }
        pointerDragRectangle = flags.contains(.alternate)
        switch pan.state {
        case .began:
            if !isFirstResponder { becomeFirstResponder() }
            menuPoint = nil
            let px = surface.pixels(start)
            surface.terminal.clearSelection()
            selectionGesture.press(cell: surface.cell(at: start), x: px.x, y: px.y, time: CACurrentMediaTime())
            fallthrough
        case .changed:
            let px = surface.pixels(point)
            selectionGesture.drag(cell: surface.cell(at: point), x: px.x, y: px.y, rectangle: pointerDragRectangle, geometry: surface.selectionGeometry)
            selectionChanged(showMenu: false)
            updateAutoscroll(at: point, extend: false)
        case .ended, .cancelled:
            selectionGesture.release(cell: surface.cell(at: point))
            stopAutoscroll()
            if surface.terminal.selection != nil { showEditMenu() }
        default:
            break
        }
    }

    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let point = hover.location(in: self)
        switch hover.state {
        case .began, .changed: onPointerMoved?(point)
        default: onPointerMoved?(nil)
        }
        switch hover.state {
        case .began, .changed:
            // A tap opens plain-text links too, so the pointer shows them all.
            setHoverLink(surface.reportsMouse(shift: hover.modifierFlags.contains(.shift)) ? nil : surface.link(at: point))
            // Any-event tracking (1003) reports motion with no button held.
            if surface.reportsMouse(shift: hover.modifierFlags.contains(.shift)) {
                emitGenerated(surface.mouse(.motion, button: nil, at: point, mods: KeyModifiers(hover.modifierFlags)))
            }
        default:
            setHoverLink(nil)
        }
    }

    private func setHoverLink(_ link: TerminalLink?) {
        surface.setHoveredLink(link.map { ($0.row, $0.columns) })
        guard link?.target != hoveredLinkTarget?.target else { return }
        hoveredLinkTarget = link
        onHoverLink?(link)
    }

    private func openLink(_ link: TerminalLink) {
        if let onOpenLink { return onOpenLink(link) }
        guard link.kind == .url, let url = URL(string: link.target) else { return }
        let alert = UIAlertController(title: "Open Link?", message: url.absoluteString, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) })
        presenter?.present(alert, animated: true)
    }

    private var presenter: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc.presentedViewController ?? vc }
            responder = current.next
        }
        return window?.rootViewController
    }

    // MARK: Selection

    private func selectionChanged(showMenu: Bool) {
        surface.setNeedsRender()
        layoutSelectionHandles()
        if showMenu { showEditMenu() }
    }

    public func clearSelection() {
        surface.terminal.clearSelection()
        selectionGesture.reset()
        editMenu?.dismissMenu()
        surface.setNeedsRender()
        layoutSelectionHandles()
    }

    /// Places the drag handles at the selection's ends (they follow scrolling and output).
    private func layoutSelectionHandles() {
        let ends = surface.selectionEnds()
        let showHandles = ends != nil && traitCollection.userInterfaceIdiom != .mac
        if let start = ends?.start, showHandles {
            startHandle.place(at: CGPoint(x: start.minX, y: start.minY), lineHeight: start.height)
            startHandle.isHidden = false
        } else {
            startHandle.isHidden = true
        }
        if let end = ends?.end, showHandles {
            endHandle.place(at: CGPoint(x: end.maxX, y: end.maxY), lineHeight: end.height)
            endHandle.isHidden = false
        } else {
            endHandle.isHidden = true
        }
    }

    @objc private func handleDragged(_ pan: UIPanGestureRecognizer) {
        guard let handle = pan.view as? SelectionHandle, let selection = surface.terminal.selection,
              let cellHeight = surface.cellSize?.height else { return }
        // Aim a little above the finger so the cell stays visible.
        var point = pan.location(in: self)
        point.y += handle.isStart ? cellHeight * 0.5 : -cellHeight * 0.5
        switch pan.state {
        case .began, .changed:
            editMenu?.dismissMenu()
            guard let moved = surface.terminal.screenPoint(fromViewport: surface.cell(at: point)) else { return }
            let fixed = handle.isStart ? selection.end : selection.start
            surface.terminal.setSelection(Selection(anchor: fixed, head: moved, rectangle: selection.rectangle))
            selectionChanged(showMenu: false)
            updateAutoscroll(at: point, extend: true, fixed: fixed)
        default:
            stopAutoscroll()
            showEditMenu()
        }
    }

    /// Scrolls one row per tick while a selection drag is within a row of the top or bottom
    /// edge, extending the selection into the newly visible rows.
    private func updateAutoscroll(at point: CGPoint, extend: Bool, fixed: GridPoint? = nil) {
        guard let cellHeight = surface.cellSize?.height else { return }
        let direction = point.y < cellHeight ? -1 : point.y > bounds.height - cellHeight ? 1 : 0
        guard direction != 0 else { return stopAutoscroll() }
        guard autoscrollTask == nil else { return }
        autoscrollTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.surface.scroll(rows: direction)
                let edge = CGPoint(x: point.x, y: direction < 0 ? 0 : self.bounds.height - 1)
                if extend, let selection = self.surface.terminal.selection,
                   let head = self.surface.terminal.screenPoint(fromViewport: self.surface.cell(at: edge))
                {
                    self.surface.terminal.setSelection(Selection(anchor: fixed ?? selection.anchor, head: head, rectangle: selection.rectangle))
                } else if !extend {
                    let px = self.surface.pixels(self.lastPointerLocation)
                    self.selectionGesture.autoscrollTick(
                        cell: self.surface.cell(at: edge), x: px.x, y: px.y,
                        rectangle: self.pointerDragRectangle, geometry: self.surface.selectionGeometry)
                }
                self.selectionChanged(showMenu: false)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopAutoscroll() {
        autoscrollTask?.cancel()
        autoscrollTask = nil
    }

    private func showEditMenu() {
        guard let ends = surface.selectionEnds() else {
            // Nothing selected (a long-press on blank cells): Paste, and what the rows offer.
            if let menuPoint {
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: menuPoint))
            }
            return
        }
        let anchor = ends.start ?? ends.end ?? .zero
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: anchor.midX, y: anchor.minY))
        editMenu?.presentEditMenu(with: config)
    }

    // MARK: Copy / paste

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): surface.terminal.selection != nil
        case #selector(paste(_:)): UIPasteboard.general.hasStrings || (onPasteAttachment != nil && UIPasteboard.general.hasImages)
        case #selector(selectAll(_:)): true
        case #selector(find(_:)): onFind != nil
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    /// The app's Find (⌘F). iOS routes ⌘F to the text input's standard `find:` action before any
    /// key command, so a terminal that does not answer it swallowed the shortcut.
    public var onFind: (() -> Void)?

    override public func find(_ sender: Any?) {
        onFind?()
    }

    /// Copies the selection as plain text, soft-wrapped lines joined.
    override public func copy(_ sender: Any?) {
        guard let text = surface.terminal.selectionText(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        toast.show("Copied", symbol: "checkmark")
    }

    /// The key bar's paste key. A button's read of the pasteboard is programmatic: iOS answers it
    /// for another app's text with a prompt or, on iOS 27, with nothing at all. So this app's own
    /// copies paste at once, and another app's text gets the system's Paste at the cursor, which
    /// is the user's own paste and reads without asking.
    public func pasteFromKeyBar() {
        let board = UIPasteboard.general
        if board.changeCount == PasteboardOrigin.ownChangeCount, let text = board.string, !text.isEmpty {
            return pasteText(text)
        }
        guard board.hasStrings || (onPasteAttachment != nil && board.hasImages) else { return }
        if !isFirstResponder { becomeFirstResponder() }
        menuOffersPaste = true
        let cursor = surface.cursorRect ?? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        let point = CGPoint(x: cursor.midX, y: cursor.minY)
        menuPoint = point
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    private func isSelected(_ point: CGPoint) -> Bool {
        guard let selection = surface.terminal.selection,
              let cell = surface.terminal.screenPoint(fromViewport: surface.cell(at: point)) else { return false }
        return selection.contains(cell)
    }

    override public func paste(_ sender: Any?) {
        // An image (and no text) goes to the host: a drawing artifact placed in the pane.
        if let onPasteAttachment, !UIPasteboard.general.hasStrings, UIPasteboard.general.hasImages,
           onPasteAttachment(UIPasteboard.general)
        {
            return
        }
        guard let text = UIPasteboard.general.string else { return }
        pasteText(text)
    }

    /// Handles a paste of an image with no text; returns whether it took it.
    public var onPasteAttachment: ((UIPasteboard) -> Bool)?

    /// Type identifiers of the app's own drags that carry text without being text to paste
    /// (a tab dragged onto a pane's edge): dropped here, they go to the views around it.
    public var unpastedDragTypes: [String] = []

    override public func selectAll(_ sender: Any?) {
        surface.terminal.selectAll()
        selectionChanged(showMenu: true)
    }

    /// Pastes `text`: bracketed when the program enabled it; a multi-line paste into a program that
    /// did not (a shell would run each line) asks first.
    public func pasteText(_ text: String) {
        clearSelection()
        switch surface.paste(text) {
        case .needsConfirmation:
            let lines = Terminal.pasteLineCount(text)
            let alert = UIAlertController(
                title: "Paste \(lines) Lines?",
                message: "The program did not enable bracketed paste, so each line may run as a command.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Paste", style: .destructive) { [weak self] _ in
                _ = self?.surface.paste(text, allowUnsafe: true)
            })
            presenter?.present(alert, animated: true)
        case .tooLarge:
            let alert = UIAlertController(title: PasteLimit.title, message: PasteLimit.message(bytes: text.utf8.count), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            presenter?.present(alert, animated: true)
        default:
            break
        }
    }

    // MARK: Hardware keyboard

    /// App shortcuts the terminal answers itself while it is first responder (the app's tab
    /// switching: ⌘1…⌘9, ⇧⌘[ ], ⌘T…), each sent to `onAppKeyCommand` with its index. UIKit asks
    /// the first responder before walking up the chain, so these never depend on the chain
    /// reaching the scene's menu commands, which a pane moved between hosts can lose.
    public var appKeyCommands: [UIKeyCommand] = [] {
        didSet {
            for command in appKeyCommands { command.wantsPriorityOverSystemBehavior = true }
        }
    }
    public var onAppKeyCommand: ((Int) -> Void)?
    /// Sees each hardware key event before it is encoded; returning true consumes it (the app's
    /// hold-to-talk chord).
    public var keyInterceptor: ((KeyEvent) -> Bool)?

    override public var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + appKeyCommands
    }

    @objc public func performAppKeyCommand(_ sender: UIKeyCommand) {
        guard let index = appKeyCommands.firstIndex(where: {
            $0.input == sender.input && $0.modifierFlags == sender.modifierFlags
        }) else { return }
        onAppKeyCommand?(index)
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, action: .press) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, action: .release) }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, action: .release) }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Encodes a hardware key press or release. Returns false for presses that belong elsewhere:
    /// ⌘ chords go to the app (menu commands, copy/paste), and an IME that is composing owns every
    /// key.
    private func handle(_ press: UIPress, action: KeyEvent.Action) -> Bool {
        guard let uiKey = press.key else { return false }
        if uiKey.keyCode == .keyboardLeftAlt || uiKey.keyCode == .keyboardRightAlt {
            if action == .press { heldOptionKeys.insert(uiKey.keyCode) } else { heldOptionKeys.remove(uiKey.keyCode) }
        }
        guard let key = PhysicalKey(hidUsage: UInt32(uiKey.keyCode.rawValue)) else { return false }
        // ⌘. is Esc: the Magic Keyboard for iPad has no Esc key (Blink, Echo do the same).
        if uiKey.keyCode == .keyboardPeriod, uiKey.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command {
            if markedText == nil { send(KeyEvent(key: .escape, action: action, mods: [], consumedMods: [], text: "", unshiftedCodepoint: 0)) }
            return true
        }
        guard !uiKey.modifierFlags.contains(.command), markedText == nil, !inputSourceComposes else { return false }

        let mods = KeyModifiers(uiKey.modifierFlags)
        let unshifted = uiKey.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
        let event: KeyEvent
        let meta = mods.contains(.alt) && optionAsMeta.applies(
            leftHeld: heldOptionKeys.contains(.keyboardLeftAlt), rightHeld: heldOptionKeys.contains(.keyboardRightAlt))
        if meta {
            var text = Self.printableText(uiKey.charactersIgnoringModifiers)
            if mods.contains(.shift) { text = text.uppercased() }
            event = optionAsMeta.metaEvent(key: key, action: action, mods: mods, textWithoutOption: text, unshiftedCodepoint: unshifted)
        } else {
            let text = Self.printableText(uiKey.characters)
            // The layout already applied Shift (and Option, Ghostty's macOS default) to the text.
            let consumed = text.isEmpty ? [] : mods.intersection([.shift, .alt])
            event = KeyEvent(key: key, action: action, mods: mods, consumedMods: consumed, text: text, unshiftedCodepoint: unshifted)
        }
        if keyInterceptor?(event) == true { return true }
        if action == .press, surface.terminal.selection != nil, !Self.isModifier(uiKey.keyCode) { clearSelection() }
        send(event)

        switch action {
        case .press where !Self.isModifier(uiKey.keyCode):
            repeatingKey = uiKey.keyCode
            var repeated = event
            repeated.action = .repeat
            repeater.start { [weak self] in self?.send(repeated) }
        case .release where uiKey.keyCode == repeatingKey:
            repeater.stop()
            repeatingKey = nil
        default:
            break
        }
        return true
    }

    /// Input sources whose keys feed a composition (Pinyin, Kana, Hangul) must go through the text
    /// system even on a hardware keyboard; it reports the result through `setMarkedText`/`insertText`.
    private var inputSourceComposes: Bool {
        guard let language = textInputMode?.primaryLanguage else { return false }
        return ["zh", "ja", "ko"].contains { language.hasPrefix($0) }
    }

    private static func isModifier(_ usage: UIKeyboardHIDUsage) -> Bool {
        (UIKeyboardHIDUsage.keyboardLeftControl.rawValue...UIKeyboardHIDUsage.keyboardRightGUI.rawValue).contains(usage.rawValue)
            || usage == .keyboardCapsLock
    }

    /// The press's text, or "" for C0 controls and UIKit's named keys ("UIKeyInputUpArrow"), which
    /// libghostty-vt derives from the physical key instead.
    private static func printableText(_ characters: String) -> String {
        guard characters.count == 1 else { return "" }
        let isControl = characters.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }
        return isControl ? "" : characters
    }

    // MARK: Software keyboard

    /// Sends committed text, with any latched key-bar modifiers applied to it.
    private func commit(_ text: String) {
        let mods = takeLatchedModifiers?() ?? []
        if surface.terminal.selection != nil { clearSelection() }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { send(.press(.enter, mods: mods)) }
            if line == "\t" {
                send(.press(.tab, mods: mods))
            } else if !line.isEmpty {
                if line.count == 1 || !mods.isEmpty {
                    for character in line { send(.typing(String(character), mods: mods)) }
                } else {
                    // IME commits, dictation and swipe-typed words: one text event, one write.
                    send(.typing(String(line), mods: mods))
                }
            }
        }
    }

    private var document: String { markedText ?? "" }
}

// MARK: - UITextInput

extension TerminalView: UITextInput {
    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        if markedText != nil { setMarkedText(nil, selectedRange: NSRange()) }
        commit(text)
    }

    public func deleteBackward() {
        if let markedText, !markedText.isEmpty {
            setMarkedText(String(markedText.dropLast()), selectedRange: NSRange(location: markedText.utf16.count - 1, length: 0))
        } else {
            send(.press(.backspace, mods: takeLatchedModifiers?() ?? []))
        }
    }

    /// Marked text (preedit) is drawn by the renderer at the cursor, underlined.
    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        self.markedText = markedText?.isEmpty == false ? markedText : nil
        markedSelection = selectedRange
        surface.preedit = self.markedText.map { TerminalSurface.Preedit(text: $0) }
    }

    public func unmarkText() {
        guard let markedText else { return }
        setMarkedText(nil, selectedRange: NSRange())
        commit(markedText)
    }

    public var markedTextRange: UITextRange? {
        markedText.map { TextRange(0, $0.utf16.count) }
    }

    public var selectedTextRange: UITextRange? {
        get {
            guard markedText != nil else { return TextRange(0, 0) }
            return TextRange(markedSelection.location, markedSelection.location + markedSelection.length)
        }
        set {
            guard markedText != nil, let range = newValue as? TextRange else { return }
            markedSelection = NSRange(location: range.from.offset, length: range.to.offset - range.from.offset)
        }
    }

    public func text(in range: UITextRange) -> String? {
        guard let range = range as? TextRange else { return nil }
        let utf16 = document.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: min(range.from.offset, utf16.count))
        let upper = utf16.index(utf16.startIndex, offsetBy: min(range.to.offset, utf16.count))
        return String(utf16[lower..<upper])
    }

    public func replace(_ range: UITextRange, withText text: String) {
        insertText(text)
    }

    public var beginningOfDocument: UITextPosition { TextPosition(0) }
    public var endOfDocument: UITextPosition { TextPosition(document.utf16.count) }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TextPosition, let to = toPosition as? TextPosition else { return nil }
        return TextRange(min(from.offset, to.offset), max(from.offset, to.offset))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TextPosition else { return nil }
        let target = position.offset + offset
        return (0...document.utf16.count).contains(target) ? TextPosition(target) : nil
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = (position as? TextPosition)?.offset ?? 0
        let rhs = (other as? TextPosition)?.offset ?? 0
        return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? TextPosition)?.offset ?? 0) - ((from as? TextPosition)?.offset ?? 0)
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let edge = direction == .left || direction == .up ? beginningOfDocument : endOfDocument
        return textRange(from: position, to: edge)
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// IME candidate windows anchor to the composition, which starts at the terminal cursor.
    public func firstRect(for range: UITextRange) -> CGRect {
        guard let cursor = surface.cursorRect else { return .zero }
        let cells = max(1, markedText.map { Self.cellCount($0) } ?? 1)
        return CGRect(x: cursor.minX, y: cursor.minY, width: cursor.width * CGFloat(cells), height: cursor.height)
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let cursor = surface.cursorRect else { return .zero }
        let offset = (position as? TextPosition)?.offset ?? 0
        let prefix = markedText.map { String($0.utf16.prefix(offset)) ?? "" } ?? ""
        return CGRect(x: cursor.minX + cursor.width * CGFloat(Self.cellCount(prefix)), y: cursor.minY, width: 2, height: cursor.height)
    }

    private static func cellCount(_ text: String) -> Int {
        text.reduce(0) { $0 + (TerminalSurface.isWide($1) ? 2 : 1) }
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    public func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }

    public func characterRange(at point: CGPoint) -> UITextRange? { nil }
}

// MARK: - Edit menu

extension TerminalView: @MainActor UIEditMenuInteractionDelegate {
    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let paste = Self.command(#selector(UIResponderStandardEditActions.paste(_:)), in: suggestedActions)
        if menuOffersPaste { return paste.map { UIMenu(children: [$0]) } }
        var actions: [UIMenuElement] = []
        let selection = surface.selectionEnds()
        if surface.terminal.selection != nil {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
                self?.clearSelection()
            })
        }
        // What the rows under the press (or the selection's start) belong to.
        if let point = menuPoint ?? selection?.start.map({ CGPoint(x: $0.midX, y: $0.midY) }),
           let extra = contextActions?(point)
        {
            actions.append(extra)
        }
        // The system's own Paste command (it reaches `paste(_:)` through the responder chain,
        // gated by `canPerformAction`), so reading another app's text counts as the user's paste.
        // A custom action reading `UIPasteboard.general` is a programmatic read: iOS asks "Allow
        // Paste?" or, as on a fresh iOS 27 install, returns nil without asking, and nothing pastes.
        if let paste { actions.append(paste) }
        actions.append(UIAction(title: "Select All") { [weak self] _ in self?.selectAll(nil) })
        return UIMenu(children: actions)
    }

    private static func command(_ action: Selector, in elements: [UIMenuElement]) -> UICommand? {
        for element in elements {
            if let command = element as? UICommand, command.action == action { return command }
            if let menu = element as? UIMenu, let command = command(action, in: menu.children) { return command }
        }
        return nil
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let ends = surface.selectionEnds() else {
            guard let menuPoint else { return .null }
            return CGRect(origin: menuPoint, size: .zero).insetBy(dx: -1, dy: -1)
        }
        let rects = [ends.start, ends.end].compactMap { $0 }
        return rects.dropFirst().reduce(rects.first ?? .null) { $0.union($1) }
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating
    ) {
        animator.addCompletion { [weak self] in
            self?.menuPoint = nil
            self?.menuOffersPaste = false
        }
    }
}

/// A selection drag handle: a bar the height of a line with a knob, like UIKit's.
private final class SelectionHandle: UIView {
    let isStart: Bool
    private let bar = UIView()
    private let knob = UIView()
    private static let knobSize: CGFloat = 10
    private static let hitWidth: CGFloat = 44

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        bar.backgroundColor = tintColor
        knob.backgroundColor = tintColor
        knob.layer.cornerRadius = Self.knobSize / 2
        addSubview(bar)
        addSubview(knob)
        accessibilityIdentifier = isStart ? "selection-start-handle" : "selection-end-handle"
        isAccessibilityElement = true
        accessibilityLabel = isStart ? "Selection start" : "Selection end"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        bar.backgroundColor = tintColor
        knob.backgroundColor = tintColor
    }

    /// `point` is the selection's top-left (start) or bottom-right (end) corner.
    func place(at point: CGPoint, lineHeight: CGFloat) {
        let height = lineHeight + Self.knobSize
        frame = CGRect(x: point.x - Self.hitWidth / 2, y: isStart ? point.y - Self.knobSize : point.y - lineHeight, width: Self.hitWidth, height: height)
        bar.frame = CGRect(x: Self.hitWidth / 2 - 1, y: isStart ? Self.knobSize : 0, width: 2, height: lineHeight)
        knob.frame = CGRect(
            x: Self.hitWidth / 2 - Self.knobSize / 2, y: isStart ? 0 : lineHeight, width: Self.knobSize, height: Self.knobSize)
    }
}

/// The terminal screen for assistive technologies: its value is the visible text, or the IME
/// composition while composing.
private final class ScreenElement: UIAccessibilityElement {
    var text: (() -> String?)?

    override var accessibilityValue: String? {
        get { text?() }
        set {}
    }
}

/// A UTF-16 offset into the marked text.
private final class TextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

private final class TextRange: UITextRange {
    let from: TextPosition
    let to: TextPosition

    init(_ from: Int, _ to: Int) {
        self.from = TextPosition(from)
        self.to = TextPosition(to)
    }

    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.offset == to.offset }
}

extension KeyModifiers {
    init(_ flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.alternate) { insert(.alt) }
        if flags.contains(.command) { insert(.super) }
        if flags.contains(.alphaShift) { insert(.capsLock) }
    }
}

extension TerminalView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        Set([gestureRecognizer, other].map(ObjectIdentifier.init)) == Set([pinchGesture, scrollGesture].map(ObjectIdentifier.init))
    }
}

extension TerminalView: UIScribbleInteractionDelegate {
    public func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        allowsHandwriting
    }
}

// MARK: - Drag and drop

extension TerminalView: UIDragInteractionDelegate, UIDropInteractionDelegate {
    /// A drag that starts on the selection carries its text; anywhere else it does not start, so
    /// the terminal's own gestures keep the touch.
    public func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        let point = session.location(in: self)
        if !isSelected(point), let image = surface.kittyImage(at: point) {
            return kittyDragItem(image.placement).map { [$0] } ?? []
        }
        guard isSelected(point), let text = surface.terminal.selectionText(), !text.isEmpty else { return [] }
        editMenu?.dismissMenu()
        let item = UIDragItem(itemProvider: NSItemProvider(object: text as NSString))
        item.localObject = self
        return [item]
    }

    /// An image printed with kitty graphics, as a PNG: into other apps, and onto other panes,
    /// which upload it to their host.
    private func kittyDragItem(_ placement: ImagePlacement) -> UIDragItem? {
        guard let png = surface.terminal.kittyPNG(placement) else { return nil }
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: "public.png")
        provider.suggestedName = "Image"
        let item = UIDragItem(itemProvider: provider)
        item.localObject = self
        return item
    }

    public func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        // An image is drawn by Metal: lift a copy of it. A selection lifts the view, as before.
        let point = session.location(in: self)
        guard !isSelected(point), let frame = surface.kittyImage(at: point),
              let png = surface.terminal.kittyPNG(frame.placement), let image = UIImage(data: png)
        else { return UITargetedDragPreview(view: self) }
        let view = UIImageView(image: image)
        view.frame = frame.rect
        view.contentMode = .scaleToFill
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedDragPreview(view: view, parameters: parameters, target: UIDragPreviewTarget(container: self, center: CGPoint(x: frame.rect.midX, y: frame.rect.midY)))
    }

    /// Text and links. Images and files are the host's (a drawing placed in the pane), a
    /// selection dropped back on its own terminal is a slip, not a paste, and drags of
    /// `unpastedDragTypes` are for the views around it.
    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        if session.localDragSession?.items.contains(where: { $0.localObject as? TerminalView === self }) == true { return false }
        return session.canLoadObjects(ofClass: String.self)
            && !session.hasItemsConforming(toTypeIdentifiers: ["public.image", "public.file-url"] + unpastedDragTypes)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        if !isFirstResponder { becomeFirstResponder() }
        let providers = session.items.map(\.itemProvider).filter { $0.canLoadObject(ofClass: NSString.self) }
        Task { @MainActor [weak self] in
            var texts: [String] = []
            for provider in providers {
                let text: String? = await withCheckedContinuation { done in
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in done.resume(returning: object as? String) }
                }
                if let text, !text.isEmpty { texts.append(text) }
            }
            if !texts.isEmpty { self?.pasteText(texts.joined(separator: " ")) }
        }
    }
}

/// The pasteboard's change count after this app last wrote it: its own text, which reads
/// without a prompt. The notification reports only changes made in this process.
@MainActor
private enum PasteboardOrigin {
    static var ownChangeCount = -1
    private static var observer: (any NSObjectProtocol)?

    static func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ownChangeCount = UIPasteboard.general.changeCount }
        }
    }
}

/// Gives back the shared glyph atlases on a memory warning, before the system has to end the app.
@MainActor
private enum MemoryPressure {
    private static var observer: (any NSObjectProtocol)?

    static func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { FontGrid.releaseCaches() }
        }
    }
}

/// A brief capsule at the top of the terminal: "Copied", or the font size while pinching.
private final class CapsuleToast: UIView {
    private var hideTask: Task<Void, Never>?
    private let label = UILabel()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 108, height: 34))
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        glass.contentView.addSubview(label)
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal-toast"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `lingering`: stays until `hide()` (a pinch in progress) instead of fading by itself.
    func show(_ text: String, symbol: String, lingering: Bool = false) {
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        let attributed = NSMutableAttributedString(attachment: NSTextAttachment(image: image ?? UIImage()))
        attributed.append(NSAttributedString(string: " " + text))
        label.attributedText = attributed
        let width = max(108, label.intrinsicContentSize.width + 36)
        let center = self.center
        bounds.size.width = width
        self.center = center
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        label.frame = bounds
        accessibilityLabel = text

        superview?.bringSubviewToFront(self)
        let appearing = isHidden || alpha < 1
        isHidden = false
        if appearing {
            UIView.animate(withDuration: 0.15) { self.alpha = 1 }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        hideTask?.cancel()
        guard !lingering else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        UIView.animate(withDuration: 0.3) { self.alpha = 0 } completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        }
    }
}
#endif
