import DesignSystem
import Foundation
import Observation
import PaneLayout
import TerminalCore
import TerminalRenderer
#if os(iOS)
import GameController
import HostKit
import UIKit
#endif

/// User-default keys for tab titles.
enum TabNaming {
    /// A program's OSC 0/2 title replaces the generated tab name (off: it shows as context).
    static let titleFromShell = "titleFromShell"
}

/// User-default keys for keyboard behaviour.
enum KeyboardSettings {
    static let optionAsMeta = "optionAsMeta"
    static let asciiKeyboard = "asciiKeyboard"
}

/// One window's view of one host (or this device): the host's layout, seen through the window's
/// own tab and pane selection (`WindowLayoutStore`), and this window's live panes. Two windows on
/// the same host share the host's layout store and its pane streams but each has its own
/// `Workspace`, so each has its own terminals, renderers and views (docs/APP-ARCHITECTURE.md
/// "Windows"). Views read `session` and `panes`; every change goes through `apply`, which keeps
/// the pane set in step with the layout (creating panes for new leaves, terminating closed ones).
@Observable
final class Workspace {
    /// The window's view of the host's layout.
    let layout: WindowLayoutStore
    /// The host's layout store, shared by every window on the host.
    var sharedLayout: any LayoutStore { layout.base }
    private(set) var panes: [PaneId: Pane] = [:]
    /// Panes whose terminal or backend failed to start, with the reason.
    private(set) var failures: [PaneId: String] = [:]
    /// The tab whose rename prompt is showing.
    var renamingTab: TabId?
    /// Each pane's terminal grid, for the resize overlay.
    private(set) var grids: [PaneId: GridSize] = [:]
    /// Transient per-pane states drawn over the terminal (Ghostty's surface overlays).
    var notices: [PaneId: PaneNotice] = [:]
    /// Drawings open in this window's panes: draw mode, or a canvas pane (set by
    /// `PaneDrawing`; the window's Handoff activity carries the one in view).
    var drawingFocus: [PaneId: HandoffPayload.Drawing] = [:]
    /// What runs in each pane (program and directory), refreshed about once a second.
    private(set) var foregrounds: [PaneId: PaneForeground] = [:]
    /// Until when grid changes come from the software keyboard rather than the user.
    var keyboardResizeUntil: ContinuousClock.Instant {
        #if os(iOS)
        max(keyboardFrameChangeUntil, Self.keyBarResizeUntil, layoutChangeUntil)
        #else
        max(keyboardFrameChangeUntil, layoutChangeUntil)
        #endif
    }
    /// Until when grid changes come from the window switching layouts (compact <-> regular
    /// width), which must not flash the cols x rows overlay.
    @ObservationIgnored var layoutChangeUntil = ContinuousClock.now
    @ObservationIgnored private var keyboardFrameChangeUntil = ContinuousClock.now
    /// Terminal appearance for every pane (the design layer may replace it).
    @ObservationIgnored var appearance = TerminalAppearance.fromPreferences() {
        // Font, padding and cursor apply to open panes at once; colors to panes opened after.
        didSet { for pane in panes.values { pane.view.surface.appearance = appearance } }
    }
    /// One terminal cell in points, once a pane has laid out: split sizes snap to whole cells so
    /// panes waste no partial cells (the remainder becomes padding).
    private(set) var cellSize: CGSize?

    #if os(iOS)
    /// The key bar shared by every workspace's panes; it follows the first responder. One for
    /// the app, not one per workspace: switching hosts in the multi-host sidebar keeps the same
    /// input accessory view, so the keyboard never reloads its input views (a reload drops
    /// hardware keys, ⌘ shortcuts included, while it runs).
    @ObservationIgnored let keyBar = Workspace.sharedKeyBar
    static var sharedKeyBar: KeyBar {
        // Created on first use, not as a `static let`: its UIKit setup must not run inside a
        // one-time initializer (it crashed there, `_dispatch_once_wait`).
        if let existing = sharedKeyBarStorage { return existing }
        let created = KeyBar(style: .designSystem)
        sharedKeyBarStorage = created
        return created
    }
    private static var sharedKeyBarStorage: KeyBar?
    /// Until when the shared key bar's height change resizes the grids.
    static var keyBarResizeUntil = ContinuousClock.now
    #endif

    /// Tabs already given a friendly name (or left unnamed by the user's choice).
    @ObservationIgnored private var namingRequested: Set<TabId> = []
    @ObservationIgnored private let makeBackend:@MainActor (PaneId) throws -> any PaneBackend
    /// The remote host this window shows (nil: the local workspace). Its status drives the
    /// connection banner and retry (04-mobile-ux R8, R9).
    @ObservationIgnored let host: (any HostConnection)?
    /// The host id (for the hosts list and persistence), nil for the local workspace.
    let hostId: String?

    /// This device's workspace in a window: `layout` is the device's shared store.
    init(
        layout: any LayoutStore = LocalLayoutStore(), selecting tab: TabId? = nil,
        makeBackend: @escaping @MainActor (PaneId) throws -> any PaneBackend = makeLocalBackend
    ) {
        self.layout = WindowLayoutStore(base: layout, selecting: tab)
        self.makeBackend = makeBackend
        host = nil
        hostId = nil
        start()
        followLayout()
    }

    /// A window on a remote host: its layout store (the daemon's, or a local one for plain SSH)
    /// and its pane backends (`makeBackend`: a tap of the pane's shared stream; the
    /// connection's own backends when nil).
    init(
        hostId: String, connection: any HostConnection, selecting tab: TabId? = nil,
        makeBackend: (@MainActor (PaneId) throws -> any PaneBackend)? = nil
    ) {
        layout = WindowLayoutStore(base: connection.layoutStore, selecting: tab)
        self.makeBackend = makeBackend ?? { try connection.makeBackend(for: $0) }
        host = connection
        self.hostId = hostId
        start()
        followLayout()
    }

    /// The window closed (or stopped showing this host): its terminals stop, the panes stay in
    /// the host's layout for other windows and devices. `ending`: the host is closing (or its
    /// connection was replaced), so streams no other window shows end instead of being parked.
    func close(ending: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        for pane in panes.values {
            if ending { pane.terminate() } else { pane.detach() }
        }
        panes = [:]
    }

    /// Set by `close()`: a closed workspace creates no panes.
    @ObservationIgnored private(set) var isClosed = false

    private func start() {
        reconcilePanes()
        #if os(iOS)
        // The key bar takes the terminal theme's light or dark itself (`KeyBarTheme`), like the
        // keyboard (`applyKeyboardSettings`).
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
            MainActor.assumeIsolated { self?.keyboardFrameChangeUntil = .now + .milliseconds(800) }
        }
        keyBar.onHeightChange = { Workspace.keyBarResizeUntil = .now + .milliseconds(800) }
        #endif
        _ = settingsObserver
    }

    /// Whether this window is on a remote host.
    var isRemote: Bool { host != nil }

    /// A daemon's layout changes on its own (other clients, the daemon's answers to our ops, a
    /// pane whose process exited): keep the panes in step.
    private func followLayout() {
        guard !isClosed else { return }
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

    /// Whether new tabs can open here: a host, the Mac's own shell, or the iOS echo stand-in in
    /// tests and fixtures. Otherwise "New Tab" asks for a host (`onNewTabUnavailable`).
    var canOpenTabs: Bool { isRemote || LaunchOptions.hasLocalShell }
    /// What "New Tab" does where no shell can open (iOS without a host): offer Add Host.
    @ObservationIgnored var onNewTabUnavailable: (() -> Void)?
    /// Whether the layout can change now: always here, on a host only while the link is live.
    var isLayoutLive: Bool { host?.status.isLive ?? true }
    /// What a layout change does while the host is not live: say so (never a silent no-op).
    @ObservationIgnored var onLayoutUnavailable: (() -> Void)?
    /// A pane's terminal took the keyboard (a click or tap in it): its window follows, which
    /// matters when the pane is not in the window's own tab on this host (a mixed tab's pane,
    /// the other column).
    @ObservationIgnored var onPaneFocus: ((PaneId) -> Void)?

    func apply(_ op: LayoutOp) {
        if case .newTab = op, !canOpenTabs {
            onNewTabUnavailable?()
            return
        }
        if op.opensPane, !isLayoutLive {
            onLayoutUnavailable?()
            return
        }
        layout.apply(op)
        reconcilePanes()
    }

    /// The tab's name: the user's rename, else the friendly name it got when it was created
    /// ("quiet-otter"). With Settings ▸ "Title from shell", a program's OSC 0/2 title replaces a
    /// generated name (never a rename).
    func title(of tab: Tab) -> String {
        if let title = tab.title {
            if UserDefaults.standard.bool(forKey: TabNaming.titleFromShell), FriendlyName.isGenerated(title),
               let shell = panes[tab.focused]?.title, !shell.isEmpty
            {
                return shell
            }
            return title
        }
        if let title = panes[tab.focused]?.title, !title.isEmpty { return title }
        if let foreground = foregrounds[tab.focused], !foreground.title.isEmpty { return foreground.title }
        return "Shell"
    }

    /// The live line under a tab's name: what its agent is doing, else the program running in the
    /// focused pane, else the program's own title (OSC 0/2), else the git checkout as
    /// `repo:branch`, else the directory.
    func context(of tab: Tab) -> String? {
        let pane = tab.focused
        let name = title(of: tab)
        if let daemon = host as? DaemonConnection, let agent = daemon.meta[pane]?.agent {
            let kind = agent.kind.prefix(1).uppercased() + agent.kind.dropFirst()
            switch agent.state {
            case .blocked(_, let summary, _): return "\(kind): \(summary)"
            case .running: return daemon.meta[pane].map { $0.title.isEmpty ? "\(kind) working" : "\(kind): \($0.title)" }
            case .idle, .done: break
            }
        }
        if let program = panes[pane]?.foregroundProgram ?? foregrounds[pane]?.program, !program.isEmpty,
           !PaneForeground.shells.contains(program)
        {
            return program
        }
        if let shellTitle = panes[pane]?.title, !shellTitle.isEmpty, shellTitle != name { return shellTitle }
        if !isRemote, let directory = absoluteDirectory(of: tab), let repo = GitContext.repoBranch(at: directory) { return repo }
        if let directory = directory(of: tab), directory != name { return directory }
        let count = tab.root.panes.count
        return count > 1 ? "\(count) panes" : nil
    }

    /// Gives every unnamed tab a friendly name, once. On a daemon the rename goes to the host, so
    /// all devices show the same name.
    private func nameNewTabs() {
        let unnamed = session.tabs.filter { $0.title == nil && !namingRequested.contains($0.id) }
        guard !unnamed.isEmpty else { return }
        var used = Set(session.tabs.compactMap(\.title))
        for tab in unnamed {
            namingRequested.insert(tab.id)
            let name = FriendlyName.make(avoiding: used)
            used.insert(name)
            // After this turn: `reconcilePanes` runs inside `apply`.
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, let current = self.session.tabs.first(where: { $0.id == tab.id }), current.title == nil else { return }
                self.layout.apply(.rename(tab.id, name))
            }
        }
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
        if PaneDrawing.of(pane)?.canvas != nil { return "canvas" }
        if let program = panes[pane]?.foregroundProgram { return program }
        if let program = foregrounds[pane]?.program, !program.isEmpty { return program }
        return "shell"
    }

    /// The focused pane's absolute directory, for the window's represented folder.
    func absoluteDirectory(of tab: Tab) -> String? {
        if let pwd = panes[tab.focused]?.workingDirectory, !pwd.isEmpty { return pwd }
        return foregrounds[tab.focused]?.directory
    }

    private func refreshForegrounds() {
        let daemon = host as? DaemonConnection
        for (id, pane) in panes {
            // Local panes ask the kernel; daemon panes take what the daemon reports (the agent
            // running there, the shell's cwd) until it reports the foreground program itself.
            let current = pane.foreground() ?? daemon?.meta[id].flatMap { meta in
                meta.agent.map { PaneForeground(program: $0.kind, directory: meta.cwd) }
                    ?? meta.cwd.map { PaneForeground(program: "", directory: $0) }
            }
            guard foregrounds[id] != current else { continue }
            foregrounds[id] = current
            #if os(iOS)
            if keyBar.target === pane.view { keyBar.update(context: keyBarContext(of: pane)) }
            #endif
        }
    }

    /// The foreground program when known (a backend that reports it, the local PTY, or the
    /// daemon's agent), which picks the key bar profile; the title stands in otherwise.
    func reportedProgram(of pane: Pane) -> String? {
        if let program = pane.foregroundProgram { return program }
        // A shell in the foreground says nothing about what runs in it (an agent can set the
        // title from a shell, the echo stand-in always reports zsh): the title decides then.
        if let program = foregrounds[pane.id]?.program, !program.isEmpty, !PaneForeground.shells.contains(program) {
            return program
        }
        return nil
    }

    #if os(iOS)
    private func keyBarContext(of pane: Pane) -> KeyBarContext {
        KeyBarContext(program: reportedProgram(of: pane), title: pane.title)
    }
    #endif

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
    /// Set when the window switches here from another host's workspace while typing went to a
    /// terminal: the focused pane takes the keyboard as it appears, so switching hosts never
    /// drops typing (or the ⌘ shortcuts that need a responder) on iPhone and iPad.
    @ObservationIgnored var inheritsKeyboardFocus = false

    var claimsKeyboardFocus: Bool {
        #if os(iOS)
        // `-noAutoFocus YES` (screenshots): never raise the software keyboard by itself.
        if UserDefaults.standard.bool(forKey: "noAutoFocus") { return false }
        return GCKeyboard.coalesced != nil || inheritsKeyboardFocus || panes.values.contains { $0.view.isFirstResponder }
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
        // The keyboard takes the terminal theme's light or dark, like the key bar over it.
        let appearance: UIKeyboardAppearance = KeyBarTheme.style == .light ? .light : .dark
        if pane.view.keyboardAppearance != appearance {
            pane.view.keyboardAppearance = appearance
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
        guard !isClosed else { return }
        nameNewTabs()
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

    /// Ghostty's `bell-features = border` (Settings ▸ Notifications): the pane's border lights up
    /// for a moment. Off by default, like Ghostty.
    private func ringBell(_ id: PaneId) {
        guard UserDefaults.standard.bool(forKey: TerminalPreferences.Key.bellFeatures) else { return }
        notices[id, default: PaneNotice()].bell = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.notices[id]?.bell = false
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
        pane.isFocusedPane = { [weak self] in self?.focusedPane == id }
        pane.onBell = { [weak self] in self?.ringBell(id) }
        pane.onCellSize = { [weak self] size in
            if self?.cellSize != size { self?.cellSize = size }
        }
        applyKeyboardSettings(to: pane)
        PaneDrawing.attach(to: pane, workspace: self)
        // Shell command marks: gutter stripes, the command menu, ⌘↑/⌘↓ between prompts.
        PaneCommandMarks.attach(to: pane, workspace: self)
        // Links: localhost in the in-app browser, paths in the editor, the rest per the setting.
        PaneLinks.attach(to: pane, workspace: self)
        #if os(iOS)
        pane.view.accessibilityIdentifier = id.description
        pane.view.keyBar = keyBar
        pane.view.takeLatchedModifiers = { [keyBar] in keyBar.takeLatchedModifiers() }
        // Every app shortcut: the terminal answers them itself, so they work right after the
        // window switched hosts (the menu commands, found through the responder chain, could
        // miss them then: ⌘K did nothing).
        let shortcuts = WorkspaceAction.allShortcutActions
        pane.view.appKeyCommands = shortcuts.map { action in
            UIKeyCommand(
                input: action.shortcut.key.uiKeyInput, modifierFlags: action.shortcut.modifiers.uiKeyModifierFlags,
                action: #selector(TerminalView.performAppKeyCommand(_:)))
        }
        pane.view.onFind = { [weak self] in
            guard let self else { return }
            ActiveWindow.model(for: self)?.isSearchShown = true
        }
        pane.view.onAppKeyCommand = { [weak self] index in
            guard let self, shortcuts.indices.contains(index) else { return }
            shortcuts[index].perform(on: self, window: ActiveWindow.model(for: self))
        }
        pane.view.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            keyBar.target = pane.view
            keyBar.assist = pane.backend as? any LineAssist
            keyBar.update(context: keyBarContext(of: pane))
            pane.claimSize()
            apply(.focus(id))
            onPaneFocus?(id)
            keyBar.onDraw = DrawingCommands.canDraw(in: self) ? { [weak self] in if let self { DrawingCommands.toggleDrawing(in: self) } } : nil
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
            keyBar.update(context: keyBarContext(of: pane))
        }
        #else
        pane.view.setAccessibilityIdentifier(id.description)
        pane.view.onFocus = { [weak self, weak pane] in
            ActiveWindow.workspace = self
            pane?.claimSize()
            self?.apply(.focus(id))
            self?.onPaneFocus?(id)
        }
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

private extension LayoutOp {
    /// Starts a new shell on the host (and so needs a live link).
    var opensPane: Bool {
        switch self {
        case .newTab, .split: true
        default: false
        }
    }
}
