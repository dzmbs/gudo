import Foundation
import GhosttyVt

/// A link under a cell: an OSC 8 hyperlink, or a URL or file path printed as plain text (found
/// the way Ghostty's default `link` matcher finds them, on the soft-wrapped line).
public struct TerminalLink: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case url
        /// A file path, absolute (`/…`), home-relative (`~/…`) or relative (`./…`, `src/a.rs`),
        /// with an optional `:line[:column]` suffix (compiler and grep output).
        case path
    }

    public var kind: Kind
    /// As printed (for a path, with its `:line:col` suffix).
    public var text: String
    /// The URL, or the path without its suffix. An OSC 8 `file://` link is a path.
    public var target: String
    public var line: Int?
    public var column: Int?
    /// Came from OSC 8, not from the text.
    public var isHyperlink: Bool
    /// What the screen shows for it: the printed text, or an OSC 8 link's cells, which the
    /// program chooses freely and may name another place than `target`. Cells nobody can read
    /// (concealed, or in their background colour) are left out.
    public var label: String
    /// The cells it covers on the row asked about (viewport coordinates), for hover underlines.
    public var row: Int
    public var columns: ClosedRange<Int>

    public init(kind: Kind, text: String, target: String, line: Int? = nil, column: Int? = nil, isHyperlink: Bool = false,
                label: String? = nil, row: Int = 0, columns: ClosedRange<Int> = 0...0) {
        self.kind = kind
        self.text = text
        self.target = target
        self.line = line
        self.column = column
        self.isHyperlink = isHyperlink
        self.label = label ?? text
        self.row = row
        self.columns = columns
    }

    /// The target as a URL: http(s) and other schemes as they are, paths as `file://` URLs
    /// (relative ones resolved against `directory` when given).
    public func url(relativeTo directory: String? = nil) -> URL? {
        switch kind {
        case .url: return URL(string: target)
        case .path: return URL(fileURLWithPath: resolvedPath(relativeTo: directory))
        }
    }

    /// The path made absolute against `directory` (a pane's working directory); `~` kept.
    public func resolvedPath(relativeTo directory: String?) -> String {
        guard kind == .path, !target.hasPrefix("/"), !target.hasPrefix("~"), let directory, !directory.isEmpty else { return target }
        var base = directory
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var rest = Substring(target)
        if rest.hasPrefix("./") { rest = rest.dropFirst(2) }
        return (base == "/" ? "" : base) + "/" + rest
    }
}

/// Finds URLs and paths in a line of terminal text.
public enum LinkDetector {
    public struct Match: Equatable, Sendable {
        public var kind: TerminalLink.Kind
        /// Character offsets in the line.
        public var range: Range<Int>
        public var text: String
        public var target: String
        public var line: Int?
        public var column: Int?
    }

    private static let schemes = "(?:https?://|ftp://|file://|ssh://|git://|gemini://|gopher://|mailto:)"
    private static let url = try! NSRegularExpression(pattern: schemes + #"[\w\-.~:/?#@!$&*+,;=%()\[\]']+"#)
    /// Rooted (`/`, `~/`, `./`, `../`) or relative with a slash, or a bare file name with an
    /// extension and a `:line` (`main.rs:12:5`). Not after a word or `://`.
    private static let path = try! NSRegularExpression(pattern:
        #"(?<![\w/:.~\-])(?:(?:~|\.{1,2})?/[\w\-.~/@+%,]*[\w\-~/@+%]|[\w\-.@+]+(?:/[\w\-.@+]+)+|[\w\-.@+]*\w\.\w+(?=:\d))(?::\d+(?::\d+)?)?"#)

    /// Every link in `line`, in order, URLs first where they overlap paths.
    public static func matches(in line: String) -> [Match] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Match] = []
        var taken = IndexSet()
        for result in url.matches(in: line, range: full) {
            var text = ns.substring(with: result.range)
            text = trimURL(text)
            guard text.count > 3, let range = characterRange(line, NSRange(location: result.range.location, length: (text as NSString).length)) else { continue }
            taken.insert(integersIn: result.range.location..<result.range.location + (text as NSString).length)
            // A printed `file://` URL is a path, opened the way paths are.
            if let url = URL(string: text), url.isFileURL {
                out.append(Match(kind: .path, range: range, text: text, target: url.path))
            } else {
                out.append(Match(kind: .url, range: range, text: text, target: text))
            }
        }
        for result in path.matches(in: line, range: full) {
            guard !taken.intersects(integersIn: result.range.location..<NSMaxRange(result.range)) else { continue }
            var text = ns.substring(with: result.range)
            while let last = text.last, ".,;:)]'\"".contains(last) { text.removeLast() }
            guard let match = pathMatch(text), match.target.count > 1,
                  let range = characterRange(line, NSRange(location: result.range.location, length: (text as NSString).length))
            else { continue }
            out.append(Match(kind: .path, range: range, text: text, target: match.target, line: match.line, column: match.column))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Ghostty's URL rules: no trailing `.`/`,`, and a trailing `)` only when the URL opened one.
    static func trimURL(_ text: String) -> String {
        var text = text
        while let last = text.last {
            if ".,;:!?'\"".contains(last) {
                text.removeLast()
            } else if last == ")" || last == "]" {
                let open: Character = last == ")" ? "(" : "["
                if text.filter({ $0 == open }).count < text.filter({ $0 == last }).count { text.removeLast() } else { break }
            } else {
                break
            }
        }
        return text
    }

    /// Splits `path:line:col`; a path that is only a number or a version-like word is not one.
    static func pathMatch(_ text: String) -> (target: String, line: Int?, column: Int?)? {
        var path = Substring(text)
        var numbers: [Int] = []
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":"), let n = Int(path[path.index(after: colon)...]) else { break }
            numbers.insert(n, at: 0)
            path = path[..<colon]
        }
        guard path.contains(where: \.isLetter) else { return nil }
        let rooted = path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../")
        // A relative path needs a file name with an extension, a `:line`, or a trailing slash, as
        // Ghostty's matcher does: `and/or` and `TCP/IP` are words, `src/app.rs` is a path.
        if !rooted, numbers.isEmpty, !path.hasSuffix("/"), !(path.split(separator: "/").last?.dropFirst().contains(".") ?? false) {
            return nil
        }
        return (String(path), numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    private static func characterRange(_ line: String, _ range: NSRange) -> Range<Int>? {
        guard let r = Range(range, in: line) else { return nil }
        let lower = line.distance(from: line.startIndex, to: r.lowerBound)
        return lower..<(lower + line.distance(from: r.lowerBound, to: r.upperBound))
    }
}

extension Terminal {
    /// The link under a viewport cell: its OSC 8 hyperlink, else a URL or path printed there.
    public func link(atViewport point: GridPoint) -> TerminalLink? {
        withHandle { t in
            guard let ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            let top = TerminalSearch.viewportTop(t)
            let cells = Self.logicalLine(t, screenRow: top + point.y)
            if let uri = Self.hyperlinkURI(ref) {
                // The run of cells on this row that carry the same URI.
                let row = cells.filter { $0.point.y == top + point.y && Self.hyperlinkAt(t, $0.point) == uri }
                let columns = (row.map(\.point.x).min() ?? point.x)...(row.map(\.point.x).max() ?? point.x)
                let label = Self.seenText(t, cells.filter { Self.hyperlinkAt(t, $0.point) == uri })
                if let url = URL(string: uri), url.isFileURL {
                    let suffix = url.fragment.flatMap { Int($0.drop { !$0.isNumber }) }
                    return TerminalLink(
                        kind: .path, text: uri, target: url.path, line: suffix, isHyperlink: true, label: label, row: point.y,
                        columns: columns)
                }
                return TerminalLink(kind: .url, text: uri, target: uri, isHyperlink: true, label: label, row: point.y, columns: columns)
            }
            let screen = GridPoint(x: point.x, y: top + point.y)
            guard let index = cells.firstIndex(where: { $0.point == screen }) else { return nil }
            let text = cells.map(\.text).joined()
            // Character offsets: one character per cell entry.
            guard let match = LinkDetector.matches(in: text).first(where: { $0.range.contains(index) }) else { return nil }
            let onRow = cells[match.range].filter { $0.point.y == screen.y }.map(\.point.x)
            return TerminalLink(
                kind: match.kind, text: match.text, target: match.target, line: match.line, column: match.column,
                label: Self.seenText(t, Array(cells[match.range])), row: point.y,
                columns: (onRow.min() ?? point.x)...(onRow.max() ?? point.x))
        }
    }

    private typealias LineCell = (text: String, point: GridPoint)

    /// The soft-wrapped line through a screen row: one entry per character (a wide character's
    /// spacer cells left out, an empty cell as a space), with its screen cell.
    private static func logicalLine(_ t: GhosttyTerminal, screenRow: Int) -> [LineCell] {
        let (cols, total) = screenExtent(t)
        var first = screenRow
        while first > 0, first > screenRow - 64, rowFlag(t, first - 1, GHOSTTY_ROW_DATA_WRAP) { first -= 1 }
        var last = screenRow
        while last + 1 < total, last < screenRow + 64, rowFlag(t, last, GHOSTTY_ROW_DATA_WRAP) { last += 1 }
        var cells: [LineCell] = []
        for y in first...last {
            var row: [LineCell] = []
            for x in 0..<cols {
                guard var ref = gridRef(t, GridPoint(x: x, y: y), GHOSTTY_POINT_TAG_SCREEN) else { continue }
                var cell = GhosttyCell()
                if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS {
                    var wide = GHOSTTY_CELL_WIDE_NARROW
                    ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                    if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                }
                let g = graphemes(ref)
                // One Character per entry, so character offsets index cells.
                row.append((g.isEmpty ? " " : String(g.first!), GridPoint(x: x, y: y)))
            }
            // Trailing blanks of the last row are not part of the line.
            if y == last { while row.last?.text == " " { row.removeLast() } }
            cells += row
        }
        return cells
    }

    private static func rowFlag(_ t: GhosttyTerminal, _ y: Int, _ flag: GhosttyRowData) -> Bool {
        guard var ref = gridRef(t, GridPoint(x: 0, y: y), GHOSTTY_POINT_TAG_SCREEN) else { return false }
        var row: GhosttyRow = 0
        guard ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS else { return false }
        var value = false
        return ghostty_row_get(row, flag, &value) == GHOSTTY_SUCCESS && value
    }

    private static func hyperlinkURI(_ ref: GhosttyGridRef) -> String? {
        var ref = ref
        var buffer = [UInt8](repeating: 0, count: 2048)
        var length = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_SUCCESS, length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    private static func hyperlinkAt(_ t: GhosttyTerminal, _ point: GridPoint) -> String? {
        gridRef(t, point, GHOSTTY_POINT_TAG_SCREEN).flatMap(hyperlinkURI)
    }

    /// The cells' text a person could read: concealed (SGR 8) cells and cells drawn in their own
    /// background colour are left out, so they cannot make a longer address look seen.
    private static func seenText(_ t: GhosttyTerminal, _ cells: [LineCell]) -> String {
        let colors = CellColors(t)
        return cells.filter { cell in
            guard var ref = gridRef(t, cell.point, GHOSTTY_POINT_TAG_SCREEN) else { return true }
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            guard ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS else { return true }
            return !style.invisible && !colors.blend(style)
        }.map(\.text).joined()
    }
}

/// A terminal's colours, to tell when a cell's text is drawn in its background colour.
private struct CellColors {
    var foreground: GhosttyColorRgb?
    var background: GhosttyColorRgb?
    var palette: [GhosttyColorRgb]?

    init(_ t: GhosttyTerminal) {
        var fg = GhosttyColorRgb(), bg = GhosttyColorRgb()
        if ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fg) == GHOSTTY_SUCCESS { foreground = fg }
        if ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &bg) == GHOSTTY_SUCCESS { background = bg }
        var colors = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        let got = colors.withUnsafeMutableBufferPointer { ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, $0.baseAddress) }
        if got == GHOSTTY_SUCCESS { palette = colors }
    }

    /// Whether text and background come out (nearly) the same colour.
    func blend(_ style: GhosttyStyle) -> Bool {
        guard let fg = resolve(style.fg_color, foreground), let bg = resolve(style.bg_color, background) else { return false }
        let diff = [(fg.r, bg.r), (fg.g, bg.g), (fg.b, bg.b)].map { abs(Int($0) - Int($1)) }.max() ?? 0
        return diff <= 8
    }

    private func resolve(_ color: GhosttyStyleColor, _ fallback: GhosttyColorRgb?) -> GhosttyColorRgb? {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE: palette?[Int(color.value.palette)]
        case GHOSTTY_STYLE_COLOR_RGB: color.value.rgb
        default: fallback
        }
    }
}
