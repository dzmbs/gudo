import Foundation
import Observation
import PaneLayout
import TerminalCore
import TerminalRenderer

/// User-default keys for keyboard behaviour.
enum KeyboardSettings {
    static let optionAsMeta = "optionAsMeta"
    static let asciiKeyboard = "asciiKeyboard"
}
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
    /// Terminal appearance for every pane (the design layer may replace it).
    @ObservationIgnored var appearance = TerminalAppearance()
    /// One terminal cell in points, once a pane has laid out: split sizes snap to whole cells so
    /// panes waste no partial cells (the remainder becomes padding).
    private(set) var cellSize: CGSize?

    #if os(iOS)
    /// The key bar shared by this window's panes; it follows the first responder.
    @ObservationIgnored let keyBar = KeyBar()
    #endif

    @ObservationIgnored private let makeBackend: @MainActor (PaneId) throws -> any PaneBackend
    /// The remote host this window shows (nil: the local workspace). Its status drives the
    /// connection banner and retry (04-mobile-ux R8, R9).
    @ObservationIgnored let host: (any HostConnection)?
    /// The host id (for the hosts list and persistence), nil for the local workspace.
    let hostId: String?

    init(layout: any LayoutStore = LocalLayoutStore(), makeBackend: @escaping @MainActor (PaneId) throws -> any PaneBackend = makeLocalBackend) {
        self.layout = layout
        self.makeBackend = makeBackend
        host = nil
        hostId = nil
        reconcilePanes()
        _ = settingsObserver
    }

    /// A window on a remote host: its layout store (the daemon's, or a local one for plain SSH)
    /// and its pane backends.
    init(hostId: String, connection: any HostConnection) {
        layout = connection.layoutStore
        makeBackend = { try connection.makeBackend(for: $0) }
        host = connection
        self.hostId = hostId
        reconcilePanes()
        _ = settingsObserver
        followLayout()
    }

    /// Whether this window is on a remote host.
    var isRemote: Bool { host != nil }

    /// A daemon's layout changes on its own (other clients, the daemon's answers to our ops, a
    /// pane whose process exited): keep the panes in step.
    private func followLayout() {
        withObservationTracking {
            _ = layout.session
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcilePanes()
                self?.followLayout()
            }
        }
    }

    var session: Session { layout.session }
    var focusedPane: PaneId? { session.activeTab?.focused }

    func apply(_ op: LayoutOp) {
        layout.apply(op)
        reconcilePanes()
    }

    func title(of tab: Tab) -> String {
        // A user rename wins; then the focused pane's OSC 0/2 title, as Ghostty does.
        if let title = tab.title { return title }
        if let title = panes[tab.focused]?.title, !title.isEmpty { return title }
        return "Tab \((session.tabs.firstIndex(of: tab) ?? 0) + 1)"
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

    // MARK: Keyboard settings

    /// `optionAsMeta` (none/left/right/both) and `asciiKeyboard` (iOS software keyboard type) from
    /// user defaults, applied to a pane's view; re-applied when the defaults change.
    private func applyKeyboardSettings(to pane: Pane) {
        let defaults = UserDefaults.standard
        pane.view.optionAsMeta = defaults.string(forKey: KeyboardSettings.optionAsMeta).flatMap(OptionAsMeta.init) ?? .none
        #if os(iOS)
        let ascii = defaults.bool(forKey: KeyboardSettings.asciiKeyboard)
        if pane.view.keyboardType != (ascii ? .asciiCapable : .default) {
            pane.view.keyboardType = ascii ? .asciiCapable : .default
            if pane.view.isFirstResponder { pane.view.reloadInputViews() }
        }
        #endif
    }

    @ObservationIgnored private lazy var settingsObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
        MainActor.assumeIsolated {
            guard let self else { return }
            for pane in self.panes.values { self.applyKeyboardSettings(to: pane) }
        }
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
        let pane = try Pane(id: id, backend: makeBackend(id), appearance: appearance) { [weak self] in
            // The process exited: close its pane, as Ghostty does.
            Task { @MainActor in self?.apply(.close(id)) }
        }
        pane.onCellSize = { [weak self] size in
            if self?.cellSize != size { self?.cellSize = size }
        }
        applyKeyboardSettings(to: pane)
        #if os(iOS)
        pane.view.accessibilityIdentifier = id.description
        pane.view.keyBar = keyBar
        pane.view.takeLatchedModifiers = { [keyBar] in keyBar.takeLatchedModifiers() }
        pane.view.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            keyBar.target = pane.view
            keyBar.update(context: KeyBarContext(program: pane.foregroundProgram, title: pane.title))
            apply(.focus(id))
        }
        #if DEBUG
        // `-demoPreedit <text>` shows IME marked text in the first pane, for screenshots and UI
        // tests (the simulator's software keyboard cannot be switched to an IME from a test).
        if let preedit = UserDefaults.standard.string(forKey: "demoPreedit"), !preedit.isEmpty, panes.isEmpty {
            Task { @MainActor [weak pane] in
                try? await Task.sleep(for: .seconds(1.5))
                pane?.view.setMarkedText(preedit, selectedRange: NSRange(location: preedit.utf16.count, length: 0))
            }
        }
        #endif
        pane.onContextChange = { [weak self, weak pane] in
            guard let self, let pane, keyBar.target === pane.view else { return }
            keyBar.update(context: KeyBarContext(program: pane.foregroundProgram, title: pane.title))
        }
        #else
        pane.view.setAccessibilityIdentifier(id.description)
        pane.view.onFocus = { [weak self] in self?.apply(.focus(id)) }
        #endif
        return pane
    }
}
