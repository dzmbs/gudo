import DesignSystem
import Foundation
import Observation
import os
import PaneLayout
import SwiftUI
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
/// `Workspace`, so each has its own terminals, renderers and views. Views read `session` and `pane(_:)`; every change goes through `apply`, which keeps
/// the pane set in step with the layout (creating panes for new leaves, terminating closed ones).
///
/// Panes are made in stages: the window's tab (and any pane a view asks for) at once, the rest a
/// few at a time between frames. Each pane is observed on its own (`PaneHolder`), so making one
/// redraws only the views that show it: a host with 500 tabs opens without freezing the window.
@Observable
final class Workspace {
    /// The window's view of the host's layout.
    let layout: WindowLayoutStore
    /// The host's layout store, shared by every window on the host.
    var sharedLayout: any LayoutStore { layout.base }
    /// Every pane made so far. Reading it follows the whole set (it changes once per stage);
    /// views showing one pane read `pane(_:)`, which follows that pane only.
    var panes: [PaneId: Pane] {
        _ = madeStages
        return made
    }
    @ObservationIgnored private var made: [PaneId: Pane] = [:]
    @ObservationIgnored private var slots: [PaneId: PaneHolder] = [:]
    /// Bumped once per stage of panes made (what `panes` readers follow).
    private var madeStages = 0
    /// Live panes still to make: those views asked for first, then in the sidebar's order.
    @ObservationIgnored private var unmade = PaneQueue()
    @ObservationIgnored private var makingUnmade = false
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
    #if os(iOS)
    /// The top of the software keyboard (with the key bar) in the window, nil while it is down:
    /// the terminals' room at the bottom (`KeyboardRoom`).
    private(set) var keyboardTop: CGFloat?

    private func keyboardTop(screenFrame: CGRect?) -> CGFloat? {
        guard let screenFrame, let window = made.values.lazy.compactMap({ $0.view.window }).first
            ?? UIApplication.shared.connectedScenes.lazy.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return nil }
        let frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        return frame.minY < window.bounds.maxY && frame.height > 0 ? frame.minY : nil
    }
    #endif
    /// Terminal appearance for every pane (the design layer may replace it).
    @ObservationIgnored var appearance = TerminalAppearance.fromPreferences() {
        didSet { for pane in made.values { pane.view.surface.appearance = appearance } }
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
        // Created on first use, not as a `static let`: its UIKit setup crashes inside a
        // one-time initializer (`_dispatch_once_wait`).
        if let existing = sharedKeyBarStorage { return existing }
        let created = KeyBar(style: .designSystem)
        sharedKeyBarStorage = created
        return created
    }
    private static var sharedKeyBarStorage: KeyBar?
    /// Until when the shared key bar's height change resizes the grids.
    static var keyBarResizeUntil = ContinuousClock.now
    /// How long past the keyboard's slide the grids stay held: the layout can trail it.
    static let keyboardSettle = 0.15
    /// The focused pane's repository workflows the key bar shows (`followWorkflows`).
    @ObservationIgnored let keyBarWorkflows = KeyBarWorkflowState()
    #endif

    /// Tabs already given a friendly name (or left unnamed by the user's choice).
    @ObservationIgnored private var namingRequested: Set<TabId> = []
    @ObservationIgnored private let makeBackend:@MainActor (PaneId) throws -> any PaneBackend
    /// The remote host this window shows (nil: the local workspace). Its status drives the
    /// connection banner and retry.
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
        for pane in made.values {
            if ending { pane.terminate() } else { pane.detach() }
        }
        made = [:]
        unmade = PaneQueue()
        for slot in slots.values { slot.pane = nil }
        slots = [:]
        madeStages += 1
    }

    /// The pane `id`, observed on its own. A live pane not made yet is made on the next turn
    /// (it is about to show), and the view asking redraws then.
    func pane(_ id: PaneId) -> Pane? {
        let slot = slot(id)
        if slot.pane == nil, !isClosed, unmade.prioritize(id) {
            makeUnmadeSoon()
        }
        return slot.pane
    }

    private func slot(_ id: PaneId) -> PaneHolder {
        if let slot = slots[id] { return slot }
        let slot = PaneHolder()
        slots[id] = slot
        return slot
    }

    /// Set by `close()`: a closed workspace creates no panes.
    @ObservationIgnored private(set) var isClosed = false

    private func start() {
        reconcilePanes()
        if let daemon = host as? DaemonConnection {
            // Daemon panes report through the daemon's metadata: follow it, never a timer.
            followMeta(of: daemon)
        } else if host == nil {
            // Local terminals have no change events: ask the kernel once a second. Weak across
            // the sleep, so a closed window's workspace is freed and the loop ends.
            Task { [weak self] in
                while self != nil {
                    self?.refreshForegrounds()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keyboardFrameChangeUntil = .now + .milliseconds(800)
                // The keyboard slides: the terminals' grids change once it has.
                if duration > 0 { TerminalSurface.holdGrids(for: .seconds(duration + Self.keyboardSettle)) }
                let top = self.keyboardTop(screenFrame: endFrame)
                guard top != self.keyboardTop else { return }
                withAnimation(duration > 0 ? .easeOut(duration: duration) : nil) { self.keyboardTop = top }
            }
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
    /// Input typed over a saved screen was not sent (the host's screen had changed).
    @ObservationIgnored var onHeldInputDropped: (() -> Void)?
    /// Whether any of this window's panes on the host still shows its saved screen, or the
    /// layout itself is the saved one (instant start): "Connecting…" in the header.
    var showsSavedWorkspace: Bool {
        host?.showsCachedLayout == true || panes.values.contains(where: \.showsSavedScreen)
    }
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
        // Splits, closes and zooms animate the panes' sizes (`SplitTreeView`): no cols × rows
        // overlay through them. Divider moves keep it.
        if case .resize = op {} else { layoutChangeUntil = .now + .milliseconds(700) }
        let signpost = Self.signposter.beginInterval("Layout op")
        layout.apply(op)
        reconcilePanes()
        Self.signposter.endInterval("Layout op", signpost)
    }

    /// Instruments' Points of Interest: layout ops and pane creation (what a split waits on).
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "app", category: .pointsOfInterest)

    /// The tab's name: the user's rename, else the friendly name it got when it was created
    /// ("quiet-otter"). With Settings ▸ "Title from shell", a program's OSC 0/2 title, else the
    /// directory, replaces a generated name (never a rename).
    func title(of tab: Tab) -> String {
        if let title = tab.title {
            if UserDefaults.standard.bool(forKey: TabNaming.titleFromShell), FriendlyName.isGenerated(title),
               let shell = pane(tab.focused)?.title.nonEmpty ?? directory(of: tab)
            {
                return shell
            }
            return title
        }
        if let title = pane(tab.focused)?.title, !title.isEmpty { return title }
        if let foreground = foregrounds[tab.focused], !foreground.title.isEmpty { return foreground.title }
        return "Shell"
    }

    /// The live line under a tab's name: what its agent (or a program's own report) says it is
    /// doing, else the program running in the focused pane, else the program's own title
    /// (OSC 0/2), else the git checkout as `repo:branch`, else the directory.
    func context(of tab: Tab) -> String? {
        let paneId = tab.focused
        let name = title(of: tab)
        if let daemon = host as? DaemonConnection, let agent = daemon.meta[paneId]?.agent {
            let kind = agent.kind.prefix(1).uppercased() + agent.kind.dropFirst()
            switch agent.state {
            case .blocked(_, let summary, _): return SharedApproval.shows(summary: summary) ? "\(kind): \(summary)" : "\(kind) needs you"
            case .running: return daemon.meta[paneId].map { $0.title.isEmpty ? "\(kind) working" : "\(kind): \($0.title)" }
            case .idle, .done: break
            }
        } else if let daemon = host as? DaemonConnection, let report = daemon.report(of: paneId), report.state != .idle {
            let words = report.detail ?? report.state.title
            return report.program.map { "\($0): \(words)" } ?? words
        }
        if let program = pane(paneId)?.foregroundProgram ?? foregrounds[paneId]?.program, !program.isEmpty,
           !PaneForeground.shells.contains(program)
        {
            return program
        }
        if let shellTitle = pane(paneId)?.title, !shellTitle.isEmpty, shellTitle != name { return shellTitle }
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
        var names: [(TabId, String)] = []
        for tab in unnamed {
            namingRequested.insert(tab.id)
            let name = FriendlyName.make(avoiding: used)
            used.insert(name)
            names.append((tab.id, name))
        }
        // After this turn (`reconcilePanes` runs inside `apply`), all at once: the session is
        // composed once, not once per tab.
        Task { @MainActor [weak self] in
            guard let self, !self.isClosed else { return }
            let untitled = Set(self.session.tabs.filter { $0.title == nil }.map(\.id))
            for (tab, name) in names where untitled.contains(tab) {
                self.layout.apply(.rename(tab, name))
            }
        }
    }

    /// The focused pane's directory (OSC 7, else the PTY's cwd), with ~ for home.
    func directory(of tab: Tab) -> String? {
        if let pwd = pane(tab.focused)?.workingDirectory, !pwd.isEmpty {
            return PaneForeground(program: "", directory: pwd).shortDirectory
        }
        return foregrounds[tab.focused]?.shortDirectory
    }

    /// What a pane runs, for headers and lists: the reported program, else what the PTY says,
    /// else "shell". Never the pane id, which UI tests use as the terminal's identifier.
    func programName(of pane: PaneId) -> String {
        if PaneDrawing.of(pane)?.canvas != nil { return "canvas" }
        if let program = self.pane(pane)?.foregroundProgram { return program }
        if let program = foregrounds[pane]?.program, !program.isEmpty { return program }
        return "shell"
    }

    /// The focused pane's absolute directory, for the window's represented folder.
    func absoluteDirectory(of tab: Tab) -> String? {
        if let pwd = pane(tab.focused)?.workingDirectory, !pwd.isEmpty { return pwd }
        return foregrounds[tab.focused]?.directory
    }

    /// Refreshes the foregrounds after the daemon's pane metadata changed, at most once per
    /// `metaCoalescing`: agents retitle their panes many times a second.
    private func followMeta(of daemon: DaemonConnection) {
        withObservationTracking { _ = daemon.meta.all } onChange: { [weak self, weak daemon] in
            Task { @MainActor [weak self] in
                guard self?.beginMetaRefresh() == true else { return }
                // Weak across the sleep: a busy host must not keep a closed window's workspace.
                try? await Task.sleep(for: Self.metaCoalescing)
                guard let self, let daemon, !self.isClosed else { return }
                self.metaRefreshPending = false
                self.refreshForegrounds()
                self.followMeta(of: daemon)
            }
        }
        refreshForegrounds()
    }

    @ObservationIgnored private var metaRefreshPending = false

    private func beginMetaRefresh() -> Bool {
        guard !isClosed, !metaRefreshPending else { return false }
        metaRefreshPending = true
        return true
    }
    private static let metaCoalescing = Duration.milliseconds(500)

    private func refreshForegrounds() {
        let daemon = host as? DaemonConnection
        for (id, pane) in made {
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

    /// Set when the window switches here from another host's workspace while typing went to a
    /// terminal: the focused pane takes the keyboard as it appears, so switching hosts never
    /// drops typing (or the ⌘ shortcuts that need a responder) on iPhone and iPad.
    @ObservationIgnored var inheritsKeyboardFocus = false

    /// Whether the focused pane should take first responder when it appears or gains focus. On iOS
    /// only while typing already goes to a terminal or a hardware keyboard is attached, so that
    /// focusing a pane never pops up the software keyboard unasked.
    var claimsKeyboardFocus: Bool {
        #if os(iOS)
        // `-noAutoFocus YES` (screenshots): never raise the software keyboard by itself.
        if UserDefaults.standard.bool(forKey: "noAutoFocus") { return false }
        return GCKeyboard.coalesced != nil || inheritsKeyboardFocus || made.values.contains { $0.view.isFirstResponder }
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
            for pane in self.made.values { self.applyKeyboardSettings(to: pane) }
        }
    }

    // MARK: Panes

    /// Keeps the panes in step with the layout: closed leaves end, the window's tab is made at
    /// once and every other new leaf joins `unmade`, made in stages between frames.
    private func reconcilePanes() {
        guard !isClosed else { return }
        nameNewTabs()
        let live = session.panes
        var changed = false
        for (id, pane) in made where !live.contains(id) {
            pane.terminate()
            made[id] = nil
            slots.removeValue(forKey: id)?.pane = nil
            if grids[id] != nil { grids[id] = nil }
            if notices[id] != nil { notices[id] = nil }
            if foregrounds[id] != nil { foregrounds[id] = nil }
            changed = true
        }
        if failures.keys.contains(where: { !live.contains($0) }) { failures = failures.filter { live.contains($0.key) } }
        let shown = Set(session.activeTab?.root.panes ?? [])
        unmade.keep { live.contains($0) && made[$0] == nil && !shown.contains($0) }
        // In the sidebar's order, so the rows people see first get their panes first.
        for id in session.tabs.flatMap(\.root.panes) where made[id] == nil && failures[id] == nil {
            if shown.contains(id) {
                changed = makePaneNow(id) || changed
            } else {
                unmade.append(id)
            }
        }
        if changed { madeStages += 1 }
        makeUnmadeSoon()
    }

    /// Makes `id` now; false if it failed (the reason is in `failures`).
    private func makePaneNow(_ id: PaneId) -> Bool {
        do {
            let signpost = Self.signposter.beginInterval("Make pane")
            let start = ContinuousClock.now
            let pane = try makePane(id)
            made[id] = pane
            slot(id).pane = pane
            Self.signposter.endInterval("Make pane", signpost)
            Pane.log.debug("pane \(id.description, privacy: .public) made in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            return true
        } catch {
            failures[id] = ScreenError.describe(error)
            return false
        }
    }

    /// How long one stage of background pane making may hold the main thread.
    static let stageBudget = Duration.milliseconds(8)

    /// Makes the unmade panes a stage at a time, with a frame's worth of the main thread in
    /// between, until none is left. Weak across the pause: a closed window stops it.
    private func makeUnmadeSoon() {
        guard !makingUnmade, !unmade.isEmpty, !isClosed else { return }
        makingUnmade = true
        Task { @MainActor [weak self] in
            while self?.makeStage() == true {
                try? await Task.sleep(for: .milliseconds(1))
            }
            self?.makingUnmade = false
        }
    }

    /// One stage: unmade panes until the budget is spent. Returns whether any are left.
    private func makeStage() -> Bool {
        guard !isClosed else { return false }
        let deadline = ContinuousClock.now + Self.stageBudget
        let live = session.panes
        var changed = false
        while ContinuousClock.now < deadline, let id = unmade.next() {
            guard made[id] == nil, failures[id] == nil, live.contains(id) else { continue }
            changed = makePaneNow(id) || changed
        }
        if changed { madeStages += 1 }
        return !unmade.isEmpty
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
        let saved = (host as? DaemonConnection)?.cachedScreen(for: id)
        let pane = try Pane(id: id, backend: makeBackend(id), appearance: appearance, saved: saved) { [weak self] in
            // The process exited: close its pane.
            Task { @MainActor in self?.apply(.close(id)) }
        }
        pane.onGridChange = { [weak self] grid in
            let size = GridSize(cols: Int(grid.cols), rows: Int(grid.rows))
            if self?.grids[id] != size { self?.grids[id] = size }
        }
        pane.isFocusedPane = { [weak self] in self?.focusedPane == id }
        pane.onHeldInputDropped = { [weak self] in self?.onHeldInputDropped?() }
        pane.onBell = { [weak self] in self?.ringBell(id) }
        pane.onCellSize = { [weak self] size in
            if self?.cellSize != size { self?.cellSize = size }
        }
        applyKeyboardSettings(to: pane)
        PaneDrawing.attach(to: pane, workspace: self)
        PaneCommandMarks.attach(to: pane, workspace: self)
        PaneLinks.attach(to: pane, workspace: self)
        #if os(iOS)
        pane.view.accessibilityIdentifier = id.description
        pane.view.keyBar = keyBar
        pane.view.takeLatchedModifiers = { [keyBar] in keyBar.takeLatchedModifiers() }
        // The terminal answers every app shortcut itself: right after the window switches
        // hosts, the menu commands found through the responder chain can miss them.
        let shortcuts = WorkspaceAction.allShortcutActions
        pane.view.appKeyCommands = shortcuts.map { action in
            UIKeyCommand(
                input: action.shortcut.key.uiKeyInput, modifierFlags: action.shortcut.modifiers.uiKeyModifierFlags,
                action: #selector(TerminalView.performAppKeyCommand(_:)))
        }
        pane.view.onFontSizeChange = { size in
            UserDefaults.standard.set(Double(size), forKey: TerminalPreferences.Key.fontSize)
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
            // A draft belongs to one pane: the old pane's goes when focus moves.
            if keyBar.target !== pane.view { multiplayer?.clearDraft() }
            keyBar.onDraft = { [weak self] text, caret, source in
                self?.multiplayer?.setDraft(id.rawValue, source: source, text: text, caret: caret)
            }
            keyBar.target = pane.view
            keyBar.assist = pane.backend as? any LineAssist
            keyBar.update(context: keyBarContext(of: pane))
            pane.claimSize()
            apply(.focus(id))
            onPaneFocus?(id)
            keyBar.onDraw = DrawingCommands.canDraw(in: self) ? { [weak self] in if let self { DrawingCommands.toggleDrawing(in: self) } } : nil
            followWorkflows(of: pane)
        }
        #if DEBUG
        // `-demoPreedit <text>` shows IME marked text in the first pane, for screenshots and UI
        // tests (the simulator's software keyboard cannot be switched to an IME from a test).
        if let preedit = UserDefaults.standard.string(forKey: "demoPreedit"), !preedit.isEmpty, made.isEmpty {
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

/// Panes waiting to be made: the ones views asked for first, then the rest in order. Every
/// operation is O(1) amortized, so a sidebar of 500 rows asking costs nothing quadratic.
struct PaneQueue {
    private var asked: [PaneId] = []
    private var rest: [PaneId] = []
    private var restStart = 0
    private var members: Set<PaneId> = []
    private var promoted: Set<PaneId> = []

    var isEmpty: Bool { members.isEmpty }

    mutating func append(_ id: PaneId) {
        if members.insert(id).inserted { rest.append(id) }
    }

    /// Moves a waiting pane to the front; false if it is not waiting.
    mutating func prioritize(_ id: PaneId) -> Bool {
        guard members.contains(id) else { return false }
        if promoted.insert(id).inserted { asked.append(id) }
        return true
    }

    mutating func next() -> PaneId? {
        while let id = asked.popLast() ?? nextOfRest() {
            if members.remove(id) != nil {
                promoted.remove(id)
                return id
            }
        }
        return nil
    }

    private mutating func nextOfRest() -> PaneId? {
        guard restStart < rest.count else { return nil }
        defer { restStart += 1 }
        return rest[restStart]
    }

    /// Drops the waiting panes `isKept` rejects.
    mutating func keep(_ isKept: (PaneId) -> Bool) {
        members = members.filter(isKept)
        promoted = promoted.intersection(members)
        rest = rest[restStart...].filter { members.contains($0) }
        restStart = 0
        asked = asked.filter { promoted.contains($0) }
    }
}

/// One pane of a workspace, observed on its own (`Workspace.pane(_:)`): making it redraws only
/// the views that show it.
@Observable
final class PaneHolder {
    var pane: Pane?
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
    /// Starts a new shell on the host or moves panes there (and so needs a live link).
    var opensPane: Bool {
        switch self {
        case .newTab, .split, .movePaneToNewTab, .movePane, .mergeTab, .newFloat, .movePaneToEdge: true
        case .dock(_, let target, _): target != nil
        default: false
        }
    }
}
