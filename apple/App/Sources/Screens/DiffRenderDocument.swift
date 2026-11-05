import CoreText
import Foundation

nonisolated struct DiffRenderInput: Hashable, Sendable {
    var files: [DiffFile]
    var collapsed: Set<String>
    var split: Bool
    var notes: [ReviewNote]
    var composing: NoteAnchor?
    var width: CGFloat
    var lineHeight: CGFloat = 18
    var characterWidth: CGFloat = 8
    var textSize: CGFloat = 13
}

nonisolated struct DiffRenderRow: Identifiable, Sendable {
    enum Content: Sendable {
        case summary
        case file
        case hunk(String)
        case line(DiffLine?, DiffLine?)
        case note(ReviewNote)
        case composer(NoteAnchor)
        case notice(String)
    }

    var id: String
    var fileIndex: Int?
    var content: Content
    var height: CGFloat
}

nonisolated struct DiffRenderDocument: Sendable {
    struct Anchor: Equatable, Sendable {
        var id: String
        var fileID: String?
        var offset: CGFloat
    }

    let revision = UUID()
    var input: DiffRenderInput
    private(set) var rows: [DiffRenderRow] = []
    private(set) var positions: [CGFloat] = [0]
    private(set) var indices: [String: Int] = [:]
    private(set) var headers: [Int] = []
    private(set) var contentWidth: CGFloat = 0

    var height: CGFloat { positions.last ?? 0 }

    init(input: DiffRenderInput) {
        self.input = input
        let notesByLocation = Dictionary(grouping: input.notes) { NoteLocation(path: $0.path, number: $0.startLine, oldSide: $0.oldSide) }
        var longestLine = 0
        append("summary", content: .summary, height: 88)
        for (fileIndex, file) in input.files.enumerated() {
            let prefix = "file:\(file.path)"
            headers.append(rows.count)
            append(prefix, fileIndex: fileIndex, content: .file, height: 36)
            guard !input.collapsed.contains(file.path) else { continue }
            if file.isBinary || file.hunks.isEmpty {
                let message = file.isBinary ? "Binary file not shown" : file.hunksOmitted ? "This diff is too large to show here." : "No content changes"
                append("\(prefix)/notice", fileIndex: fileIndex, content: .notice(message), height: 44)
                continue
            }
            for hunk in file.hunks {
                let hunkPrefix = "\(prefix)/hunk:\(hunk.id)"
                append(hunkPrefix, fileIndex: fileIndex, content: .hunk(hunk.header), height: 24)
                let lines = input.split ? hunk.splitRows : hunk.lines.map { SplitDiffRow(id: $0.id, left: $0, right: nil) }
                for row in lines {
                    let linePrefix = "\(hunkPrefix)/line:\(row.id)"
                    append(linePrefix, fileIndex: fileIndex, content: .line(row.left, row.right), height: input.lineHeight)
                    longestLine = max(longestLine, row.left?.text.utf16.count ?? 0, row.right?.text.utf16.count ?? 0)
                    var attachedNotes: Set<UUID> = []
                    for oldSide in [true, false] {
                        let line = input.split ? (oldSide ? row.left : row.right) : row.left
                        guard let line, let number = oldSide ? line.oldNumber : line.newNumber else { continue }
                        let location = NoteLocation(path: file.path, number: number, oldSide: oldSide)
                        for note in notesByLocation[location] ?? [] where attachedNotes.insert(note.id).inserted {
                            append("note:\(note.id)", fileIndex: fileIndex, content: .note(note), height: noteHeight(note.note, width: input.width, textSize: input.textSize))
                        }
                    }
                    if let composing = input.composing, composing.path == file.path,
                       (composing.oldSide ? row.left : (input.split ? row.right : row.left))?.id == composing.lineId {
                        append("\(linePrefix)/composer:\(composing.oldSide)", fileIndex: fileIndex, content: .composer(composing), height: max(220, input.lineHeight * 10))
                    }
                }
            }
        }
        let codeWidth = CGFloat(longestLine) * input.characterWidth
        contentWidth = max(input.width, input.split ? (codeWidth + 72) * 2 : codeWidth + 112)
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

    private func headerInsertion(after rowIndex: Int) -> Int {
        var lower = 0
        var upper = headers.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if headers[middle] <= rowIndex { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    func anchor(at position: CGFloat) -> Anchor? {
        guard let index = row(at: position) else { return nil }
        let row = rows[index]
        return Anchor(id: row.id, fileID: row.fileIndex.map { "file:\(input.files[$0].path)" }, offset: position - positions[index])
    }

    func position(of anchor: Anchor) -> CGFloat? {
        guard let index = indices[anchor.id] ?? anchor.fileID.flatMap({ indices[$0] }) else { return nil }
        return positions[index] + min(max(0, anchor.offset), max(0, rows[index].height - 1))
    }

    private mutating func append(_ id: String, fileIndex: Int? = nil, content: DiffRenderRow.Content, height: CGFloat) {
        indices[id] = rows.count
        rows.append(DiffRenderRow(id: id, fileIndex: fileIndex, content: content, height: height))
        positions.append((positions.last ?? 0) + height)
    }

    private func noteHeight(_ text: String, width: CGFloat, textSize: CGFloat) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, textSize, nil)!
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(80, width - 140), height: .greatestFiniteMagnitude), nil)
        return max(52, ceil(size.height) + 40)
    }

    private struct NoteLocation: Hashable {
        var path: String
        var number: Int
        var oldSide: Bool
    }
}
