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
    /// A `file://` link's host, unless it is `localhost`.
    public var host: String?
    /// What the screen shows for it: the printed text, or an OSC 8 link's cells, which the
    /// program chooses freely and may name another place than `target`. Cells nobody can read
    /// (concealed, or in their background colour) are left out.
    public var label: String
    /// The cells it covers on the row asked about (viewport coordinates), for hover underlines.
    public var row: Int
    public var columns: ClosedRange<Int>

    public init(kind: Kind, text: String, target: String, line: Int? = nil, column: Int? = nil, isHyperlink: Bool = false,
                host: String? = nil, label: String? = nil, row: Int = 0, columns: ClosedRange<Int> = 0...0) {
        self.kind = kind
        self.text = text
        self.target = target
        self.line = line
        self.column = column
        self.isHyperlink = isHyperlink
        self.host = host
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

    /// Made absolute against `directory` and normalised; `~` kept.
    public func resolvedPath(relativeTo directory: String?) -> String {
        guard kind == .path else { return target }
        return TerminalPath.resolved(target, relativeTo: directory)
    }

    static func fileTarget(_ url: URL) -> (path: String, host: String?) {
        let host = url.host(percentEncoded: false).flatMap { $0.isEmpty || $0.lowercased() == "localhost" ? nil : $0 }
        return (url.path(percentEncoded: false), host)
    }
}

public enum TerminalPath {
    public static func resolved(_ path: String, relativeTo directory: String?) -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), let directory, !directory.isEmpty else { return normalized(path) }
        return normalized(directory + "/" + path)
    }

    /// Folds `.` and `..` lexically; the file may be on another host.
    public static func normalized(_ path: String) -> String {
        let prefix: String
        var rest = Substring(path)
        if rest.hasPrefix("/") {
            prefix = "/"
        } else if rest == "~" || rest.hasPrefix("~/") {
            prefix = "~/"
            rest = rest.dropFirst()
        } else {
            prefix = ""
        }
        var components: [Substring] = []
        for component in rest.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if prefix.isEmpty {
                    components.append(component)
                }
            default: components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        switch prefix {
        case "~/": return joined.isEmpty ? "~" : "~/" + joined
        case "/": return "/" + joined
        default: return joined.isEmpty ? "." : joined
        }
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
        public var host: String?
    }

    private typealias Location = (line: Int?, column: Int?)

    private static let schemes = "(?:https?://|ftp://|file://|ssh://|git://|gemini://|gopher://|mailto:)"
    private static let url = try! NSRegularExpression(pattern: schemes + #"[\w\-.~:/?#@!$&*+,;=%()\[\]']+"#)
    /// Rooted, relative with a slash, or a bare `name.ext` followed by a line suffix.
    private static let path = try! NSRegularExpression(pattern:
        #"(?<![\w/:.~\-])(?:(?:~|\.{1,2})?/[\w\-.~/@+%,]*[\w\-~/@+%]|[\w\-.@+]+(?:/[\w\-.@+]+)+|[\w\-.@+]*\w\.\w+(?=:\d|\(\d| \[\d))"#)
    private static let quoted = try! NSRegularExpression(pattern: #"(?<![\w"'`])(["'`])([^"'`\s][^"'`\t\n]{0,1023}?)\1"#)
    /// `:12`, `:12:5`, `:12.5`, `(12)`, `(12,5)`, ` [12, 5]`.
    private static let suffix = try! NSRegularExpression(pattern: #":(\d+)(?:[:.](\d+))?|\((\d+)(?:, ?(\d+))?\)| \[(\d+), ?(\d+)\]"#)
    private static let quotedSuffix = try! NSRegularExpression(pattern: #", line (\d+)"#)

    /// Every link in `line`, in order; URLs win over quoted paths, quoted over bare ones.
    public static func matches(in line: String) -> [Match] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var matches: [Match] = []
        var taken = IndexSet()
        for result in url.matches(in: line, range: full) {
            var text = ns.substring(with: result.range)
            text = trimURL(text)
            guard text.count > 3, let range = characterRange(line, NSRange(location: result.range.location, length: (text as NSString).length)) else { continue }
            taken.insert(integersIn: result.range.location..<result.range.location + (text as NSString).length)
            // A printed `file://` URL is a path, opened the way paths are.
            if let url = URL(string: text), url.isFileURL {
                let file = TerminalLink.fileTarget(url)
                matches.append(Match(kind: .path, range: range, text: text, target: file.path, host: file.host))
            } else {
                matches.append(Match(kind: .url, range: range, text: text, target: text))
            }
        }
        for result in quoted.matches(in: line, range: full) {
            guard !taken.intersects(integersIn: result.range.location..<NSMaxRange(result.range)) else { continue }
            let inner = result.range(at: 2)
            let text = ns.substring(with: inner)
            var path = text
            var location = trailingNumbers(&path)
            let afterQuote = NSMaxRange(result.range)
            if location.line == nil,
               let python = quotedSuffix.firstMatch(in: line, options: .anchored, range: NSRange(location: afterQuote, length: ns.length - afterQuote)) {
                location = (Int(ns.substring(with: python.range(at: 1))), nil)
            }
            guard let target = pathTarget(path, hasLine: location.line != nil, allowsSpaces: true), let range = characterRange(line, inner) else { continue }
            taken.insert(integersIn: result.range.location..<NSMaxRange(result.range))
            matches.append(Match(kind: .path, range: range, text: text, target: target, line: location.line, column: location.column))
        }
        for result in path.matches(in: line, range: full) {
            guard !taken.intersects(integersIn: result.range.location..<NSMaxRange(result.range)) else { continue }
            var path = ns.substring(with: result.range)
            while let last = path.last, ".,;:)]'\"".contains(last) { path.removeLast() }
            var length = (path as NSString).length
            var location: Location = (nil, nil)
            let suffixStart = result.range.location + length
            if let found = suffix.firstMatch(in: line, options: .anchored, range: NSRange(location: suffixStart, length: ns.length - suffixStart)) {
                location = suffixLocation(found, in: ns)
                length += found.range.length
            }
            let printed = NSRange(location: result.range.location, length: length)
            guard let target = pathTarget(path, hasLine: location.line != nil, allowsSpaces: false), target.count > 1,
                  let range = characterRange(line, printed)
            else { continue }
            matches.append(Match(kind: .path, range: range, text: ns.substring(with: printed), target: target, line: location.line, column: location.column))
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func suffixLocation(_ result: NSTextCheckingResult, in line: NSString) -> Location {
        let groups = (1..<result.numberOfRanges).map { index -> Int? in
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : Int(line.substring(with: range))
        }
        for pair in stride(from: 0, to: groups.count - 1, by: 2) where groups[pair] != nil {
            return (groups[pair], groups[pair + 1])
        }
        return (nil, nil)
    }

    private static func trailingNumbers(_ text: inout String) -> Location {
        var path = Substring(text)
        var numbers: [Int] = []
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]) else { break }
            numbers.insert(number, at: 0)
            path = path[..<colon]
        }
        text = String(path)
        return (numbers.first, numbers.count > 1 ? numbers[1] : nil)
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
        var path = text
        let location = trailingNumbers(&path)
        guard let target = pathTarget(path, hasLine: location.line != nil, allowsSpaces: false) else { return nil }
        return (target, location.line, location.column)
    }

    // As in Ghostty's matcher, a relative path needs an extension, a line or a trailing slash:
    // `and/or` is a word, `src/app.rs` a path.
    private static func pathTarget(_ path: String, hasLine: Bool, allowsSpaces: Bool) -> String? {
        guard path.contains(where: \.isLetter) else { return nil }
        if path.contains(" "), !allowsSpaces || !path.contains("/") { return nil }
        let rooted = path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../")
        if !rooted, !hasLine, !path.hasSuffix("/"), !(path.split(separator: "/").last?.dropFirst().contains(".") ?? false) {
            return nil
        }
        return path
    }

    private static func characterRange(_ line: String, _ range: NSRange) -> Range<Int>? {
        guard let stringRange = Range(range, in: line) else { return nil }
        let lower = line.distance(from: line.startIndex, to: stringRange.lowerBound)
        return lower..<(lower + line.distance(from: stringRange.lowerBound, to: stringRange.upperBound))
    }
}

extension Terminal {
    /// The link under a viewport cell: its OSC 8 hyperlink, else a URL or path printed there.
    public func link(atViewport point: GridPoint) -> TerminalLink? {
        withHandle { handle in
            guard let ref = Self.gridRef(handle, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            let top = TerminalSearch.viewportTop(handle)
            let cells = Self.logicalLine(handle, screenRow: top + point.y)
            if let uri = Self.hyperlinkURI(ref) {
                // The run of cells on this row that carry the same URI.
                let row = cells.filter { $0.point.y == top + point.y && Self.hyperlinkAt(handle, $0.point) == uri }
                let columns = (row.map(\.point.x).min() ?? point.x)...(row.map(\.point.x).max() ?? point.x)
                let label = Self.seenText(handle, cells.filter { Self.hyperlinkAt(handle, $0.point) == uri })
                if let url = URL(string: uri), url.isFileURL {
                    let suffix = url.fragment.flatMap { Int($0.drop { !$0.isNumber }) }
                    let file = TerminalLink.fileTarget(url)
                    return TerminalLink(
                        kind: .path, text: uri, target: file.path, line: suffix, isHyperlink: true, host: file.host, label: label,
                        row: point.y, columns: columns)
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
                kind: match.kind, text: match.text, target: match.target, line: match.line, column: match.column, host: match.host,
                label: Self.seenText(handle, Array(cells[match.range])), row: point.y,
                columns: (onRow.min() ?? point.x)...(onRow.max() ?? point.x))
        }
    }

    private typealias LineCell = (text: String, point: GridPoint)

    /// The soft-wrapped line through a screen row: one entry per character (a wide character's
    /// spacer cells left out, an empty cell as a space), with its screen cell.
    private static func logicalLine(_ handle: GhosttyTerminal, screenRow: Int) -> [LineCell] {
        let (cols, total) = screenExtent(handle)
        var first = screenRow
        while first > 0, first > screenRow - 64, rowFlag(handle, first - 1, GHOSTTY_ROW_DATA_WRAP) { first -= 1 }
        var last = screenRow
        while last + 1 < total, last < screenRow + 64, rowFlag(handle, last, GHOSTTY_ROW_DATA_WRAP) { last += 1 }
        var cells: [LineCell] = []
        for y in first...last {
            var row: [LineCell] = []
            for x in 0..<cols {
                guard var ref = gridRef(handle, GridPoint(x: x, y: y), GHOSTTY_POINT_TAG_SCREEN) else { continue }
                var cell = GhosttyCell()
                if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS {
                    var wide = GHOSTTY_CELL_WIDE_NARROW
                    ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                    if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                }
                let grapheme = graphemes(ref)
                // One Character per entry, so character offsets index cells.
                row.append((grapheme.isEmpty ? " " : String(grapheme.first!), GridPoint(x: x, y: y)))
            }
            // Trailing blanks of the last row are not part of the line.
            if y == last { while row.last?.text == " " { row.removeLast() } }
            cells += row
        }
        return cells
    }

    private static func rowFlag(_ handle: GhosttyTerminal, _ y: Int, _ flag: GhosttyRowData) -> Bool {
        guard var ref = gridRef(handle, GridPoint(x: 0, y: y), GHOSTTY_POINT_TAG_SCREEN) else { return false }
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

    private static func hyperlinkAt(_ handle: GhosttyTerminal, _ point: GridPoint) -> String? {
        gridRef(handle, point, GHOSTTY_POINT_TAG_SCREEN).flatMap(hyperlinkURI)
    }

    /// The cells' text a person could read: concealed (SGR 8) cells and cells drawn in their own
    /// background colour are left out, so they cannot make a longer address look seen.
    private static func seenText(_ handle: GhosttyTerminal, _ cells: [LineCell]) -> String {
        let colors = CellColors(handle)
        return cells.filter { cell in
            guard var ref = gridRef(handle, cell.point, GHOSTTY_POINT_TAG_SCREEN) else { return true }
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

    init(_ handle: GhosttyTerminal) {
        var fg = GhosttyColorRgb(), bg = GhosttyColorRgb()
        if ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fg) == GHOSTTY_SUCCESS { foreground = fg }
        if ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &bg) == GHOSTTY_SUCCESS { background = bg }
        var colors = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        let got = colors.withUnsafeMutableBufferPointer { ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, $0.baseAddress) }
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
