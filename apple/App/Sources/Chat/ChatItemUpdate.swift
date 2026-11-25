import Foundation

/// Older history is asked for while the reader is within this many screens of the loaded top,
/// so a page lands before they reach it, even over a slow link.
nonisolated enum ChatHistoryLead {
    static let screens: CGFloat = 3
}

/// The items a collection removes and inserts to move from its rows to a frame's, keeping the
/// rows that did not move: the leading rows that kept their place and the trailing rows that
/// kept theirs, or, when older history arrived above and the newest rows left below, the one run
/// of rows in between. Indices of removals are the old rows', of insertions the new rows'.
nonisolated struct ChatItemUpdate: Equatable {
    var removed: [Int]
    var inserted: [Int]

    init(removed: [Int], inserted: [Int]) {
        self.removed = removed
        self.inserted = inserted
    }

    /// `keptOrder` leading and `keptTail` trailing rows of `old` end `new` too.
    init(old: [ChatRowID], new: [ChatRow], keptOrder: Int, keptTail: Int) {
        if keptOrder == 0, keptTail == 0, let run = Self.shiftedRun(old: old, new: new) {
            removed = Array(run.count..<old.count)
            inserted = Array(0..<run.shift) + Array((run.shift + run.count)..<new.count)
            return
        }
        let start = min(keptOrder, old.count, new.count)
        let kept = min(keptTail, old.count - start, new.count - start)
        removed = Array(start..<(old.count - kept))
        inserted = Array(start..<(new.count - kept))
    }

    /// Where the old first row now is in `new`, and how many rows from it kept their order.
    private static func shiftedRun(old: [ChatRowID], new: [ChatRow]) -> (shift: Int, count: Int)? {
        guard let first = old.first, let shift = new.firstIndex(where: { $0.id == first }), shift > 0 else { return nil }
        var count = 0
        while count < old.count, shift + count < new.count, new[shift + count].id == old[count] { count += 1 }
        return (shift, count)
    }
}
