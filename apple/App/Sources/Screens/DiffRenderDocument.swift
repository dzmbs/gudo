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
    typealias Anchor = NativeListLayout.Anchor

    var input: DiffRenderInput
    private(set) var rows: [DiffRenderRow] = []
    private(set) var layout = NativeListLayout()
    var positions: [CGFloat] { layout.positions }
    var indices: [String: Int] { layout.indices }
    var contentWidth: CGFloat { layout.contentWidth }
    var height: CGFloat { layout.height }

    init(input: DiffRenderInput) {
        self.input = input
        let notesByLocation = Dictionary(grouping: input.notes) { NoteLocation(path: $0.path, number: $0.startLine, oldSide: $0.oldSide) }
        var longestLine = 0
        append("summary", content: .summary, height: 88)
        for (fileIndex, file) in input.files.enumerated() {
            let prefix = "file:\(file.id)"
            append(prefix, fileIndex: fileIndex, content: .file, height: 36)
            guard !input.collapsed.contains(file.id) else { continue }
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
            if file.hunksOmitted {
                append("\(prefix)/omitted", fileIndex: fileIndex,
                       content: .notice("Some changes are not shown."), height: 44)
            }
        }
        let codeWidth = CGFloat(longestLine) * input.characterWidth
        let width = input.split
            ? input.width + max(0, codeWidth - max(0, input.width / 2 - 72))
            : max(input.width, codeWidth + 112)
        let nativeRows = rows.map { row in
            let isHeader: Bool
            let scrollsHorizontally: Bool
            switch row.content {
            case .file: isHeader = true; scrollsHorizontally = false
            case .line, .hunk: isHeader = false; scrollsHorizontally = !input.split
            default: isHeader = false; scrollsHorizontally = false
            }
            return NativeListRow(id: row.id, height: row.height, isHeader: isHeader,
                scrollsHorizontally: scrollsHorizontally, sectionID: row.fileIndex.map { "file:\(input.files[$0].id)" })
        }
        layout = NativeListLayout(rows: nativeRows, contentWidth: width)
    }

    func row(at position: CGFloat) -> Int? { layout.row(at: position) }

    func visibleRows(in rect: CGRect) -> Range<Int> { layout.visibleRows(in: rect) }

    func anchor(at position: CGFloat) -> Anchor? { layout.anchor(at: position) }

    func position(of anchor: Anchor) -> CGFloat? { layout.position(of: anchor) }

    private mutating func append(_ id: String, fileIndex: Int? = nil, content: DiffRenderRow.Content, height: CGFloat) {
        rows.append(DiffRenderRow(id: id, fileIndex: fileIndex, content: content, height: height))
    }

    static func noteFont(_ preferred: CTFont?, size: CGFloat) -> CTFont {
        // The named factory has an internal fallback and cannot return nil.
        preferred ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func noteHeight(_ text: String, width: CGFloat, textSize: CGFloat) -> CGFloat {
        let font = Self.noteFont(CTFontCreateUIFontForLanguage(.system, textSize, nil), size: textSize)
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
