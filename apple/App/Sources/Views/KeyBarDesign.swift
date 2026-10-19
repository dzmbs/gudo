#if os(iOS)
import DesignSystem
import UIKit

extension KeyBarStyle {
    /// The key bar as part of the iOS 26 keyboard (DesignSystem `KeyBarLook`): glass keys at the
    /// keyboard's key height and corner radius, SF Pro labels at its size, grouped spacing, the
    /// latched modifier and the profile chip as prominent glass.
    static var designSystem: KeyBarStyle {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        var style = KeyBarStyle.default
        style.rowHeight = KeyBarLook.barHeight(isPad: isPad)
        style.buttonHeight = KeyBarLook.keyHeight(isPad: isPad)
        style.minimumButtonWidth = KeyBarLook.minKeyWidth(isPad: isPad)
        style.spacing = KeyBarLook.spacing(isPad: isPad)
        style.horizontalInset = KeyBarLook.edgeInset(isPad: isPad)
        // The composer holds prose for an agent, not terminal output: SF Pro at the keyboard's size.
        style.composerFont = .systemFont(ofSize: isPad ? 17 : 16)
        style.composerCornerRadius = isPad ? 12 : 10
        style.button = { content in
            guard content.isChip else {
                return KeyBarLook.configuration(title: content.title, symbol: content.symbol, active: content.active, isPad: isPad)
            }
            var configuration = UIButton.Configuration.glass()
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            if let symbol = content.symbol {
                configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium))
                configuration.imagePadding = 4
            }
            if let title = content.title {
                var attributes = AttributeContainer()
                attributes.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
                configuration.attributedTitle = AttributedString(title, attributes: attributes)
            }
            return configuration
        }
        return style
    }
}
#endif
