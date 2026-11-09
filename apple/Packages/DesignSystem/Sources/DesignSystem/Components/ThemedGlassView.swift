#if canImport(UIKit)
import UIKit

/// Liquid Glass for UIKit chrome, or under Reduce Transparency the chrome's surface, opaque
/// (`GlassSurface`). Call `refresh()` when the theme changes.
public final class ThemedGlassView: UIVisualEffectView {
    private let chrome: () -> ChromePalette

    public init(chrome: @escaping () -> ChromePalette) {
        self.chrome = chrome
        super.init(effect: nil)
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc public func refresh() {
        switch GlassSurface.choose(for: chrome(), reduceTransparency: UIAccessibility.isReduceTransparencyEnabled) {
        case .glass:
            if !(effect is UIGlassEffect) { effect = UIGlassEffect() }
            backgroundColor = nil
        case .opaque(let surface):
            effect = nil
            backgroundColor = UIColor(surface.color)
        }
    }
}
#endif
