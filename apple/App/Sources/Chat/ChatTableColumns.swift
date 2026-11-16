import CoreGraphics

/// A table column is as wide as its widest cell, measured, up to a limit past which the cell
/// wraps. On a narrow screen the widest columns give way first, down to the narrowest a column
/// may be; only a table that still does not fit scrolls sideways.
nonisolated enum ChatTableColumns {
    static func widths(natural: [CGFloat], narrowest: CGFloat, limit: CGFloat, spacing: CGFloat = 0,
                       available: CGFloat = .infinity) -> [CGFloat] {
        var widths = natural.map { min(max(narrowest, limit), max(narrowest, $0)) }
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
