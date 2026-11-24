import HostKit

/// The rows Chat shows, folded into turns and tool runs, kept between render batches. Turns are
/// independent (a fold never reaches across a prompt), so a batch that touches only the tail
/// refolds from the turn before the first item it touched: streaming costs the size of the last
/// turn, not of the timeline.
nonisolated struct ChatTimelineFold {
    struct Change {
        /// Rows before this index are the ones the previous fold had.
        let from: Int
        /// The previous fold's rows from `from` on.
        let replaced: [ChatRow]
    }

    private struct TurnStart {
        let item: Int
        let row: Int
    }

    /// More changed items than this in one batch refold everything: the search for the first
    /// one would cost more than the fold.
    static let changedItemsLimit = 256
    /// Debug builds refold everything too and check the two agree. Timing tests turn it off.
    nonisolated(unsafe) static var checksAgainstFullFold = _isDebugAssertConfiguration()

    private(set) var rows: [ChatRow] = []
    private var order: [String] = []
    private var orderIndex: [String: Int] = [:]
    private var turns: [TurnStart] = []
    private var expanded: Set<ChatRowID> = []
    private var collapses = false

    mutating func update(order next: [String], rowsOf: (String) -> [ChatRow], changed: Set<String>, removed: Set<String>,
                         resets: Bool, expanded: Set<ChatRowID>, collapses: Bool,
                         reply: (String) -> String?, previous: [ChatRowID: ChatRow]) -> Change {
        let item = firstDirtyItem(next, changed: changed, removed: removed, resets: resets,
                                  expanded: expanded, collapses: collapses)
        let turn = item == 0 ? 0 : lastTurn(atOrBefore: item - 1)
        let start = turns.isEmpty || turn == 0 ? TurnStart(item: 0, row: 0) : turns[turn]
        let replaced = Array(rows[start.row...])
        rows.removeSubrange(start.row...)
        turns.removeSubrange(min(turn, turns.count)...)
        if start.item == 0 { orderIndex.removeAll(keepingCapacity: true) }
        for index in max(start.item, start.item == 0 ? 0 : order.count)..<next.count { orderIndex[next[index]] = index }
        order = next
        self.expanded = expanded
        self.collapses = collapses

        var input: [ChatRow] = []
        for identifier in next[start.item...] { input.append(contentsOf: rowsOf(identifier)) }
        let tail = Self.fold(input, expanded: expanded, collapses: collapses, reply: reply, previous: previous)
        for (offset, row) in tail.enumerated() where ChatRowSpacing.role(of: row) == .prompt {
            let index = start.row + offset
            let follows = offset == 0 ? rows.last : tail[offset - 1]
            guard follows.map({ ChatRowSpacing.role(of: $0) != .prompt }) ?? true,
                  let itemIndex = orderIndex[row.id.item] else { continue }
            turns.append(TurnStart(item: itemIndex, row: index))
        }
        rows.append(contentsOf: tail)

        if Self.checksAgainstFullFold {
            var full: [ChatRow] = []
            for identifier in next { full.append(contentsOf: rowsOf(identifier)) }
            assert(rows == Self.fold(full, expanded: expanded, collapses: collapses, reply: reply, previous: previous),
                   "the incremental fold differs from a full one")
        }
        assert(turns.indices.dropFirst().allSatisfy { turns[$0 - 1].row < turns[$0].row }, "turns out of order")
        return Change(from: start.row, replaced: replaced)
    }

    static func fold(_ rows: [ChatRow], expanded: Set<ChatRowID>, collapses: Bool,
                     reply: (String) -> String?, previous: [ChatRowID: ChatRow]) -> [ChatRow] {
        let turns = ChatTurnCollapse.fold(rows, expanded: expanded, collapses: collapses, reply: reply, previous: previous)
        return ChatToolGroups.fold(turns, expanded: expanded, previous: previous)
    }

    /// The first index in `next` whose rows may differ from the last fold; 0 refolds everything.
    private func firstDirtyItem(_ next: [String], changed: Set<String>, removed: Set<String>, resets: Bool,
                                expanded: Set<ChatRowID>, collapses: Bool) -> Int {
        guard !resets, removed.isEmpty, changed.count <= Self.changedItemsLimit,
              expanded == self.expanded, collapses == self.collapses,
              let last = order.last, next.count >= order.count,
              next[0] == order[0], next[order.count - 1] == last else { return 0 }
        var dirty = order.count
        for identifier in changed {
            guard let index = orderIndex[identifier] else { continue }
            guard index < order.count, next[index] == identifier else { return 0 }
            dirty = min(dirty, index)
        }
        return dirty
    }

    private func lastTurn(atOrBefore item: Int) -> Int {
        var low = 0
        var high = turns.count
        while low < high {
            let middle = (low + high) / 2
            if turns[middle].item <= item { low = middle + 1 } else { high = middle }
        }
        return max(low - 1, 0)
    }
}
