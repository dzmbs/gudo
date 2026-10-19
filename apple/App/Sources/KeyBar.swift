#if os(iOS)
import GameController
import HostKit
import TerminalCore
import TerminalRenderer
import UIKit

/// - the key row: `[profile] [esc ctl alt tab] ║ wing (scrolls) ║ [←↑↓→ on wide] [✥]`;
/// - the arrow pad (↑ ↓ ← → Home End PgUp PgDn), opened by tapping the joystick;
/// - the snippets row, when toggled;
/// - the composer, when on: a multi-line text view that sends on Send / ⌘↩.
///
/// The spine (`esc ctl alt tab` and the joystick) is identical in every profile; profiles only
/// replace the wing. Every wing key has two glyphs: tap sends the big one, a vertical flick of
/// 12 pt or more sends the small one. Keys go through the terminal's encoder, so arrows honour
/// application-cursor mode and the kitty keyboard protocol like hardware keys do.
///
/// - `ctl` and `alt` are one-shot: tap and they apply to the next key (from the bar or the software
///   keyboard). Double-tap or long-press locks; tap again to unlock. Flicking `ctl` sends ^C at once,
///   flicking `alt` sends `ESC .` (last argument).
/// - The joystick sends arrows by dragging from wherever the touch started: one arrow on crossing
///   8 pt, then repeats at 12/25/50 per second the further the finger goes. Lifting stops at once.
/// - With a hardware keyboard attached the bar collapses to a slim strip (profile and Esc).
///
/// Per pane (keyed by its terminal view) it remembers a manual profile choice, the composer on/off
/// choice and the composer draft.
final class KeyBar: UIInputView {
    private enum Latch {
        case off, oneShot, locked
    }

    private struct PaneState {
        var detected = KeyBarProfile.shell
        /// Set from the profile menu; dropped when detection picks a different profile.
        var manual: KeyBarProfile?
        /// nil follows the profile's preference.
        var composerOn: Bool?
        var draft = ""
        var profile: KeyBarProfile { manual ?? detected }
    }

    /// Called when the bar's height changes (rows shown or hidden), so the workspace can treat
    /// the resulting terminal resize like a keyboard slide (no cols × rows overlay).
    var onHeightChange: (() -> Void)?

    /// Opens draw mode on the focused pane; nil when the pane cannot be drawn on (no daemon).
    var onDraw: (() -> Void)? {
        didSet { updateProfileButton() }
    }

    /// The terminal that receives keys: the focused pane's view.
    weak var target: TerminalView? {
        didSet {
            guard oldValue !== target else { return }
            lineEditor.terminal = target
            apply()
        }
    }

    /// The focused pane's input assistance (daemon panes): drives the line editor, smart row and
    /// agent decision strip. nil keeps the bar in direct mode.
    var assist: (any LineAssist)? {
        didSet { lineEditor.attach(assist) }
    }

    /// The active profile (for tests and the design layer).
    private(set) var profile = KeyBarProfile.shell

    static let fullWithHardwareKeyboardKey = "keyBar.fullWithHardwareKeyboard"
    /// Bars at least this wide show the arrow cluster and the panel toggles inline (iPad, landscape).
    private static let wideWidth: CGFloat = 600

    private let style: KeyBarStyle
    private let snippets: SnippetStore
    private var paneStates: [ObjectIdentifier: PaneState] = [:]
    private var ctrl = Latch.off {
        didSet { updateModifierButtons() }
    }
    private var alt = Latch.off {
        didSet { updateModifierButtons() }
    }
    private var lastCtrlTap: ContinuousClock.Instant?
    private var lastAltTap: ContinuousClock.Instant?
    private let repeater = KeyRepeater()
    private var hardwareKeyboard = GCKeyboard.coalesced != nil
    private var snippetsShown = false
    private var arrowPadShown = false
    private var wide = false

    private let column = UIStackView()
    private let composer: ComposerView
    private let lineEditor: LineEditorController
    private let snippetScroll = UIScrollView()
    private let snippetStack = UIStackView()
    private let arrowPad = UIStackView()
    private let keyRow = UIView()
    private let wingScroll = HorizontalScrollView()
    private let wingStack = UIStackView()
    private let spine = UIStackView()
    private let trailing = UIStackView()
    private let profileButton = UIButton()
    private let escButton: FlickButton
    private let ctrlButton: FlickButton
    private let altButton: FlickButton
    private let tabButton: FlickButton
    private let arrowCluster = UIStackView()
    private let joystick = JoystickView()
    private let composerToggle = UIButton()
    private let snippetsToggle = UIButton()
    private let hideKeyboard = UIButton()
    private var keyRowHeight: NSLayoutConstraint!
    private var buttonHeights: [NSLayoutConstraint] = []

    private static let doubleTapWindow = Duration.milliseconds(350)

    init(style: KeyBarStyle = .default, snippets: SnippetStore = .shared) {
        self.style = style
        self.snippets = snippets
        composer = ComposerView(style: style)
        lineEditor = LineEditorController(style: style)
        escButton = FlickButton(style: style)
        ctrlButton = FlickButton(style: style)
        altButton = FlickButton(style: style)
        tabButton = FlickButton(style: style)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: style.rowHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false

        column.axis = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        composer.isHidden = true
        composer.onSubmit = { [weak self] text in self?.target?.sendComposedText(text, submit: true) }
        composer.onHeightChange = { [weak self] in self?.relayout() }
        composer.onTextChange = { [weak self] text in self?.state.draft = text }
        column.addArrangedSubview(composer)

        configureSnippetRow()
        column.addArrangedSubview(snippetScroll)

        configureArrowPad()
        column.addArrangedSubview(arrowPad)

        lineEditor.onLayoutChange = { [weak self] in self?.relayout() }
        column.insertArrangedSubview(lineEditor.decisionStrip, at: 1)
        column.addArrangedSubview(lineEditor.smartRow)
        column.addArrangedSubview(lineEditor.editorRow)

        configureKeyRow()
        column.addArrangedSubview(keyRow)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged), name: .GCKeyboardDidDisconnect, object: nil)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isWide = bounds.width >= Self.wideWidth
        if isWide != wide {
            wide = isWide
            applyWidth()
            updateProfileButton()
        }
    }

    /// What runs in the focused pane; picks the key bar profile.
    func update(context: KeyBarContext) {
        guard let target else { return }
        let detected = KeyBarProfile.match(context)
        let id = ObjectIdentifier(target)
        var state = paneStates[id, default: PaneState()]
        if detected != state.detected {
            // A different program took over: its own profile and composer default apply again.
            state.detected = detected
            state.manual = nil
            state.composerOn = nil
        }
        paneStates[id] = state
        apply()
        lineEditor.refreshBlocked()
        lineEditor.paneFocused()
    }

    /// The latched modifiers for the next key; reading clears one-shot Ctrl and Alt.
    func takeLatchedModifiers() -> KeyModifiers {
        var mods: KeyModifiers = []
        if ctrl != .off { mods.insert(.control) }
        if alt != .off { mods.insert(.alt) }
        if ctrl == .oneShot { ctrl = .off }
        if alt == .oneShot { alt = .off }
        return mods
    }

    // MARK: State

    private var state: PaneState {
        get { target.map { paneStates[ObjectIdentifier($0), default: PaneState()] } ?? PaneState() }
        set { if let target { paneStates[ObjectIdentifier(target)] = newValue } }
    }

    /// The composer shows where the user turned it on, else for agents on the software keyboard
    /// only: with a hardware keyboard the terminal takes the typing.
    private func showsComposer(_ state: PaneState) -> Bool {
        state.composerOn ?? (state.profile.prefersComposer && !compact)
    }

    private var compact: Bool {
        hardwareKeyboard && !UserDefaults.standard.bool(forKey: Self.fullWithHardwareKeyboardKey)
    }

    /// Brings the views in line with the focused pane's state.
    private func apply() {
        let state = state
        profile = state.profile
        lineEditor.shellProfile = profile.id == "shell" && !showsComposer(state)
        lineEditor.agentProfile = profile.id == "claude" || profile.id == "codex"
        rebuildWing()
        updateProfileButton()
        if composer.text != state.draft { composer.text = state.draft }
        composer.isHidden = !showsComposer(state)
        composerToggle.configuration = style.button(.init(title: nil, symbol: "text.bubble", active: showsComposer(state)))
        composerToggle.accessibilityValue = showsComposer(state) ? "on" : "off"
        snippetScroll.isHidden = !snippetsShown || compact
        snippetsToggle.configuration = style.button(.init(title: nil, symbol: "text.append", active: snippetsShown))
        snippetsToggle.accessibilityValue = snippetsShown ? "shown" : "hidden"
        arrowPad.isHidden = !arrowPadShown || compact
        joystick.isActive = arrowPadShown
        // The wing's keys go, its scroll view stays: it is the flexible middle that keeps the
        // trailing toggles at their own size.
        for view in [ctrlButton, altButton, tabButton, wingStack, joystick] as [UIView] { view.isHidden = compact }
        if compact {
            ctrl = .off
            alt = .off
        }
        applyWidth()
        keyRowHeight.constant = compact ? style.compactRowHeight : style.rowHeight
        for constraint in buttonHeights { constraint.constant = compact ? style.compactButtonHeight : style.buttonHeight }
        relayout()
    }

    /// Wide bars (iPad, landscape) show the arrow cluster and the panel toggles inline; narrow ones
    /// keep them in the profile menu so the wing has room.
    private func applyWidth() {
        let inline = wide && !compact
        arrowCluster.isHidden = !inline
        // The composer toggle is for agents (or a composer the user turned on); for a shell the
        // composer is in the profile menu.
        let agent = profile.id == "claude" || profile.id == "codex"
        composerToggle.isHidden = !(agent || showsComposer(state))
        snippetsToggle.isHidden = !inline
        hideKeyboard.isHidden = !inline
    }

    private func relayout() {
        onHeightChange?()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
    }

    @objc private func keyboardsChanged() {
        hardwareKeyboard = GCKeyboard.coalesced != nil
        apply()
    }

    // MARK: Key row

    private func configureKeyRow() {
        configureProfileButton()
        configureSpine()
        configureJoystick()
        configureArrowCluster()

        composerToggle.accessibilityIdentifier = "keybar-composer-toggle"
        composerToggle.accessibilityLabel = "Composer"
        composerToggle.addAction(UIAction { [weak self] _ in self?.toggleComposer() }, for: .touchUpInside)
        snippetsToggle.accessibilityIdentifier = "keybar-snippets"
        snippetsToggle.accessibilityLabel = "Snippets"
        snippetsToggle.addAction(UIAction { [weak self] _ in self?.toggleSnippets() }, for: .touchUpInside)
        hideKeyboard.configuration = style.button(.init(title: nil, symbol: "keyboard.chevron.compact.down", active: false))
        hideKeyboard.accessibilityIdentifier = "keybar-hide-keyboard"
        hideKeyboard.accessibilityLabel = "Hide keyboard"
        hideKeyboard.addAction(UIAction { [weak self] _ in _ = self?.target?.resignFirstResponder() }, for: .touchUpInside)

        wingStack.axis = .horizontal
        wingStack.spacing = style.spacing
        // Wing keys take the stack's (key) height, like the spine keys.
        wingStack.alignment = .fill
        wingScroll.showsHorizontalScrollIndicator = false
        wingScroll.alwaysBounceHorizontal = true
        wingScroll.addSubview(wingStack)

        trailing.axis = .horizontal
        trailing.spacing = style.spacing
        trailing.alignment = .center
        for view in [arrowCluster, composerToggle, snippetsToggle, joystick, hideKeyboard] as [UIView] {
            trailing.addArrangedSubview(view)
        }

        let row = UIStackView(arrangedSubviews: [spine, wingScroll, trailing])
        row.axis = .horizontal
        row.spacing = style.spacing
        row.alignment = .center
        keyRow.addSubview(row)
        for view in [row, wingStack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        keyRowHeight = keyRow.heightAnchor.constraint(equalToConstant: style.rowHeight)
        for view in [spine, trailing] as [UIView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for button in [composerToggle, snippetsToggle, hideKeyboard] {
            buttonHeights.append(button.heightAnchor.constraint(equalToConstant: style.buttonHeight))
        }
        buttonHeights.append(wingStack.heightAnchor.constraint(equalToConstant: style.buttonHeight))
        NSLayoutConstraint.activate(buttonHeights + [
            keyRowHeight,
            row.leadingAnchor.constraint(equalTo: keyRow.leadingAnchor, constant: style.horizontalInset),
            row.trailingAnchor.constraint(equalTo: keyRow.trailingAnchor, constant: -style.horizontalInset),
            row.topAnchor.constraint(equalTo: keyRow.topAnchor),
            row.bottomAnchor.constraint(equalTo: keyRow.bottomAnchor),
            wingScroll.heightAnchor.constraint(equalTo: row.heightAnchor),
            wingStack.leadingAnchor.constraint(equalTo: wingScroll.contentLayoutGuide.leadingAnchor),
            wingStack.trailingAnchor.constraint(equalTo: wingScroll.contentLayoutGuide.trailingAnchor),
            wingStack.centerYAnchor.constraint(equalTo: wingScroll.frameLayoutGuide.centerYAnchor),
        ])
    }

    /// The profile's wing keys (hidden in the hardware-keyboard strip).
    private func rebuildWing() {
        wingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in profile.keys { wingStack.addArrangedSubview(button(for: key)) }
        wingScroll.contentOffset = .zero
    }

    private func button(for key: KeySpec) -> UIView {
        let button = FlickButton(style: style)
        button.configure(title: key.title, symbol: key.symbol, alternate: key.alternateTitle)
        button.accessibilityIdentifier = "keybar-\(key.id)"
        button.accessibilityLabel = key.accessibilityLabel
        if let alternate = key.alternateTitle {
            button.accessibilityHint = "Flick for \(alternate)"
            button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Send \(alternate)") { [weak self] _ in
                self?.send(key, alternate: true)
                return true
            }]
        }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: style.minimumButtonWidth).isActive = true
        if key.repeatable, key.alternate == nil {
            button.onDown = { [weak self] in self?.pressRepeating(key) }
            button.onUp = { [weak self] _ in self?.repeater.stop() }
            button.onCancel = { [weak self] in self?.repeater.stop() }
        } else {
            button.onUp = { [weak self] flicked in self?.send(key, alternate: flicked) }
        }
        return button
    }

    private func send(_ key: KeySpec, alternate: Bool) {
        guard let target else { return }
        let output = alternate ? (key.alternate ?? key.output) : key.output
        if lineEditor.isActive {
            // Plain characters go into the draft; ^C clears it; anything else is for the shell,
            // so the draft goes back to the shell's line first.
            switch output {
            case .text(let text, let mods) where mods.isEmpty && ctrl == .off && alt == .off:
                lineEditor.insert(text)
                return
            case .text("c", .control) where lineEditor.interrupt():
                return
            default:
                lineEditor.leaveToShell()
            }
        }
        for event in key.events(latched: takeLatchedModifiers(), alternate: alternate) { target.send(event) }
    }

    private func pressRepeating(_ key: KeySpec) {
        guard let target else { return }
        let event = key.event(latched: takeLatchedModifiers())
        target.send(event)
        var repeated = event
        repeated.action = .repeat
        repeater.start { [weak target] in target?.send(repeated) }
    }

    // MARK: Spine

    private func configureSpine() {
        spine.axis = .horizontal
        spine.spacing = style.spacing
        spine.alignment = .center

        escButton.configure(title: "esc", symbol: nil, alternate: "`")
        escButton.accessibilityIdentifier = "keybar-esc"
        escButton.accessibilityLabel = "Escape"
        escButton.onUp = { [weak self] flicked in
            guard let self else { return }
            if !flicked, lineEditor.isActive {
                lineEditor.leaveToShell()
                return
            }
            send(flicked ? .text("backtick", "`", label: "Backtick") : .esc, alternate: false)
        }

        ctrlButton.accessibilityIdentifier = "keybar-ctrl"
        ctrlButton.accessibilityLabel = "Control"
        ctrlButton.accessibilityHint = "Applies to the next key. Double-tap to lock. Flick sends Control C."
        ctrlButton.onUp = { [weak self] flicked in
            guard let self else { return }
            if flicked {
                ctrl = .off
                target?.send(.typing("c", mods: .control))
            } else {
                ctrl = Self.tapped(ctrl, last: &lastCtrlTap)
            }
        }
        ctrlButton.onLongPress = { [weak self] in self?.ctrl = .locked }

        altButton.accessibilityIdentifier = "keybar-alt"
        altButton.accessibilityLabel = "Alt"
        altButton.accessibilityHint = "Applies to the next key. Double-tap to lock. Flick sends Escape dot, the last argument."
        altButton.onUp = { [weak self] flicked in
            guard let self else { return }
            if flicked {
                alt = .off
                target?.send(.typing(".", mods: .alt))
            } else {
                alt = Self.tapped(alt, last: &lastAltTap)
            }
        }
        altButton.onLongPress = { [weak self] in self?.alt = .locked }

        tabButton.configure(title: nil, symbol: "arrow.right.to.line", alternate: "⇧⇥")
        tabButton.accessibilityIdentifier = "keybar-tab"
        tabButton.accessibilityLabel = "Tab"
        tabButton.accessibilityHint = "Flick for Shift Tab"
        tabButton.onUp = { [weak self] flicked in
            guard let self else { return }
            if !flicked, lineEditor.isActive {
                lineEditor.complete()
                return
            }
            send(flicked ? .shiftTab : .tab, alternate: false)
        }

        for button in [profileButton, escButton, ctrlButton, altButton, tabButton] {
            spine.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: style.spineKeyWidth).isActive = true
            buttonHeights.append(button.heightAnchor.constraint(equalToConstant: style.buttonHeight))
        }
        updateModifierButtons()
    }

    /// One-shot → (double-tap) locked; any other tap toggles off.
    private static func tapped(_ latch: Latch, last: inout ContinuousClock.Instant?) -> Latch {
        let now = ContinuousClock.now
        defer { last = now }
        switch latch {
        case .off: return .oneShot
        case .oneShot:
            let isDoubleTap = last.map { now - $0 < doubleTapWindow } ?? false
            return isDoubleTap ? .locked : .off
        case .locked: return .off
        }
    }

    private func updateModifierButtons() {
        ctrlButton.configure(title: "ctl", symbol: ctrl == .locked ? "lock.fill" : nil, alternate: "^C", active: ctrl != .off)
        ctrlButton.accessibilityValue = Self.describe(ctrl)
        altButton.configure(title: "alt", symbol: alt == .locked ? "lock.fill" : nil, alternate: "⎋.", active: alt != .off)
        altButton.accessibilityValue = Self.describe(alt)
        joystick.modifiers = (ctrl != .off ? "⌃" : "") + (alt != .off ? "⌥" : "")
    }

    private static func describe(_ latch: Latch) -> String {
        switch latch {
        case .off: "off"
        case .oneShot: "next key"
        case .locked: "locked"
        }
    }

    // MARK: Joystick and arrows

    private func configureJoystick() {
        joystick.accessibilityIdentifier = "keybar-joystick"
        joystick.accessibilityLabel = "Arrow keys"
        joystick.accessibilityHint = "Drag for arrows. Tap for the arrow pad."
        joystick.style = style
        joystick.onArrow = { [weak self] key, isRepeat in self?.arrow(key, isRepeat: isRepeat) }
        joystick.onTap = { [weak self] in self?.toggleArrowPad() }
        joystick.accessibilityCustomActions = [
            ("Up", PhysicalKey.arrowUp), ("Down", .arrowDown), ("Left", .arrowLeft), ("Right", .arrowRight),
        ].map { name, key in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.arrow(key, isRepeat: false)
                return true
            }
        }
        NSLayoutConstraint.activate([
            joystick.widthAnchor.constraint(equalToConstant: style.joystickWidth),
        ])
        buttonHeights.append(joystick.heightAnchor.constraint(equalToConstant: style.buttonHeight))
    }

    /// An arrow from the joystick or the arrow keys. Modifiers stay latched for the whole drag and
    /// are released when it ends, so a one-shot Ctrl turns a whole drag into word jumps.
    private func arrow(_ key: PhysicalKey, isRepeat: Bool) {
        guard let target else { return }
        if lineEditor.isActive {
            // ←/→ move the caret in the draft; ↑/↓ are the shell's history.
            if key == .arrowLeft || key == .arrowRight {
                lineEditor.moveCaret(by: key == .arrowLeft ? -1 : 1)
                return
            }
            lineEditor.leaveToShell()
        }
        var mods: KeyModifiers = []
        if ctrl != .off { mods.insert(.control) }
        if alt != .off { mods.insert(.alt) }
        var event = KeyEvent.press(key, mods: mods)
        if isRepeat { event.action = .repeat }
        target.send(event)
    }

    private func configureArrowCluster() {
        arrowCluster.axis = .horizontal
        arrowCluster.spacing = 2
        for key in [KeySpec.left, .up, .down, .right] {
            let button = FlickButton(style: style)
            button.configure(title: nil, symbol: key.symbol, alternate: nil)
            button.accessibilityIdentifier = "keybar-\(key.id)"
            button.accessibilityLabel = key.accessibilityLabel
            button.onDown = { [weak self] in self?.pressRepeating(key) }
            button.onUp = { [weak self] _ in self?.repeater.stop() }
            button.onCancel = { [weak self] in self?.repeater.stop() }
            button.widthAnchor.constraint(equalToConstant: style.spineKeyWidth).isActive = true
            buttonHeights.append(button.heightAnchor.constraint(equalToConstant: style.buttonHeight))
            arrowCluster.addArrangedSubview(button)
        }
    }

    /// the joystick is tapped again.
    private func configureArrowPad() {
        arrowPad.axis = .horizontal
        arrowPad.spacing = style.spacing
        arrowPad.alignment = .center
        arrowPad.distribution = .fillEqually
        arrowPad.isLayoutMarginsRelativeArrangement = true
        arrowPad.directionalLayoutMargins = .init(top: 0, leading: style.horizontalInset, bottom: 0, trailing: style.horizontalInset)
        arrowPad.isHidden = true
        for key in [KeySpec.left, .down, .up, .right, .home, .end, .pageUp, .pageDown] {
            let button = FlickButton(style: style)
            button.configure(title: key.title, symbol: key.symbol, alternate: nil)
            button.accessibilityIdentifier = "keybar-pad-\(key.id)"
            button.accessibilityLabel = key.accessibilityLabel
            if key.repeatable {
                button.onDown = { [weak self] in self?.pressRepeating(key) }
                button.onUp = { [weak self] _ in self?.repeater.stop() }
                button.onCancel = { [weak self] in self?.repeater.stop() }
            } else {
                button.onUp = { [weak self] _ in self?.send(key, alternate: false) }
            }
            buttonHeights.append(button.heightAnchor.constraint(equalToConstant: style.buttonHeight))
            arrowPad.addArrangedSubview(button)
        }
        arrowPad.heightAnchor.constraint(equalToConstant: style.snippetRowHeight).isActive = true
    }

    private func toggleArrowPad() {
        arrowPadShown.toggle()
        apply()
    }

    // MARK: Profile

    private func configureProfileButton() {
        profileButton.accessibilityIdentifier = "keybar-profile"
        profileButton.accessibilityLabel = "Key bar profile"
        profileButton.showsMenuAsPrimaryAction = true
    }

    private func updateProfileButton() {
        let symbol = switch profile.id {
        case "claude", "codex": "sparkle"
        case "shell": "chevron.right"
        default: "keyboard"
        }
        profileButton.configuration = style.button(.init(title: nil, symbol: symbol, active: state.manual != nil, isChip: true))
        profileButton.accessibilityValue = profile.name
        let automatic = UIAction(
            title: "Automatic (\(state.detected.name))",
            state: state.manual == nil ? .on : .off
        ) { [weak self] _ in self?.choose(nil) }
        let choices = KeyBarProfile.builtIn.map { candidate in
            UIAction(title: candidate.name, state: state.manual == candidate ? .on : .off) { [weak self] _ in self?.choose(candidate) }
        }
        let panels = UIMenu(options: .displayInline, children: [
            UIAction(title: "Composer", image: UIImage(systemName: "text.bubble"), state: showsComposer(state) ? .on : .off) { [weak self] _ in
                self?.toggleComposer()
            },
            UIAction(title: "Snippets", image: UIImage(systemName: "text.append"), state: snippetsShown ? .on : .off) { [weak self] _ in
                self?.toggleSnippets()
            },
            UIAction(title: "Line Editor at Prompts", image: UIImage(systemName: "character.cursor.ibeam"), state: LineEditorController.enabled ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(!LineEditorController.enabled, forKey: LineEditorController.enabledKey)
                self?.apply()
            },
            UIAction(title: "Arrow Pad", image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"), state: arrowPadShown ? .on : .off) { [weak self] _ in
                self?.toggleArrowPad()
            },
        ] + (onDraw.map { draw in
            [UIAction(title: "Draw on Pane", image: UIImage(systemName: "pencil.and.scribble")) { _ in draw() }]
        } ?? []))
        // Narrow bars (iPhone): panels first and the key sets in a submenu, so the menu fits
        // without scrolling. Wide bars (iPad) have room for everything inline.
        let keySets = [automatic, UIMenu(options: .displayInline, children: choices)]
        // No menu title: on a menu long enough to scroll, UIKit draws the title over the first
        // rows. The checked key set says which keys are showing.
        profileButton.menu = wide
            ? UIMenu(children: keySets + [panels])
            : UIMenu(children: [
                UIMenu(title: "Key Set", subtitle: profile.name, image: UIImage(systemName: "keyboard"), children: keySets),
                panels,
            ])
    }

    private func choose(_ profile: KeyBarProfile?) {
        var state = state
        state.manual = profile
        state.composerOn = nil
        self.state = state
        apply()
    }

    // MARK: Composer

    private func toggleComposer() {
        var state = state
        state.composerOn = !showsComposer(state)
        self.state = state
        apply()
        if showsComposer(state) { composer.textView.becomeFirstResponder() }
    }

    // MARK: Snippets

    private func configureSnippetRow() {
        snippetStack.axis = .horizontal
        snippetStack.spacing = style.spacing
        snippetStack.alignment = .center
        snippetStack.translatesAutoresizingMaskIntoConstraints = false
        snippetScroll.showsHorizontalScrollIndicator = false
        snippetScroll.alwaysBounceHorizontal = true
        snippetScroll.isHidden = true
        snippetScroll.addSubview(snippetStack)
        NSLayoutConstraint.activate([
            snippetScroll.heightAnchor.constraint(equalToConstant: style.snippetRowHeight),
            snippetStack.leadingAnchor.constraint(equalTo: snippetScroll.contentLayoutGuide.leadingAnchor, constant: style.horizontalInset),
            snippetStack.trailingAnchor.constraint(equalTo: snippetScroll.contentLayoutGuide.trailingAnchor, constant: -style.horizontalInset),
            snippetStack.centerYAnchor.constraint(equalTo: snippetScroll.frameLayoutGuide.centerYAnchor),
            snippetStack.heightAnchor.constraint(equalToConstant: style.buttonHeight),
        ])
    }

    private func toggleSnippets() {
        snippetsShown.toggle()
        if snippetsShown { rebuildSnippets() }
        apply()
    }

    private func rebuildSnippets() {
        snippetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, snippet) in snippets.snippets.enumerated() {
            let button = UIButton(configuration: style.button(.init(
                title: snippet.label, symbol: snippet.sendReturn ? nil : "text.cursor", active: false)))
            button.accessibilityIdentifier = "keybar-snippet-\(index)"
            button.accessibilityLabel = snippet.sendReturn ? "Run \(snippet.label)" : "Insert \(snippet.label)"
            button.addAction(UIAction { [weak self] _ in self?.send(snippet) }, for: .touchUpInside)
            snippetStack.addArrangedSubview(button)
        }
    }

    private func send(_ snippet: Snippet) {
        if !composer.isHidden, !snippet.sendReturn {
            // Into the composer draft, for agent prompts.
            composer.text += snippet.body
            state.draft = composer.text
        } else {
            target?.sendComposedText(snippet.body, submit: snippet.sendReturn)
        }
    }
}

/// A horizontal scroller that leaves vertical drags to its buttons, so a flick on a wing key is
/// never stolen by the scroll view.
private final class HorizontalScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === panGestureRecognizer else { return super.gestureRecognizerShouldBegin(gesture) }
        let velocity = panGestureRecognizer.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
}

/// A key with an optional second glyph: tap sends the main one, a vertical flick of 12 pt or more
/// (either direction) sends the alternate. The small glyph grows while the finger travels and a
/// light haptic marks the threshold. Long-press fires `onLongPress` (latching modifiers).
private final class FlickButton: UIButton {
    static let flickDistance: CGFloat = 12
    private static let longPress = Duration.milliseconds(500)

    var onDown: (() -> Void)?
    var onUp: ((_ flicked: Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onLongPress: (() -> Void)?

    private let style: KeyBarStyle
    private let alternateLabel = UILabel()
    private var start: CGPoint = .zero
    private var flicked = false
    private var longPressTask: Task<Void, Never>?
    private var longPressed = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(style: KeyBarStyle) {
        self.style = style
        super.init(frame: .zero)
        alternateLabel.font = style.alternateFont
        alternateLabel.textColor = style.alternateColor
        alternateLabel.isUserInteractionEnabled = false
        alternateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(alternateLabel)
        NSLayoutConstraint.activate([
            alternateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            alternateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String?, symbol: String?, alternate: String?, active: Bool = false) {
        var configuration = style.button(.init(title: title, symbol: symbol, active: active))
        // Keys are narrow and carry a corner glyph: tight insets, one line, never wrapped.
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        configuration.titleLineBreakMode = .byClipping
        if let title {
            var attributes = AttributeContainer()
            attributes.font = style.keyFont
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        self.configuration = configuration
        alternateLabel.text = alternate
        alternateLabel.isHidden = alternate == nil
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        start = touch.location(in: self)
        flicked = false
        longPressed = false
        haptic.prepare()
        if let onLongPress {
            longPressTask = Task { [weak self] in
                guard (try? await Task.sleep(for: Self.longPress)) != nil, let self, !self.flicked else { return }
                longPressed = true
                haptic.impactOccurred()
                onLongPress()
            }
        }
        onDown?()
        return super.beginTracking(touch, with: event)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let travel = abs(touch.location(in: self).y - start.y)
        let armed = alternateLabel.text != nil && travel >= Self.flickDistance
        if armed != flicked {
            flicked = armed
            if armed {
                longPressTask?.cancel()
                haptic.impactOccurred()
            }
        }
        // The small glyph grows as the finger travels: progress towards the flick.
        let progress = min(travel / Self.flickDistance, 1)
        alternateLabel.transform = alternateLabel.text == nil ? .identity
            : CGAffineTransform(scaleX: 1 + progress * 0.8, y: 1 + progress * 0.8)
        return super.continueTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        longPressTask?.cancel()
        alternateLabel.transform = .identity
        // Flicks may leave the key; a plain tap must end on it.
        let inside = touch.map { bounds.insetBy(dx: -8, dy: -8).contains($0.location(in: self)) } ?? false
        if longPressed {
            onUp.map { _ in onCancel?() }
        } else if flicked || inside {
            onUp?(flicked)
        } else {
            onCancel?()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        longPressTask?.cancel()
        alternateLabel.transform = .identity
        onCancel?()
    }
}

/// zone it sends one arrow along the dominant axis, then repeats at 12/s (8–30 pt), 25/s (30–60 pt)
/// or 50/s (beyond) after 350 ms. A direction change sends one arrow at once and restarts the
/// repeat. Tracking continues across the whole bar; lifting stops before the next tick. A tap
/// (no drag) calls `onTap`.
private final class JoystickView: UIView {
    var onArrow: ((PhysicalKey, _ isRepeat: Bool) -> Void)?
    var onTap: (() -> Void)?
    var style: KeyBarStyle? {
        didSet { updateLook() }
    }
    /// The arrow pad is open (drawn active).
    var isActive = false {
        didSet { if isActive != oldValue { updateLook() } }
    }
    /// Latched modifiers shown on the joystick ("⌃", "⌥").
    var modifiers = "" {
        didSet { if modifiers != oldValue { updateLook() } }
    }

    private static let deadZone: CGFloat = 8
    private static let repeatDelay = Duration.milliseconds(350)

    private let face = UIButton()
    private var origin: CGPoint = .zero
    private var direction: PhysicalKey?
    private var distance: CGFloat = 0
    private var repeatTask: Task<Void, Never>?
    private var lastTick = ContinuousClock.now
    private let selection = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        face.isUserInteractionEnabled = false
        face.translatesAutoresizingMaskIntoConstraints = false
        addSubview(face)
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: leadingAnchor),
            face.trailingAnchor.constraint(equalTo: trailingAnchor),
            face.topAnchor.constraint(equalTo: topAnchor),
            face.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateLook() {
        guard let style else { return }
        face.configuration = style.button(.init(
            title: modifiers.isEmpty ? nil : modifiers,
            symbol: "arrow.up.and.down.and.arrow.left.and.right",
            active: isActive || !modifiers.isEmpty))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        origin = touch.location(in: self)
        direction = nil
        distance = 0
        selection.prepare()
        face.isHighlighted = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        distance = max(abs(dx), abs(dy))
        guard distance >= Self.deadZone else { return }
        let next: PhysicalKey = abs(dx) >= abs(dy) ? (dx > 0 ? .arrowRight : .arrowLeft) : (dy > 0 ? .arrowDown : .arrowUp)
        guard next != direction else { return }
        direction = next
        fire(next, isRepeat: false)
        startRepeating()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasTap = direction == nil
        stop()
        if wasTap { onTap?() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        stop()
    }

    private func stop() {
        repeatTask?.cancel()
        repeatTask = nil
        direction = nil
        face.isHighlighted = false
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.repeatDelay)) != nil else { return }
            while let self, !Task.isCancelled, let direction = self.direction {
                fire(direction, isRepeat: true)
                let rate: Double = distance < 30 ? 12 : distance < 60 ? 25 : 50
                guard (try? await Task.sleep(for: .milliseconds(Int(1000 / rate)))) != nil else { return }
            }
        }
    }

    private func fire(_ key: PhysicalKey, isRepeat: Bool) {
        onArrow?(key, isRepeat)
        // A selection tick at most every 66 ms (15 Hz), never per key at 50/s.
        let now = ContinuousClock.now
        if now - lastTick >= .milliseconds(66) {
            selection.selectionChanged()
            lastTick = now
        }
    }
}
#endif
