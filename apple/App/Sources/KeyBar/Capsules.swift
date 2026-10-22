#if os(iOS)
import UIKit

/// press shows a soft pill behind it; a latched modifier keeps a tinted pill, and a locked one adds
/// rootshell's underline. A long-press opens its `menu` when it has one.
final class CapsuleKey: UIButton {
    enum Latch: Equatable {
        case off, oneShot, locked
    }

    var title: String? {
        didSet { setNeedsUpdateConfiguration() }
    }
    var symbol: String? {
        didSet { setNeedsUpdateConfiguration() }
    }
    /// Modifier state (ctrl, alt): drawn and announced.
    var latch = Latch.off {
        didSet { if latch != oldValue { setNeedsUpdateConfiguration() } }
    }
    /// A toggle that is on (the composer): drawn like a latch, announced by its own value.
    var isOn = false {
        didSet { if isOn != oldValue { setNeedsUpdateConfiguration() } }
    }
    var metrics: CapsuleMetrics {
        didSet { if metrics != oldValue { setNeedsUpdateConfiguration() } }
    }

    /// Touch down / up / cancel, for keys that repeat while held.
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A tap (touch up inside, not after a menu opened).
    var onTap: (() -> Void)?

    private let underline = UIView()

    init(metrics: CapsuleMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        underline.isUserInteractionEnabled = false
        underline.layer.cornerRadius = 1
        addSubview(underline)
        addAction(UIAction { [weak self] _ in self?.onDown?() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in
            self?.onUp?()
            self?.onTap?()
        }, for: .touchUpInside)
        addAction(UIAction { [weak self] _ in self?.onUp?() }, for: .touchUpOutside)
        addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchCancel)
        configurationUpdateHandler = { button in
            guard let key = button as? CapsuleKey else { return }
            key.applyConfiguration()
        }
        isPointerInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyConfiguration() {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.titleLineBreakMode = .byClipping
        let active = latch != .off || isOn
        let label = KeyBarTheme.ink.withAlphaComponent(isHighlighted || active ? 1 : 0.9)
        configuration.baseForegroundColor = label
        if let title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.systemFont(ofSize: metrics.fontSize, weight: active ? .semibold : .medium)
            configuration.attributedTitle = AttributedString(title + (latch != .off && title == "ctrl" ? "⌃" : ""), attributes: attributes)
        }
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: metrics.symbolConfiguration)
        }
        // The pressed / latched pill, inset 4 pt inside the slot.
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = active
            ? tintColor.withAlphaComponent(0.22)
            : isHighlighted ? KeyBarTheme.ink.withAlphaComponent(0.14) : .clear
        background.cornerRadius = (metrics.capsuleHeight - 8) / 2
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        configuration.background = background
        self.configuration = configuration
        underline.backgroundColor = KeyBarTheme.ink
        underline.isHidden = latch != .locked
        accessibilityTraits = active ? [.button, .selected] : .button
        switch latch {
        case .off: break
        case .oneShot: accessibilityValue = "Latched"
        case .locked: accessibilityValue = "Locked"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width * 0.6
        underline.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 3 - 2, width: width, height: 2)
    }
}

/// A floating Liquid Glass capsule holding keys edge to edge (no dead gaps between them). Its
/// touch area reaches 6 pt above and below, so a 40 pt capsule is a 52 pt target.
final class CapsuleView: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private(set) var keys: [UIView] = []
    var metrics: CapsuleMetrics

    init(metrics: CapsuleMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the keys; `widths` are their slots, in order.
    func setKeys(_ views: [UIView]) {
        keys.forEach { $0.removeFromSuperview() }
        keys = views
        views.forEach(addSubview)
        setNeedsLayout()
    }

    /// The capsule's width for slots of these widths.
    static func width(slots: [CGFloat], metrics: CapsuleMetrics) -> CGFloat {
        slots.reduce(0, +) + metrics.padding * 2
    }

    /// Lays the keys out in slots of the given widths.
    func layout(slots: [CGFloat]) {
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        glass.layer.cornerCurve = .continuous
        var x = metrics.padding
        for (view, width) in zip(keys, slots) {
            view.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -6).contains(point)
    }

    /// A touch in the extended area or the end padding goes to the nearest key.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if let hit = super.hitTest(point, with: event), hit !== self { return hit }
        return keys.min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }
    }
}
#endif
