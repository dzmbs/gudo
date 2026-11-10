#if os(iOS)
import DesignSystem
import UIKit

/// A key inside a capsule: a bare label or symbol with no fill of its own. A press shows a soft pill
/// behind it and clicks like a system key; a one-shot modifier keeps a tinted pill, a locked one a
/// solid accent pill.
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
    var latch = Latch.off {
        didSet { if latch != oldValue { setNeedsUpdateConfiguration() } }
    }
    var metrics: CapsuleMetrics {
        didSet { if metrics != oldValue { setNeedsUpdateConfiguration() } }
    }

    /// For keys that repeat while held.
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTap: (() -> Void)?

    private static let feedback = UIImpactFeedbackGenerator(style: .light)

    init(metrics: CapsuleMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            Self.feedback.impactOccurred(intensity: 0.6)
            self?.onDown?()
        }, for: .touchDown)
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
        let active = latch != .off
        let locked = latch == .locked
        configuration.baseForegroundColor = locked ? .white : KeyBarTheme.ink.withAlphaComponent(isHighlighted || active ? 1 : 0.9)
        if let title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.systemFont(ofSize: metrics.fontSize, weight: active ? .semibold : .medium)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: metrics.symbolConfiguration)
        }
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = locked ? tintColor
            : active ? tintColor.withAlphaComponent(0.28)
            : isHighlighted ? KeyBarTheme.ink.withAlphaComponent(0.14) : .clear
        background.cornerRadius = (metrics.capsuleHeight - 8) / 2
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        configuration.background = background
        self.configuration = configuration
        accessibilityTraits = active ? [.button, .selected] : .button
        switch latch {
        case .off: break
        case .oneShot: accessibilityValue = "Latched"
        case .locked: accessibilityValue = "Locked"
        }
    }
}

/// A floating Liquid Glass capsule holding keys edge to edge (no dead gaps between them). Its
/// touch area reaches 6 pt above and below, so a 40 pt capsule is a 52 pt target.
final class CapsuleView: UIView {
    private let glass = ThemedGlassView { KeyBarTheme.chrome }
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

    func setKeys(_ views: [UIView]) {
        keys.forEach { $0.removeFromSuperview() }
        keys = views
        views.forEach(addSubview)
        setNeedsLayout()
    }

    static func width(slots: [CGFloat], metrics: CapsuleMetrics) -> CGFloat {
        slots.reduce(0, +) + metrics.padding * 2
    }

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

/// The key bar's one row: a Liquid Glass capsule with the pinned keys (esc, ctrl, tab, enter) at
/// its leading end and the rest in a strip that scrolls sideways, a key cut by an edge faded while
/// more keys wait past it. Like `CapsuleView`, its touch area reaches 6 pt above and below.
final class KeyStripView: UIView, UIScrollViewDelegate {
    private static let dividerWidth: CGFloat = 9
    static let hintsShownKey = "keyBar.stripHintsShown"
    static let scrolledKey = "keyBar.stripScrolled"

    private let glass = ThemedGlassView { KeyBarTheme.chrome }
    private let divider = UIView()
    private let scrollView = KeyScrollView()
    private(set) var pinnedKeys: [CapsuleKey] = []
    private(set) var scrollingKeys: [CapsuleKey] = []
    private var pinnedSlots: [CGFloat] = []
    private var scrollingSlots: [CGFloat] = []
    private var settleIn: UIViewPropertyAnimator?
    var metrics: CapsuleMetrics

    init(metrics: CapsuleMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addSubview(glass)
        divider.isUserInteractionEnabled = false
        addSubview(divider)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.accessibilityIdentifier = "keybar-strip"
        scrollView.delegate = self
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func width(pinned: [CGFloat], scrolling: [CGFloat], metrics: CapsuleMetrics) -> CGFloat {
        let divider = pinned.isEmpty || scrolling.isEmpty ? 0 : dividerWidth
        return pinned.reduce(0, +) + divider + scrolling.reduce(0, +) + metrics.padding * 2
    }

    /// Re-parents keys only when the set changes: moving a key mid-touch would cancel the touch.
    func setKeys(pinned: [CapsuleKey], pinnedSlots: [CGFloat], scrolling: [CapsuleKey], scrollingSlots: [CGFloat]) {
        if pinned != pinnedKeys || pinned.contains(where: { $0.superview !== self }) {
            pinnedKeys.filter { $0.superview === self }.forEach { $0.removeFromSuperview() }
            pinned.forEach(addSubview)
            pinnedKeys = pinned
        }
        if scrolling != scrollingKeys || scrolling.contains(where: { $0.superview !== scrollView }) {
            scrollingKeys.filter { $0.superview === scrollView }.forEach { $0.removeFromSuperview() }
            scrolling.forEach(scrollView.addSubview)
            scrollingKeys = scrolling
        }
        self.pinnedSlots = pinnedSlots
        self.scrollingSlots = scrollingSlots
        setNeedsLayout()
    }

    func scrollToStart() {
        scrollView.setContentOffset(.zero, animated: false)
    }

    func applyInk() {
        divider.backgroundColor = KeyBarTheme.ink.withAlphaComponent(0.18)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        glass.layer.cornerCurve = .continuous
        var x = metrics.padding
        for (key, width) in zip(pinnedKeys, pinnedSlots) {
            key.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
        let hasDivider = !pinnedKeys.isEmpty && !scrollingKeys.isEmpty
        divider.isHidden = !hasDivider
        if hasDivider {
            let height = bounds.height * 0.45
            divider.frame = CGRect(x: x + (Self.dividerWidth - 1) / 2, y: (bounds.height - height) / 2, width: 1, height: height)
            x += Self.dividerWidth
        }
        let scrollFrame = CGRect(x: x, y: 0, width: max(0, bounds.width - metrics.padding - x), height: bounds.height)
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        var contentWidth: CGFloat = 0
        for (key, width) in zip(scrollingKeys, scrollingSlots) {
            key.frame = CGRect(x: contentWidth, y: 0, width: width, height: bounds.height)
            contentWidth += width
        }
        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        scrollView.alwaysBounceHorizontal = contentWidth > scrollFrame.width
        updateFade()
    }

    private var scroll: KeyStripScroll {
        KeyStripScroll(keyWidths: scrollingSlots, viewportWidth: scrollView.bounds.width)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFade()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        settleIn?.stopAnimation(true)
        settleIn = nil
        UserDefaults.standard.set(true, forKey: Self.scrolledKey)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee.x = scroll.restingOffset(near: targetContentOffset.pointee.x)
    }

    /// The first few times the bar comes up, until the user has scrolled the keys themselves, they
    /// settle in from two keys along: one motion toward the start, showing that the row moves.
    func settleInIfNeeded() {
        layoutIfNeeded()
        let defaults = UserDefaults.standard
        let hintsShown = defaults.integer(forKey: Self.hintsShownKey)
        let scroll = scroll
        guard settleIn == nil, scrollView.contentOffset.x == 0,
              scroll.showsHint(hintsShown: hintsShown, hasScrolled: defaults.bool(forKey: Self.scrolledKey),
                               reduceMotion: UIAccessibility.isReduceMotionEnabled) else { return }
        defaults.set(hintsShown + 1, forKey: Self.hintsShownKey)
        scrollView.contentOffset.x = scroll.hintOffset
        // Critically damped: no overshoot past the first key. A drag stops it where it is.
        let animator = UIViewPropertyAnimator(duration: 0.7, dampingRatio: 1) { [scrollView] in
            scrollView.contentOffset.x = 0
        }
        animator.addCompletion { [weak self] _ in self?.settleIn = nil }
        settleIn = animator
        animator.startAnimation(afterDelay: 0.15)
    }

    /// Each key fades by how far it reaches past an edge.
    private func updateFade() {
        guard scrollView.bounds.width > 0 else { return }
        let offset = scrollView.contentOffset.x
        let scroll = scroll
        for key in scrollingKeys {
            key.alpha = scroll.opacity(ofKeyFrom: key.frame.minX, to: key.frame.maxX, at: offset)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -6).contains(point)
    }

    /// A touch above, below or between keys goes to the nearest visible key.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        let clamped = CGPoint(x: point.x, y: min(max(point.y, 1), bounds.height - 1))
        if let hit = super.hitTest(clamped, with: event), hit is CapsuleKey || hit.superview is CapsuleKey { return hit }
        let visible = scrollView.convert(scrollView.bounds, to: self)
        let candidates = pinnedKeys + scrollingKeys.filter { visible.intersects(scrollView.convert($0.frame, to: self)) }
        return candidates.min {
            abs($0.convert($0.bounds, to: self).midX - point.x) < abs($1.convert($1.bounds, to: self).midX - point.x)
        } ?? scrollView
    }
}

/// A drag that starts on a key still scrolls the strip (UIKit keeps it for the key by default).
private final class KeyScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}
#endif
