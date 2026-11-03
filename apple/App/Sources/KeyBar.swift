#if os(iOS)
import DesignSystem
import GameController
import HostKit
import TerminalCore
import TerminalRenderer
import UIKit
import GudoCore
import VoiceKit

/// The keys above the software keyboard: one slim Liquid Glass row floating over the terminal.
///
/// ```
/// ( esc  ctrl  ⇥ │ ←  ↓  ↑  →  ~  |  /  -  …  Home  End  PgUp  PgDn )  (⋯)
///   pinned          scrolls sideways: arrows, the profile's keys, paging
/// ```
///
/// - `esc ctrl ⇥` (and `alt` where there is room) never move; the rest scrolls, faded at the edge
///   while more keys wait. Only the keys after the arrows change with the profile.
/// - A key's second character is in its long-press menu. Arrows and ⌫ repeat while held.
/// - `ctrl` and `alt` are one-shot: tap and they apply to the next key (from the bar, the software
///   keyboard or the arrows). Double-tap or long-press locks (solid); tap again to clear.
/// - ⋯ holds the key set, the panels (composer, snippets, line editor) and drawing.
/// - With a hardware keyboard (the Magic Keyboard has no Esc) only a slim `esc ⌃ ⋯` pill stays,
///   at the trailing edge; Settings can hide it or keep the full bar.
///
/// Above the row, on one glass card: the composer, snippets and the line editor, when shown. Per
/// pane (keyed by its terminal view) the bar remembers a manual profile choice, the composer
/// on/off choice and the composer draft.
final class KeyBar: UIInputView, UIInputViewAudioFeedback {
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
            // Focus may have crossed a fold: the bar follows it to the other page.
            setNeedsLayout()
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
    /// own snippets.
    var workflows: [KeyBarWorkflow] = [] {
        didSet { if workflows != oldValue, snippetsShown { rebuildSnippets() } }
    }
    /// A workflow in the row was tapped (its id): the window types it or opens its form.
    var onWorkflow: ((String) -> Void)?
    /// The snippets row was shown: read the pane's workflows again (it may have changed
    /// directory since it was focused).
    var onSnippetsShown: (() -> Void)?

    static let hardwareModeKey = "keyBar.hardwareKeyboard"
    /// Forces the full bar with a hardware keyboard (UI tests pass it).
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
    private var metrics = CapsuleMetrics.for(width: 400, compactHeight: false, isPad: false)

    private let panelCard = UIVisualEffectView(effect: UIGlassEffect())
    private let column = UIStackView()
    private let composer: ComposerView
    private let lineEditor: LineEditorController
    private let snippetScroll = UIScrollView()
    private let snippetStack = UIStackView()
    private let band = BandView()
    private var bandHeight: NSLayoutConstraint!
    private var columnLeading: NSLayoutConstraint!
    private var columnTrailing: NSLayoutConstraint!

    private let strip: KeyStripView
    /// The slim hardware-keyboard pill (`esc ⌃`).
    private let pill: CapsuleView
    private let escKey: CapsuleKey
    private let ctrlKey: CapsuleKey
    private let altKey: CapsuleKey
    private let tabKey: CapsuleKey
    private var arrowKeys: [CapsuleKey] = []
    private var pagingKeys: [(spec: KeySpec, view: CapsuleKey)] = []
    private var profileKeys: [(spec: KeySpec, view: CapsuleKey)] = []
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
        strip = KeyStripView(metrics: metrics)
        pill = CapsuleView(metrics: metrics)
        escKey = CapsuleKey(metrics: metrics)
        ctrlKey = CapsuleKey(metrics: metrics)
        altKey = CapsuleKey(metrics: metrics)
        tabKey = CapsuleKey(metrics: metrics)
        menuCircle = CircleView(content: menuButton)
        hideCircle = CircleView(content: hideButton)
        micCircle = CircleView(content: micButton)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: metrics.bandHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
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
        columnLeading = column.leadingAnchor.constraint(equalTo: leadingAnchor)
        columnTrailing = column.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            columnLeading,
            columnTrailing,
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
    /// into the keys' configurations and the strip's divider, so a new theme redraws them.
    private func applyTheme() {
        let chrome = KeyBarTheme.chrome
        guard chrome != appliedTheme else { return }
        appliedTheme = chrome
        overrideUserInterfaceStyle = KeyBarTheme.style
        tintColor = KeyBarTheme.accent
        for case let key as UIButton in allSubviews(of: self) { key.setNeedsUpdateConfiguration() }
        configureCircles()
        strip.applyInk()
    }

    var enableInputClicksWhenVisible: Bool { true }

    private var appliedTheme: ChromePalette?
    private var settingsObserver: NSObjectProtocol?
    private var keyboardObservers: [NSObjectProtocol] = []

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        let page = foldPage()
        if columnLeading.constant != page.minX || columnTrailing.constant != page.maxX - bounds.width {
            columnLeading.constant = page.minX
            columnTrailing.constant = page.maxX - bounds.width
        }
        super.layoutSubviews()
        let next = CapsuleMetrics.for(
            width: page.width,
            compactHeight: traitCollection.verticalSizeClass == .compact,
            isPad: traitCollection.userInterfaceIdiom == .pad)
        if next != metrics {
            metrics = next
            applyMetrics()
        }
        layoutPanelCard()
    }

    /// The span the bar uses: all of it, or across an open foldable's fold only the page under
    /// the focused terminal, so no key sits in the crease and the keys stay under the text they
    /// type into (`FoldProbe.page(containing:)`).
    private func foldPage() -> CGRect {
        guard let target, let page = FoldProbe.page(containing: target), let screen = window?.screen else { return bounds }
        let local = convert(page, from: screen.coordinateSpace)
        let span = bounds.intersection(CGRect(x: local.minX, y: bounds.minY, width: local.width, height: bounds.height))
        return span.width >= FoldLayout.minimumPage ? span : bounds
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
        var modifiers: KeyModifiers = []
        if ctrl != .off { modifiers.insert(.control) }
        if alt != .off { modifiers.insert(.alt) }
        if ctrl == .oneShot { ctrl = .off }
        if alt == .oneShot { alt = .off }
        return modifiers
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

    /// Only where the user turned it on (⋯ ▸ Composer): by default the terminal takes the typing.
    private func showsComposer(_ state: PaneState) -> Bool {
        state.composerOn ?? false
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
        snippetScroll.isHidden = !snippetsShown || compact
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
        strip.metrics = metrics
        pill.metrics = metrics
        for key in [escKey, ctrlKey, altKey, tabKey] + arrowKeys + pagingKeys.map(\.view) + profileKeys.map(\.view) {
            key.metrics = metrics
        }
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
    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = window?.windowScene?.screen ?? (notification.object as? UIScreen) ?? window?.screen else { return }
        let visible = frame.intersection(screen.bounds).height
        let shown = visible - bounds.height > 120
        guard shown != softwareKeyboardShown else { return }
        softwareKeyboardShown = shown
        apply()
    }

    /// The panels above the capsules share one glass card.
    private func layoutPanelCard() {
        // The panels' frames are the column's to set: lay it out first, or the card is drawn
        // where they were before a panel came or went.
        column.layoutIfNeeded()
        let panels: [UIView] = [composer, lineEditor.decisionStrip, snippetScroll, lineEditor.smartRow, lineEditor.editorRow]
        let frames = panels.filter { !$0.isHidden && $0.superview != nil && $0.bounds.height > 0 }
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

        arrowKeys = [(KeySpec.left, PhysicalKey.arrowLeft), (.down, .arrowDown), (.up, .arrowUp), (.right, .arrowRight)].map { spec, physical in
            let view = CapsuleKey(metrics: metrics)
            view.symbol = spec.symbol
            view.accessibilityIdentifier = "keybar-" + spec.id
            view.accessibilityLabel = spec.accessibilityLabel
            view.onDown = { [weak self] in self?.pressArrow(physical) }
            view.onUp = { [weak self] in self?.repeater.stop() }
            view.onCancel = { [weak self] in self?.repeater.stop() }
            return view
        }
        pagingKeys = [KeySpec.home, .end, .pageUp, .pageDown].map { ($0, keyCap(for: $0, idPrefix: "keybar-")) }

        menuButton.accessibilityIdentifier = "keybar-profile"
        menuButton.accessibilityLabel = "Keys and panels"
        menuButton.showsMenuAsPrimaryAction = true
        hideButton.accessibilityIdentifier = "keybar-hide-keyboard"
        hideButton.accessibilityLabel = "Hide keyboard"
        hideButton.addAction(UIAction { [weak self] _ in _ = self?.target?.resignFirstResponder() }, for: .touchUpInside)

        configureMic()
        for view in [strip, pill, micCircle, menuCircle, hideCircle] as [UIView] { band.addSubview(view) }
    }

    private func circleConfiguration(symbol: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: metrics.symbolConfiguration)
        configuration.baseForegroundColor = KeyBarTheme.ink.withAlphaComponent(0.9)
        configuration.contentInsets = .zero
        return configuration
    }

    /// Places the strip and the circles, centred, from the current metrics and profile.
    private func layoutBand() {
        let width = band.bounds.width
        guard width > 0 else { return }
        let metrics = self.metrics
        let capsuleHeight = metrics.capsuleHeight
        if compact {
            layoutPill(width: width)
            return
        }
        pill.isHidden = true
        let pinned: [CapsuleKey] = [escKey, ctrlKey] + (metrics.showsAlt ? [altKey] : []) + [tabKey]
        let profileIds = Set(profileKeys.map(\.spec.id))
        let scrolling = arrowKeys + profileKeys.map(\.view) + pagingKeys.filter { !profileIds.contains($0.spec.id) }.map(\.view)
        let pinnedSlots = pinned.map { metrics.slotWidth(title: $0.title, symbol: $0.symbol) }
        let scrollingSlots = scrolling.map { metrics.slotWidth(title: $0.title, symbol: $0.symbol) }
        altKey.isHidden = !metrics.showsAlt
        for view in scrolling { view.isHidden = false }

        // Hold-to-talk where there is room; narrow iPhones have the keyboard's own mic.
        let showsMic = metrics.showsAlt && VoiceSettings.load().isEnabled
        micCircle.isHidden = !showsMic
        hideCircle.isHidden = !metrics.showsAlt
        menuCircle.isHidden = false
        strip.isHidden = false
        let circles: [UIView] = (showsMic ? [micCircle] : []) + [menuCircle] + (metrics.showsAlt ? [hideCircle] : [])
        let circlesWidth = CGFloat(circles.count) * (capsuleHeight + metrics.gap)
        let available = width - 2 * metrics.margin - circlesWidth
        let natural = KeyStripView.width(pinned: pinnedSlots, scrolling: scrollingSlots, metrics: metrics)
        let stripWidth = min(natural, available)

        strip.setKeys(pinned: pinned, pinnedSlots: pinnedSlots, scrolling: scrolling, scrollingSlots: scrollingSlots)
        var x = max(metrics.margin, (width - stripWidth - circlesWidth) / 2)
        let y = (band.bounds.height - capsuleHeight) / 2
        strip.frame = CGRect(x: x, y: y, width: stripWidth, height: capsuleHeight)
        x += stripWidth + metrics.gap
        for circle in circles {
            circle.frame = CGRect(x: x, y: y, width: capsuleHeight, height: capsuleHeight)
            x += capsuleHeight + metrics.gap
        }
    }

    /// Hardware keyboard: one slim pill at the trailing edge, `esc ⌃` and ⋯. The Magic Keyboard
    /// has no Esc key; ⌘. sends Esc as well.
    private func layoutPill(width: CGFloat) {
        let metrics = self.metrics
        for view in [strip, hideCircle, micCircle] as [UIView] { view.isHidden = true }
        guard hardwareMode == .minimal else {
            pill.isHidden = true
            menuCircle.isHidden = true
            return
        }
        var pillMetrics = metrics
        pillMetrics.capsuleHeight = metrics.pillHeight
        pillMetrics.padding = 4
        pillMetrics.minimumSlot = 30
        let keys: [CapsuleKey] = [escKey, ctrlKey]
        let slots = keys.map { pillMetrics.slotWidth(title: $0.title, symbol: $0.symbol) }
        let pillWidth = CapsuleView.width(slots: slots, metrics: pillMetrics)
        let pillHeight = metrics.pillHeight
        let y = (band.bounds.height - pillHeight) / 2
        let menuX = width - metrics.margin - pillHeight
        menuCircle.isHidden = false
        menuCircle.frame = CGRect(x: menuX, y: y, width: pillHeight, height: pillHeight)
        pill.isHidden = false
        pill.metrics = pillMetrics
        if pill.keys != keys as [UIView] || keys.contains(where: { $0.superview !== pill }) { pill.setKeys(keys) }
        pill.frame = CGRect(x: menuX - 6 - pillWidth, y: y, width: pillWidth, height: pillHeight)
        pill.layout(slots: slots)
        pill.metrics = metrics
    }

    // MARK: Keys

    /// The profile's keys, built once per profile change (a cross-fade, back at the strip's start).
    private func rebuildProfileKeys() {
        profileKeys.forEach { $0.view.removeFromSuperview() }
        profileKeys = profile.keys.map { ($0, keyCap(for: $0, idPrefix: "keybar-")) }
        UIView.transition(with: strip, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
                          options: .transitionCrossDissolve) {
            self.layoutBand()
            self.strip.layoutIfNeeded()
            self.strip.scrollToStart()
        }
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
            case .text(let text, let modifiers) where modifiers.isEmpty && ctrl == .off && alt == .off:
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
    }

    // MARK: Arrows

    /// An arrow key went down: it takes the latched modifiers (a one-shot Ctrl turns the whole
    /// hold into word jumps) and repeats while held.
    private func pressArrow(_ key: PhysicalKey) {
        let modifiers = takeLatchedModifiers()
        sendArrow(key, modifiers: modifiers, isRepeat: false)
        repeater.start { [weak self] in self?.sendArrow(key, modifiers: modifiers, isRepeat: true) }
    }

    private func sendArrow(_ key: PhysicalKey, modifiers: KeyModifiers, isRepeat: Bool) {
        guard let target else { return }
        if lineEditor.isActive {
            // ←/→ move the caret in the draft; ↑/↓ are the shell's history.
            if key == .arrowLeft || key == .arrowRight {
                lineEditor.moveCaret(by: key == .arrowLeft ? -1 : 1)
                return
            }
            lineEditor.leaveToShell()
        }
        var event = KeyEvent.press(key, mods: modifiers)
        if isRepeat { event.action = .repeat }
        target.send(event)
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
        ] + (onDraw.map { draw in
            [UIAction(title: "Draw on Pane", image: UIImage(systemName: "pencil.and.scribble")) { _ in draw() }]
        } ?? []))
        let hide = metrics.showsAlt && !compact ? [] : [UIAction(title: "Hide Keyboard", image: UIImage(systemName: "keyboard.chevron.compact.down")) { [weak self] _ in
            _ = self?.target?.resignFirstResponder()
        }]
        let keySets = [automatic, UIMenu(options: .displayInline, children: choices)]
        // No menu title: on a menu long enough to scroll, UIKit draws it over the first rows.
        menuButton.menu = bounds.width >= Self.wideWidth
            ? UIMenu(children: keySets + [panels, UIMenu(options: .displayInline, children: hide)])
            : UIMenu(children: [
                UIMenu(title: "Key Set", subtitle: profile.name, image: UIImage(systemName: "keyboard"), children: keySets),
                panels,
                UIMenu(options: .displayInline, children: hide),
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
        if !showsComposer(state), composer.textView.isFirstResponder { target?.becomeFirstResponder() }
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
#endif
