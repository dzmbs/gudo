#if os(iOS)
import TerminalCore
import UIKit

/// UIKit host for a `TerminalSurface`. It carries the surface's `CAMetalLayer`, paces it with a
/// `CADisplayLink`, and turns input into terminal bytes:
/// - hardware keys (`UIPress`, HID usages through the shared `PhysicalKey` table), with our own
///   hold-to-repeat because UIKit sends none for presses handled here;
/// - the software keyboard through `UITextInput`. The text "document" is only the IME's marked
///   text: committed text goes to the PTY at once and marked text is never sent (04-mobile-ux A1.6);
/// - one- and two-finger pans, trackpads and mouse wheels scroll the scrollback.
///
/// Not yet: mouse reporting, selection, paste, momentum scrolling, Option-as-Meta remapping.
public final class TerminalView: UIView {
    public let surface: TerminalSurface
    /// Bytes to write to the PTY (encoded keys).
    public var onInput: (([UInt8]) -> Void)?
    /// Called when the view becomes first responder (a tap, or a programmatic focus change).
    public var onFocus: (() -> Void)?
    /// Modifiers latched on an on-screen key bar (sticky Ctrl), applied to the next key from the
    /// software keyboard. The provider clears a one-shot latch when it is read.
    public var takeLatchedModifiers: (() -> KeyModifiers)?
    /// Shown above the software keyboard while this view is first responder.
    public var keyBar: UIView?

    private let repeater = KeyRepeater()
    private var repeatingKey: UIKeyboardHIDUsage?
    private var scrollRemainder: CGFloat = 0
    private let preeditLabel = UILabel()

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

    public init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        layer.addSublayer(surface.layer)
        backgroundColor = .black

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedScrollTypesMask = .all
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        preeditLabel.isHidden = true
        preeditLabel.font = .monospacedSystemFont(ofSize: surface.fontSize, weight: .regular)
        preeditLabel.textColor = .label
        preeditLabel.backgroundColor = .secondarySystemBackground
        addSubview(preeditLabel)

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
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            surface.stopDisplayLink()
            return
        }
        surface.startDisplayLink { CADisplayLink(target: $0, selector: $1) }
    }

    /// Sends a key as if typed here (key bar, menu actions).
    public func send(_ key: KeyEvent) {
        let bytes = surface.encode(key)
        if !bytes.isEmpty { onInput?(bytes) }
    }

    // MARK: Focus

    override public var canBecomeFirstResponder: Bool { true }
    override public var inputAccessoryView: UIView? { keyBar }

    @discardableResult
    override public func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        surface.isFocused = true
        onFocus?()
        return true
    }

    @discardableResult
    override public func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        surface.isFocused = false
        repeater.stop()
        repeatingKey = nil
        setMarkedText(nil, selectedRange: NSRange())
        return true
    }

    @objc private func tapped() {
        becomeFirstResponder()
    }

    // MARK: Scrolling

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let grid = surface.grid else { return }
        let cellHeight = CGFloat(grid.cellHeight) / surface.layer.contentsScale
        scrollRemainder += pan.translation(in: self).y / cellHeight
        pan.setTranslation(.zero, in: self)
        let whole = Int(scrollRemainder.rounded(.towardZero))
        scrollRemainder -= CGFloat(whole)
        // Dragging content down reveals history, which is a negative (upward) viewport scroll.
        surface.scroll(rows: -whole)
        if pan.state == .ended || pan.state == .cancelled { scrollRemainder = 0 }
    }

    // MARK: Hardware keyboard

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
    /// ⌘ chords go to the app (menu commands), and an IME that is composing owns every key.
    private func handle(_ press: UIPress, action: KeyEvent.Action) -> Bool {
        guard let uiKey = press.key, let key = PhysicalKey(hidUsage: UInt32(uiKey.keyCode.rawValue)) else { return false }
        guard !uiKey.modifierFlags.contains(.command), markedText == nil, !inputSourceComposes else { return false }

        let mods = KeyModifiers(uiKey.modifierFlags)
        let text = Self.printableText(uiKey.characters)
        // The layout already applied Shift (and Option, Ghostty's macOS default) to the text.
        let consumed = text.isEmpty ? [] : mods.intersection([.shift, .alt])
        let unshifted = uiKey.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
        let event = KeyEvent(key: key, action: action, mods: mods, consumedMods: consumed, text: text, unshiftedCodepoint: unshifted)
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
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { send(.press(.enter, mods: mods)) }
            if line == "\t" {
                send(.press(.tab, mods: mods))
            } else if !line.isEmpty {
                send(.typing(String(line), mods: mods))
            }
        }
    }

    private func updatePreedit() {
        guard let markedText, let cursor = surface.cursorRect else {
            preeditLabel.isHidden = true
            return
        }
        preeditLabel.attributedText = NSAttributedString(
            string: markedText, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        preeditLabel.sizeToFit()
        preeditLabel.frame.origin = cursor.origin
        preeditLabel.frame.size.height = cursor.height
        preeditLabel.isHidden = false
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

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        self.markedText = markedText?.isEmpty == false ? markedText : nil
        markedSelection = selectedRange
        updatePreedit()
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

    /// IME candidate windows anchor to the terminal cursor.
    public func firstRect(for range: UITextRange) -> CGRect {
        surface.cursorRect ?? .zero
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        surface.cursorRect ?? .zero
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    public func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }

    public func characterRange(at point: CGPoint) -> UITextRange? { nil }
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
#endif
