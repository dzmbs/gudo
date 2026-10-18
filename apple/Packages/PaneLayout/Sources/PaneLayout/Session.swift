import CoreGraphics

public struct TabId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "tab-\(rawValue)" }
}

public struct Tab: Identifiable, Hashable, Sendable, Codable {
    public let id: TabId
    /// Set by `rename`; nil means the UI derives a title.
    public var title: String?
    public var root: Node
    public var focused: PaneId
    /// The pane shown alone in the tab, if any.
    public var zoomed: PaneId?

    public init(id: TabId, title: String? = nil, root: Node, focused: PaneId, zoomed: PaneId? = nil) {
        self.id = id
        self.title = title
        self.root = root
        self.focused = focused
        self.zoomed = zoomed
    }
}

/// A change to a session's layout. The same vocabulary as the daemon's layout model, so a
/// daemon-backed `LayoutStore` can forward ops unchanged.
public enum LayoutOp: Hashable, Sendable, Codable {
    /// Splits `pane`; the new pane becomes `second` (right of or below it) and takes focus.
    case split(PaneId, Axis)
    /// Closes `pane`. Its sibling takes the parent's space; closing a tab's last pane closes the tab.
    case close(PaneId)
    /// Focuses `pane` and activates its tab.
    case focus(PaneId)
    /// Moves focus from the active tab's focused pane to the nearest pane in `direction`.
    case focusDirection(Direction)
    /// Moves a divider next to `pane` in `direction` by `amount`, a fraction of that split's extent:
    /// the divider on `pane`'s `direction` side if it has one, otherwise the one on its other side.
    case resize(PaneId, Direction, amount: Double)
    /// Zooms the active tab's focused pane, or unzooms.
    case toggleZoom
    /// Opens a tab with one pane after the active tab.
    case newTab
    case closeTab(TabId)
    /// Moves a tab to `index` (clamped to the tab range).
    case moveTab(TabId, to: Int)
    /// Renames a tab; an empty title goes back to the derived one.
    case rename(TabId, String)
}

/// Session → ordered tabs → split tree per tab. A value type: `apply` is pure apart from id
/// allocation, which keeps every op easy to test and to mirror on the daemon.
public struct Session: Hashable, Sendable, Codable {
    public private(set) var tabs: [Tab] = []
    public private(set) var activeTabId: TabId?
    private var lastId: UInt64 = 0

    /// A session with one tab holding one pane.
    public init() {
        apply(.newTab)
    }

    public var activeTab: Tab? {
        tabs.first { $0.id == activeTabId }
    }

    public var panes: Set<PaneId> {
        Set(tabs.flatMap(\.root.panes))
    }

    public func tab(containing pane: PaneId) -> Tab? {
        tabs.first { $0.root.contains(pane) }
    }

    public mutating func apply(_ op: LayoutOp) {
        switch op {
        case .split(let pane, let axis): split(pane, axis)
        case .close(let pane): close(pane)
        case .focus(let pane): focus(pane)
        case .focusDirection(let direction): focusDirection(direction)
        case .resize(let pane, let direction, let amount): resize(pane, direction, amount)
        case .toggleZoom: toggleZoom()
        case .newTab: newTab()
        case .closeTab(let id): closeTab(id)
        case .moveTab(let id, let index): moveTab(id, to: index)
        case .rename(let id, let title): updateTab(id) { $0.title = title.isEmpty ? nil : title }
        }
    }

    // MARK: Ops

    private mutating func split(_ pane: PaneId, _ axis: Axis) {
        guard let tab = tab(containing: pane) else { return }
        let new = PaneId(nextId())
        updateTab(tab.id) {
            $0.root = $0.root.replacing(pane, with: .split(axis: axis, ratio: 0.5, first: .leaf(pane), second: .leaf(new)))
            $0.focused = new
            $0.zoomed = nil
        }
        activeTabId = tab.id
    }

    private mutating func close(_ pane: PaneId) {
        guard let tab = tab(containing: pane) else { return }
        guard let (root, nearest) = tab.root.removing(pane) else {
            closeTab(tab.id)
            return
        }
        updateTab(tab.id) {
            $0.root = root
            if $0.focused == pane { $0.focused = nearest }
            if $0.zoomed == pane { $0.zoomed = nil }
        }
    }

    private mutating func focus(_ pane: PaneId) {
        guard let tab = tab(containing: pane) else { return }
        updateTab(tab.id) {
            $0.focused = pane
            if $0.zoomed != pane { $0.zoomed = nil }
        }
        activeTabId = tab.id
    }

    /// Geometric: of the panes entirely beyond the focused pane's `direction` edge that overlap it
    /// across the other axis, the closest wins, then the one sharing the longest edge, then the
    /// first in reading order. No wrap-around. Unzooms, since the target is hidden while zoomed.
    private mutating func focusDirection(_ direction: Direction) {
        guard let tab = activeTab else { return }
        let frames = tab.root.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let from = frames[tab.focused] else { return }
        let epsilon = 1e-9

        func gap(_ to: CGRect) -> Double {
            switch direction {
            case .left: from.minX - to.maxX
            case .right: to.minX - from.maxX
            case .up: from.minY - to.maxY
            case .down: to.minY - from.maxY
            }
        }
        func overlap(_ to: CGRect) -> Double {
            direction.axis == .horizontal
                ? min(from.maxY, to.maxY) - max(from.minY, to.minY)
                : min(from.maxX, to.maxX) - max(from.minX, to.minX)
        }

        let order = tab.root.panes
        let target = frames
            .filter { $0.key != tab.focused && gap($0.value) > -epsilon && overlap($0.value) > epsilon }
            .min { a, b in
                let (gapA, gapB) = (gap(a.value), gap(b.value))
                if abs(gapA - gapB) > epsilon { return gapA < gapB }
                let (overlapA, overlapB) = (overlap(a.value), overlap(b.value))
                if abs(overlapA - overlapB) > epsilon { return overlapA > overlapB }
                return order.firstIndex(of: a.key)! < order.firstIndex(of: b.key)!
            }?.key
        guard let target else { return }
        updateTab(tab.id) {
            $0.focused = target
            $0.zoomed = nil
        }
    }

    private mutating func resize(_ pane: PaneId, _ direction: Direction, _ amount: Double) {
        guard let tab = tab(containing: pane), let path = tab.root.path(to: pane) else { return }
        let candidates = path.indices.reversed().filter { path[$0].axis == direction.axis }
        // The divider on the pane's `direction` side: the pane is in `first` for right/down.
        guard let depth = candidates.first(where: { path[$0].inFirst == direction.isForward }) ?? candidates.first else { return }
        updateTab(tab.id) {
            $0.root = $0.root.adjustingRatio(towards: pane, depth: depth, by: direction.isForward ? amount : -amount)
        }
    }

    private mutating func toggleZoom() {
        guard let tab = activeTab, case .split = tab.root else { return }
        updateTab(tab.id) { $0.zoomed = $0.zoomed == nil ? $0.focused : nil }
    }

    private mutating func newTab() {
        let pane = PaneId(nextId())
        let tab = Tab(id: TabId(nextId()), root: .leaf(pane), focused: pane)
        let index = tabs.firstIndex { $0.id == activeTabId }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        activeTabId = tab.id
    }

    /// Closing the active tab activates the one that slides into its place, else the previous one.
    private mutating func closeTab(_ id: TabId) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    private mutating func moveTab(_ id: TabId, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
    }

    private mutating func updateTab(_ id: TabId, _ body: (inout Tab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[index])
    }

    private mutating func nextId() -> UInt64 {
        lastId += 1
        return lastId
    }
}
