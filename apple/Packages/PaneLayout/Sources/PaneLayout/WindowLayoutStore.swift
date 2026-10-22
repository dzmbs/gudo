import Observation

/// One window's view of a layout that several windows share (docs/APP-ARCHITECTURE.md
/// "Windows"). The tabs, split trees, names and zoom are the host's, one `base` store per host;
/// which tab is active and which pane of each tab has focus belong to the window, so two windows
/// on the same host select tabs and panes independently.
///
/// Every op still goes to `base`: focus too, so a daemon keeps hearing what was focused last.
/// Ops that act on "the active tab" (toggle zoom, a new tab after it) first focus this window's
/// pane in `base`, so they land where this window is. A tab or pane this window creates becomes
/// its selection once `base` has it (at once for a local store, after the daemon's answer for a
/// remote one).
@MainActor
@Observable
public final class WindowLayoutStore: LayoutStore {
    public let base: any LayoutStore
    /// This window's active tab (nil: follow `base` until something is selected).
    public private(set) var activeTabId: TabId?
    /// This window's focused pane per tab (tabs without an entry use the tab's own focus).
    public private(set) var focusedPanes: [TabId: PaneId] = [:]

    /// Where the active tab was, so a tab closed elsewhere hands over to its neighbour.
    @ObservationIgnored private var lastActiveIndex: Int?
    /// An op from this window that will create a tab or pane: what existed before it.
    @ObservationIgnored private var pendingAdoption: Adoption?
    /// How long a remote op's tab or pane is waited for before the adoption is dropped.
    @ObservationIgnored public var adoptionTimeout = Duration.seconds(5)

    private struct Adoption {
        var tabs: Set<TabId>
        var panes: Set<PaneId>
        /// A pane this window moved: selected once it has left `from`.
        var moved: (pane: PaneId, from: TabId)?
        var deadline: ContinuousClock.Instant
    }

    /// - Parameters:
    ///   - base: the host's shared layout store.
    ///   - tab: the tab this window opens on (nil: the host's active tab).
    public init(base: any LayoutStore, selecting tab: TabId? = nil) {
        self.base = base
        let session = base.session
        activeTabId = tab.flatMap { id in session.tabs.contains { $0.id == id } ? id : nil } ?? session.activeTabId
        if let activeTabId { lastActiveIndex = session.tabs.firstIndex { $0.id == activeTabId } }
        follow()
    }

    public var session: Session {
        compose(base.session)
    }

    /// What this window shows of the host: the focused pane and every visible pane.
    public var view: (focused: PaneId?, visible: [PaneId]) {
        guard let tab = session.activeTab else { return (nil, []) }
        return (tab.focused, tab.zoomed.map { [$0] } ?? tab.root.panes)
    }

    public func apply(_ op: LayoutOp) {
        let current = session
        switch op {
        case .focus(let pane):
            guard let tab = current.tab(containing: pane) else { return }
            select(tab: tab.id, pane: pane)
            base.apply(op)
        case .focusDirection:
            // Geometry is the window's own (its focus): move here, then tell the base.
            var next = current
            next.apply(op)
            guard let tab = next.activeTab, tab.focused != current.activeTab?.focused else { return }
            apply(.focus(tab.focused))
        case .toggleZoom, .newTab:
            alignBase(with: current)
            expectNewPanes(op, before: base.session)
            base.apply(op)
            adoptIfReady()
        case .split, .close, .closeTab, .resize, .moveTab, .rename:
            expectNewPanes(op, before: base.session)
            base.apply(op)
            adoptIfReady()
        case .movePaneToNewTab(let pane), .movePane(let pane, _, _):
            follow(pane, current)
            base.apply(op)
            adoptIfReady()
        case .mergeTab(let id, _, _):
            guard let tab = current.tabs.first(where: { $0.id == id }) else { return }
            follow(tab.focused, current)
            base.apply(op)
            adoptIfReady()
        }
    }

    /// Selects a tab (its focused pane in this window).
    public func select(tab id: TabId) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        apply(.focus(tab.focused))
    }

    // MARK: Composition

    private func compose(_ shared: Session) -> Session {
        guard !shared.tabs.isEmpty else { return shared }
        let tabs = shared.tabs.map { tab -> Tab in
            var tab = tab
            if let zoomed = tab.zoomed {
                // A zoomed tab shows one pane: that is the focused one, in every window.
                tab.focused = zoomed
            } else if let pane = focusedPanes[tab.id], tab.root.contains(pane) {
                tab.focused = pane
            }
            return tab
        }
        let active: TabId?
        if let activeTabId, let index = tabs.firstIndex(where: { $0.id == activeTabId }) {
            lastActiveIndex = index
            active = activeTabId
        } else if activeTabId != nil, let index = lastActiveIndex {
            // Closed elsewhere: the tab that slid into its place, else the one before.
            active = tabs[min(index, tabs.count - 1)].id
        } else {
            active = shared.activeTabId
        }
        return Session(tabs: tabs, activeTabId: active)
    }

    private func select(tab: TabId, pane: PaneId) {
        if activeTabId != tab { activeTabId = tab }
        if focusedPanes[tab] != pane { focusedPanes[tab] = pane }
    }

    /// Focuses this window's pane in `base`, so an op on "the active tab" acts on this window's.
    private func alignBase(with current: Session) {
        guard let focused = current.activeTab?.focused, base.session.activeTab?.focused != focused else { return }
        base.apply(.focus(focused))
    }

    // MARK: Following the base

    private func expectNewPanes(_ op: LayoutOp, before shared: Session) {
        switch op {
        case .newTab, .split:
            pendingAdoption = Adoption(
                tabs: Set(shared.tabs.map(\.id)), panes: shared.panes, deadline: .now + adoptionTimeout)
        default:
            break
        }
    }

    private func follow(_ pane: PaneId, _ current: Session) {
        guard let from = current.tab(containing: pane)?.id else { return }
        pendingAdoption = Adoption(tabs: [], panes: [], moved: (pane, from), deadline: .now + adoptionTimeout)
    }

    /// Selects the tab or pane this window's last op created, once the base has it.
    private func adoptIfReady() {
        guard let adoption = pendingAdoption else { return }
        let shared = base.session
        if ContinuousClock.now > adoption.deadline {
            pendingAdoption = nil
            return
        }
        if let moved = adoption.moved {
            if let tab = shared.tab(containing: moved.pane), tab.id != moved.from {
                pendingAdoption = nil
                select(tab: tab.id, pane: moved.pane)
            }
        } else if let tab = shared.tabs.first(where: { !adoption.tabs.contains($0.id) }) {
            pendingAdoption = nil
            select(tab: tab.id, pane: tab.focused)
        } else if let pane = shared.panes.subtracting(adoption.panes).first, let tab = shared.tab(containing: pane) {
            pendingAdoption = nil
            select(tab: tab.id, pane: pane)
        }
    }

    /// Drops selections the base no longer has (tabs or panes closed in any window or on any
    /// device), keeping a closed tab's place.
    private func reconcile() {
        adoptIfReady()
        let shared = base.session
        let live = Set(shared.tabs.map(\.id))
        let stale = focusedPanes.filter { !live.contains($0.key) || shared.tab(containing: $0.value)?.id != $0.key }
        for key in stale.keys { focusedPanes[key] = nil }
        if let activeTabId, !live.contains(activeTabId) {
            self.activeTabId = compose(shared).activeTabId
        }
    }

    private func follow() {
        withObservationTracking {
            _ = base.session
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcile()
                self?.follow()
            }
        }
    }
}
