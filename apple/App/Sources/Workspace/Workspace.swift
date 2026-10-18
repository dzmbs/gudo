import DesignSystem
import PaneLayout
import Observation
#if os(iOS)
import GameController
import UIKit
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
    /// Each pane's terminal grid, for the resize overlay.
    private(set) var grids: [PaneId: GridSize] = [:]
    /// Transient per-pane states drawn over the terminal (Ghostty's surface overlays).
    var notices: [PaneId: PaneNotice] = [:]
    /// What runs in each pane (program and directory), refreshed about once a second.
    private(set) var foregrounds: [PaneId: PaneForeground] = [:]
    /// Until when grid changes come from the software keyboard rather than the user.
    @ObservationIgnored private(set) var keyboardResizeUntil = ContinuousClock.now

    #if os(iOS)
    /// The key bar shared by this window's panes; it follows the first responder.
    @ObservationIgnored let keyBar = KeyBar()
    #endif

    @ObservationIgnored private let makeBackend: @MainActor (PaneId) throws -> any PaneBackend

    init(layout: any LayoutStore = LocalLayoutStore(), makeBackend: @escaping @MainActor (PaneId) throws -> any PaneBackend = makeLocalBackend) {
        self.layout = layout
        self.makeBackend = makeBackend
        reconcilePanes()
        // Weak across the sleep, so a closed window's workspace is freed and the loop ends.
        Task { [weak self] in
            while self != nil {
                self?.refreshForegrounds()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardResizeUntil = .now + .milliseconds(800) }
        }
        #endif
    }

    var session: Session { layout.session }
    var focusedPane: PaneId? { session.activeTab?.focused }

    func apply(_ op: LayoutOp) {
        layout.apply(op)
        reconcilePanes()
    }

    /// A rename wins; otherwise the focused pane's program or directory, like Ghostty's titles.
    func title(of tab: Tab) -> String {
        tab.title ?? foregrounds[tab.focused]?.title ?? "Shell"
    }

    /// The focused pane's directory, for the window title and the sidebar's second line.
    func directory(of tab: Tab) -> String? {
        foregrounds[tab.focused]?.shortDirectory
    }

    private func refreshForegrounds() {
        for (id, pane) in panes {
            let current = pane.foreground()
            if foregrounds[id] != current { foregrounds[id] = current }
        }
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
            grids[id] = nil
            notices[id] = nil
            foregrounds[id] = nil
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
        pane.onGridChange = { [weak self] grid in
            let size = GridSize(cols: Int(grid.cols), rows: Int(grid.rows))
            if self?.grids[id] != size { self?.grids[id] = size }
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

/// What Ghostty draws over a surface besides the grid.
struct PaneNotice: Equatable {
    /// "Process exited" bar; the pane stays open showing its last output.
    var exit: (message: String, failed: Bool)?
    /// The terminal is reading a password with echo off.
    var secureInput = false
    /// The bell rang recently.
    var bell = false
    /// The link under the pointer.
    var hoveredURL: String?

    static func == (lhs: PaneNotice, rhs: PaneNotice) -> Bool {
        lhs.exit?.message == rhs.exit?.message && lhs.exit?.failed == rhs.exit?.failed
            && lhs.secureInput == rhs.secureInput && lhs.bell == rhs.bell && lhs.hoveredURL == rhs.hoveredURL
    }
}
