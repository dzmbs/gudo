#if os(iOS)
import GameController
import TerminalCore
import TerminalRenderer
import UIKit

/// The bar above the software keyboard (04-mobile-ux A1, C5), from bottom to top:
/// - the key row: `[profile chip] [context keys … (scrolls)] [composer toggle] [snippets]`;
/// - the snippets row, when toggled: one chip per snippet (A1.8);
/// - the composer, when on: a multi-line text view that sends on Send / ⌘↩ (C5).
///
/// Keys come from the focused pane's profile (`KeyBarProfile`): Shell, Claude Code, Codex, Vim,
/// Pager, picked from the pane's foreground program or its title, or manually from the chip's menu.
/// Keys go through the terminal's encoder, so arrows honour application-cursor mode and the kitty
/// keyboard protocol like hardware keys do.
///
/// - Ctrl is one-shot: tap once and it applies to the next key (from the bar or the software
///   keyboard), then releases. Double-tap locks it; tap again to unlock.
/// - Arrows repeat while held: first repeat after 400 ms, then every 45 ms. A hold keeps sending
///   to the pane that was focused when it started.
/// - With a hardware keyboard attached the bar collapses to a slim strip with only what a Magic
///   Keyboard lacks: Esc, the profile chip, the composer and snippets (A15). The
///   `keyBar.fullWithHardwareKeyboard` default keeps the full row.
///
/// Per pane (keyed by its terminal view) it remembers a manual profile choice, the composer on/off
/// choice and the composer draft.
final class KeyBar: UIInputView {
    private enum Latch {
        case off, oneShot, locked
    }

    private struct PaneState {
        var detected = KeyBarProfile.shell
        /// Set from the chip's menu; dropped when detection picks a different profile.
        var manual: KeyBarProfile?
        /// nil follows the profile's preference.
        var composerOn: Bool?
        var draft = ""
        var profile: KeyBarProfile { manual ?? detected }
        var showsComposer: Bool { composerOn ?? profile.prefersComposer }
    }

    /// The terminal that receives keys: the focused pane's view.
    weak var target: TerminalView? {
        didSet {
            guard oldValue !== target else { return }
            apply()
        }
    }

    /// The active profile (for tests and the design layer).
    private(set) var profile = KeyBarProfile.shell

    static let fullWithHardwareKeyboardKey = "keyBar.fullWithHardwareKeyboard"

    private let style: KeyBarStyle
    private let snippets: SnippetStore
    private var paneStates: [ObjectIdentifier: PaneState] = [:]
    private var ctrl = Latch.off {
        didSet { updateCtrlButton() }
    }
    private var lastCtrlTap: ContinuousClock.Instant?
    private let repeater = KeyRepeater()
    private var hardwareKeyboard = GCKeyboard.coalesced != nil
    private var snippetsShown = false

    private let column = UIStackView()
    private let composer: ComposerView
    private let snippetScroll = UIScrollView()
    private let snippetStack = UIStackView()
    private let keyRow = UIView()
    private let keyScroll = UIScrollView()
    private let keyStack = UIStackView()
    private let chip = UIButton()
    private let ctrlButton = UIButton()
    private let composerToggle = UIButton()
    private let snippetsToggle = UIButton()
    private var keyRowHeight: NSLayoutConstraint!
    private var buttonHeights: [NSLayoutConstraint] = []

    private static let doubleTapWindow = Duration.milliseconds(350)

    init(style: KeyBarStyle = .default, snippets: SnippetStore = .shared) {
        self.style = style
        self.snippets = snippets
        composer = ComposerView(style: style)
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

        configureKeyRow()
        column.addArrangedSubview(keyRow)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged), name: .GCKeyboardDidDisconnect, object: nil)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
    }

    /// The latched modifiers for the next key; reading clears a one-shot Ctrl.
    func takeLatchedModifiers() -> KeyModifiers {
        switch ctrl {
        case .off: return []
        case .locked: return .control
        case .oneShot:
            ctrl = .off
            return .control
        }
    }

    // MARK: State

    private var state: PaneState {
        get { target.map { paneStates[ObjectIdentifier($0), default: PaneState()] } ?? PaneState() }
        set { if let target { paneStates[ObjectIdentifier(target)] = newValue } }
    }

    private var compact: Bool {
        hardwareKeyboard && !UserDefaults.standard.bool(forKey: Self.fullWithHardwareKeyboardKey)
    }

    /// Brings the views in line with the focused pane's state.
    private func apply() {
        let state = state
        profile = state.profile
        rebuildKeys()
        updateChip()
        if composer.text != state.draft { composer.text = state.draft }
        composer.isHidden = !state.showsComposer
        composerToggle.configuration = style.button(.init(title: nil, symbol: "text.bubble", active: state.showsComposer))
        composerToggle.accessibilityValue = state.showsComposer ? "on" : "off"
        snippetScroll.isHidden = !snippetsShown
        snippetsToggle.configuration = style.button(.init(title: nil, symbol: "text.append", active: snippetsShown))
        snippetsToggle.accessibilityValue = snippetsShown ? "shown" : "hidden"
        keyRowHeight.constant = compact ? style.compactRowHeight : style.rowHeight
        for constraint in buttonHeights { constraint.constant = compact ? style.compactButtonHeight : style.buttonHeight }
        relayout()
    }

    private func relayout() {
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
        configureChip()
        configureCtrlButton()

        composerToggle.accessibilityIdentifier = "keybar-composer-toggle"
        composerToggle.accessibilityLabel = "Composer"
        composerToggle.addAction(UIAction { [weak self] _ in self?.toggleComposer() }, for: .touchUpInside)
        snippetsToggle.accessibilityIdentifier = "keybar-snippets"
        snippetsToggle.accessibilityLabel = "Snippets"
        snippetsToggle.addAction(UIAction { [weak self] _ in self?.toggleSnippets() }, for: .touchUpInside)

        keyStack.axis = .horizontal
        keyStack.spacing = style.spacing
        keyStack.alignment = .center
        keyScroll.showsHorizontalScrollIndicator = false
        keyScroll.alwaysBounceHorizontal = true
        keyScroll.addSubview(keyStack)

        let row = UIStackView(arrangedSubviews: [chip, keyScroll, composerToggle, snippetsToggle])
        row.axis = .horizontal
        row.spacing = style.spacing
        row.alignment = .center
        keyRow.addSubview(row)
        for view in [row, keyStack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        keyRowHeight = keyRow.heightAnchor.constraint(equalToConstant: style.rowHeight)
        for button in [chip, composerToggle, snippetsToggle] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttonHeights.append(button.heightAnchor.constraint(equalToConstant: style.buttonHeight))
        }
        let stackHeight = keyStack.heightAnchor.constraint(equalToConstant: style.buttonHeight)
        buttonHeights.append(stackHeight)
        NSLayoutConstraint.activate(buttonHeights + [
            keyRowHeight,
            row.leadingAnchor.constraint(equalTo: keyRow.leadingAnchor, constant: style.horizontalInset),
            row.trailingAnchor.constraint(equalTo: keyRow.trailingAnchor, constant: -style.horizontalInset),
            row.topAnchor.constraint(equalTo: keyRow.topAnchor),
            row.bottomAnchor.constraint(equalTo: keyRow.bottomAnchor),
            keyScroll.heightAnchor.constraint(equalTo: row.heightAnchor),
            keyStack.leadingAnchor.constraint(equalTo: keyScroll.contentLayoutGuide.leadingAnchor),
            keyStack.trailingAnchor.constraint(equalTo: keyScroll.contentLayoutGuide.trailingAnchor),
            keyStack.centerYAnchor.constraint(equalTo: keyScroll.frameLayoutGuide.centerYAnchor),
        ])
    }

    /// The profile's keys (only Esc in the hardware-keyboard strip), with Ctrl at its position.
    private func rebuildKeys() {
        keyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var keys = profile.keys
        if compact { keys = keys.filter { $0.id == "esc" } }
        for (index, key) in keys.enumerated() {
            if profile.showsCtrl, !compact, index == profile.ctrlPosition { keyStack.addArrangedSubview(ctrlButton) }
            keyStack.addArrangedSubview(button(for: key))
        }
        if profile.showsCtrl, !compact, keys.count <= profile.ctrlPosition { keyStack.addArrangedSubview(ctrlButton) }
        if !profile.showsCtrl || compact { ctrl = .off }
        keyScroll.contentOffset = .zero
    }

    private func button(for key: KeySpec) -> UIButton {
        let button = UIButton(configuration: style.button(.init(title: key.title, symbol: key.symbol, active: false)))
        button.accessibilityIdentifier = "keybar-\(key.id)"
        button.accessibilityLabel = key.accessibilityLabel
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: style.minimumButtonWidth).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.pressBegan(key) }, for: .touchDown)
        for end: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.repeater.stop() }, for: end)
        }
        return button
    }

    private func pressBegan(_ key: KeySpec) {
        guard let target else { return }
        let event = key.event(latched: takeLatchedModifiers())
        target.send(event)
        guard key.repeatable else { return }
        var repeated = event
        repeated.action = .repeat
        repeater.start { [weak target] in target?.send(repeated) }
    }

    // MARK: Profile chip

    private func configureChip() {
        chip.accessibilityIdentifier = "keybar-profile"
        chip.accessibilityLabel = "Key bar profile"
        chip.showsMenuAsPrimaryAction = true
    }

    private func updateChip() {
        chip.configuration = style.button(.init(title: profile.name, symbol: nil, active: state.manual != nil, isChip: true))
        chip.accessibilityValue = profile.name
        let automatic = UIAction(
            title: "Automatic (\(state.detected.name))",
            state: state.manual == nil ? .on : .off
        ) { [weak self] _ in self?.choose(nil) }
        let choices = KeyBarProfile.builtIn.map { candidate in
            UIAction(title: candidate.name, state: state.manual == candidate ? .on : .off) { [weak self] _ in self?.choose(candidate) }
        }
        chip.menu = UIMenu(title: "Keys for", children: [automatic, UIMenu(options: .displayInline, children: choices)])
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
        state.composerOn = !state.showsComposer
        self.state = state
        apply()
        if state.showsComposer { composer.textView.becomeFirstResponder() }
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

    // MARK: Ctrl

    private func configureCtrlButton() {
        ctrlButton.accessibilityIdentifier = "keybar-ctrl"
        ctrlButton.accessibilityLabel = "Control"
        ctrlButton.widthAnchor.constraint(greaterThanOrEqualToConstant: style.minimumButtonWidth + 8).isActive = true
        ctrlButton.addAction(UIAction { [weak self] _ in self?.ctrlTapped() }, for: .touchUpInside)
        updateCtrlButton()
    }

    private func ctrlTapped() {
        let now = ContinuousClock.now
        defer { lastCtrlTap = now }
        switch ctrl {
        case .off:
            ctrl = .oneShot
        case .oneShot:
            let isDoubleTap = lastCtrlTap.map { now - $0 < Self.doubleTapWindow } ?? false
            ctrl = isDoubleTap ? .locked : .off
        case .locked:
            ctrl = .off
        }
    }

    private func updateCtrlButton() {
        var configuration = style.button(.init(title: "ctrl", symbol: ctrl == .locked ? "lock.fill" : nil, active: ctrl != .off))
        configuration.imagePlacement = .trailing
        ctrlButton.configuration = configuration
        ctrlButton.accessibilityValue = switch ctrl {
        case .off: "off"
        case .oneShot: "next key"
        case .locked: "locked"
        }
    }
}
#endif
