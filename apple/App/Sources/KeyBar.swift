#if os(iOS)
import DesignSystem
import GameController
import HostKit
import TerminalCore
import TerminalRenderer
import UIKit
import UnnamedCore
import VoiceKit

/// floating Liquid Glass shapes over the terminal, centred on the keyboard.
///
/// ```
/// ( esc  ctrl  alt  ⇥ )   ( ~  |  /  -  ⌫  ⎘ … )   ( ← ↓ ↑ → )   (✥) (⋯) (⌄)
///   capsule A: control      capsule B: the profile    C: wide only   circles
/// ```
///
/// - Capsule A and the circles are identical in every profile; only capsule B changes, keeping
///   its place. B's keys are in priority order: a narrow bar shows the first ones (never fewer
///   than four) and the rest are under ⋯ ▸ More Keys. Nothing scrolls.
/// - A key's second character is in its long-press menu (no glyphs drawn in corners).
/// - `ctrl` and `alt` are one-shot: tap and they apply to the next key (from the bar, the software
///   keyboard or the arrows). Double-tap or long-press locks; tap again to clear.
/// - ✥ sends arrows by dragging from wherever the touch started, faster the further the finger
///   goes; tapping it opens the arrow pad (← ↓ ↑ → Home End PgUp PgDn).
/// - ⋯ holds the key set, the panels (composer, snippets, line editor, arrow pad), drawing and the
///   keys that did not fit.
/// - With a hardware keyboard (the Magic Keyboard has no Esc) only a slim `esc ⌃ ⋯` pill stays,
///   at the trailing edge; Settings can hide it or keep the full bar.
///
/// Above the capsules, on one glass card: the composer, snippets, the arrow pad and the line
/// editor, when shown. Per pane (keyed by its terminal view) the bar remembers a manual profile
/// choice, the composer on/off choice and the composer draft.
final class KeyBar: UIInputView {
    private typealias Latch = CapsuleKey.Latch

    private struct PaneState {
        var detected = KeyBarProfile.shell
        /// Set from the menu; dropped when detection picks a different profile.
        var manual: KeyBarProfile?
        /// nil follows the profile's preference.
        var composerOn: Bool?
        var draft = ""
        var profile: KeyBarProfile { manual ?? detected }
    }

    /// What the bar does with a hardware keyboard attached (Settings ▸ Keyboard).
    enum HardwareMode: String {
        case minimal, hidden, full
    }

    /// Called when the bar's height changes (rows shown or hidden), so the workspace can treat
    /// the resulting terminal resize like a keyboard slide (no cols × rows overlay).
    var onHeightChange: (() -> Void)?

    /// The focused pane's draft as it is written (composer or line editor), "" once sent or
    /// dropped: others in a shared session watch it live.
    var onDraft: ((String, Int, DraftSource) -> Void)?

    /// Opens draw mode on the focused pane; nil when the pane cannot be drawn on (no daemon).
    var onDraw: (() -> Void)? {
        didSet { updateMenu() }
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

    /// The focused pane's repository workflows: first in the snippets row, before the user's
    /// own snippets (`Model/Workflows.swift`).
    var workflows: [KeyBarWorkflow] = [] {
        didSet { if workflows != oldValue, snippetsShown { rebuildSnippets() } }
    }
    /// A workflow in the row was tapped (its id): the window types it or opens its form.
    var onWorkflow: ((String) -> Void)?
    /// The snippets row was shown: read the pane's workflows again (it may have changed
    /// directory since it was focused).
    var onSnippetsShown: (() -> Void)?

    static let hardwareModeKey = "keyBar.hardwareKeyboard"
    /// The older switch for the full bar with a hardware keyboard (UI tests pass it).
    static let fullWithHardwareKeyboardKey = "keyBar.fullWithHardwareKeyboard"
    /// Menus at least this wide list the key sets inline; narrower ones use a submenu.
    private static let wideWidth: CGFloat = 600
    private static let doubleTapWindow = Duration.milliseconds(400)

    private let style: KeyBarStyle
    private let snippets: SnippetStore
    private var paneStates: [ObjectIdentifier: PaneState] = [:]
    private var ctrl = Latch.off {
        didSet { updateModifiers() }
    }
    private var alt = Latch.off {
        didSet { updateModifiers() }
    }
    private var lastCtrlTap: ContinuousClock.Instant?
    private var lastAltTap: ContinuousClock.Instant?
    private let repeater = KeyRepeater()
    private var hardwareKeyboard = GCKeyboard.coalesced != nil
    /// The on-screen keyboard is up (its frame is taller than this bar): even with a hardware
    /// keyboard attached, it then gets the full bar.
    private var softwareKeyboardShown = false
    private var snippetsShown = false
    private var arrowPadShown = false
    private var metrics = CapsuleMetrics.for(width: 400, compactHeight: false, isPad: false)

    private let panelCard = UIVisualEffectView(effect: UIGlassEffect())
    private let column = UIStackView()
    private let composer: ComposerView
    private let lineEditor: LineEditorController
    private let snippetScroll = UIScrollView()
    private let snippetStack = UIStackView()
    private let arrowPadRow = BandView()
    private let arrowPad: CapsuleView
    private let band = BandView()
    private var bandHeight: NSLayoutConstraint!

    private let capsuleA: CapsuleView
    private let capsuleB: CapsuleView
    private let capsuleC: CapsuleView
    private let escKey: CapsuleKey
    private let ctrlKey: CapsuleKey
    private let altKey: CapsuleKey
    private let tabKey: CapsuleKey
    private let composerKey: CapsuleKey
    /// Capsule B's keys for the current profile, all of them; the visible prefix is laid out.
    private var profileKeys: [(spec: KeySpec, view: CapsuleKey)] = []
    private var visibleProfileKeys = 0
    private let joystick = JoystickView()
    private let menuButton = UIButton()
    private let hideButton = UIButton()
    private let micButton = UIButton()
    private let menuCircle: CircleView
    private let hideCircle: CircleView
    private let micCircle: CircleView

    init(style: KeyBarStyle = .default, snippets: SnippetStore = .shared) {
        self.style = style
        self.snippets = snippets
        composer = ComposerView(style: style)
        lineEditor = LineEditorController(style: style)
        let metrics = metrics
        capsuleA = CapsuleView(metrics: metrics)
        capsuleB = CapsuleView(metrics: metrics)
        capsuleC = CapsuleView(metrics: metrics)
        arrowPad = CapsuleView(metrics: metrics)
        escKey = CapsuleKey(metrics: metrics)
        ctrlKey = CapsuleKey(metrics: metrics)
        altKey = CapsuleKey(metrics: metrics)
        tabKey = CapsuleKey(metrics: metrics)
        composerKey = CapsuleKey(metrics: metrics)
        menuCircle = CircleView(content: menuButton)
        hideCircle = CircleView(content: hideButton)
        micCircle = CircleView(content: micButton)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: metrics.bandHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        // Transparent: the terminal shows through around the capsules.
        backgroundColor = .clear

        panelCard.isUserInteractionEnabled = false
        panelCard.clipsToBounds = true
        panelCard.layer.cornerRadius = 22
        panelCard.layer.cornerCurve = .continuous
        addSubview(panelCard)

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
        composer.onTextChange = { [weak self] text in
            guard let self else { return }
            state.draft = text
            let caret = composer.textView.selectedRange.location
            onDraft?(text, caret == NSNotFound ? text.count : min(caret, text.count), .composer)
        }
        column.addArrangedSubview(composer)

        configureSnippetRow()
        column.addArrangedSubview(snippetScroll)

        configureArrowPad()
        column.addArrangedSubview(arrowPadRow)

        lineEditor.onLayoutChange = { [weak self] in self?.relayout() }
        lineEditor.onDraft = { [weak self] text, caret in self?.onDraft?(text, caret, .lineEditor) }
        column.insertArrangedSubview(lineEditor.decisionStrip, at: 1)
        column.addArrangedSubview(lineEditor.smartRow)
        column.addArrangedSubview(lineEditor.editorRow)

        configureBand()
        column.addArrangedSubview(band)

        keyboardObservers = [.GCKeyboardDidConnect, .GCKeyboardDidDisconnect].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardsChanged() }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Posted on the writing thread, which need not be main.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        applyTheme()
        apply()
    }

    /// The terminal theme's scheme, ink and accent (`KeyBarTheme`): the bar floats over the
    /// terminal, so it reads as part of it whatever the window's chrome does. The ink is baked
    /// into the keys' configurations and the joystick, so a new theme redraws them.
    private func applyTheme() {
        let chrome = KeyBarTheme.chrome
        guard chrome != appliedTheme else { return }
        appliedTheme = chrome
        overrideUserInterfaceStyle = KeyBarTheme.style
        tintColor = KeyBarTheme.accent
        for case let key as UIButton in allSubviews(of: self) { key.setNeedsUpdateConfiguration() }
        configureCircles()
        joystick.applyInk()
    }

    private var appliedTheme: ChromePalette?
    private var settingsObserver: NSObjectProtocol?
    private var keyboardObservers: [NSObjectProtocol] = []

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let next = CapsuleMetrics.for(
            width: bounds.width,
            compactHeight: traitCollection.verticalSizeClass == .compact,
            isPad: traitCollection.userInterfaceIdiom == .pad)
        if next != metrics {
            metrics = next
            applyMetrics()
        }
        layoutPanelCard()
    }

    /// What runs in the focused pane; picks the key set.
    func update(context: KeyBarContext) {
        guard let target else { return }
        let detected = KeyBarProfile.match(context)
        let id = ObjectIdentifier(target)
        var state = paneStates[id, default: PaneState()]
        if detected != state.detected {
            // A different program took over: its own keys and composer default apply again.
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

    private var hardwareMode: HardwareMode {
        if UserDefaults.standard.bool(forKey: Self.fullWithHardwareKeyboardKey) { return .full }
        return UserDefaults.standard.string(forKey: Self.hardwareModeKey).flatMap(HardwareMode.init) ?? .minimal
    }

    /// The slim pill (hardware keyboard, minimal), or nothing (hidden). Only while no on-screen
    /// keyboard shows: someone who brings it up with a Magic Keyboard attached types on it.
    private var compact: Bool {
        hardwareKeyboard && !softwareKeyboardShown && hardwareMode != .full
    }

    /// The composer shows where the user turned it on, else for agents on the software keyboard
    /// only: with a hardware keyboard the terminal takes the typing.
    private func showsComposer(_ state: PaneState) -> Bool {
        state.composerOn ?? (state.profile.prefersComposer && !compact)
    }

    private var isAgent: Bool { profile.id == "claude" || profile.id == "codex" }

    /// Brings the views in line with the focused pane's state.
    private func apply() {
        let state = state
        let profileChanged = profile != state.profile || profileKeys.isEmpty
        profile = state.profile
        lineEditor.shellProfile = profile.id == "shell" && !showsComposer(state)
        lineEditor.agentProfile = isAgent
        if profileChanged { rebuildProfileKeys() }
        if composer.text != state.draft { composer.text = state.draft }
        composer.isHidden = !showsComposer(state)
        composerKey.isOn = showsComposer(state)
        composerKey.accessibilityValue = showsComposer(state) ? "on" : "off"
        snippetScroll.isHidden = !snippetsShown || compact
        arrowPadRow.isHidden = !arrowPadShown || compact
        joystick.isActive = arrowPadShown
        if compact {
            ctrl = .off
            alt = .off
        }
        bandHeight.constant = compact
            ? (hardwareMode == .hidden ? 0 : metrics.pillHeight + 12)
            : metrics.bandHeight
        updateMenu()
        layoutBand()
        relayout()
    }

    private func applyMetrics() {
        for capsule in [capsuleA, capsuleB, capsuleC, arrowPad] { capsule.metrics = metrics }
        for key in [escKey, ctrlKey, altKey, tabKey, composerKey] + profileKeys.map(\.view) { key.metrics = metrics }
        for case let key as CapsuleKey in capsuleC.keys + arrowPad.keys { key.metrics = metrics }
        joystick.diameter = metrics.capsuleHeight
        configureCircles()
        apply()
    }

    private func configureCircles() {
        menuButton.configuration = circleConfiguration(symbol: "ellipsis")
        hideButton.configuration = circleConfiguration(symbol: "keyboard.chevron.compact.down")
        updateMic()
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

    /// The keyboard frame includes this bar; anything much taller is the on-screen keyboard
    /// (a hardware keyboard leaves only the bar, or the bar and the shortcuts strip).
    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = window?.windowScene?.screen ?? (note.object as? UIScreen) ?? window?.screen else { return }
        let visible = frame.intersection(screen.bounds).height
        let shown = visible - bounds.height > 120
        guard shown != softwareKeyboardShown else { return }
        softwareKeyboardShown = shown
        apply()
    }

    /// The panels above the capsules share one glass card.
    private func layoutPanelCard() {
        let panels: [UIView] = [composer, lineEditor.decisionStrip, snippetScroll, arrowPadRow, lineEditor.smartRow, lineEditor.editorRow]
        let frames = panels.filter { !$0.isHidden && $0.superview != nil && $0.bounds.height > 0 && $0 !== arrowPadRow }
            .map { $0.convert($0.bounds, to: self) }
        guard let first = frames.first else {
            panelCard.isHidden = true
            return
        }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        panelCard.isHidden = false
        panelCard.frame = union.insetBy(dx: metrics.margin - 4, dy: 0)
    }

    // MARK: The band

    private func configureBand() {
        bandHeight = band.heightAnchor.constraint(equalToConstant: metrics.bandHeight)
        bandHeight.isActive = true
        band.onLayout = { [weak self] in self?.layoutBand() }

        escKey.title = "esc"
        escKey.accessibilityIdentifier = "keybar-esc"
        escKey.accessibilityLabel = "Escape"
        escKey.onTap = { [weak self] in
            guard let self else { return }
            if lineEditor.isActive {
                lineEditor.leaveToShell()
                return
            }
            send(.esc)
        }
        escKey.menu = UIMenu(children: [
            UIAction(title: "Escape Twice") { [weak self] _ in self?.send(.rewind) },
            UIAction(title: "Backtick `") { [weak self] _ in self?.send(.text("backtick", "`", label: "Backtick")) },
        ])

        ctrlKey.title = "ctrl"
        ctrlKey.accessibilityIdentifier = "keybar-ctrl"
        ctrlKey.accessibilityLabel = "Control"
        ctrlKey.accessibilityHint = "Applies to the next key. Double-tap to lock."
        ctrlKey.onTap = { [weak self] in
            guard let self else { return }
            ctrl = Self.tapped(ctrl, last: &lastCtrlTap)
            haptic(for: ctrl)
        }

        altKey.title = "alt"
        altKey.accessibilityIdentifier = "keybar-alt"
        altKey.accessibilityLabel = "Option"
        altKey.accessibilityHint = "Applies to the next key. Double-tap to lock."
        altKey.onTap = { [weak self] in
            guard let self else { return }
            alt = Self.tapped(alt, last: &lastAltTap)
            haptic(for: alt)
        }
        altKey.menu = UIMenu(children: [
            UIAction(title: "Lock Option", image: UIImage(systemName: "lock")) { [weak self] _ in self?.alt = .locked },
        ])

        tabKey.symbol = "arrow.right.to.line"
        tabKey.accessibilityIdentifier = "keybar-tab"
        tabKey.accessibilityLabel = "Tab"
        tabKey.onTap = { [weak self] in
            guard let self else { return }
            if lineEditor.isActive {
                lineEditor.complete()
                return
            }
            send(.tab)
        }
        tabKey.menu = UIMenu(children: [
            UIAction(title: "Shift Tab", image: UIImage(systemName: "arrow.left.to.line")) { [weak self] _ in self?.send(.shiftTab) },
        ])
        updateModifiers()

        composerKey.symbol = "text.bubble"
        composerKey.accessibilityIdentifier = "keybar-composer-toggle"
        composerKey.accessibilityLabel = "Composer"
        composerKey.onTap = { [weak self] in self?.toggleComposer() }

        for key in [KeySpec.left, .down, .up, .right] {
            let view = keyCap(for: key, idPrefix: "keybar-")
            capsuleC.setKeys(capsuleC.keys + [view])
        }

        joystick.accessibilityIdentifier = "keybar-joystick"
        joystick.accessibilityLabel = "Arrow keys"
        joystick.accessibilityHint = "Drag for arrows. Tap for the arrow pad."
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

        menuButton.accessibilityIdentifier = "keybar-profile"
        menuButton.accessibilityLabel = "Keys and panels"
        menuButton.showsMenuAsPrimaryAction = true
        hideButton.accessibilityIdentifier = "keybar-hide-keyboard"
        hideButton.accessibilityLabel = "Hide keyboard"
        hideButton.addAction(UIAction { [weak self] _ in _ = self?.target?.resignFirstResponder() }, for: .touchUpInside)

        configureMic()
        for view in [capsuleA, capsuleB, capsuleC, micCircle, joystick, menuCircle, hideCircle] as [UIView] { band.addSubview(view) }
    }

    private func circleConfiguration(symbol: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: metrics.symbolConfiguration)
        configuration.baseForegroundColor = KeyBarTheme.ink.withAlphaComponent(0.9)
        configuration.contentInsets = .zero
        return configuration
    }

    /// Places the capsules and circles, centred, from the current metrics and profile.
    private func layoutBand() {
        let width = band.bounds.width
        guard width > 0 else { return }
        let m = metrics
        let h = m.capsuleHeight
        if compact {
            layoutPill(width: width)
            return
        }
        let aKeys: [CapsuleKey] = [escKey, ctrlKey] + (m.showsAlt ? [altKey] : []) + [tabKey]
        let aSlots = aKeys.map { m.slotWidth(title: $0.title, symbol: $0.symbol) }
        let aWidth = CapsuleView.width(slots: aSlots, metrics: m)
        let cSlots = capsuleC.keys.map { _ in m.minimumSlot }
        let cWidth = m.showsArrowKeys ? CapsuleView.width(slots: cSlots, metrics: m) : 0
        // Hold-to-talk where there is room; narrow iPhones have the keyboard's own mic.
        let showsMic = m.showsAlt && VoiceSettings.load().isEnabled
        micCircle.isHidden = !showsMic
        let circles: [UIView] = (showsMic ? [micCircle] : []) + [joystick, menuCircle] + (m.showsAlt ? [hideCircle] : [])
        let circlesWidth = CGFloat(circles.count) * h + CGFloat(circles.count - 1) * m.gap
        let fixed = aWidth + m.gap + (m.showsArrowKeys ? cWidth + m.gap : 0) + m.gap + circlesWidth
        let budget = width - 2 * m.margin - fixed

        // Capsule B has one width per width bucket, whatever the profile, so nothing else moves
        // when the keys change: the composer toggle for agents, then the profile's keys by
        // priority while they fit (never fewer than four), spread evenly over the width.
        let nominalSlots: CGFloat = width < 500 ? 5 : width < 900 ? 8 : 10
        let bWidth = min(budget, CapsuleView.width(slots: Array(repeating: m.minimumSlot + 4, count: Int(nominalSlots)), metrics: m))
        let inner = bWidth - 2 * m.padding
        let leading: [CapsuleKey] = isAgent || showsComposer(state) ? [composerKey] : []
        var bViews: [CapsuleKey] = leading
        var natural = leading.map { m.slotWidth(title: $0.title, symbol: $0.symbol) }
        var shown = 0
        for (spec, view) in profileKeys {
            let slot = m.slotWidth(title: spec.title, symbol: spec.symbol)
            guard natural.reduce(0, +) + slot <= inner || shown < 4 else { break }
            bViews.append(view)
            natural.append(slot)
            shown += 1
        }
        if shown != visibleProfileKeys {
            visibleProfileKeys = shown
            updateMenu()
        }
        for (_, view) in profileKeys.dropFirst(shown) { view.isHidden = true }
        for view in bViews { view.isHidden = false }
        // Keys keep their natural spacing (a little extra at most); the capsule hugs them, so a
        // profile with fewer keys only narrows capsule B from its trailing side.
        let spare = min(6, max(0, inner - natural.reduce(0, +)) / CGFloat(max(natural.count, 1)))
        let bSlots = natural.map { $0 + spare }
        let bCapsule = CapsuleView.width(slots: bSlots, metrics: m)

        altKey.isHidden = !m.showsAlt
        capsuleA.setKeys(aKeys)
        capsuleB.setKeys(bViews)
        capsuleC.isHidden = !m.showsArrowKeys
        hideCircle.isHidden = !m.showsAlt
        for view in [capsuleA, capsuleB, joystick, menuCircle] as [UIView] { view.isHidden = false }

        // Centred on the nominal width, so capsule A and the circles stay put across profiles.
        let total = aWidth + m.gap + max(bWidth, bCapsule) + (m.showsArrowKeys ? m.gap + cWidth : 0) + m.gap + circlesWidth
        var x = max(m.margin, (width - total) / 2)
        let y = (band.bounds.height - h) / 2
        func place(_ view: UIView, width: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: width, height: h)
            x += width + m.gap
        }
        place(capsuleA, width: aWidth)
        capsuleA.layout(slots: aSlots)
        capsuleB.frame = CGRect(x: x, y: y, width: bCapsule, height: h)
        capsuleB.layout(slots: bSlots)
        x += max(bWidth, bCapsule) + m.gap
        if m.showsArrowKeys {
            place(capsuleC, width: cWidth)
            capsuleC.layout(slots: cSlots)
        }
        for circle in circles { place(circle, width: h) }
    }

    /// Hardware keyboard: one slim pill at the trailing edge, `esc ⌃` (+ the composer for
    /// agents) and ⋯. The Magic Keyboard has no Esc key; ⌘. sends Esc as well.
    private func layoutPill(width: CGFloat) {
        let m = metrics
        for view in [capsuleB, capsuleC, joystick, hideCircle, micCircle] as [UIView] { view.isHidden = true }
        guard hardwareMode == .minimal else {
            capsuleA.isHidden = true
            menuCircle.isHidden = true
            return
        }
        var pillMetrics = m
        pillMetrics.capsuleHeight = m.pillHeight
        pillMetrics.padding = 4
        pillMetrics.minimumSlot = 30
        let keys: [CapsuleKey] = [escKey, ctrlKey] + (isAgent ? [composerKey] : [])
        altKey.isHidden = true
        let slots = keys.map { pillMetrics.slotWidth(title: $0.title, symbol: $0.symbol) }
        let pillWidth = CapsuleView.width(slots: slots, metrics: pillMetrics)
        let h = m.pillHeight
        let y = (band.bounds.height - h) / 2
        let menuX = width - m.margin - h
        menuCircle.isHidden = false
        menuCircle.frame = CGRect(x: menuX, y: y, width: h, height: h)
        capsuleA.isHidden = false
        capsuleA.metrics = pillMetrics
        capsuleA.setKeys(keys)
        capsuleA.frame = CGRect(x: menuX - 6 - pillWidth, y: y, width: pillWidth, height: h)
        capsuleA.layout(slots: slots)
        capsuleA.metrics = m
    }

    // MARK: Keys

    /// Capsule B's views for the profile, built once per profile change (a cross-fade).
    private func rebuildProfileKeys() {
        profileKeys.forEach { $0.view.removeFromSuperview() }
        profileKeys = profile.keys.map { ($0, keyCap(for: $0, idPrefix: "keybar-")) }
        visibleProfileKeys = 0
        UIView.transition(with: capsuleB, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
                          options: .transitionCrossDissolve) { self.layoutBand() }
        UIAccessibility.post(notification: .layoutChanged, argument: profile.name)
    }

    private func keyCap(for key: KeySpec, idPrefix: String) -> CapsuleKey {
        let view = CapsuleKey(metrics: metrics)
        view.title = key.title
        view.symbol = key.symbol
        view.accessibilityIdentifier = idPrefix + key.id
        view.accessibilityLabel = key.accessibilityLabel
        if key.repeatable {
            view.onDown = { [weak self] in self?.pressRepeating(key) }
            view.onUp = { [weak self] in self?.repeater.stop() }
            view.onCancel = { [weak self] in self?.repeater.stop() }
        } else {
            view.onTap = { [weak self] in self?.send(key) }
        }
        if let alternate = key.alternate, let title = key.alternateTitle {
            view.menu = UIMenu(children: [UIAction(title: title) { [weak self] _ in self?.send(key, alternate: true) }])
            view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Send \(title)") { [weak self] _ in
                self?.send(key, alternate: true)
                return true
            }]
            _ = alternate
        }
        return view
    }

    private func send(_ key: KeySpec, alternate: Bool = false) {
        guard let target else { return }
        let output = alternate ? (key.alternate ?? key.output) : key.output
        if case .paste = output {
            target.pasteFromKeyBar()
            return
        }
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
        if lineEditor.isActive, key.id == "backspace" {
            lineEditor.leaveToShell()
        }
        let event = key.event(latched: takeLatchedModifiers())
        target.send(event)
        var repeated = event
        repeated.action = .repeat
        repeater.start { [weak target] in target?.send(repeated) }
    }

    // MARK: Voice

    /// Hold to dictate (VoiceKit, on device): the words show at the cursor while held and go in on
    /// release, without Return. Dragging off cancels.
    private func configureMic() {
        micButton.accessibilityIdentifier = "keybar-mic"
        micButton.accessibilityLabel = "Dictate"
        micButton.accessibilityHint = "Hold and speak; release to insert the words."
        let voice = VoiceDictation.shared.voice
        micButton.addAction(UIAction { _ in _ = voice.start() }, for: .touchDown)
        micButton.addAction(UIAction { _ in Task { _ = await voice.stop() } }, for: .touchUpInside)
        micButton.addAction(UIAction { _ in voice.cancel() }, for: [.touchUpOutside, .touchCancel])
        updateMic()
        observeMic()
    }

    private func updateMic() {
        let voice = VoiceDictation.shared.voice
        var configuration = circleConfiguration(symbol: voice.isActive ? "mic.fill" : "mic")
        if voice.isActive { configuration.baseForegroundColor = tintColor }
        micButton.configuration = configuration
        micButton.accessibilityValue = voice.isActive ? "Listening" : nil
    }

    private func observeMic() {
        withObservationTracking {
            _ = VoiceDictation.shared.voice.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateMic()
                self?.observeMic()
            }
        }
    }

    // MARK: Modifiers

    /// One-shot → (double-tap) locked; any other tap clears.
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

    private func haptic(for latch: Latch) {
        switch latch {
        case .oneShot: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .locked: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .off: break
        }
    }

    private func updateModifiers() {
        ctrlKey.latch = ctrl
        altKey.latch = alt
        // The key announces Latched / Locked itself; off is ours to say.
        if ctrl == .off { ctrlKey.accessibilityValue = "off" }
        if alt == .off { altKey.accessibilityValue = "off" }
        // Without an alt key (narrow bars) the ctrl menu offers Option.
        ctrlKey.menu = UIMenu(children: [
            UIAction(title: "Lock Control", image: UIImage(systemName: "lock")) { [weak self] _ in self?.ctrl = .locked },
        ] + (metrics.showsAlt ? [] : [
            UIAction(title: "Option for Next Key", image: UIImage(systemName: "option")) { [weak self] _ in self?.alt = .oneShot },
            UIAction(title: "Lock Option", image: UIImage(systemName: "lock")) { [weak self] _ in self?.alt = .locked },
        ]))
        joystick.modifiers = (ctrl != .off ? "⌃" : "") + (alt != .off ? "⌥" : "")
    }

    // MARK: Arrows

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

    /// The arrow pad: one tap per arrow, Home/End and paging, on a capsule above the band; stays
    /// open until ✥ is tapped again.
    private func configureArrowPad() {
        arrowPadRow.isHidden = true
        arrowPadRow.heightAnchor.constraint(equalToConstant: 48).isActive = true
        arrowPad.setKeys([KeySpec.left, .down, .up, .right, .home, .end, .pageUp, .pageDown].map { keyCap(for: $0, idPrefix: "keybar-pad-") })
        arrowPadRow.addSubview(arrowPad)
        arrowPadRow.onLayout = { [weak self] in
            guard let self else { return }
            let m = metrics
            let slots = arrowPad.keys.map { view in
                let key = view as? CapsuleKey
                return max(m.minimumSlot + 4, m.slotWidth(title: key?.title, symbol: key?.symbol))
            }
            let width = min(CapsuleView.width(slots: slots, metrics: m), arrowPadRow.bounds.width - 2 * m.margin)
            arrowPad.frame = CGRect(x: (arrowPadRow.bounds.width - width) / 2, y: (48 - m.capsuleHeight) / 2,
                                    width: width, height: m.capsuleHeight)
            arrowPad.layout(slots: slots)
        }
    }

    private func toggleArrowPad() {
        arrowPadShown.toggle()
        apply()
    }

    // MARK: Menu

    private func updateMenu() {
        let state = state
        menuButton.accessibilityValue = profile.name
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
        // Keys that did not fit on this width.
        let hidden = profileKeys.dropFirst(visibleProfileKeys)
        let more = hidden.isEmpty ? [] : [UIMenu(title: "More Keys", image: UIImage(systemName: "keyboard"), children: hidden.map { key, _ in
            UIAction(title: key.title ?? key.accessibilityLabel) { [weak self] _ in self?.send(key) }
        })]
        let hide = metrics.showsAlt && !compact ? [] : [UIAction(title: "Hide Keyboard", image: UIImage(systemName: "keyboard.chevron.compact.down")) { [weak self] _ in
            _ = self?.target?.resignFirstResponder()
        }]
        let keySets = [automatic, UIMenu(options: .displayInline, children: choices)]
        // No menu title: on a menu long enough to scroll, UIKit draws it over the first rows.
        menuButton.menu = bounds.width >= Self.wideWidth
            ? UIMenu(children: keySets + [panels, UIMenu(options: .displayInline, children: more + hide)])
            : UIMenu(children: [
                UIMenu(title: "Key Set", subtitle: profile.name, image: UIImage(systemName: "keyboard"), children: keySets),
                panels,
                UIMenu(options: .displayInline, children: more + hide),
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
            snippetStack.leadingAnchor.constraint(equalTo: snippetScroll.contentLayoutGuide.leadingAnchor, constant: style.horizontalInset + 8),
            snippetStack.trailingAnchor.constraint(equalTo: snippetScroll.contentLayoutGuide.trailingAnchor, constant: -style.horizontalInset - 8),
            snippetStack.centerYAnchor.constraint(equalTo: snippetScroll.frameLayoutGuide.centerYAnchor),
            snippetStack.heightAnchor.constraint(equalToConstant: style.buttonHeight),
        ])
    }

    private func toggleSnippets() {
        snippetsShown.toggle()
        if snippetsShown {
            rebuildSnippets()
            onSnippetsShown?()
        }
        apply()
    }

    private func rebuildSnippets() {
        snippetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, workflow) in workflows.enumerated() {
            let button = UIButton(configuration: style.button(.init(
                title: workflow.name, symbol: workflow.hasArguments ? "curlybraces" : "text.cursor", active: false)))
            button.accessibilityIdentifier = "keybar-workflow-\(index)"
            button.accessibilityLabel = "Workflow \(workflow.name)"
            let id = workflow.id
            button.addAction(UIAction { [weak self] _ in self?.onWorkflow?(id) }, for: .touchUpInside)
            snippetStack.addArrangedSubview(button)
        }
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

/// A plain container that reports its layout passes (frames are set by hand).
private final class BandView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    /// Touches between the shapes fall through to the terminal behind.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A glass circle around one button (⋯, ⌄).
private final class CircleView: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect())

    init(content: UIView) {
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addSubview(glass)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        for view in subviews where view !== glass { view.frame = bounds }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -6).contains(point)
    }
}

/// Past an 8 pt dead zone it sends one arrow along the dominant axis, then repeats at 12/s
/// (8–30 pt), 25/s (30–60 pt) or 50/s (beyond) after 350 ms. A direction change sends one arrow at
/// once and restarts the repeat. Tracking continues outside the circle; lifting stops before the
/// next tick. A tap (no drag) calls `onTap`. While dragging, a dot leans toward the direction.
private final class JoystickView: UIView {
    var onArrow: ((PhysicalKey, _ isRepeat: Bool) -> Void)?
    var onTap: (() -> Void)?
    var diameter: CGFloat = 40 {
        didSet { setNeedsLayout() }
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

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let icon = UIImageView()
    private let label = UILabel()
    private let dot = UIView()
    private var origin: CGPoint = .zero
    private var direction: PhysicalKey?
    private var distance: CGFloat = 0
    private var repeatTask: Task<Void, Never>?
    private var lastTick = ContinuousClock.now
    private let selection = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addSubview(glass)
        icon.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentMode = .center
        addSubview(icon)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        addSubview(label)
        dot.layer.cornerRadius = 3
        dot.isHidden = true
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        icon.frame = bounds
        label.frame = CGRect(x: 0, y: bounds.height - 14, width: bounds.width, height: 12)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -6).contains(point)
    }

    func applyInk() {
        icon.tintColor = KeyBarTheme.ink.withAlphaComponent(0.9)
        dot.backgroundColor = KeyBarTheme.ink
    }

    private func updateLook() {
        label.text = modifiers
        glass.backgroundColor = isActive || !modifiers.isEmpty ? tintColor.withAlphaComponent(0.22) : .clear
        accessibilityValue = isActive ? "Arrow pad open" : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        origin = touch.location(in: self)
        direction = nil
        distance = 0
        selection.prepare()
        icon.alpha = 0.6
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        distance = max(abs(dx), abs(dy))
        guard distance >= Self.deadZone else { return }
        let next: PhysicalKey = abs(dx) >= abs(dy) ? (dx > 0 ? .arrowRight : .arrowLeft) : (dy > 0 ? .arrowDown : .arrowUp)
        showDot(toward: next)
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

    private func showDot(toward key: PhysicalKey) {
        let offset: CGFloat = bounds.width / 2 - 8
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let point = switch key {
        case .arrowLeft: CGPoint(x: center.x - offset, y: center.y)
        case .arrowRight: CGPoint(x: center.x + offset, y: center.y)
        case .arrowUp: CGPoint(x: center.x, y: center.y - offset)
        default: CGPoint(x: center.x, y: center.y + offset)
        }
        dot.frame = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        dot.isHidden = false
    }

    private func stop() {
        repeatTask?.cancel()
        repeatTask = nil
        direction = nil
        dot.isHidden = true
        icon.alpha = 1
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
