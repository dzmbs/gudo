import GhosttyVt

/// A match drawn in the viewport: one row's run of cells (a match that wraps covers several).
public struct SearchHighlight: Equatable, Sendable {
    /// Viewport row (0 = top).
    public var row: Int
    public var columns: ClosedRange<Int>
    /// The selected match (`TerminalSearch.select`), drawn in the stronger color.
    public var selected: Bool

    public init(row: Int, columns: ClosedRange<Int>, selected: Bool) {
        self.row = row
        self.columns = columns
        self.selected = selected
    }
}

/// Where a search stands, for a find bar's "3/17".
public struct SearchStatus: Equatable, Sendable {
    /// Matches on the active screen, scrollback included.
    public var total: Int
    /// Zero-based index of the selected match, newest (bottom of the screen) first.
    public var selected: Int?
    /// Caught up with the terminal: `total` is final until more output arrives.
    public var isComplete: Bool

    public init(total: Int, selected: Int?, isComplete: Bool) {
        self.total = total
        self.selected = selected
        self.isComplete = isComplete
    }

    public static let idle = SearchStatus(total: 0, selected: nil, isComplete: true)
}

/// Scrollback search over a terminal: libghostty-vt's search (`search.h`), which covers the
/// active area and the whole scrollback of both screens and keeps its results in step with new
/// output, resizes and pruning, as Ghostty's own find does.
///
/// libghostty-vt compares ASCII letters case-insensitively and everything else byte for byte.
/// With `caseSensitive`, matches whose text differs in case from the needle are dropped here
/// (from the count, the highlights, and next/previous).
///
/// Not thread-safe: drive it from one actor (the surface's, the main actor). Calls that read the
/// terminal take its lock.
public final class TerminalSearch {
    public enum Direction: Sendable {
        /// Towards older output (up from the prompt), wrapping past the oldest match.
        case next
        /// Towards newer output, wrapping past the newest.
        case previous
    }

    private let terminal: Terminal
    private var search: GhosttySearch?
    /// The terminal handle `search` is bound to; a snapshot restore replaces the handle.
    private var boundHandle: GhosttyTerminal?
    public private(set) var needle = ""
    public private(set) var caseSensitive = false
    /// For each match (newest first), whether its text has the needle's exact case; nil when
    /// every match counts.
    private var exact: [Bool]?
    private var exactTotal = -1
    public private(set) var status = SearchStatus.idle

    public init(terminal: Terminal) {
        self.terminal = terminal
    }

    deinit {
        guard let search else { return }
        terminal.withHandle { _ in ghostty_search_free(search) }
    }

    public var isActive: Bool { !needle.isEmpty }

    /// Starts searching for `needle` (empty ends the search). Setting the same needle keeps the
    /// results and the selection.
    public func setNeedle(_ needle: String, caseSensitive: Bool) {
        let restart = needle != self.needle || caseSensitive != self.caseSensitive
        self.needle = needle
        self.caseSensitive = caseSensitive
        guard restart else { return }
        exact = nil
        exactTotal = -1
        terminal.withHandle { t in
            bind(t)
            guard let search else { return }
            apply(needle: needle, to: search)
        }
        status = needle.isEmpty ? .idle : SearchStatus(total: 0, selected: nil, isComplete: false)
    }

    /// Catches up with the terminal: one feed, then ticks for at most `budget` seconds. Call
    /// after output and while `status.isComplete` is false.
    @discardableResult
    public func update(budget: Double = 0.004, outputChanged: Bool = true) -> SearchStatus {
        guard isActive else { return .idle }
        let deadline = ContinuousClock.now + .microseconds(Int64(budget * 1_000_000))
        var state = GHOSTTY_SEARCH_STATUS_RUNNING
        terminal.withHandle { t in
            if bind(t) { apply(needle: needle, to: search) }
            guard let search else { return }
            ghostty_search_feed(search)
            repeat {
                guard ghostty_search_tick(search, &state) == GHOSTTY_SUCCESS else { return }
                if state == GHOSTTY_SEARCH_STATUS_FEED_REQUIRED {
                    ghostty_search_feed(search)
                    state = GHOSTTY_SEARCH_STATUS_RUNNING
                }
            } while state == GHOSTTY_SEARCH_STATUS_RUNNING && ContinuousClock.now < deadline
            if state != GHOSTTY_SEARCH_STATUS_COMPLETE {
                ghostty_search_get(search, GHOSTTY_SEARCH_DATA_STATUS, &state)
            }
            refreshExact(t, search, force: outputChanged)
        }
        status = readStatus(complete: state == GHOSTTY_SEARCH_STATUS_COMPLETE)
        return status
    }

    /// Runs the search to completion (tests, small terminals).
    @discardableResult
    public func run() -> SearchStatus {
        guard isActive else { return .idle }
        terminal.withHandle { t in
            if bind(t) { apply(needle: needle, to: search) }
            guard let search else { return }
            ghostty_search_run(search)
            refreshExact(t, search, force: true)
        }
        status = readStatus(complete: true)
        return status
    }

    /// Selects the next or previous match and scrolls the viewport to it when it is out of
    /// view (centered vertically, like Xcode and Safari). Returns false without matches.
    @discardableResult
    public func select(_ direction: Direction) -> Bool {
        guard isActive else { return false }
        let found: Bool = terminal.withHandle { t in
            if bind(t) { apply(needle: needle, to: search) }
            guard let search else { return false }
            var scroll = GHOSTTY_SEARCH_SCROLL_NONE
            ghostty_search_set(search, GHOSTTY_SEARCH_OPT_SELECT_SCROLL, &scroll)
            let option = direction == .next ? GHOSTTY_SEARCH_OPT_SELECT_NEXT : GHOSTTY_SEARCH_OPT_SELECT_PREV
            var total = 0
            ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
            // With exact case, step over matches that differ in case (at most once round).
            for _ in 0..<max(1, total) {
                guard ghostty_search_set(search, option, nil) == GHOSTTY_SUCCESS else { return false }
                guard let exact else { break }
                var index = 0
                if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS,
                   exact.indices.contains(index) ? exact[index] : isExact(t, selected(search)) { break }
            }
            guard let match = selected(search), let range = Self.screenRange(t, match) else { return false }
            if exact != nil, !matchesCase(t, match) { return false }
            Self.reveal(t, range)
            return true
        }
        status = readStatus(complete: status.isComplete)
        return found
    }

    /// The selected match in screen coordinates (row 0 = oldest retained row), if any.
    public var selectedRange: (start: GridPoint, end: GridPoint)? {
        guard isActive, let search else { return nil }
        return terminal.withHandle { t in
            guard boundHandle == t, let match = selected(search) else { return nil }
            return Self.screenRange(t, match)
        }
    }

    /// Matches in the viewport (`rows` × `cols`), split per row, the selected one marked.
    public func viewportHighlights(rows: Int, cols: Int) -> [SearchHighlight] {
        guard isActive, let search, rows > 0, cols > 0 else { return [] }
        return terminal.withHandle { t in
            guard boundHandle == t else { return [] }
            var buffer = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
            // Asked with no room first: the answer is the count.
            _ = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer)
            guard buffer.len > 0 else { return [] }
            var matches = [GhosttySelection](repeating: Self.emptySelection, count: buffer.len)
            let ok = matches.withUnsafeMutableBufferPointer { storage in
                buffer = GhosttySelectionBuffer(ptr: storage.baseAddress, cap: storage.count, len: 0)
                return ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer) == GHOSTTY_SUCCESS
            }
            guard ok else { return [] }
            let top = Self.viewportTop(t)
            let chosen = selected(search).flatMap { Self.screenRange(t, $0) }
            var out: [SearchHighlight] = []
            for match in matches.prefix(buffer.len) {
                guard let range = Self.screenRange(t, match) else { continue }
                let first = range.start.y - top, last = range.end.y - top
                guard last >= 0, first < rows else { continue }
                if exact != nil, !matchesCase(t, match) { continue }
                let isSelected = chosen.map { $0.start == range.start && $0.end == range.end } ?? false
                for row in max(first, 0)...min(last, rows - 1) {
                    let lo = row == first ? range.start.x : 0
                    let hi = row == last ? range.end.x : cols - 1
                    guard lo <= hi else { continue }
                    out.append(SearchHighlight(row: row, columns: min(lo, cols - 1)...min(hi, cols - 1), selected: isSelected))
                }
            }
            return out
        }
    }

    // MARK: Private (terminal lock held)

    /// Makes sure the search is bound to the terminal's current handle. Returns true when it
    /// was (re)created and needs its needle.
    @discardableResult
    private func bind(_ t: GhosttyTerminal) -> Bool {
        if search != nil, boundHandle == t { return false }
        if let search { ghostty_search_free(search) }
        search = nil
        var created: GhosttySearch?
        guard ghostty_search_new(nil, &created, t) == GHOSTTY_SUCCESS, let created else { return false }
        search = created
        boundHandle = t
        exact = nil
        exactTotal = -1
        return true
    }

    private func apply(needle: String, to search: GhosttySearch?) {
        guard let search else { return }
        if needle.isEmpty {
            ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            return
        }
        var bytes = Array(needle.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, &string)
        }
    }

    /// Exact case only matters when the needle has ASCII letters (libghostty-vt folds only those).
    private var needsExactFilter: Bool {
        caseSensitive && needle.utf8.contains { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }

    private func refreshExact(_ t: GhosttyTerminal, _ search: GhosttySearch, force: Bool) {
        guard needsExactFilter else {
            exact = nil
            return
        }
        var total = 0
        ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        guard force || total != exactTotal || exact == nil else { return }
        exactTotal = total
        guard total > 0 else {
            exact = []
            return
        }
        var matches = [GhosttySelection](repeating: Self.emptySelection, count: total)
        var written = 0
        let ok = matches.withUnsafeMutableBufferPointer { storage in
            var buffer = GhosttySelectionBuffer(ptr: storage.baseAddress, cap: storage.count, len: 0)
            let result = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_MATCHES, &buffer)
            written = buffer.len
            return result == GHOSTTY_SUCCESS
        }
        guard ok else { return }
        exact = matches.prefix(written).map { matchesCase(t, $0) }
    }

    private func matchesCase(_ t: GhosttyTerminal, _ match: GhosttySelection) -> Bool {
        Self.text(t, match) == needle
    }

    private func isExact(_ t: GhosttyTerminal, _ match: GhosttySelection?) -> Bool {
        match.map { matchesCase(t, $0) } ?? false
    }

    private func selected(_ search: GhosttySearch) -> GhosttySelection? {
        var match = Self.emptySelection
        guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match) == GHOSTTY_SUCCESS else { return nil }
        return match
    }

    private func readStatus(complete: Bool) -> SearchStatus {
        guard isActive, let search else { return .idle }
        var total = 0
        var index = 0
        ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        let hasSelection = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS
        guard let exact else {
            return SearchStatus(total: total, selected: hasSelection ? index : nil, isComplete: complete)
        }
        let selected: Int? = hasSelection && exact.indices.contains(index) && exact[index]
            ? exact[..<index].lazy.filter { $0 }.count : nil
        return SearchStatus(total: exact.lazy.filter { $0 }.count, selected: selected, isComplete: complete)
    }

    private static var emptySelection: GhosttySelection {
        var s = GhosttySelection()
        s.size = MemoryLayout<GhosttySelection>.size
        return s
    }

    /// A match's ends in screen coordinates, in reading order.
    static func screenRange(_ t: GhosttyTerminal, _ match: GhosttySelection) -> (start: GridPoint, end: GridPoint)? {
        var a = match.start, b = match.end
        guard let p = Terminal.point(t, &a, GHOSTTY_POINT_TAG_SCREEN), let q = Terminal.point(t, &b, GHOSTTY_POINT_TAG_SCREEN) else { return nil }
        return (min(p, q), max(p, q))
    }

    static func text(_ t: GhosttyTerminal, _ match: GhosttySelection) -> String? {
        var match = match
        return withUnsafePointer(to: &match) { pointer in
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = false
            options.selection = pointer
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(t, nil, options, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
            defer { ghostty_free(nil, ptr, len) }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
        }
    }

    static func viewportTop(_ t: GhosttyTerminal) -> Int {
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return Int(bar.offset)
    }

    /// Scrolls so the range is in view: untouched when it already is, else centered.
    static func reveal(_ t: GhosttyTerminal, _ range: (start: GridPoint, end: GridPoint)) {
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        let top = Int(bar.offset), rows = max(1, Int(bar.len))
        guard range.start.y < top || range.end.y >= top + rows else { return }
        let height = range.end.y - range.start.y + 1
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        scroll.value.row = max(0, range.start.y - max(0, (rows - height) / 2))
        ghostty_terminal_scroll_viewport(t, scroll)
    }
}
