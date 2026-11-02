import PaneLayout
import GudoCore

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
                  let firstNode = node(nodes, Int(first)), let secondNode = node(nodes, Int(second))
            else { return nil }
            return .split(axis: PaneLayout.Axis(axis), ratio: Double(ratio), first: firstNode, second: secondNode)
        }
    }

    /// The daemon op for a local one, given the session it applies to. Nil when the op has no
    /// effect (no focused pane, an unknown tab).
    static func op(_ op: PaneLayout.LayoutOp, sessionId: UInt64, session: Session) -> GudoCore.LayoutOp? {
        let shell = PaneLaunch.shell(cwd: nil)
        switch op {
        case .split(let pane, let axis):
            return .split(paneId: pane.rawValue, axis: GudoCore.Axis(axis), launch: shell)
        case .close(let pane):
            return .closePane(paneId: pane.rawValue)
        case .focus(let pane):
            return .focus(paneId: pane.rawValue)
        case .focusDirection(let direction):
            guard let tab = session.activeTab else { return nil }
            return .focusDirection(tabId: tab.id.rawValue, direction: GudoCore.Direction(direction))
        case .resize(let pane, let direction, let amount):
            let own = session.window(containing: pane)?.id
            guard let tab = session.tab(containing: pane),
                  let inFirst = nearestSplitSide(of: pane, in: tab.root, along: direction.axis, sameLayer: { session.window(containing: $0)?.id == own })
            else { return nil }
            // Local semantics move the divider towards `direction`; the daemon grows or shrinks
            // the pane by moving its nearest divider on that axis. The divider moves forward
            // (right/down) exactly when a pane in the split's first half grows.
            let forward = direction == .right || direction == .down
            let delta = Float(amount) * (forward == inFirst ? 1 : -1)
            return .resize(paneId: pane.rawValue, axis: GudoCore.Axis(direction.axis), delta: delta)
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
            return .movePane(paneId: pane.rawValue, target: target.rawValue, side: GudoCore.Direction(side))
        case .mergeTab(let tab, let target, let side):
            return .mergeTab(tabId: tab.rawValue, target: target.rawValue, side: GudoCore.Direction(side))
        case .float(let pane, let frame):
            return .floatPane(paneId: pane.rawValue, frame: frame.map(GudoCore.FloatFrame.init))
        case .newFloat(let pane, let frame, let focus):
            return .newFloat(paneId: pane.rawValue, launch: shell, frame: frame.map(GudoCore.FloatFrame.init), focus: focus, closeWhenDone: false)
        case .setFloat(let pane, let frame, let minimized, let pinned):
            return .setFloat(paneId: pane.rawValue, frame: frame.map(GudoCore.FloatFrame.init), minimized: minimized, pinned: pinned)
        case .dock(let pane, let target, let side):
            return .dockPane(paneId: pane.rawValue, target: target?.rawValue, side: GudoCore.Direction(side))
        case .movePaneToEdge(let pane, let tab, let side):
            return .movePaneToEdge(paneId: pane.rawValue, tabId: tab.rawValue, side: GudoCore.Direction(side))
        }
    }

    /// Whether `pane` is in the first child of the deepest split along `axis` on its path whose
    /// other side holds a pane of its layer (the daemon resizes that one).
    static func nearestSplitSide(
        of pane: PaneId, in node: Node, along axis: PaneLayout.Axis, sameLayer: (PaneId) -> Bool = { _ in true }
    ) -> Bool? {
        guard case .split(let splitAxis, _, let first, let second) = node else { return nil }
        let inFirst = first.contains(pane)
        guard inFirst || second.contains(pane) else { return nil }
        if let deeper = nearestSplitSide(of: pane, in: inFirst ? first : second, along: axis, sameLayer: sameLayer) { return deeper }
        let other = inFirst ? second : first
        return splitAxis == axis && other.panes.contains(where: sameLayer) ? inFirst : nil
    }

    /// Whether a local op can be applied optimistically before the daemon answers: it moves
    /// focus or ratios but allocates no ids and starts or ends no process.
    static func isOptimistic(_ op: PaneLayout.LayoutOp) -> Bool {
        switch op {
        case .focus, .focusDirection, .resize, .toggleZoom, .moveTab, .rename: true
        // A window lifting out, moving, going to the tray or docking in place: at once, so it
        // follows the hand; nothing is created and no pane changes tab.
        case .float, .setFloat: true
        case .dock(_, let target, _): target == nil
        // Moves wait for the daemon: an older one refuses them, and the answer is the truth.
        case .split, .close, .newTab, .closeTab, .movePaneToNewTab, .movePane, .mergeTab, .newFloat, .movePaneToEdge: false
        }
    }

    /// Whether an optimistic op can be replayed on a layout that may already include it: it
    /// sets a state (focus, position, name) rather than stepping one (a resize, a zoom toggle).
    static func isReplayable(_ op: PaneLayout.LayoutOp) -> Bool {
        switch op {
        case .focus, .moveTab, .rename, .float, .setFloat: true
        case .dock(_, let target, _): target == nil
        default: false
        }
    }

    static func op(_ change: ProjectChange, sessionId: UInt64) -> GudoCore.LayoutOp {
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

    static func floats(_ report: DaemonFloats) -> [FloatWindow] {
        report.floats.map {
            FloatWindow(
                id: FloatId($0.id), panes: $0.panes.map(PaneId.init),
                frame: FloatFrame(x: Double($0.frame.x), y: Double($0.frame.y), width: Double($0.frame.w), height: Double($0.frame.h)),
                z: $0.z, minimized: $0.minimized, pinned: $0.pinned, closesWhenDone: $0.closeWhenDone)
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

nonisolated extension GudoCore.FloatFrame {
    init(_ frame: PaneLayout.FloatFrame) {
        self.init(x: Float(frame.x), y: Float(frame.y), w: Float(frame.width), h: Float(frame.height))
    }
}

nonisolated extension PaneLayout.Axis {
    init(_ axis: GudoCore.Axis) {
        self = axis == .horizontal ? .horizontal : .vertical
    }
}

nonisolated extension GudoCore.Axis {
    init(_ axis: PaneLayout.Axis) {
        self = axis == .horizontal ? .horizontal : .vertical
    }
}

nonisolated extension GudoCore.Direction {
    init(_ direction: PaneLayout.Direction) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        }
    }
}
