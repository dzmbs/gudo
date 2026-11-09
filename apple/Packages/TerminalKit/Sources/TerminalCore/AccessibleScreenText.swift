import Foundation
import GhosttyVt

/// The viewport as text for assistive technologies, read from the grid once per screen change.
/// Each viewport row is a line; a soft-wrapped row runs into the next without a line break.
/// Offsets count UTF-16 units, as `NSString` and the accessibility APIs do.
public struct AccessibleScreenText: Sendable, Equatable {
    /// An OSC 8 hyperlink's text and target.
    public struct Link: Sendable, Equatable {
        public var range: Range<Int>
        public var url: String
    }

    /// Columns of one viewport row.
    public struct CellSpan: Sendable, Equatable {
        public var row: Int
        public var columns: Range<Int>
    }

    struct GridCharacter: Sendable, Equatable {
        var text: String
        var column: Int
        var width: Int
        var hyperlink: String?
    }

    struct GridRow: Sendable, Equatable {
        var characters: [GridCharacter]
        var isWrapped: Bool
    }

    private struct PlacedCharacter: Sendable, Equatable {
        var offset: Int
        var length: Int
        var column: Int
        var width: Int

        var endOffset: Int { offset + length }
        var endColumn: Int { column + width }
    }

    private struct Line: Sendable, Equatable {
        var characters: [PlacedCharacter]
        var textRange: Range<Int>
        var hasLineBreak: Bool

        var range: Range<Int> { textRange.lowerBound..<(textRange.upperBound + (hasLineBreak ? 1 : 0)) }
        var endColumn: Int { characters.last?.endColumn ?? 0 }

        func character(atColumn column: Int) -> PlacedCharacter? {
            characters.first { column < $0.endColumn }
        }
    }

    public let string: String
    public let length: Int
    public let links: [Link]
    private let lines: [Line]
    private let viewportRows: Int

    /// Trailing blanks of a row are left out, except on the cursor's row up to the cursor;
    /// empty rows after the last text and the cursor are left out.
    init(rows: [GridRow], viewportRows: Int, cursor: GridPoint?) {
        let trimmedRows = rows.enumerated().map { y, row in
            Self.trimmed(row, keepingColumnsBefore: cursor?.y == y ? cursor?.x ?? 0 : 0)
        }
        let lastTextRow = trimmedRows.lastIndex { !$0.characters.isEmpty } ?? 0
        let lastRow = min(max(lastTextRow, cursor?.y ?? 0), trimmedRows.count - 1)
        let keptRows = lastRow < 0 ? [GridRow(characters: [], isWrapped: false)] : Array(trimmedRows[...lastRow])

        var string = ""
        var offset = 0
        var links: [Link] = []
        var lines: [Line] = []
        for (index, row) in keptRows.enumerated() {
            let lineStart = offset
            var placed: [PlacedCharacter] = []
            for character in row.characters {
                let length = character.text.utf16.count
                placed.append(PlacedCharacter(offset: offset, length: length, column: character.column, width: character.width))
                if let url = character.hyperlink {
                    if let last = links.last, last.url == url, last.range.upperBound == offset {
                        links[links.count - 1].range = last.range.lowerBound..<(offset + length)
                    } else {
                        links.append(Link(range: offset..<(offset + length), url: url))
                    }
                }
                string += character.text
                offset += length
            }
            let hasLineBreak = !row.isWrapped && index < keptRows.count - 1
            lines.append(Line(characters: placed, textRange: lineStart..<offset, hasLineBreak: hasLineBreak))
            if hasLineBreak {
                string += "\n"
                offset += 1
            }
        }
        self.string = string
        length = offset
        self.links = links
        self.lines = lines
        self.viewportRows = viewportRows
    }

    private static func trimmed(_ row: GridRow, keepingColumnsBefore keptColumns: Int) -> GridRow {
        guard !row.isWrapped else { return row }
        var row = row
        while let last = row.characters.last, last.text == " ", last.column >= keptColumns {
            row.characters.removeLast()
        }
        return row
    }

    public var lineCount: Int { lines.count }

    /// A line's range, its line break included.
    public func range(forLine line: Int) -> Range<Int>? {
        lines.indices.contains(line) ? lines[line].range : nil
    }

    /// The line holding an offset; the end of the text is on the last line.
    public func line(forOffset offset: Int) -> Int {
        guard offset < length else { return lines.count - 1 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].range.upperBound > offset { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// The offset of the character covering a viewport cell, or of the end of its row's text
    /// for a cell past it.
    public func offset(of cell: GridPoint) -> Int {
        guard cell.y >= 0 else { return 0 }
        guard cell.y < lines.count else { return length }
        let line = lines[cell.y]
        return line.character(atColumn: cell.x)?.offset ?? line.textRange.upperBound
    }

    private func endOffset(through cell: GridPoint) -> Int {
        guard cell.y >= 0 else { return 0 }
        guard cell.y < lines.count else { return length }
        let line = lines[cell.y]
        return line.character(atColumn: cell.x)?.endOffset ?? line.textRange.upperBound
    }

    /// The viewport cell where the character at an offset starts; an offset past a row's text
    /// is the cell after it.
    public func cell(atOffset offset: Int) -> GridPoint {
        let y = line(forOffset: offset)
        let line = lines[y]
        guard offset < line.textRange.upperBound, let character = line.characters.last(where: { $0.offset <= offset }) else {
            return GridPoint(x: line.endColumn, y: y)
        }
        return GridPoint(x: character.column, y: y)
    }

    /// The text a selection (screen coordinates) covers in view, nil when none of it is.
    public func range(of selection: Selection, viewportTop: Int) -> Range<Int>? {
        let start = GridPoint(x: selection.start.x, y: selection.start.y - viewportTop)
        let end = GridPoint(x: selection.end.x, y: selection.end.y - viewportTop)
        guard end.y >= 0, start.y < viewportRows else { return nil }
        let lower = start.y < 0 ? 0 : offset(of: start)
        let upper = end.y >= viewportRows ? length : endOffset(through: end)
        return lower..<max(lower, upper)
    }

    /// The selection (screen coordinates) covering a range; nil for an empty one.
    public func selection(for range: Range<Int>, viewportTop: Int) -> Selection? {
        guard !range.isEmpty else { return nil }
        let start = cell(atOffset: range.lowerBound)
        let last = cell(atOffset: range.upperBound - 1)
        return Selection(
            anchor: GridPoint(x: start.x, y: start.y + viewportTop), head: GridPoint(x: last.x, y: last.y + viewportTop))
    }

    /// The cells a range covers, one span per row; an empty range is the cell where it sits.
    public func spans(for range: Range<Int>) -> [CellSpan] {
        let insertionPoint = cell(atOffset: range.lowerBound)
        let insertionSpan = CellSpan(row: insertionPoint.y, columns: insertionPoint.x..<(insertionPoint.x + 1))
        guard !range.isEmpty else { return [insertionSpan] }
        let firstLine = line(forOffset: range.lowerBound)
        let lastLine = line(forOffset: range.upperBound - 1)
        let spans = (firstLine...lastLine).compactMap { y -> CellSpan? in
            let covered = lines[y].characters.filter { $0.offset < range.upperBound && $0.endOffset > range.lowerBound }
            guard let first = covered.first, let last = covered.last else { return nil }
            return CellSpan(row: y, columns: first.column..<last.endColumn)
        }
        return spans.isEmpty ? [insertionSpan] : spans
    }

    /// Every link in reading order: the OSC 8 hyperlinks, and the URLs and paths printed as text
    /// outside them, found on each line as ⌘-click finds them.
    public func linkRanges() -> [Range<Int>] {
        var ranges = links.map(\.range)
        var lineStart = 0
        for line in string.split(separator: "\n", omittingEmptySubsequences: false) {
            for match in LinkDetector.matches(in: String(line)) {
                let start = line.index(line.startIndex, offsetBy: match.range.lowerBound)
                let end = line.index(start, offsetBy: match.range.count)
                let lower = lineStart + line.utf16.distance(from: line.startIndex, to: start)
                let range = lower..<(lower + line.utf16.distance(from: start, to: end))
                if !links.contains(where: { $0.range.overlaps(range) }) { ranges.append(range) }
            }
            lineStart += line.utf16.count + 1
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The text in a range, clamped to the text.
    public func substring(in range: Range<Int>) -> String {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        return (string as NSString).substring(with: NSRange(location: lower, length: upper - lower))
    }
}

extension Terminal {
    /// The viewport as `AccessibleScreenText`, in one pass over its cells. Concealed (SGR 8)
    /// text reads as blanks.
    public func accessibleScreenText() -> AccessibleScreenText {
        withHandle { handle in
            var cols: UInt16 = 0, rows: UInt16 = 0
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            let gridRows = (0..<Int(rows)).map { y in Self.accessibleRow(handle, y: y, cols: Int(cols)) }
            var cursorX: UInt16 = 0, cursorY: UInt16 = 0
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY)
            let cursor = Self.gridRef(handle, GridPoint(x: Int(cursorX), y: Int(cursorY)), GHOSTTY_POINT_TAG_ACTIVE).flatMap { ref in
                var ref = ref
                return Self.point(handle, &ref, GHOSTTY_POINT_TAG_VIEWPORT)
            }
            return AccessibleScreenText(rows: gridRows, viewportRows: Int(rows), cursor: cursor)
        }
    }

    private static func accessibleRow(_ handle: GhosttyTerminal, y: Int, cols: Int) -> AccessibleScreenText.GridRow {
        var characters: [AccessibleScreenText.GridCharacter] = []
        var isWrapped = false
        for x in 0..<cols {
            guard var ref = gridRef(handle, GridPoint(x: x, y: y), GHOSTTY_POINT_TAG_VIEWPORT) else { continue }
            if x == 0 {
                var row: GhosttyRow = 0
                if ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS { ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &isWrapped) }
            }
            var cell = GhosttyCell()
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { continue }
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
            var hasHyperlink = false
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hasHyperlink)
            characters.append(AccessibleScreenText.GridCharacter(
                text: readableText(ref, cell), column: x, width: wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1,
                hyperlink: hasHyperlink ? hyperlinkURI(ref) : nil))
        }
        return AccessibleScreenText.GridRow(characters: characters, isWrapped: isWrapped)
    }

    private static func readableText(_ ref: GhosttyGridRef, _ cell: GhosttyCell) -> String {
        var hasText = false
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)
        guard hasText else { return " " }
        var hasStyling = false
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_STYLING, &hasStyling)
        if hasStyling {
            var ref = ref
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            if ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS, style.invisible { return " " }
        }
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
        if tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME { return graphemes(ref) }
        var codepoint: UInt32 = 0
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
        return Unicode.Scalar(codepoint).map { String($0) } ?? " "
    }
}
