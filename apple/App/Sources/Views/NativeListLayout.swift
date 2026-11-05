import Foundation

nonisolated struct NativeListRow: Identifiable, Hashable, Sendable {
    var id: String
    var height: CGFloat
    var isHeader = false
    var scrollsHorizontally = false
    var sectionID: String?
}

nonisolated struct NativeListLayout: Sendable {
    struct Anchor: Equatable, Sendable {
        var id: String
        var sectionID: String?
        var offset: CGFloat
    }

    let revision: Int
    private(set) var rows: [NativeListRow]
    private(set) var contentWidth: CGFloat
    private(set) var positions: [CGFloat] = [0]
    private(set) var indices: [String: Int] = [:]
    private(set) var headers: [Int] = []
    var height: CGFloat { positions.last ?? 0 }

    init(rows: [NativeListRow] = [], contentWidth: CGFloat = 0) {
        self.rows = rows
        self.contentWidth = contentWidth
        var hasher = Hasher()
        hasher.combine(contentWidth)
        for (index, row) in rows.enumerated() {
            hasher.combine(row)
            indices[row.id] = index
            positions.append((positions.last ?? 0) + row.height)
            if row.isHeader { headers.append(index) }
        }
        revision = hasher.finalize()
    }

    func row(at position: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if positions[middle + 1] <= position { lower = middle + 1 } else { upper = middle }
        }
        return min(lower, rows.count - 1)
    }

    func visibleRows(in rect: CGRect) -> Range<Int> {
        guard let first = row(at: rect.minY), let last = row(at: rect.maxY) else { return 0..<0 }
        return first..<min(rows.count, last + 1)
    }

    func header(at position: CGFloat) -> Int? {
        guard let rowIndex = row(at: position) else { return nil }
        let insertion = headerInsertion(after: rowIndex)
        return insertion > 0 ? headers[insertion - 1] : nil
    }

    func nextHeaderPosition(after rowIndex: Int) -> CGFloat {
        let insertion = headerInsertion(after: rowIndex)
        return insertion < headers.count ? positions[headers[insertion]] : height
    }

    func anchor(at position: CGFloat) -> Anchor? {
        guard let index = row(at: position) else { return nil }
        let row = rows[index]
        return Anchor(id: row.id, sectionID: row.sectionID, offset: position - positions[index])
    }

    func position(of anchor: Anchor) -> CGFloat? {
        guard let index = indices[anchor.id] ?? anchor.sectionID.flatMap({ indices[$0] }) else { return nil }
        return positions[index] + min(max(0, anchor.offset), max(0, rows[index].height - 1))
    }

    private func headerInsertion(after rowIndex: Int) -> Int {
        var lower = 0
        var upper = headers.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if headers[middle] <= rowIndex { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
