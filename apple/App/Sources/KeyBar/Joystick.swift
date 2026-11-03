#if os(iOS)
import TerminalCore
import UIKit

/// The arrow joystick, a glass circle: drag from wherever the touch starts.
/// Past an 8 pt dead zone it sends one arrow along the dominant axis, then repeats at 12/s
/// (8–30 pt), 25/s (30–60 pt) or 50/s (beyond) after 350 ms. A direction change sends one arrow at
/// once and restarts the repeat. Tracking continues outside the circle; lifting stops before the
/// next tick. A tap (no drag) calls `onTap`. While dragging, a dot leans toward the direction.
final class JoystickView: UIView {
    var onDragStart: (() -> Void)?
    var onArrow: ((PhysicalKey, _ isRepeat: Bool) -> Void)?
    var onTap: (() -> Void)?
    /// Drawn active (the keys panel is open).
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
    private var dragging = false
    private var distance: CGFloat = 0
    private var repeatTask: Task<Void, Never>?
    private var lastTick = ContinuousClock.now
    private let selection = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addSubview(glass)
        icon.contentMode = .center
        addSubview(icon)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textAlignment = .center
        addSubview(label)
        dot.layer.cornerRadius = 3
        dot.isHidden = true
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
        isMultipleTouchEnabled = false
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbolConfiguration(_ configuration: UIImage.SymbolConfiguration) {
        icon.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right", withConfiguration: configuration)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        icon.frame = bounds
        label.frame = CGRect(x: 0, y: bounds.height - 13, width: bounds.width, height: 11)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -6).contains(point)
    }

    func applyInk() {
        icon.tintColor = KeyBarTheme.ink.withAlphaComponent(0.9)
        label.textColor = KeyBarTheme.ink
        dot.backgroundColor = KeyBarTheme.ink
    }

    private func updateLook() {
        label.text = modifiers
        glass.backgroundColor = isActive || !modifiers.isEmpty ? tintColor.withAlphaComponent(0.22) : .clear
        accessibilityValue = isActive ? "Keys open" : nil
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateLook()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        origin = touch.location(in: self)
        direction = nil
        dragging = false
        distance = 0
        selection.prepare()
        icon.alpha = 0.6
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let deltaX = point.x - origin.x
        let deltaY = point.y - origin.y
        distance = max(abs(deltaX), abs(deltaY))
        guard distance >= Self.deadZone else { return }
        let next: PhysicalKey = abs(deltaX) >= abs(deltaY) ? (deltaX > 0 ? .arrowRight : .arrowLeft) : (deltaY > 0 ? .arrowDown : .arrowUp)
        showDot(toward: next)
        guard next != direction else { return }
        if !dragging {
            dragging = true
            onDragStart?()
        }
        direction = next
        fire(next, isRepeat: false)
        startRepeating()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasTap = !dragging
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
        dragging = false
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
