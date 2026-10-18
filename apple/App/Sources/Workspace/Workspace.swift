import DesignSystem
import PaneLayout
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
    /// Terminal appearance for every pane (the design layer may replace it).
    @ObservationIgnored var appearance = TerminalAppearance.fromPreferences() {
        // Font, padding and cursor apply to open panes at once; colors to panes opened after.
        didSet { for pane in panes.values { pane.view.surface.appearance = appearance } }
    }
    /// One terminal cell in points, once a pane has laid out: split sizes snap to whole cells so
    /// panes waste no partial cells (the remainder becomes padding).
    private(set) var cellSize: CGSize?

    #if os(iOS)
    /// The key bar shared by this window's panes; it follows the first responder.
    @ObservationIgnored let keyBar = KeyBar(style: .designSystem)
    #endif

    @ObservationIgnored private let makeBackend: @MainActor (PaneId) throws -> any PaneBackend

    init(layout: any LayoutStore = LocalLayoutStore(), makeBackend: @escaping @MainActor (PaneId) throws -> any PaneBackend = makeLocalBackend) {
        self.layout = layout
        self.makeBackend = makeBackend
        reconcilePanes()
        #if os(iOS)
        // The terminal's keyboard is dark (TerminalView.keyboardAppearance); its key bar matches.
        keyBar.overrideUserInterfaceStyle = .dark
        #endif
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
        _ = settingsObserver
    }

    var session: Session { layout.session }
    var focusedPane: PaneId? { session.activeTab?.focused }

    func apply(_ op: LayoutOp) {
        layout.apply(op)
        reconcilePanes()
    }

    /// A rename wins; otherwise the focused pane's program or directory, like Ghostty's titles.
    func title(of tab: Tab) -> String {
        // A user rename wins; then the focused pane's OSC 0/2 title, as Ghostty does; then what
        // the PTY says runs there (the directory at a prompt).
        if let title = tab.title { return title }
        if let title = panes[tab.focused]?.title, !title.isEmpty { return title }
        return foregrounds[tab.focused]?.title ?? "Shell"
    }

    /// The focused pane's directory (OSC 7, else the PTY's cwd), with ~ for home.
    func directory(of tab: Tab) -> String? {
        if let pwd = panes[tab.focused]?.workingDirectory, !pwd.isEmpty {
            return PaneForeground(program: "", directory: pwd).shortDirectory
        }
        return foregrounds[tab.focused]?.shortDirectory
    }

    /// What a pane runs, for headers and lists: the reported program, else what the PTY says,
    /// else "shell". Never the pane id, which UI tests use as the terminal's identifier.
    func programName(of pane: PaneId) -> String {
        panes[pane]?.foregroundProgram ?? foregrounds[pane]?.program ?? "shell"
    }

    /// The focused pane's absolute directory, for the window's represented folder.
    func absoluteDirectory(of tab: Tab) -> String? {
        if let pwd = panes[tab.focused]?.workingDirectory, !pwd.isEmpty { return pwd }
        return foregrounds[tab.focused]?.directory
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
        let pane = try Pane(id: id, backend: makeBackend(id), appearance: appearance) { [weak self] in
            // The process exited: close its pane, as Ghostty does.
            Task { @MainActor in self?.apply(.close(id)) }
        }
        pane.onGridChange = { [weak self] grid in
            let size = GridSize(cols: Int(grid.cols), rows: Int(grid.rows))
            if self?.grids[id] != size { self?.grids[id] = size }
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
