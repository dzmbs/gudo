import Foundation
import Observation

/// A pane on one of a window's hosts: the host's id (`HostGroups.localId` for this device) and
/// the pane's id in that host's layout. Pane ids are per host, so two hosts can both have a
/// "pane 3".
public struct HostPane: Hashable, Sendable, Codable, CustomStringConvertible {
    public var hostId: String
    public var pane: PaneId

    public init(hostId: String, pane: PaneId) {
        self.hostId = hostId
        self.pane = pane
    }

    public var description: String { "\(hostId)/\(pane.rawValue)" }
}

/// A VS Code editor in a window's split tree (docs/APP-ARCHITECTURE.md §20): a folder on a host,
/// shown by the window itself (a web view on that host's editor server), not a pane any host
/// knows. `id` names it for as long as it is open (its web view and session in the window), and
/// across relaunches.
public struct EditorMember: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public var id: UUID
    public var hostId: String
    /// The folder on the host (the worktree's root when the pane it was opened from is in one).
    public var folder: String

    public init(id: UUID = UUID(), hostId: String, folder: String) {
        self.id = id
        self.hostId = hostId
        self.folder = folder
    }

    /// The folder's last component ("proj"), or the folder itself ("~", "/").
    public var folderName: String {
        let trimmed = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return name.isEmpty ? folder : name
    }

    /// Whether `path` is the folder or inside it.
    public func contains(path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    public var description: String { "\(hostId):\(folder)" }
}

/// A browser page in a window's split tree: shown by the window itself, not a pane any host
/// knows. `hostId` is the host whose `localhost` it reaches (its dev servers), if any; `url` the
/// page it shows, kept as it navigates so a relaunch comes back to it.
public struct BrowserMember: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public var id: UUID
    public var hostId: String?
    public var url: String

    public init(id: UUID = UUID(), hostId: String?, url: String) {
        self.id = id
        self.hostId = hostId
        self.url = url
    }

    public var description: String { "\(hostId ?? "-"):\(url)" }
}

/// A browsing tool in a window's split tree (Files, Changes, Ports, Session Replays): shown by
/// the window itself beside its panes, as editors and pages are. `hostId` is the host it was
/// opened for; a relaunch brings it back.
public struct ToolMember: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public enum Tool: String, Hashable, Sendable, Codable, CaseIterable {
        case files, changes, ports, replays, viewer
    }

    public var id: UUID
    public var hostId: String
    public var tool: Tool
    /// The viewer's file, as the host spells it.
    public var path: String?
    public var line: Int?
    public var column: Int?

    public init(id: UUID = UUID(), hostId: String, tool: Tool, path: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.id = id
        self.hostId = hostId
        self.tool = tool
        self.path = path
        self.line = line
        self.column = column
    }

    public var description: String { "\(hostId):\(tool.rawValue)" }
}

/// A tab whose panes live on more than one host (a "mixed" tab, docs/APP-ARCHITECTURE.md §19),
/// or that holds VS Code editors (`editors`, §20): an editor is a leaf only the window knows.
/// The window owns it: no host knows the arrangement. Its split tree is an ordinary `Tab` over
/// the composite's own leaf ids, so every layout op (focus, directional focus, resize, zoom) is
/// the same code as a host tab's; `members` says which host pane each leaf shows.
///
/// Each host's panes in a composite live in one tab on that host, its *carrier*: a pane split
/// off a leaf is split in the carrier on its host, a pane added from another host opens a new
/// tab there that becomes its carrier, closing a leaf closes the pane on its host. So every
/// pane still belongs to its host's own layout (other windows and devices see the carrier as a
/// plain tab), and the host keeps a sensible arrangement of its own panes.
public struct CompositeTab: Identifiable, Hashable, Sendable, Codable {
    /// The arrangement. Its id is the composite's id in the window
    /// (`TabRef(hostId: HostGroups.mixedId, tab: id)`).
    public private(set) var layout: Tab
    public private(set) var members: [PaneId: HostPane]
    /// The editor each editor leaf shows (leaves not in `members`).
    public private(set) var editors: [PaneId: EditorMember] = [:]
    /// The page each browser leaf shows (leaves in neither of the above).
    public private(set) var browsers: [PaneId: BrowserMember] = [:]
    public private(set) var tools: [PaneId: ToolMember] = [:]
    /// The tab on each host that holds this composite's panes there.
    public internal(set) var carriers: [String: TabId]

    private enum CodingKeys: String, CodingKey {
        case layout, members, editors, browsers, tools, carriers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(Tab.self, forKey: .layout)
        members = try container.decode([PaneId: HostPane].self, forKey: .members)
        // Absent from older saves.
        editors = try container.decodeIfPresent([PaneId: EditorMember].self, forKey: .editors) ?? [:]
        browsers = try container.decodeIfPresent([PaneId: BrowserMember].self, forKey: .browsers) ?? [:]
        tools = try container.decodeIfPresent([PaneId: ToolMember].self, forKey: .tools) ?? [:]
        carriers = try container.decode([String: TabId].self, forKey: .carriers)
    }

    public var id: TabId { layout.id }
    public var title: String? { layout.title }
    public var leaves: [PaneId] { layout.root.panes }
    public var focusedLeaf: PaneId { layout.focused }
    public var focusedMember: HostPane? { members[layout.focused] }
    public var focusedEditor: EditorMember? { editors[layout.focused] }
    /// Only editors: a VS Code tab (the sidebar lists it under VS Code, not Mixed).
    public var isEditorOnly: Bool { members.isEmpty && browsers.isEmpty && tools.isEmpty && !editors.isEmpty }
    public var focusedBrowser: BrowserMember? { browsers[layout.focused] }
    public var isBrowserOnly: Bool { members.isEmpty && editors.isEmpty && tools.isEmpty && !browsers.isEmpty }
    public var focusedTool: ToolMember? { tools[layout.focused] }

    public func leaf(forTool id: UUID) -> PaneId? {
        tools.first { $0.value.id == id }?.key
    }

    /// The first leaf (in reading order) showing a tool of this kind.
    public func leaf(showing tool: ToolMember.Tool) -> PaneId? {
        leaves.first { tools[$0]?.tool == tool }
    }

    public func leaf(forBrowser id: UUID) -> PaneId? {
        browsers.first { $0.value.id == id }?.key
    }

    public func leaf(forEditor id: UUID) -> PaneId? {
        editors.first { $0.value.id == id }?.key
    }

    /// The leaves on screen: the zoomed one alone, else all.
    public var visibleLeaves: [PaneId] { layout.zoomed.map { [$0] } ?? leaves }

    /// The hosts it shows, in the order their first pane (or editor) appears.
    public var hosts: [String] {
        var result: [String] = []
        for leaf in leaves {
            if let host = members[leaf]?.hostId ?? editors[leaf]?.hostId ?? browsers[leaf]?.hostId ?? tools[leaf]?.hostId, !result.contains(host) {
                result.append(host)
            }
        }
        return result
    }

    /// The hosts whose panes it shows (editors left out): a composite down to one dissolves.
    public var paneHosts: [String] {
        var result: [String] = []
        for leaf in leaves {
            if let host = members[leaf]?.hostId, !result.contains(host) { result.append(host) }
        }
        return result
    }

    /// The same tab under another id (reopened after it closed).
    func renumbered(_ id: TabId) -> CompositeTab {
        var copy = self
        copy.layout = Tab(id: id, title: layout.title, root: layout.root, focused: layout.focused, zoomed: layout.zoomed)
        return copy
    }

    public init(id: TabId, editor: EditorMember) {
        let leaf = PaneId(1)
        layout = Tab(id: id, root: .leaf(leaf), focused: leaf)
        members = [:]
        editors = [leaf: editor]
        carriers = [:]
    }

    public init(id: TabId, browser: BrowserMember) {
        let leaf = PaneId(1)
        layout = Tab(id: id, root: .leaf(leaf), focused: leaf)
        members = [:]
        browsers = [leaf: browser]
        carriers = [:]
    }

    public init(id: TabId, tool: ToolMember) {
        let leaf = PaneId(1)
        layout = Tab(id: id, root: .leaf(leaf), focused: leaf)
        members = [:]
        tools = [leaf: tool]
        carriers = [:]
    }

    /// A host tab made into a composite (to split it with another host): the same tree, each of
    /// its panes a leaf, the tab its host's carrier.
    public init(id: TabId, hostId: String, tab: Tab) {
        var members: [PaneId: HostPane] = [:]
        var lastLeaf: UInt64 = 0
        var leafForPane: [PaneId: PaneId] = [:]
        func map(_ node: Node) -> Node {
            switch node {
            case .leaf(let pane):
                lastLeaf += 1
                let leaf = PaneId(lastLeaf)
                members[leaf] = HostPane(hostId: hostId, pane: pane)
                leafForPane[pane] = leaf
                return .leaf(leaf)
            case .split(let axis, let ratio, let first, let second):
                return .split(axis: axis, ratio: ratio, first: map(first), second: map(second))
            }
        }
        let root = map(tab.root)
        layout = Tab(id: id, title: tab.title, root: root, focused: leafForPane[tab.focused] ?? root.panes[0])
        self.members = members
        carriers = [hostId: tab.id]
    }

    public func leaf(for member: HostPane) -> PaneId? {
        members.first { $0.value == member }?.key
    }

    /// The panes it shows of `host`, in reading order.
    public func panes(onHost host: String) -> [PaneId] {
        leaves.compactMap { members[$0]?.hostId == host ? members[$0]?.pane : nil }
    }

    /// Ops that only arrange the composite: focus, directional focus, resize, zoom, rename.
    /// Ops that make or end panes go through `CompositeTabs`, which asks the hosts first.
    public mutating func apply(_ op: LayoutOp) {
        switch op {
        case .focus, .focusDirection, .resize, .toggleZoom, .rename:
            var session = Session(tabs: [layout], activeTabId: layout.id)
            session.apply(op)
            if let tab = session.tabs.first { layout = tab }
        case .split, .close, .newTab, .closeTab, .moveTab, .movePaneToNewTab, .movePane, .mergeTab,
             .float, .newFloat, .setFloat, .dock, .movePaneToEdge:
            break
        }
    }

    /// Adds `member` beside `leaf` (right of it for `.horizontal`, below for `.vertical`), focused.
    @discardableResult
    public mutating func insert(_ member: HostPane, beside leaf: PaneId, axis: Axis) -> PaneId? {
        guard let newLeaf = splitLeaf(leaf, axis: axis) else { return nil }
        members[newLeaf] = member
        return newLeaf
    }

    @discardableResult
    public mutating func insert(editor: EditorMember, beside leaf: PaneId, axis: Axis) -> PaneId? {
        guard let newLeaf = splitLeaf(leaf, axis: axis) else { return nil }
        editors[newLeaf] = editor
        return newLeaf
    }

    @discardableResult
    public mutating func insert(browser: BrowserMember, beside leaf: PaneId, axis: Axis) -> PaneId? {
        guard let newLeaf = splitLeaf(leaf, axis: axis) else { return nil }
        browsers[newLeaf] = browser
        return newLeaf
    }

    @discardableResult
    public mutating func insert(tool: ToolMember, beside leaf: PaneId, axis: Axis) -> PaneId? {
        guard let newLeaf = splitLeaf(leaf, axis: axis) else { return nil }
        tools[newLeaf] = tool
        return newLeaf
    }

    /// The page a browser leaf shows now (it navigated).
    public mutating func update(browser: BrowserMember) {
        guard let leaf = leaf(forBrowser: browser.id) else { return }
        browsers[leaf] = browser
    }

    public mutating func update(tool: ToolMember) {
        guard let leaf = leaf(forTool: tool.id) else { return }
        tools[leaf] = tool
    }

    private mutating func splitLeaf(_ leaf: PaneId, axis: Axis) -> PaneId? {
        var session = Session(tabs: [layout], activeTabId: layout.id)
        let before = Set(leaves)
        session.apply(.split(leaf, axis))
        guard let tab = session.tabs.first, let newLeaf = tab.root.panes.first(where: { !before.contains($0) }) else { return nil }
        layout = tab
        return newLeaf
    }

    /// Removes a leaf; its sibling takes its place. False when it was the last leaf (the
    /// composite is then empty and left as it was).
    @discardableResult
    public mutating func remove(leaf: PaneId) -> Bool {
        guard isLeaf(leaf) else { return true }
        var session = Session(tabs: [layout], activeTabId: layout.id)
        session.apply(.close(leaf))
        guard let tab = session.tabs.first else { return false }
        layout = tab
        members[leaf] = nil
        editors[leaf] = nil
        browsers[leaf] = nil
        tools[leaf] = nil
        return true
    }

    /// Whether the leaf shows anything (a pane, an editor, a page or a tool).
    func isLeaf(_ leaf: PaneId) -> Bool {
        members[leaf] != nil || editors[leaf] != nil || browsers[leaf] != nil || tools[leaf] != nil
    }
}

/// A window's mixed tabs, kept in step with the hosts whose panes they show. The store never
/// changes a host's layout by itself: it asks through `send`, and adopts what the host answers
/// (a daemon answers after a round trip) when `reconcile()` sees it.
///
/// What it reconciles:
/// - a pane its host no longer has (closed there, its process exited, closed on another device)
///   leaves the composite, but only while the host is known (`hostSession` non-nil): a host that
///   is down or still connecting keeps its leaves, shown stale;
/// - a pane that appears in a carrier (split on another device) joins the composite beside that
///   host's last leaf;
/// - a composite left with panes from one host only dissolves: its carrier shows again as that
///   host's plain tab (`onDissolve`).
@MainActor
@Observable
public final class CompositeTabs {
    public private(set) var tabs: [CompositeTab] = []

    /// Each host's layout as this window sees it now, or nil while it is unknown (not open, not
    /// ready, link down): its leaves then stay as they are.
    @ObservationIgnored public var hostSession: (String) -> Session? = { _ in nil }
    /// Sends an op to a host's layout; false when the host cannot take it now (not live).
    @ObservationIgnored public var send: (String, LayoutOp) -> Bool = { _, _ in false }
    /// A composite dissolved into its one remaining host's tab (nil: nothing was left).
    @ObservationIgnored public var onDissolve: (TabId, TabRefParts?) -> Void = { _, _ in }
    /// A pane this window asked for arrived and is now the composite's focused leaf.
    @ObservationIgnored public var onAdopt: (TabId, PaneId) -> Void = { _, _ in }
    /// How long a host's answer to a split is waited for.
    @ObservationIgnored public var answerTimeout = Duration.seconds(10)

    /// A host tab, without HostKit's `TabRef` (PaneLayout does not know hosts).
    public struct TabRefParts: Hashable, Sendable {
        public var hostId: String
        public var tab: TabId
    }

    /// A pane this window asked a host for, to place once the host has it.
    private struct Pending {
        let token = UUID()
        var composite: TabId
        var host: String
        var beside: PaneId
        var axis: Axis
        var panesBefore: Set<PaneId>
        var tabsBefore: Set<TabId>
        /// The host has no carrier yet: the pane comes in a new tab, which becomes it.
        var newCarrier: Bool
        var deadline: ContinuousClock.Instant
    }

    @ObservationIgnored private var pending: [Pending] = []
    /// Panes moved out to a tab of their own, until their host has taken them out of the
    /// carrier (so they are not adopted back as strays meanwhile).
    @ObservationIgnored private var released: [HostPane: ContinuousClock.Instant] = [:]

    public init(tabs: [CompositeTab] = []) {
        self.tabs = tabs
    }

    public func tab(_ id: TabId) -> CompositeTab? {
        tabs.first { $0.id == id }
    }

    public func tab(containing member: HostPane) -> CompositeTab? {
        tabs.first { $0.leaf(for: member) != nil }
    }

    public func tab(containingEditor id: UUID) -> CompositeTab? {
        tabs.first { $0.leaf(forEditor: id) != nil }
    }

    public func tab(containingBrowser id: UUID) -> CompositeTab? {
        tabs.first { $0.leaf(forBrowser: id) != nil }
    }

    public func tab(containingTool id: UUID) -> CompositeTab? {
        tabs.first { $0.leaf(forTool: id) != nil }
    }

    public var tools: [ToolMember] {
        tabs.flatMap { tab in tab.leaves.compactMap { tab.tools[$0] } }
    }

    public var browsers: [BrowserMember] {
        tabs.flatMap { tab in tab.leaves.compactMap { tab.browsers[$0] } }
    }

    public var editors: [EditorMember] {
        tabs.flatMap { tab in tab.leaves.compactMap { tab.editors[$0] } }
    }

    /// The tabs in the order the window lists them: VS Code tabs (editors only) first, then
    /// browser tabs, then mixed tabs, each in the order they were made.
    public var ordered: [CompositeTab] {
        tabs.filter(\.isEditorOnly) + tabs.filter(\.isBrowserOnly) + tabs.filter { !$0.isEditorOnly && !$0.isBrowserOnly }
    }

    /// Host tabs that carry a composite: their host groups leave them out (the composite shows
    /// their panes).
    public var carriers: [String: Set<TabId>] {
        var result: [String: Set<TabId>] = [:]
        for tab in tabs {
            for (host, carrier) in tab.carriers { result[host, default: []].insert(carrier) }
        }
        return result
    }

    public func isWaiting(_ id: TabId) -> Bool {
        pending.contains { $0.composite == id }
    }

    /// The composites a relaunch restores (ids and trees as saved). Unknown hosts are dropped by
    /// the caller (`dropHost`); stale panes go at the first `reconcile` with their host known.
    public func restore(_ saved: [CompositeTab]) {
        tabs = saved.filter { !$0.leaves.isEmpty }
        pending = []
    }

    // MARK: Making and splitting

    /// Makes a host tab a composite, in its place: the host's group stops listing the tab.
    public func make(fromHost host: String, tab: Tab) -> TabId {
        if let existing = tabs.first(where: { $0.carriers[host] == tab.id }) { return existing.id }
        let id = nextId()
        tabs.append(CompositeTab(id: id, hostId: host, tab: tab))
        return id
    }

    /// ⌘D / ⇧⌘D in a composite: a new pane on the focused leaf's host (an editor's host for an
    /// editor), split in its carrier there, placed beside the focused leaf here.
    public func split(_ id: TabId, axis: Axis) {
        guard let tab = tab(id), let host = tab.focusedMember?.hostId ?? tab.focusedEditor?.hostId ?? tab.focusedTool?.hostId else { return }
        split(id, onHost: host, axis: axis)
    }

    // MARK: Editors

    /// Open in VS Code in a new tab: a composite of one editor.
    @discardableResult
    public func openEditor(_ editor: EditorMember) -> TabId {
        let id = nextId()
        tabs.append(CompositeTab(id: id, editor: editor))
        return id
    }

    /// Open in VS Code beside the focused leaf of a composite.
    @discardableResult
    public func addEditor(_ editor: EditorMember, to id: TabId, axis: Axis = .horizontal) -> PaneId? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        var tab = tabs[index]
        guard let leaf = tab.insert(editor: editor, beside: tab.focusedLeaf, axis: axis) else { return nil }
        tabs[index] = tab
        return leaf
    }

    /// Open in VS Code beside a host tab's focused pane: the tab becomes a composite in its place
    /// (as for Split with Host), the editor beside that pane.
    @discardableResult
    public func addEditor(_ editor: EditorMember, besideHost host: String, tab: Tab, axis: Axis = .horizontal) -> TabId {
        let id = make(fromHost: host, tab: tab)
        addEditor(editor, to: id, axis: axis)
        return id
    }

    // MARK: Browser pages

    @discardableResult
    public func openBrowser(_ browser: BrowserMember) -> TabId {
        let id = nextId()
        tabs.append(CompositeTab(id: id, browser: browser))
        return id
    }

    @discardableResult
    public func addBrowser(_ browser: BrowserMember, to id: TabId, axis: Axis = .horizontal) -> PaneId? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        var tab = tabs[index]
        guard let leaf = tab.insert(browser: browser, beside: tab.focusedLeaf, axis: axis) else { return nil }
        tabs[index] = tab
        return leaf
    }

    /// A browser page beside a host tab's focused pane: the tab becomes a composite in its place.
    @discardableResult
    public func addBrowser(_ browser: BrowserMember, besideHost host: String, tab: Tab, axis: Axis = .horizontal) -> TabId {
        let id = make(fromHost: host, tab: tab)
        addBrowser(browser, to: id, axis: axis)
        return id
    }

    /// Keeps where a page is (it navigated).
    public func update(browser: BrowserMember) {
        guard let index = tabs.firstIndex(where: { $0.leaf(forBrowser: browser.id) != nil }),
              tabs[index].browsers.values.first(where: { $0.id == browser.id }) != browser
        else { return }
        tabs[index].update(browser: browser)
    }

    // MARK: Tools

    /// Keeps what a tool shows (the viewer moved to another file).
    public func update(tool: ToolMember) {
        guard let index = tabs.firstIndex(where: { $0.leaf(forTool: tool.id) != nil }) else { return }
        tabs[index].update(tool: tool)
    }

    @discardableResult
    public func openTool(_ tool: ToolMember) -> TabId {
        let id = nextId()
        tabs.append(CompositeTab(id: id, tool: tool))
        return id
    }

    @discardableResult
    public func addTool(_ tool: ToolMember, to id: TabId, axis: Axis = .horizontal) -> PaneId? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        var tab = tabs[index]
        guard let leaf = tab.insert(tool: tool, beside: tab.focusedLeaf, axis: axis) else { return nil }
        tabs[index] = tab
        return leaf
    }

    /// A tool beside a host tab's focused pane: the tab becomes a composite in its place.
    @discardableResult
    public func addTool(_ tool: ToolMember, besideHost host: String, tab: Tab, axis: Axis = .horizontal) -> TabId {
        let id = make(fromHost: host, tab: tab)
        addTool(tool, to: id, axis: axis)
        return id
    }

    private func nextId() -> TabId {
        TabId((tabs.map(\.id.rawValue).max() ?? 0) + 1)
    }

    /// Split with Host: a new pane on `host` beside the focused leaf.
    public func split(_ id: TabId, onHost host: String, axis: Axis) {
        guard let tab = tab(id), let session = hostSession(host) else {
            settle(id)
            return
        }
        let carrier = tab.carriers[host].flatMap { carrier in session.tabs.first { $0.id == carrier } }
        let op: LayoutOp
        if let focused = tab.focusedMember, focused.hostId == host, carrier?.root.contains(focused.pane) == true {
            op = .split(focused.pane, axis)
        } else if let carrier {
            op = .split(carrier.root.panes.last!, axis)
        } else {
            op = .newTab
        }
        let ask = Pending(
            composite: id, host: host, beside: tab.focusedLeaf, axis: axis, panesBefore: session.panes,
            tabsBefore: Set(session.tabs.map(\.id)), newCarrier: carrier == nil, deadline: .now + answerTimeout)
        guard send(host, op) else {
            settle(id)
            return
        }
        pending.append(ask)
        reconcile()
        let timeout = answerTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout + .milliseconds(50))
            self?.reconcile()
        }
    }

    // MARK: Arranging and closing

    /// Focus, directional focus, resize, zoom and rename; focus is also told to the pane's host.
    public func apply(_ op: LayoutOp, to id: TabId) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        let focusedBefore = tab.focusedMember
        tab.apply(op)
        if tab != tabs[index] { tabs[index] = tab }
        if let member = tab.focusedMember, member != focusedBefore {
            _ = send(member.hostId, .focus(member.pane))
        }
    }

    /// Closes a leaf: its pane closes on its host (the host's layout drops it from the carrier);
    /// an editor leaf just leaves (its server keeps running on the host).
    public func close(leaf: PaneId, in id: TabId) {
        guard let tab = tab(id), tab.isLeaf(leaf) else { return }
        if let member = tab.members[leaf] { _ = send(member.hostId, .close(member.pane)) }
        remove(leaf: leaf, from: id)
        settle(id)
        if let member = self.tab(id)?.focusedMember { _ = send(member.hostId, .focus(member.pane)) }
    }

    /// Move to New Tab from a composite: an editor leaf becomes a VS Code tab of its own (its id
    /// is returned); a host pane goes to a new tab on its host (its own carrier's tab when it
    /// was the composite's last pane there). A composite's only leaf stays.
    @discardableResult
    public func moveToNewTab(leaf: PaneId, in id: TabId) -> TabId? {
        guard let tab = tab(id), tab.leaves.count > 1, tab.leaves.contains(leaf) else { return nil }
        if let editor = tab.editors[leaf] {
            remove(leaf: leaf, from: id)
            settle(id)
            return openEditor(editor)
        }
        guard let member = tab.members[leaf] else { return nil }
        remove(leaf: leaf, from: id)
        if self.tab(id)?.panes(onHost: member.hostId).isEmpty == false {
            released[member] = .now + answerTimeout
            _ = send(member.hostId, .movePaneToNewTab(member.pane))
        } else if let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].carriers[member.hostId] = nil
        }
        settle(id)
        return nil
    }

    /// Undo of closing a window-owned tab: editors and pages only (host panes end with their
    /// tab). It comes back as it was, under a new id.
    @discardableResult
    public func reopen(_ tab: CompositeTab) -> TabId? {
        guard tab.members.isEmpty, !tab.leaves.isEmpty else { return nil }
        let id = nextId()
        tabs.append(tab.renumbered(id))
        return id
    }

    /// Each host closes its carrier.
    public func closeTab(_ id: TabId) {
        guard let tab = tab(id) else { return }
        for (host, carrier) in tab.carriers { _ = send(host, .closeTab(carrier)) }
        tabs.removeAll { $0.id == id }
        pending.removeAll { $0.composite == id }
    }

    /// The window stopped showing a host (closed or forgotten there; its panes stay on it): its
    /// leaves leave every composite, its editors too.
    public func dropHost(_ host: String) {
        for id in tabs.map(\.id) {
            guard let tab = tab(id) else { continue }
            for (leaf, member) in tab.members where member.hostId == host { remove(leaf: leaf, from: id) }
            for (leaf, editor) in tab.editors where editor.hostId == host { remove(leaf: leaf, from: id) }
            for (leaf, browser) in tab.browsers where browser.hostId == host { remove(leaf: leaf, from: id) }
            for (leaf, tool) in tab.tools where tool.hostId == host { remove(leaf: leaf, from: id) }
            if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].carriers[host] = nil }
            settle(id)
        }
        pending.removeAll { $0.host == host }
    }

    // MARK: Following the hosts

    /// Brings every composite in step with its hosts (see the type's comment). Cheap; call it
    /// whenever a host's layout or link changes.
    public func reconcile() {
        for id in tabs.map(\.id) { adoptAnswers(for: id) }
        // Unanswered in time (the host refused, or never answered): give up on it.
        let now = ContinuousClock.now
        let live = Set(tabs.map(\.id))
        pending.removeAll { $0.deadline < now || !live.contains($0.composite) }
        for id in tabs.map(\.id) {
            dropGonePanes(of: id)
            adoptStrays(of: id)
            settle(id)
        }
    }

    private func adoptAnswers(for id: TabId) {
        for ask in pending where ask.composite == id {
            guard let session = hostSession(ask.host), let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            var tab = tabs[index]
            let taken = Set(tabs.flatMap { $0.panes(onHost: ask.host) })
            let fresh = session.panes.subtracting(ask.panesBefore).subtracting(taken)
            let candidate: (pane: PaneId, tab: TabId)? = session.tabs.lazy.compactMap { hostTab -> (PaneId, TabId)? in
                if ask.newCarrier {
                    guard !ask.tabsBefore.contains(hostTab.id), let pane = hostTab.root.panes.first(where: fresh.contains) else { return nil }
                    return (pane, hostTab.id)
                }
                guard hostTab.id == tab.carriers[ask.host], let pane = hostTab.root.panes.first(where: fresh.contains) else { return nil }
                return (pane, hostTab.id)
            }.first
            guard let candidate else { continue }
            pending.removeAll { $0.token == ask.token }
            let beside = tab.leaves.contains(ask.beside) ? ask.beside : tab.focusedLeaf
            guard let leaf = tab.insert(HostPane(hostId: ask.host, pane: candidate.pane), beside: beside, axis: ask.axis) else { continue }
            tab.carriers[ask.host] = candidate.tab
            tabs[index] = tab
            onAdopt(id, leaf)
        }
    }

    private func dropGonePanes(of id: TabId) {
        guard let tab = tab(id) else { return }
        for (leaf, member) in tab.members {
            guard let session = hostSession(member.hostId), !session.panes.contains(member.pane) else { continue }
            remove(leaf: leaf, from: id)
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // A carrier the host no longer has, or that holds none of this composite's panes any
        // more (a restarted daemon reuses tab ids), carries nothing.
        for (host, carrier) in tabs[index].carriers {
            guard let session = hostSession(host), !pending.contains(where: { $0.composite == id && $0.host == host }) else { continue }
            let panes = Set(tabs[index].panes(onHost: host))
            let hostTab = session.tabs.first { $0.id == carrier }
            if hostTab == nil || !(hostTab!.root.panes.contains(where: panes.contains)) {
                tabs[index].carriers[host] = nil
            }
        }
    }

    /// Panes that appeared in a carrier without this window asking (another device split it).
    private func adoptStrays(of id: TabId) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        let now = ContinuousClock.now
        released = released.filter { $0.value > now }
        let taken = Set(tabs.flatMap { other in other.members.values }).union(released.keys)
        for (host, carrier) in tab.carriers {
            guard let session = hostSession(host), !pending.contains(where: { $0.composite == id && $0.host == host }),
                  let hostTab = session.tabs.first(where: { $0.id == carrier })
            else { continue }
            for pane in hostTab.root.panes where !taken.contains(HostPane(hostId: host, pane: pane)) {
                let anchor = tab.leaves.last { tab.members[$0]?.hostId == host } ?? tab.focusedLeaf
                let focused = tab.focusedLeaf
                tab.insert(HostPane(hostId: host, pane: pane), beside: anchor, axis: .horizontal)
                tab.apply(.focus(focused))
            }
        }
        if tab != tabs[index] { tabs[index] = tab }
    }

    private func remove(leaf: PaneId, from id: TabId) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if !tabs[index].remove(leaf: leaf) {
            tabs.remove(at: index)
            pending.removeAll { $0.composite == id }
            onDissolve(id, nil)
        }
    }

    /// A composite down to one host (and waiting for no other) dissolves into that host's tab.
    /// One holding an editor, a page or a tool stays: no host tab can show it.
    private func settle(_ id: TabId) {
        guard let tab = tab(id), tab.editors.isEmpty, tab.browsers.isEmpty, tab.tools.isEmpty, !pending.contains(where: { $0.composite == id }) else { return }
        let hosts = tab.paneHosts
        guard hosts.count <= 1 else { return }
        tabs.removeAll { $0.id == id }
        let host = hosts.first
        onDissolve(id, host.flatMap { host in tab.carriers[host].map { TabRefParts(hostId: host, tab: $0) } })
    }
}
