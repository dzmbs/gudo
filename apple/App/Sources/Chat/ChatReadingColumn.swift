import CoreGraphics
import DesignSystem

/// Chat reads in one centred column: full width on a phone, a comfortable line length on wider screens.
nonisolated enum ChatReadingColumn {
    static let maximumWidth = DS.Size.proseReadingWidth + 2 * DS.Space.xl

    static func rowWidth(in width: CGFloat) -> CGFloat { min(width, maximumWidth) }

    static func textWidth(in width: CGFloat) -> CGFloat { rowWidth(in: width) - 2 * DS.Space.xl }
}
