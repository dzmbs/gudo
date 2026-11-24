import DesignSystem
import SwiftUI

/// Chat's type. On touch it is the chrome's own scale, so Dynamic Type applies. The Mac reads
/// Chat a step above its 13 pt body, near the phone's reading size, and leaves the chrome as it is.
nonisolated enum ChatFont {
    #if os(macOS)
    static let proseSize: CGFloat = 15
    static let prose = Font.system(size: proseSize)
    static let proseEmphasis = Font.system(size: 15, weight: .medium)
    static let proseTitle = Font.system(size: 20, weight: .semibold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let proseHeading = Font.system(size: 15, weight: .semibold)
    static let proseSecondary = Font.system(size: 14)
    static let proseSecondaryEmphasis = Font.system(size: 14, weight: .semibold)
    static let subtitle = Font.system(size: 13)
    static let button = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let captionDetail = Font.system(size: 11)
    static let meta = Font.system(size: 12).monospacedDigit()
    static let literal = Font.system(size: 14, design: .monospaced)
    static let literalSmall = Font.system(size: 12, design: .monospaced)
    #else
    static let prose = DS.Font.prose
    static let proseEmphasis = DS.Font.rowTitleEmphasis
    static let proseTitle = DS.Font.proseTitle
    static let title = DS.Font.title
    static let proseHeading = DS.Font.proseHeading
    static let proseSecondary = DS.Font.proseSecondary
    static let proseSecondaryEmphasis = DS.Font.proseSecondaryEmphasis
    static let subtitle = DS.Font.rowSubtitle
    static let button = DS.Font.button
    static let caption = DS.Font.caption
    static let captionDetail = DS.Font.captionDetail
    static let meta = DS.Font.meta
    static let literal = DS.Font.literal
    static let literalSmall = DS.Font.literalSmall
    #endif
}
