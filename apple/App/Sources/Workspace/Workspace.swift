import PaneLayout
import Observation
#if os(iOS)
import GameController
#endif

/// One window's state: the layout (behind `LayoutStore`) and the live panes it references.
/// Views read `session` and `panes`; every change goes through `apply`, which keeps the pane set
/// in step with the layout (creating panes for new leaves, terminating closed ones).
@Observable
final class Workspace {
    let layout: any LayoutStore
    private(set) var panes: [PaneId: Pane] = [:]
    /// Panes whose terminal or backend failed to start, with the reason.
    private(set) var failures: [PaneId: String] = [:]
    /// The tab whose rename prompt is showing.
    var renamingTab: TabId?

    #if os(iOS)
    /// The key bar shared by this window's panes; it follows the first responder.
    @ObservationIgnored let keyBar = KeyBar()
    #endif

    @ObservationIgnored private let makeBackend: @MainActor (PaneId) throws -> any PaneBackend

    init(layout: any LayoutStore = LocalLayoutStore(), makeBackend: @escaping @MainActor (PaneId) throws -> any PaneBackend = makeLocalBackend) {
        self.layout = layout
        self.makeBackend = makeBackend
        reconcilePanes()
    }

    var session: Session { layout.session }
    var focusedPane: PaneId? { session.activeTab?.focused }

    func apply(_ op: LayoutOp) {
        layout.apply(op)
        reconcilePanes()
    }

    func title(of tab: Tab) -> String {
        tab.title ?? "Tab \((session.tabs.firstIndex(of: tab) ?? 0) + 1)"
    }

    // MARK: Commands on the focused pane / active tab

    func split(_ axis: Axis) {
        if let focusedPane { apply(.split(focusedPane, axis)) }
    }

    func closeFocusedPane() {
        if let focusedPane { apply(.close(focusedPane)) }
    }

    /// Keyboard resize step: a twentieth of the split, about Ghostty's 10 cells on a laptop screen.
    func resizeFocusedPane(_ direction: Direction) {
        if let focusedPane { apply(.resize(focusedPane, direction, amount: 0.05)) }
    }

    func selectTab(_ id: TabId) {
        if let tab = session.tabs.first(where: { $0.id == id }) { apply(.focus(tab.focused)) }
    }

    /// Selects the tab at `index`; ⌘9 passes `nil` for the last tab, as in Ghostty and browsers.
    func selectTab(at index: Int?) {
        let tabs = session.tabs
        guard let tab = index.map({ tabs.indices.contains($0) ? tabs[$0] : nil }) ?? tabs.last else { return }
        selectTab(tab.id)
    }

    /// Selects the next (`offset` 1) or previous (-1) tab, wrapping around.
    func selectTab(offset: Int) {
        let tabs = session.tabs
        guard let current = tabs.firstIndex(where: { $0.id == session.activeTabId }) else { return }
        selectTab(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    // MARK: Keyboard focus

    /// Whether the focused pane should take first responder when it appears or gains focus. On iOS
    /// only while typing already goes to a terminal or a hardware keyboard is attached, so that
    /// focusing a pane never pops up the software keyboard unasked (04-mobile-ux A1.5, R6).
    var claimsKeyboardFocus: Bool {
        #if os(iOS)
        GCKeyboard.coalesced != nil || panes.values.contains { $0.view.isFirstResponder }
        #else
        true
        #endif
    }

    // MARK: Panes

    private func reconcilePanes() {
        let live = session.panes
        for (id, pane) in panes where !live.contains(id) {
            pane.terminate()
            panes[id] = nil
        }
        failures = failures.filter { live.contains($0.key) }
        for id in live where panes[id] == nil && failures[id] == nil {
            do {
                panes[id] = try makePane(id)
            } catch {
                failures[id] = String(describing: error)
            }
        }
    }

    private func makePane(_ id: PaneId) throws -> Pane {
        let pane = try Pane(id: id, backend: makeBackend(id)) { [weak self] in
            // The process exited: close its pane, as Ghostty does.
            Task { @MainActor in self?.apply(.close(id)) }
        }
        #if os(iOS)
        pane.view.accessibilityIdentifier = id.description
        pane.view.keyBar = keyBar
        pane.view.takeLatchedModifiers = { [keyBar] in keyBar.takeLatchedModifiers() }
        pane.view.onFocus = { [weak self, weak view = pane.view] in
            self?.keyBar.target = view
            self?.apply(.focus(id))
        }
        #else
        pane.view.setAccessibilityIdentifier(id.description)
        pane.view.onFocus = { [weak self] in self?.apply(.focus(id)) }
        #endif
        return pane
    }
}
