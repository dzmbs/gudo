import Foundation
import HostKit

nonisolated enum ChatDiffLimits {
    static let files = 128
    static let hunks = 512
    static let rows = 20_000
    static let bytes = 2 * 1_024 * 1_024
    static let lineBytes = 8 * 1_024
    static let jsonBytes = bytes * 6 + 1_024
}

nonisolated struct ChatDiffSnapshot: Sendable {
    let files: [DiffFile]

    init(groups: [ChatToolDiff]) throws {
        var builder = Builder()
        for group in groups { try builder.append(group) }
        self = builder.snapshot
    }

    private init(files: [DiffFile]) { self.files = files }

    struct Builder: Sendable {
        private var files = 0
        private var hunks = 0
        private var bytes = 0
        private var rows = 0
        private var converted: [DiffFile] = []

        var snapshot: ChatDiffSnapshot { ChatDiffSnapshot(files: converted) }

        mutating func append(_ group: ChatToolDiff) throws {
            for (index, file) in group.files.enumerated() {
                let identity = "tool:\(group.item.utf8.count):\(group.item):\(index)"
                converted.append(try self.file(file, identity: identity))
            }
        }

        private mutating func file(_ source: TimelineFileDiff, identity: String) throws -> DiffFile {
            guard files < ChatDiffLimits.files else { throw ChatDiffError.tooLarge }
            files += 1
            try charge(2 * (source.path.utf8.count + (source.oldPath?.utf8.count ?? 0) + identity.utf8.count) + 256)
            var converted: [DiffHunk] = []
            for (index, hunk) in source.hunks.enumerated() { converted.append(try self.hunk(hunk, index: index)) }
            return DiffFile(renderIdentity: identity, path: source.path, status: try Self.status(source.change),
                            additions: Int(source.additions), deletions: Int(source.deletions), hunks: converted,
                            oldPath: source.oldPath, isBinary: source.binary, hunksOmitted: source.hunksOmitted)
        }

        private mutating func hunk(_ source: TimelineHunk, index: Int) throws -> DiffHunk {
            guard hunks < ChatDiffLimits.hunks else { throw ChatDiffError.tooLarge }
            hunks += 1
            let header = source.header.isEmpty
                ? "@@ -\(source.oldStart),\(source.oldLines) +\(source.newStart),\(source.newLines) @@" : source.header
            try charge(header.utf8.count * 2 + 128)
            var oldLine = Int(source.oldStart)
            var newLine = Int(source.newStart)
            var lines: [DiffLine] = []
            for (index, line) in source.lines.enumerated() {
                lines.append(try self.line(line, index: index, old: &oldLine, new: &newLine))
            }
            return DiffHunk(id: index, header: header, lines: lines)
        }

        private mutating func line(_ source: TimelineDiffLine, index: Int,
                                   old: inout Int, new: inout Int) throws -> DiffLine {
            guard source.text.utf8.count <= ChatDiffLimits.lineBytes else { throw ChatDiffError.tooLarge }
            try charge(source.text.utf8.count * 2 + max(128, MemoryLayout<DiffLine>.stride * 2), rows: 1)
            let kind: DiffLine.Kind
            switch source.kind {
            case .known(.context), .known(.noNewline): kind = .context
            case .known(.added): kind = .added
            case .known(.removed): kind = .removed
            case .unknown: throw ChatDiffError.unsupported
            }
            let marker = source.kind == .known(.noNewline)
            let oldNumber = kind == .added || marker ? nil : old
            let newNumber = kind == .removed || marker ? nil : new
            if oldNumber != nil { old += 1 }
            if newNumber != nil { new += 1 }
            let text = marker && source.text.isEmpty ? "\\ No newline at end of file" : source.text
            return DiffLine(id: index, kind: kind, oldNumber: oldNumber, newNumber: newNumber, text: text)
        }

        private mutating func charge(_ bytes: Int, rows: Int = 0) throws {
            guard bytes <= ChatDiffLimits.bytes - self.bytes, rows <= ChatDiffLimits.rows - self.rows else {
                throw ChatDiffError.tooLarge
            }
            self.bytes += bytes
            self.rows += rows
        }

        private static func status(_ change: TimelineFileChange) throws -> FileEntry.GitStatus {
            switch change {
            case .known(.added), .known(.copied): .added
            case .known(.deleted): .deleted
            case .known(.renamed): .renamed
            case .known(.untracked): .untracked
            case .known(.unmodified), .known(.modified), .known(.typeChanged), .known(.unmerged): .modified
            case .unknown: throw ChatDiffError.unsupported
            }
        }
    }
}

nonisolated enum ChatDiffError: Error, LocalizedError {
    case tooLarge, unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This diff is too large for Chat. Open Terminal to read it."
        case .unsupported: "This diff is not supported in Chat. Open Terminal to read it."
        }
    }
}
