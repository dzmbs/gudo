import HostKit

nonisolated struct ChatInlineDiff: Equatable, Sendable {
    let file: DiffFile
    let bytes: Int

    init?(tool: TimelineTool, item: String) {
        guard var file = tool.diff.first, !file.binary, var hunk = file.hunks.first else { return nil }
        hunk.lines = hunk.lines.prefix(6).map { line in
            var line = line
            if !line.text.unicodeScalars.dropFirst(512).isEmpty {
                line.text = String(String.UnicodeScalarView(line.text.unicodeScalars.prefix(512))) + "…"
            }
            return line
        }
        file.hunks = [hunk]
        file.hunksOmitted = true
        guard let snapshot = try? ChatDiffSnapshot(groups: [ChatToolDiff(item: item, files: [file])]),
              let converted = snapshot.files.first else { return nil }
        self.file = converted
        bytes = 1_024 + 2 * (converted.path.utf8.count + (converted.oldPath?.utf8.count ?? 0)
                            + converted.id.utf8.count + hunk.header.utf8.count)
            + hunk.lines.reduce(0) { $0 + 256 + 2 * $1.text.utf8.count }
    }
}
