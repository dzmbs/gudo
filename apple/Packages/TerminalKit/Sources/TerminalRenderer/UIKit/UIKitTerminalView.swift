#if os(iOS)
import TerminalCore
import UIKit

/// UIKit host for a `TerminalSurface`. It carries the surface's `CAMetalLayer`, paces it with a
/// `CADisplayLink`, and turns input into terminal bytes:
/// - hardware keys (`UIPress`, HID usages through the shared `PhysicalKey` table) with our own
///   hold-to-repeat, Option-as-Meta per side, and ⌘ chords left to the app's key commands;
/// - the software keyboard and IMEs through `UITextInput`. Marked text is drawn inline at the
/// - touch: tap focuses (or clicks, or opens a link after confirmation), double/triple tap and
///   long-press select a word/line with drag handles and the edit menu, one-finger drag scrolls
///   with momentum (alt screen: arrow keys; mouse mode: drag events), two fingers send the wheel;
/// - pointer (iPad trackpad/mouse): click-drag selects (⌥ for a block, ⇧-click extends, edge
///   auto-scroll), hover underlines links and reports motion in any-event mode, the wheel follows
///   the same mouse-mode routing. Shift always selects instead of reporting.
public final class TerminalView: UIView {
    public let surface: TerminalSurface
    /// Bytes to write to the PTY (encoded keys, mouse reports, focus reports).
    public var onInput: (([UInt8]) -> Void)?
    /// Called when the view becomes first responder (a tap, or a programmatic focus change).
    public var onFocus: (() -> Void)?
    /// Modifiers latched on an on-screen key bar (sticky Ctrl), applied to the next key from the
    /// software keyboard. The provider clears a one-shot latch when it is read.
    public var takeLatchedModifiers: (() -> KeyModifiers)?
    /// Shown above the software keyboard while this view is first responder.
    public var keyBar: UIView?
    /// Which Option keys act as Meta (Ghostty's `macos-option-as-alt`).
    public var optionAsMeta = OptionAsMeta.none
    /// Visual flash plus a haptic on BEL.
    public var bellHaptics = true
    /// Opens a link the user tapped; the default asks for confirmation and opens it with
    /// `UIApplication.open`.
    public var onOpenLink: ((URL) -> Void)?
    /// Whether Apple Pencil handwriting (Scribble) may type into the terminal. Off: Pencil
    /// strokes over a terminal are drawing or nothing, never text sent to the shell unseen.
    public var allowsHandwriting = false

    private let repeater = KeyRepeater()
    private var repeatingKey: UIKeyboardHIDUsage?
    private var heldOptionKeys: Set<UIKeyboardHIDUsage> = []

    // Scrolling
    private var scrollRemainder: CGFloat = 0
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var momentumPoint = CGPoint.zero
    private var lastMomentumTime: CFTimeInterval = 0

    // Selection
    private lazy var selectionGesture = SelectionGesture(terminal: surface.terminal)
    private let startHandle = SelectionHandle(isStart: true)
    private let endHandle = SelectionHandle(isStart: false)
    private var editMenu: UIEditMenuInteraction?
    private var autoscrollTask: Task<Void, Never>?
    private var lastPointerLocation = CGPoint.zero
    private var pointerDragRectangle = false
    private var touchMouseDrag = false

    private let bellLayer = CALayer()

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
        backgroundColor = .black
        isMultipleTouchEnabled = true

        bellLayer.backgroundColor = UIColor.white.cgColor
        bellLayer.opacity = 0
        layer.addSublayer(bellLayer)

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
        bellLayer.frame = bounds
        CATransaction.commit()
        surface.layout(size: bounds.size, scale: traitCollection.displayScale)
        layoutSelectionHandles()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            surface.stopDisplayLink()
            stopMomentum()
            return
        }
        surface.startDisplayLink { CADisplayLink(target: $0, selector: $1) }
    }

    /// Sends a key as if typed here (key bar, menu actions).
    public func send(_ key: KeyEvent) {
        let bytes = surface.encode(key)
        if !bytes.isEmpty { emit(bytes) }
    }

    /// Sends text written in a composer (04-mobile-ux C5): as a paste (bracketed when the program
    /// asked for it, so a multi-line prompt arrives as one), then Return when `submit`.
    public func sendComposedText(_ text: String, submit: Bool = true) {
        _ = surface.paste(text, source: .text, allowUnsafe: true)
        if submit { send(.press(.enter)) }
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onInput?(bytes)
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

    override public var accessibilityIdentifier: String? {
        didSet { screenElement.accessibilityIdentifier = accessibilityIdentifier.map { "\($0)-screen" } }
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
            return Array(hosted) + [screenElement] + [startHandle, endHandle].filter { !$0.isHidden }
        }
        set {}
    }

    // MARK: Bell

    /// BEL: a short flash and, on iPhone/iPad, a warning haptic.
    public func ringBell() {
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.25
        flash.toValue = 0
        flash.duration = 0.3
        bellLayer.add(flash, forKey: "bell")
        if bellHaptics { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    // MARK: Focus

    override public var canBecomeFirstResponder: Bool { true }
    override public var inputAccessoryView: UIView? { keyBar }

    @discardableResult
    override public func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        surface.isFocused = true
        emit(surface.terminal.encodeFocus(true))
        onFocus?()
        return true
    }

    @discardableResult
    override public func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        surface.isFocused = false
        emit(surface.terminal.encodeFocus(false))
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

        // Touch drags and the scroll wheel / two-finger trackpad scroll (no touches).
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedScrollTypesMask = .all
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        // Pointer click-drag: selection, or mouse drags for the program.
        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointerDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerDrag.allowedScrollTypesMask = []
        addGestureRecognizer(pointerDrag)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let shift = tap.modifierFlags.contains(.shift)
        if !isFirstResponder { becomeFirstResponder() }

        if surface.reportsMouse(shift: shift) {
            let mods = KeyModifiers(tap.modifierFlags)
            emit(surface.mouse(.press, button: .left, at: point, mods: mods))
            emit(surface.mouse(.release, button: .left, at: point, mods: mods))
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
            selectionChanged(showMenu: true)
            return
        }
        if surface.terminal.selection != nil {
            clearSelection()
            return
        }
        if let link = surface.link(at: point), let url = URL(string: link.url) {
            openLink(url)
        }
    }

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: self)
        switch press.state {
        case .began:
            if surface.terminal.selectWord(atViewport: surface.cell(at: point)) != nil {
                UISelectionFeedbackGenerator().selectionChanged()
                selectionChanged(showMenu: false)
            }
        case .changed:
            guard let selection = surface.terminal.selection,
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

    /// One finger scrolls (alt screen: arrows; mouse mode: drag), two fingers or the wheel send
    /// wheel events in mouse mode. Ends with momentum, like `UIScrollView`.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        let isWheel = pan.numberOfTouches == 0 || pan.numberOfTouches >= 2
        let mods = KeyModifiers(pan.modifierFlags)
        switch pan.state {
        case .began:
            stopMomentum()
            touchMouseDrag = !isWheel && surface.reportsMouse(shift: pan.modifierFlags.contains(.shift))
            if touchMouseDrag {
                let start = CGPoint(x: point.x - pan.translation(in: self).x, y: point.y - pan.translation(in: self).y)
                emit(surface.mouse(.press, button: .left, at: start, mods: mods))
            }
        case .changed:
            if touchMouseDrag {
                emit(surface.mouse(.motion, button: .left, at: point, mods: mods))
                return
            }
            scroll(points: pan.translation(in: self).y, at: point, mods: mods)
            pan.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            if touchMouseDrag {
                emit(surface.mouse(.release, button: .left, at: point, mods: mods))
                touchMouseDrag = false
                return
            }
            scroll(points: pan.translation(in: self).y, at: point, mods: mods)
            let velocity = pan.velocity(in: self).y
            if pan.state == .ended, abs(velocity) > 80 { startMomentum(velocity: velocity, at: point) }
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
        emit(surface.wheel(rows: -whole, at: point, mods: mods))
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
                emit(surface.mouse(.press, button: .left, at: start, mods: mods))
                emit(surface.mouse(.motion, button: .left, at: point, mods: mods))
            case .changed: emit(surface.mouse(.motion, button: .left, at: point, mods: mods))
            case .ended, .cancelled: emit(surface.mouse(.release, button: .left, at: point, mods: mods))
            default: break
            }
            return
        }
        pointerDragRectangle = flags.contains(.alternate)
        switch pan.state {
        case .began:
            if !isFirstResponder { becomeFirstResponder() }
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
        case .began, .changed:
            if let link = surface.link(at: point) {
                surface.setHoveredLink((link.row, link.columns))
            } else {
                surface.setHoveredLink(nil)
            }
            // Any-event tracking (1003) reports motion with no button held.
            if surface.reportsMouse(shift: hover.modifierFlags.contains(.shift)) {
                emit(surface.mouse(.motion, button: nil, at: point, mods: KeyModifiers(hover.modifierFlags)))
            }
        default:
            surface.setHoveredLink(nil)
        }
    }

    private func openLink(_ url: URL) {
        if let onOpenLink { return onOpenLink(url) }
        let alert = UIAlertController(title: "Open Link?", message: url.absoluteString, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) })
        presenter?.present(alert, animated: true)
    }

    private var presenter: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc.presentedViewController ?? vc }
            responder = r.next
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
        guard let ends = surface.selectionEnds() else { return }
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
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    /// Copies the selection as plain text, soft-wrapped lines joined.
    override public func copy(_ sender: Any?) {
        guard let text = surface.terminal.selectionText() else { return }
        UIPasteboard.general.string = text
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
            let lines = text.split(whereSeparator: \.isNewline).count
            let alert = UIAlertController(
                title: "Paste \(lines) Lines?",
                message: "The program did not enable bracketed paste, so each line may run as a command.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Paste", style: .destructive) { [weak self] _ in
                _ = self?.surface.paste(text, allowUnsafe: true)
            })
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
        let a = (position as? TextPosition)?.offset ?? 0
        let b = (other as? TextPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
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
        var actions: [UIMenuElement] = []
        if surface.terminal.selection != nil {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
                self?.clearSelection()
            })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste(nil) })
        }
        actions.append(UIAction(title: "Select All") { [weak self] _ in self?.selectAll(nil) })
        return UIMenu(children: actions)
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let ends = surface.selectionEnds() else { return .null }
        let rects = [ends.start, ends.end].compactMap { $0 }
        return rects.dropFirst().reduce(rects.first ?? .null) { $0.union($1) }
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

extension TerminalView: UIScribbleInteractionDelegate {
    public func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        allowsHandwriting
    }
}
#endif
