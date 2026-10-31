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
    /// Moves a pane out of its tab into a new tab right after it, focused. A tab's only pane
    /// stays where it is.
    case movePaneToNewTab(PaneId)
    /// Moves a pane beside another one (in any tab) on `side`, focused; a tab left empty closes.
    case movePane(PaneId, beside: PaneId, side: Direction)
    /// Moves every pane of a tab beside a pane of another tab on `side`, keeping their
    /// arrangement and focus; the tab closes.
    case mergeTab(TabId, beside: PaneId, side: Direction)
    /// Floats a tiled pane in a window of its own (in front), tears a pane out of a window it
    /// shares, or moves a window that is just this pane to `frame`. A tab keeps a tiled pane.
    case float(PaneId, frame: FloatFrame?)
    /// Opens a new pane in a window of its own over `beside`'s tab; in the tree it goes right
    /// of the whole tab. Takes focus only when asked (an agent's float never does).
    case newFloat(beside: PaneId, frame: FloatFrame?, focus: Bool)
    /// Changes the window holding `pane`; nil keeps each value. Restoring it from the tray
    /// raises it; sending the focused window to the tray hands focus to the tiled panes.
    case setFloat(PaneId, frame: FloatFrame?, minimized: Bool?, pinned: Bool?)
    /// Docks the window holding `pane`, splits and all: where it is (`beside` nil), or beside
    /// a tiled pane on `side`. Focuses `pane`.
    case dock(PaneId, beside: PaneId?, side: Direction)
    /// Moves `pane` (out of a window too) along the whole `side` edge of a tab's tiled panes.
    case movePaneToEdge(PaneId, tab: TabId, side: Direction)
}

/// Session → ordered tabs → split tree per tab. A value type: `apply` is pure apart from id
/// allocation, which keeps every op easy to test and to mirror on the daemon.
public struct Session: Hashable, Sendable, Codable {
    public private(set) var tabs: [Tab] = []
    public private(set) var activeTabId: TabId?
    /// Floating windows over the tabs, back to front.
    public private(set) var floats: [FloatWindow] = []
    private var lastId: UInt64 = 0
    private var lastFloat: UInt64 = 0

    /// Most windows one tab holds.
    public static let maxFloatsPerTab = 16

    private enum CodingKeys: String, CodingKey {
        case tabs, activeTabId, floats, lastId, lastFloat
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decode([Tab].self, forKey: .tabs)
        activeTabId = try c.decodeIfPresent(TabId.self, forKey: .activeTabId)
        floats = try c.decodeIfPresent([FloatWindow].self, forKey: .floats) ?? []
        lastId = try c.decode(UInt64.self, forKey: .lastId)
        lastFloat = try c.decodeIfPresent(UInt64.self, forKey: .lastFloat) ?? 0
    }

    /// A session with one tab holding one pane.
    public init() {
        apply(.newTab)
    }

    /// A session as another source of truth has it (the daemon's layout). Ids it allocates
    /// later (local ops) continue after the largest id in `tabs`.
    public init(tabs: [Tab], activeTabId: TabId?, floats: [FloatWindow] = []) {
        self.tabs = tabs
        self.activeTabId = activeTabId ?? tabs.first?.id
        lastId = tabs.flatMap { [$0.id.rawValue] + $0.root.panes.map(\.rawValue) }.max() ?? 0
        self.floats = floats.sorted { $0.z < $1.z }
        lastFloat = floats.map(\.id.rawValue).max() ?? 0
    }

    /// The same tabs with the windows another source of truth reports (the daemon's
    /// `Floats`), kept consistent with the trees.
    public func with(floats: [FloatWindow]) -> Session {
        var next = self
        next.floats = floats.sorted { $0.z < $1.z }
        next.lastFloat = max(lastFloat, floats.map(\.id.rawValue).max() ?? 0)
        next.tidyFloats()
        return next
    }

    // MARK: Floating windows

    /// The window holding `pane`.
    public func window(containing pane: PaneId) -> FloatWindow? {
        floats.first { $0.panes.contains(pane) }
    }

    public func isFloating(_ pane: PaneId) -> Bool {
        floats.contains { $0.panes.contains(pane) }
    }

    /// The windows over `tab`, back to front.
    public func windows(in tab: TabId) -> [FloatWindow] {
        guard let root = tabs.first(where: { $0.id == tab })?.root else { return [] }
        return floats.filter { $0.panes.first.map(root.contains) == true }
    }

    /// The tab's tiled panes: its tree without its windows' subtrees.
    public func tiledRoot(of tab: Tab) -> Node? {
        tab.root.removing { isFloating($0) }
    }

    /// The window's own layout: its subtree of the tab's tree.
    public func root(of window: FloatWindow) -> Node? {
        tab(containing: window.panes.first ?? PaneId(0))?.root.subtree(of: window.panes)
    }

    private func windowIndex(_ pane: PaneId) -> Int? {
        floats.firstIndex { $0.panes.contains(pane) }
    }

    private var topZ: UInt32 { floats.last?.z ?? 0 }

    /// Brings window `index` to the front.
    private mutating func raise(_ index: Int) {
        guard index != floats.count - 1 else { return }
        var window = floats.remove(at: index)
        window.z = topZ + 1
        floats.append(window)
    }

    private mutating func openWindow(_ panes: [PaneId], frame: FloatFrame) {
        lastFloat += 1
        floats.append(FloatWindow(id: FloatId(lastFloat), panes: panes, frame: frame, z: topZ + 1))
    }

    /// Panes just put beside `target` join its window, if it is in one.
    private mutating func adopt(_ target: PaneId, _ panes: [PaneId]) {
        guard let index = windowIndex(target) else { return }
        floats[index].panes += panes
    }

    /// Takes `pane` out of the window holding it.
    private mutating func release(_ pane: PaneId) {
        for index in floats.indices { floats[index].panes.removeAll { $0 == pane } }
    }

    /// The daemon's invariants: a window's panes are one subtree of one tab, in reading order;
    /// empty windows go; a tab left without a tiled pane docks its frontmost window.
    private mutating func tidyFloats() {
        for index in floats.indices {
            let window = floats[index]
            guard let tab = window.panes.compactMap({ tab(containing: $0) }).first else {
                floats[index].panes = []
                continue
            }
            let order = tab.root.panes
            let kept = order.filter(window.panes.contains)
            floats[index].panes = kept.first.map { tab.root.contiguous(around: $0, within: Set(kept)) } ?? []
        }
        floats.removeAll { $0.panes.isEmpty }
        for tab in tabs {
            while tiledRoot(of: tab) == nil, let front = floats.lastIndex(where: { tab.root.contains($0.panes[0]) }) {
                floats.remove(at: front)
            }
        }
    }

    /// A spot for a new window in `tab`: stepped down and right for each window already there.
    private func freeFrame(in tab: Tab) -> FloatFrame {
        let step = 0.04 * Double(windows(in: tab.id).count % 5)
        var frame = FloatFrame.standard
        frame.x += step
        frame.y += step
        return frame
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
        case .movePaneToNewTab(let pane): movePaneToNewTab(pane)
        case .movePane(let pane, let target, let side): movePane(pane, beside: target, side: side)
        case .mergeTab(let id, let target, let side): mergeTab(id, beside: target, side: side)
        case .float(let pane, let frame): float(pane, frame: frame?.clamped)
        case .newFloat(let pane, let frame, let focus): newFloat(beside: pane, frame: frame?.clamped, focus: focus)
        case .setFloat(let pane, let frame, let minimized, let pinned):
            setFloat(pane, frame: frame?.clamped, minimized: minimized, pinned: pinned)
        case .dock(let pane, let target, let side): dock(pane, beside: target, side: side)
        case .movePaneToEdge(let pane, let tab, let side): movePaneToEdge(pane, tab: tab, side: side)
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
        adopt(pane, [new])
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
        tidyFloats()
    }

    private mutating func focus(_ pane: PaneId) {
        guard let tab = tab(containing: pane) else { return }
        updateTab(tab.id) {
            $0.focused = pane
            if $0.zoomed != pane { $0.zoomed = nil }
        }
        activeTabId = tab.id
        // A window focused comes to the front, and back from the tray.
        if let index = windowIndex(pane) {
            floats[index].minimized = false
            raise(index)
        }
    }

    /// Geometric: of the panes entirely beyond the focused pane's `direction` edge that overlap it
    /// across the other axis, the closest wins, then the one sharing the longest edge, then the
    /// first in reading order. No wrap-around. Unzooms, since the target is hidden while zoomed.
    private mutating func focusDirection(_ direction: Direction) {
        guard let tab = activeTab else { return }
        // Within the focused pane's own layer: the tiled panes, or its window.
        let layer = window(containing: tab.focused).flatMap { tab.root.subtree(of: $0.panes) } ?? tiledRoot(of: tab) ?? tab.root
        let frames = layer.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
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

        let order = layer.panes
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
        // Only dividers the pane's own layer shows: a split whose other side lies wholly in
        // another layer (a window over the tiled panes, or the panes around a window) is hidden.
        let own = window(containing: pane)?.id
        let candidates = path.indices.reversed().filter {
            path[$0].axis == direction.axis && path[$0].sibling.panes.contains { window(containing: $0)?.id == own }
        }
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
        tidyFloats()
    }

    private mutating func moveTab(_ id: TabId, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
    }

    private mutating func movePaneToNewTab(_ pane: PaneId) {
        guard let tab = tab(containing: pane), let index = tabs.firstIndex(of: tab), detach(pane, from: tab.id) else { return }
        let new = Tab(id: TabId(nextId()), root: .leaf(pane), focused: pane)
        tabs.insert(new, at: index + 1)
        activeTabId = new.id
        release(pane)
        tidyFloats()
    }

    private mutating func movePane(_ pane: PaneId, beside target: PaneId, side: Direction) {
        guard pane != target, let source = tab(containing: pane), tab(containing: target) != nil else { return }
        release(pane)
        if !detach(pane, from: source.id) { tabs.removeAll { $0.id == source.id } }
        insert(.leaf(pane), beside: target, side: side, focus: pane)
        tidyFloats()
    }

    private mutating func mergeTab(_ id: TabId, beside target: PaneId, side: Direction) {
        guard let source = tabs.first(where: { $0.id == id }), let into = tab(containing: target), into.id != id else { return }
        tabs.removeAll { $0.id == id }
        // Its windows dock as they merge: one window never sits inside another.
        floats.removeAll { source.root.contains($0.panes[0]) }
        insert(source.root, beside: target, side: side, focus: source.focused)
        tidyFloats()
    }

    private mutating func float(_ pane: PaneId, frame: FloatFrame?) {
        guard let tab = tab(containing: pane) else { return }
        if let index = windowIndex(pane) {
            if floats[index].panes.count == 1 {
                if let frame { floats[index].frame = frame }
                raise(index)
                return
            }
            // Torn out of a shared window: its own, just below and right of the old one.
            guard windows(in: tab.id).count < Self.maxFloatsPerTab else { return }
            var from = floats[index].frame
            from.x += 0.04
            from.y += 0.04
            release(pane)
            _ = detach(pane, from: tab.id)
            updateTab(tab.id) {
                $0.root = .split(axis: .horizontal, ratio: 0.5, first: $0.root, second: .leaf(pane))
                $0.focused = pane
            }
            openWindow([pane], frame: frame ?? from.clamped ?? .standard)
        } else {
            guard let tiled = tiledRoot(of: tab), tiled.panes.count > 1,
                  windows(in: tab.id).count < Self.maxFloatsPerTab else { return }
            updateTab(tab.id) { if $0.zoomed == pane { $0.zoomed = nil } }
            openWindow([pane], frame: frame ?? freeFrame(in: tab))
        }
        tidyFloats()
    }

    private mutating func newFloat(beside anchor: PaneId, frame: FloatFrame?, focus: Bool) {
        guard let tab = tab(containing: anchor), windows(in: tab.id).count < Self.maxFloatsPerTab else { return }
        let new = PaneId(nextId())
        let spot = frame ?? freeFrame(in: tab)
        updateTab(tab.id) {
            $0.root = .split(axis: .horizontal, ratio: 0.5, first: $0.root, second: .leaf(new))
            if focus {
                $0.focused = new
                $0.zoomed = nil
            }
        }
        if focus { activeTabId = tab.id }
        openWindow([new], frame: spot)
    }

    private mutating func setFloat(_ pane: PaneId, frame: FloatFrame?, minimized: Bool?, pinned: Bool?) {
        guard let index = windowIndex(pane), let tab = tab(containing: pane) else { return }
        if let frame { floats[index].frame = frame }
        if let minimized { floats[index].minimized = minimized }
        if let pinned { floats[index].pinned = pinned }
        let window = floats[index]
        // Restoring raises, even a window already out: forward without taking the focus.
        if minimized == false { raise(index) }
        if window.minimized && window.panes.contains(tab.focused), let next = tiledRoot(of: tab)?.panes.first {
            updateTab(tab.id) {
                $0.focused = next
                $0.zoomed = nil
            }
        }
    }

    private mutating func dock(_ pane: PaneId, beside target: PaneId?, side: Direction) {
        guard let index = windowIndex(pane), let home = tab(containing: pane) else { return }
        guard let target else {
            floats.remove(at: index)
            focus(pane)
            return
        }
        guard tab(containing: target) != nil, !isFloating(target) else { return }
        let window = floats.remove(at: index)
        guard let (rest, taken) = home.root.takingSubtree(window.panes) else {
            floats.insert(window, at: index)
            return
        }
        updateTab(home.id) {
            $0.root = rest
            if window.panes.contains($0.focused) || $0.zoomed != nil {
                $0.focused = rest.panes[0]
                $0.zoomed = nil
            }
        }
        insert(taken, beside: target, side: side, focus: pane)
        tidyFloats()
    }

    private mutating func movePaneToEdge(_ pane: PaneId, tab id: TabId, side: Direction) {
        guard let source = tab(containing: pane), tabs.contains(where: { $0.id == id }) else { return }
        if source.id == id, source.root == .leaf(pane) { return }
        release(pane)
        if !detach(pane, from: source.id) { tabs.removeAll { $0.id == source.id } }
        // A third of the edge: the pane joins the tab's panes rather than halving them.
        updateTab(id) {
            $0.root = side.isForward
                ? .split(axis: side.axis, ratio: 2.0 / 3.0, first: $0.root, second: .leaf(pane))
                : .split(axis: side.axis, ratio: 1.0 / 3.0, first: .leaf(pane), second: $0.root)
            $0.focused = pane
            $0.zoomed = nil
        }
        activeTabId = id
        tidyFloats()
    }

    /// Takes `pane` out of a tab that keeps others; false when it is the tab's only pane.
    private mutating func detach(_ pane: PaneId, from id: TabId) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), let (root, nearest) = tab.root.removing(pane) else { return false }
        updateTab(id) {
            $0.root = root
            if $0.focused == pane { $0.focused = nearest }
            if $0.zoomed == pane { $0.zoomed = nil }
        }
        return true
    }

    private mutating func insert(_ node: Node, beside target: PaneId, side: Direction, focus: PaneId) {
        guard let tab = tab(containing: target) else { return }
        adopt(target, node.panes)
        updateTab(tab.id) {
            $0.root = $0.root.replacing(target, with: side.isForward
                ? .split(axis: side.axis, ratio: 0.5, first: .leaf(target), second: node)
                : .split(axis: side.axis, ratio: 0.5, first: node, second: .leaf(target)))
            $0.focused = focus
            $0.zoomed = nil
        }
        activeTabId = tab.id
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
