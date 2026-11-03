#if os(iOS)
import UIKit

/// The capsule bar's numbers, chosen by the bar's width and the window's height class, never by
/// device: a foldable's inner screen or an iPad split behaves by its size.
struct CapsuleMetrics: Equatable {
    /// The area reserved above the keyboard; transparent, the terminal shows through.
    var bandHeight: CGFloat
    /// Capsule height, also the circles' diameter.
    var capsuleHeight: CGFloat
    var padding: CGFloat
    var minimumSlot: CGFloat
    /// Added to a label's width to get its slot.
    var slotPadding: CGFloat
    var fontSize: CGFloat
    var gap: CGFloat
    var margin: CGFloat
    /// The pinned keys include `alt`.
    var showsAlt: Bool
    /// Height of the slim `esc ⌃ ⋯` pill shown with a hardware keyboard.
    var pillHeight: CGFloat = 28

    /// Width buckets: compact < 500 pt, medium 500–900, wide ≥ 900.
    static func `for`(width: CGFloat, compactHeight: Bool, isPad: Bool) -> CapsuleMetrics {
        if compactHeight, !isPad {
            return CapsuleMetrics(
                bandHeight: 44, capsuleHeight: 34, padding: 6, minimumSlot: 32, slotPadding: 16,
                fontSize: 13, gap: 8, margin: 12, showsAlt: true)
        }
        if width < 500 {
            return CapsuleMetrics(
                bandHeight: 52, capsuleHeight: 40, padding: 6, minimumSlot: 30, slotPadding: 14,
                fontSize: 13, gap: 8, margin: 12, showsAlt: false)
        }
        // A phone this wide is the iPhone Duo's inner screen: a phone's reach, a smaller key.
        let phone = !isPad && width < 900
        return CapsuleMetrics(
            bandHeight: 56, capsuleHeight: phone ? 38 : 40, padding: 8, minimumSlot: 36, slotPadding: 18,
            fontSize: phone ? 13 : 14, gap: 10, margin: 16, showsAlt: true)
    }

    var font: UIFont { .systemFont(ofSize: fontSize, weight: .medium) }
    var symbolConfiguration: UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: fontSize, weight: .medium)
    }

    func slotWidth(title: String?, symbol: String?) -> CGFloat {
        let label: CGFloat = if let title {
            ceil((title as NSString).size(withAttributes: [.font: font]).width)
        } else if symbol != nil {
            fontSize + 4
        } else {
            0
        }
        return max(minimumSlot, label + slotPadding)
    }
}
#endif
