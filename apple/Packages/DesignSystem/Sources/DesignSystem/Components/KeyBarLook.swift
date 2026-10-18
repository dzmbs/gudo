#if os(iOS)
import UIKit

/// The look of the key bar above the software keyboard, kept here so the key bar's behaviour
/// (profiles, latching, repeat) and its look can change independently.
///
/// It reads as part of the iOS 26 keyboard: no strip behind it, keys as glass rounded rects at
/// the keyboard's own key height and corner radius, SF Pro labels at the keyboard's size, the
/// latched modifier as prominent (tinted) glass. Keys are grouped (escape and tab · modifiers ·
/// arrows · symbols) with wider gaps between groups than inside them.
public enum KeyBarLook {
    public static func barHeight(isPad: Bool) -> CGFloat { isPad ? DS.Size.keyBarPad : DS.Size.keyBarPhone }
    public static func keyHeight(isPad: Bool) -> CGFloat { isPad ? 40 : 34 }
    public static func minKeyWidth(isPad: Bool) -> CGFloat { isPad ? 52 : 40 }
    public static func spacing(isPad: Bool) -> CGFloat { isPad ? 8 : 6 }
    /// Inset of the first and last key from the bar's edges (the keyboard's own side margin).
    public static func edgeInset(isPad: Bool) -> CGFloat { isPad ? 8 : 6 }

    public static func configuration(title: String?, symbol: String?, active: Bool, isPad: Bool) -> UIButton.Configuration {
        var configuration = active ? UIButton.Configuration.prominentGlass() : .glass()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = isPad ? 10 : 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        configuration.baseForegroundColor = active ? .white : .label
        if let symbol {
            configuration.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: isPad ? 17 : 15, weight: .medium))
        }
        if let title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.systemFont(ofSize: isPad ? 17 : 16, weight: .regular)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        return configuration
    }
}
#endif
