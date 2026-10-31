import PaneLayout
import UnnamedCore

/// The daemon's layout (`SessionLayout`, flattened split trees) as the app's `PaneLayout`
/// model, and the app's ops as the daemon's. Both sides share the vocabulary
/// (docs/DAEMON.md §1), so this is a mechanical mapping.
nonisolated enum LayoutConversion {
    static func session(_ layout: SessionLayout) -> Session {
        let tabs = layout.tabs.compactMap(tab)
        return Session(tabs: tabs, activeTabId: layout.activeTab.map(TabId.init))
    }

    static func tab(_ tab: TabLayout) -> PaneLayout.Tab? {
        guard let root = node(tab.nodes, 0) else { return nil }
        return PaneLayout.Tab(
            id: TabId(tab.tabId),
            title: tab.name.isEmpty ? nil : tab.name,
            root: root,
            focused: PaneId(tab.focused),
            zoomed: tab.zoomed.map(PaneId.init))
    }

    private static func node(_ nodes: [LayoutNode], _ index: Int) -> Node? {
        guard nodes.indices.contains(index) else { return nil }
        switch nodes[index] {
        case .leaf(let pane):
            return .leaf(PaneId(pane))
        case .split(let axis, let ratio, let first, let second):
            // Children come after their parent, which rules out cycles.
            guard Int(first) > index, Int(second) > index,
                  let a = node(nodes, Int(first)), let b = node(nodes, Int(second))
            else { return nil }
            return .split(axis: PaneLayout.Axis(axis), ratio: Double(ratio), first: a, second: b)
        }
    }

    /// The daemon op for a local one, given the session it applies to. Nil when the op has no
    /// effect (no focused pane, an unknown tab).
    static func op(_ op: PaneLayout.LayoutOp, sessionId: UInt64, session: Session) -> UnnamedCore.LayoutOp? {
        let shell = PaneLaunch.shell(cwd: nil)
        switch op {
        case .split(let pane, let axis):
            return .split(paneId: pane.rawValue, axis: UnnamedCore.Axis(axis), launch: shell)
        case .close(let pane):
            return .closePane(paneId: pane.rawValue)
        case .focus(let pane):
            return .focus(paneId: pane.rawValue)
        case .focusDirection(let direction):
            guard let tab = session.activeTab else { return nil }
            return .focusDirection(tabId: tab.id.rawValue, direction: UnnamedCore.Direction(direction))
        case .resize(let pane, let direction, let amount):
            guard let tab = session.tab(containing: pane),
                  let inFirst = nearestSplitSide(of: pane, in: tab.root, along: direction.axis)
            else { return nil }
            // Local semantics move the divider towards `direction`; the daemon grows or shrinks
            // the pane by moving its nearest divider on that axis. The divider moves forward
            // (right/down) exactly when a pane in the split's first half grows.
            let forward = direction == .right || direction == .down
            let delta = Float(amount) * (forward == inFirst ? 1 : -1)
            return .resize(paneId: pane.rawValue, axis: UnnamedCore.Axis(direction.axis), delta: delta)
        case .toggleZoom:
            guard let tab = session.activeTab else { return nil }
            return .toggleZoom(paneId: tab.focused.rawValue)
        case .newTab:
            return .newTab(sessionId: sessionId, name: "", launch: shell)
        case .closeTab(let tab):
            return .closeTab(tabId: tab.rawValue)
        case .moveTab(let tab, let index):
            return .moveTab(tabId: tab.rawValue, index: UInt32(clamping: max(index, 0)))
        case .rename(let tab, let title):
            return .renameTab(tabId: tab.rawValue, name: title)
        case .movePaneToNewTab(let pane):
            return .breakPane(paneId: pane.rawValue)
        case .movePane(let pane, let target, let side):
            return .movePane(paneId: pane.rawValue, target: target.rawValue, side: UnnamedCore.Direction(side))
        case .mergeTab(let tab, let target, let side):
            return .mergeTab(tabId: tab.rawValue, target: target.rawValue, side: UnnamedCore.Direction(side))
        }
    }

    /// Whether `pane` is in the first child of the deepest split along `axis` on its path.
    static func nearestSplitSide(of pane: PaneId, in node: Node, along axis: PaneLayout.Axis) -> Bool? {
        guard case .split(let splitAxis, _, let first, let second) = node else { return nil }
        let inFirst = first.contains(pane)
        guard inFirst || second.contains(pane) else { return nil }
        if let deeper = nearestSplitSide(of: pane, in: inFirst ? first : second, along: axis) { return deeper }
        return splitAxis == axis ? inFirst : nil
    }

    /// Whether a local op can be applied optimistically before the daemon answers: it moves
    /// focus or ratios but allocates no ids and starts or ends no process.
    static func isOptimistic(_ op: PaneLayout.LayoutOp) -> Bool {
        switch op {
        case .focus, .focusDirection, .resize, .toggleZoom, .moveTab, .rename: true
        // Moves wait for the daemon: an older one refuses them, and the answer is the truth.
        case .split, .close, .newTab, .closeTab, .movePaneToNewTab, .movePane, .mergeTab: false
        }
    }

    /// Whether an optimistic op can be replayed on a layout that may already include it: it
    /// sets a state (focus, position, name) rather than stepping one (a resize, a zoom toggle).
    static func isReplayable(_ op: PaneLayout.LayoutOp) -> Bool {
        switch op {
        case .focus, .moveTab, .rename: true
        default: false
        }
    }

    static func op(_ change: ProjectChange, sessionId: UInt64) -> UnnamedCore.LayoutOp {
        switch change {
        case .put(let info):
            return .putProject(sessionId: sessionId, project: DaemonProject(
                id: info.id, name: info.name, color: UInt8(clamping: info.color), order: info.order, updatedMs: info.updated))
        case .setTab(let tab, let membership):
            return .setTabProject(tabId: tab.rawValue, projectId: membership?.project, rank: membership?.rank ?? 0)
        case .remove(let id):
            return .removeProject(sessionId: sessionId, projectId: id)
        }
    }

    static func projects(_ report: DaemonProjects) -> HostProjects {
        HostProjects(
            projects: Dictionary(report.projects.map {
                ($0.id, ProjectInfo(id: $0.id, name: $0.name, color: Int($0.color), order: $0.order, updated: $0.updatedMs))
            }, uniquingKeysWith: { a, _ in a }),
            members: Dictionary(report.tabs.map {
                (TabId($0.tabId), Membership(project: $0.projectId, rank: $0.rank))
            }, uniquingKeysWith: { a, _ in a }))
    }
}

nonisolated extension PaneLayout.Axis {
    init(_ axis: UnnamedCore.Axis) {
        self = axis == .horizontal ? .horizontal : .vertical
    }
}

nonisolated extension UnnamedCore.Axis {
    init(_ axis: PaneLayout.Axis) {
        self = axis == .horizontal ? .horizontal : .vertical
    }
}

nonisolated extension UnnamedCore.Direction {
    init(_ direction: PaneLayout.Direction) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        }
    }
}
