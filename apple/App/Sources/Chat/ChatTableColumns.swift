import CoreGraphics
import DesignSystem
import Foundation

/// A table column is as wide as its longest cell, up to a limit past which the cell wraps.
nonisolated enum ChatTableColumns {
    /// An average glyph of the callout text the cells use.
    static let characterWidth: CGFloat = 8

    static func widths(_ rows: [[AttributedString]], characterWidth: CGFloat) -> [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        let scale = characterWidth / Self.characterWidth
        return (0..<columns).map { column in
            let longest = rows.lazy.compactMap { $0.indices.contains(column) ? $0[column].characters.count : nil }.max() ?? 0
            let natural = CGFloat(longest) * characterWidth + DS.Space.xs
            return min(DS.Size.proseTableColumnMaximum * scale, max(DS.Size.proseTableColumn * scale, natural))
        }
    }
}
