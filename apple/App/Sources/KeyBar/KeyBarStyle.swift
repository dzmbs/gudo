#if os(iOS)
import UIKit

/// Everything about how the key bar looks, in one place: the design layer skins the bar by passing
/// its own `KeyBarStyle` to `KeyBar.init(style:)` instead of editing the bar.
struct KeyBarStyle {
    /// What a button shows; `active` is a latched modifier, a toggled panel, or the profile chip.
    struct ButtonContent {
        var title: String?
        var symbol: String?
        var active: Bool
        /// The profile chip (wider, shows the profile name).
        var isChip = false
    }

    var rowHeight: CGFloat
    /// The strip shown instead when a hardware keyboard is attached.
    var compactRowHeight: CGFloat
    var buttonHeight: CGFloat
    var compactButtonHeight: CGFloat
    var minimumButtonWidth: CGFloat
    /// The fixed spine keys (`esc ctl alt tab`, the profile glyph).
    var spineKeyWidth: CGFloat
    /// The small flick glyph in a key's corner.
    var alternateFont: UIFont
    /// Key labels (`esc`, `~`, `^C`): monospaced so `ctl` and `alt` line up.
    var keyFont: UIFont
    var alternateColor: UIColor
    var spacing: CGFloat
    var horizontalInset: CGFloat
    var snippetRowHeight: CGFloat

    var composerFont: UIFont
    var composerTextColor: UIColor
    var composerBackground: UIColor
    var composerCornerRadius: CGFloat
    var composerInsets: UIEdgeInsets
    /// The composer grows with its text up to this many lines, then scrolls.
    var composerMaxLines: Int

    /// Called again whenever the button's state changes.
    var button: (ButtonContent) -> UIButton.Configuration

    static var `default`: KeyBarStyle {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return KeyBarStyle(
            rowHeight: isPad ? 52 : 44,
            compactRowHeight: 28,
            buttonHeight: isPad ? 40 : 34,
            compactButtonHeight: 24,
            minimumButtonWidth: 40,
            spineKeyWidth: isPad ? 52 : 42,
            alternateFont: .monospacedSystemFont(ofSize: 10, weight: .medium),
            keyFont: .monospacedSystemFont(ofSize: isPad ? 16 : 15, weight: .medium),
            alternateColor: .secondaryLabel,
            spacing: 6,
            horizontalInset: 8,
            snippetRowHeight: isPad ? 44 : 40,
            composerFont: .monospacedSystemFont(ofSize: 15, weight: .regular),
            composerTextColor: .label,
            composerBackground: .secondarySystemBackground,
            composerCornerRadius: 10,
            composerInsets: UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8),
            composerMaxLines: 5,
            button: { content in
                var configuration = content.active ? UIButton.Configuration.prominentGlass() : .glass()
                configuration.cornerStyle = content.isChip ? .capsule : .medium
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
                if let symbol = content.symbol {
                    configuration.image = UIImage(
                        systemName: symbol,
                        withConfiguration: UIImage.SymbolConfiguration(textStyle: .callout, scale: .medium))
                    configuration.imagePadding = 4
                }
                if let title = content.title {
                    var attributes = AttributeContainer()
                    attributes.font = content.isChip
                        ? UIFont.systemFont(ofSize: 13, weight: .semibold)
                        : UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                    configuration.attributedTitle = AttributedString(title, attributes: attributes)
                }
                return configuration
            })
    }
}
#endif
