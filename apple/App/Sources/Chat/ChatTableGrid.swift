import SwiftUI

/// A table's cells, row by row, with a rule (`chatTableRule()`) between rows: each column as
/// wide as its widest cell measures, fitted to the room by `ChatTableColumns`.
struct ChatTableGrid: Layout {
    let narrowest: CGFloat
    let limit: CGFloat
    let spacing: CGFloat
    /// The room a table has even when it is offered none, inside a sideways scroller.
    let available: CGFloat

    private struct Arrangement {
        let widths: [CGFloat]
        let rowHeights: [CGFloat]
        let ruleHeights: [CGFloat]
        let width: CGFloat
        var height: CGFloat { rowHeights.reduce(0, +) + ruleHeights.reduce(0, +) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrange(subviews, room: min(proposal.width ?? .infinity, available))
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, room: min(proposal.width ?? .infinity, available))
        var y = bounds.minY
        var row = 0
        var rule = 0
        var column = 0
        for subview in subviews {
            if subview[ChatTableRule.self] {
                if column > 0 { y += arrangement.rowHeights[row]; row += 1; column = 0 }
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: arrangement.width, height: nil))
                y += arrangement.ruleHeights[rule]
                rule += 1
                continue
            }
            guard arrangement.widths.indices.contains(column) else { continue }
            let x = bounds.minX + arrangement.widths[..<column].reduce(0, +) + spacing * CGFloat(column)
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: arrangement.widths[column], height: nil))
            column += 1
        }
    }

    private func rows(of subviews: Subviews) -> (cells: [[LayoutSubview]], rules: [LayoutSubview]) {
        var cells: [[LayoutSubview]] = [[]]
        var rules: [LayoutSubview] = []
        for subview in subviews {
            if subview[ChatTableRule.self] {
                rules.append(subview)
                if !cells[cells.count - 1].isEmpty { cells.append([]) }
            } else {
                cells[cells.count - 1].append(subview)
            }
        }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return (cells, rules)
    }

    private func arrange(_ subviews: Subviews, room: CGFloat) -> Arrangement {
        let (cells, rules) = rows(of: subviews)
        let columns = cells.map(\.count).max() ?? 0
        var natural = Array(repeating: CGFloat(0), count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() {
                natural[column] = max(natural[column], ceil(cell.sizeThatFits(.unspecified).width))
            }
        }
        let widths = ChatTableColumns.widths(natural: natural, narrowest: narrowest,
                                             limit: room.isFinite ? room : limit, spacing: spacing, available: room)
        let width = ChatTableColumns.width(of: widths, spacing: spacing)
        let rowHeights = cells.map { row in
            row.enumerated().map { column, cell in
                cell.sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
        let ruleHeights = rules.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return Arrangement(widths: widths, rowHeights: rowHeights, ruleHeights: ruleHeights, width: width)
    }
}

private nonisolated struct ChatTableRule: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Marks a view in a `ChatTableGrid` as the rule between two rows.
    func chatTableRule() -> some View { layoutValue(key: ChatTableRule.self, value: true) }
}
