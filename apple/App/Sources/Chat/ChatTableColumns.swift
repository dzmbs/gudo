import CoreGraphics
import DesignSystem
import Foundation

/// A table column is as wide as its longest cell, up to a limit past which the cell wraps.
/// On a narrow screen the widest columns give way first, down to the narrowest a column may be;
/// only a table that still does not fit scrolls sideways.
nonisolated enum ChatTableColumns {
    /// An average glyph of the callout text the cells use.
    static let characterWidth: CGFloat = 8

    static func widths(_ rows: [[AttributedString]], characterWidth: CGFloat, spacing: CGFloat = 0,
                       available: CGFloat = .infinity) -> [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        let scale = characterWidth / Self.characterWidth
        let narrowest = DS.Size.proseTableColumn * scale
        var widths = (0..<columns).map { column in
            let longest = rows.lazy.compactMap { $0.indices.contains(column) ? $0[column].characters.count : nil }.max() ?? 0
            let natural = CGFloat(longest) * characterWidth + DS.Space.xs
            return min(DS.Size.proseTableColumnMaximum * scale, max(narrowest, natural))
        }
        var excess = width(of: widths, spacing: spacing) - available
        while excess > 0.01 {
            let shrinkable = widths.filter { $0 > narrowest }
            guard let widest = shrinkable.max() else { break }
            let widestColumns = widths.indices.filter { widths[$0] == widest }
            let next = max(narrowest, shrinkable.filter { $0 < widest }.max() ?? narrowest)
            let step = min(widest - next, excess / CGFloat(widestColumns.count))
            for column in widestColumns { widths[column] -= step }
            excess -= step * CGFloat(widestColumns.count)
        }
        return widths
    }

    static func width(of columns: [CGFloat], spacing: CGFloat) -> CGFloat {
        columns.reduce(0, +) + spacing * CGFloat(max(0, columns.count - 1))
    }
}
