import Foundation

/// A review's files as one unified diff, the text `git diff` prints and `git apply` reads.
nonisolated enum UnifiedDiff {
    static func text(_ files: [DiffFile]) -> String {
        files.map(text).joined()
    }

    static func text(_ file: DiffFile) -> String {
        let oldPath = file.oldPath ?? file.path
        var lines = ["diff --git a/\(oldPath) b/\(file.path)"]
        switch file.status {
        case .added, .untracked: lines.append("new file mode 100644")
        case .deleted: lines.append("deleted file mode 100644")
        case .renamed:
            lines.append("rename from \(oldPath)")
            lines.append("rename to \(file.path)")
        case .modified: break
        }
        let isNew = file.status == .added || file.status == .untracked
        let from = isNew ? "/dev/null" : "a/\(oldPath)"
        let to = file.status == .deleted ? "/dev/null" : "b/\(file.path)"
        if file.isBinary {
            lines.append("Binary files \(from) and \(to) differ")
        } else if !file.hunks.isEmpty {
            lines.append("--- \(from)")
            lines.append("+++ \(to)")
            for hunk in file.hunks {
                lines.append(hunk.header)
                for line in hunk.lines {
                    lines.append(prefix(line.kind) + line.text)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }
}

/// Lines picked in one file of a review, from `anchor` to `head` (line ids, both included).
nonisolated struct DiffLineSelection: Hashable, Sendable {
    /// Side by side, the column the lines were picked in; nil in the unified layout.
    enum Side: Hashable, Sendable { case old, new }

    var fileId: String
    var side: Side?
    var anchor: Int
    var head: Int

    var lineIds: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }

    func contains(_ line: DiffLine, fileId: String, side: Side?) -> Bool {
        fileId == self.fileId && side == self.side && lineIds.contains(line.id) && Self.shows(line, on: side)
    }

    /// The picked lines' text, as the file has it.
    func text(in file: DiffFile) -> String {
        lines(in: file).map(\.text).joined(separator: "\n")
    }

    func lines(in file: DiffFile) -> [DiffLine] {
        file.hunks.flatMap(\.lines).filter { lineIds.contains($0.id) && Self.shows($0, on: side) }
    }

    /// A click or tap on a line's number. `extending` (⇧ on the Mac; any tap on touch while
    /// lines are picked) moves the head; a lone picked line tapped again lets go.
    static func picking(
        _ line: DiffLine, fileId: String, side: Side?, extending: Bool, current: DiffLineSelection?
    ) -> DiffLineSelection? {
        if let current, current.fileId == fileId, current.side == side {
            if current.anchor == line.id, current.head == line.id { return nil }
            if extending { return DiffLineSelection(fileId: fileId, side: side, anchor: current.anchor, head: line.id) }
        }
        return DiffLineSelection(fileId: fileId, side: side, anchor: line.id, head: line.id)
    }

    private static func shows(_ line: DiffLine, on side: Side?) -> Bool {
        switch side {
        case nil: true
        case .old: line.kind != .added
        case .new: line.kind != .removed
        }
    }
}
