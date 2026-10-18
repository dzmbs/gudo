#if os(iOS)
import TerminalCore
import TerminalRenderer
import UIKit

/// The row above the software keyboard (04-mobile-ux A1, C5): flat one-tap keys plus a sticky
/// Ctrl. Keys go through the terminal's encoder, so arrows honour application-cursor mode and the
/// kitty keyboard protocol like hardware keys do.
///
/// - Ctrl is one-shot: tap once and it applies to the next key (from the bar or the software
///   keyboard), then releases. Double-tap locks it; tap again to unlock.
/// - Arrows repeat while held: first repeat after 400 ms, then every 45 ms. A hold keeps sending
///   to the pane that was focused when it started.
final class KeyBar: UIInputView {
    /// One key: its look and the key event it sends with the latched modifiers applied.
    private struct Key {
        var id: String
        var title: String?
        var symbol: String?
        var accessibilityLabel: String
        var repeatable = false
        var event: (KeyModifiers) -> KeyEvent
    }

    private enum Latch {
        case off, oneShot, locked
    }

    /// The terminal that receives keys: the focused pane's view.
    weak var target: TerminalView?

    private var ctrl = Latch.off {
        didSet { updateCtrlButton() }
    }
    private var lastCtrlTap: ContinuousClock.Instant?
    private let repeater = KeyRepeater()
    private let ctrlButton = UIButton()

    private static let doubleTapWindow = Duration.milliseconds(350)

    /// Shell profile defaults (C5): Esc · Tab · Ctrl · ↑ ↓ ← → · ^C · ~ · | · /
    private static let leadingKeys = [
        Key(id: "esc", title: "esc", accessibilityLabel: "Escape") { .press(.escape, mods: $0) },
        Key(id: "tab", symbol: "arrow.right.to.line", accessibilityLabel: "Tab") { .press(.tab, mods: $0) },
    ]
    private static let trailingKeys = [
        Key(id: "up", symbol: "arrow.up", accessibilityLabel: "Up arrow", repeatable: true) { .press(.arrowUp, mods: $0) },
        Key(id: "down", symbol: "arrow.down", accessibilityLabel: "Down arrow", repeatable: true) { .press(.arrowDown, mods: $0) },
        Key(id: "left", symbol: "arrow.left", accessibilityLabel: "Left arrow", repeatable: true) { .press(.arrowLeft, mods: $0) },
        Key(id: "right", symbol: "arrow.right", accessibilityLabel: "Right arrow", repeatable: true) { .press(.arrowRight, mods: $0) },
        Key(id: "ctrl-c", title: "^C", accessibilityLabel: "Control C") { .typing("c", mods: $0.union(.control)) },
        Key(id: "tilde", title: "~", accessibilityLabel: "Tilde") { .typing("~", mods: $0) },
        Key(id: "pipe", title: "|", accessibilityLabel: "Pipe") { .typing("|", mods: $0) },
        Key(id: "slash", title: "/", accessibilityLabel: "Slash") { .typing("/", mods: $0) },
    ]

    init() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: isPad ? 52 : 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        Self.leadingKeys.forEach { stack.addArrangedSubview(button(for: $0)) }
        configureCtrlButton()
        stack.addArrangedSubview(ctrlButton)
        Self.trailingKeys.forEach { stack.addArrangedSubview(button(for: $0)) }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.addSubview(stack)
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: isPad ? 52 : 44),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: isPad ? 40 : 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    // MARK: Keys

    private func button(for key: Key) -> UIButton {
        let button = UIButton(configuration: Self.style(title: key.title, symbol: key.symbol, active: false))
        button.accessibilityIdentifier = "keybar-\(key.id)"
        button.accessibilityLabel = key.accessibilityLabel
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.pressBegan(key) }, for: .touchDown)
        for end: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.repeater.stop() }, for: end)
        }
        return button
    }

    private func pressBegan(_ key: Key) {
        guard let target else { return }
        let event = key.event(takeLatchedModifiers())
        target.send(event)
        guard key.repeatable else { return }
        var repeated = event
        repeated.action = .repeat
        repeater.start { [weak target] in target?.send(repeated) }
    }

    private static func style(title: String?, symbol: String?, active: Bool) -> UIButton.Configuration {
        var configuration = active ? UIButton.Configuration.prominentGlass() : .glass()
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .callout, scale: .medium))
        }
        if let title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        return configuration
    }

    // MARK: Ctrl


    private func configureCtrlButton() {
        ctrlButton.accessibilityIdentifier = "keybar-ctrl"
        ctrlButton.accessibilityLabel = "Control"
        ctrlButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
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
        var configuration = Self.style(title: "ctrl", symbol: nil, active: ctrl != .off)
        if ctrl == .locked {
            configuration.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2))
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 4
        }
        ctrlButton.configuration = configuration
        ctrlButton.accessibilityValue = switch ctrl {
        case .off: "off"
        case .oneShot: "next key"
        case .locked: "locked"
        }
    }
}
#endif
