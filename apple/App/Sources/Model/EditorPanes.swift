import DesignSystem
import Foundation
import HostKit
import Observation
import os
import PaneLayout
import WebKit
#if canImport(UIKit)
import GameController
import UIKit
#else
import AppKit
#endif

// VS Code editors as panes of a window's split tree (docs/APP-ARCHITECTURE.md §20). An editor is
// a leaf of a window-owned tab (`CompositeTab.editors`): a tab of its own ("Open in VS Code"),
// or beside a terminal (⌥, or "Open in VS Code Beside"). Each has its own web view and its own
// session on its host's editor server, kept alive across tab switches and released (snapshot
// first) after ten minutes off screen.

extension ProgramIdentity {
    /// An editor pane. The neutral code glyph: Microsoft's logo is not ours to use.
    static let vscode = ProgramIdentity(id: "vscode", displayName: "VS Code", kind: .language)
}

/// Where Open in VS Code puts the editor.
enum EditorPlacement: Equatable {
    /// A tab of its own (the default).
    case tab
    /// Beside the focused pane, in its tab.
    case split

    /// ⌥ held while choosing the command (a ⌥-click, ⌥Return in the palette): beside the
    /// focused pane; else a tab of its own.
    static var fromModifiers: EditorPlacement {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option) ? .split : .tab
        #else
        let keyboard = GCKeyboard.coalesced?.keyboardInput
        let held = keyboard?.button(forKeyCode: .leftAlt)?.isPressed == true || keyboard?.button(forKeyCode: .rightAlt)?.isPressed == true
        return held ? .split : .tab
        #endif
    }
}

/// One open editor: its source (host, folder, session), its web view and what its screen
/// shows. Lives as long as its leaf (`EditorPanes.prune`), so a tab switch never reloads it.
@MainActor
@Observable
final class EditorPane: Identifiable {
    let member: EditorMember
    let source: any EditorSource
    var id: UUID { member.id }

    /// The web view (serve-web's workbench or vscode.dev): nil until first shown, and while
    /// suspended.
    private(set) var browser: TunnelBrowser?
    /// The workbench is up in the web view (else the steps, or the snapshot while resuming).
    var isWorkbenchVisible = false
    /// The web view is on screen in one of the pane's views (not left in one that went away).
    var isWebViewShown = false
    /// Released after a while off screen: the snapshot stands in until the workbench is back.
    private(set) var isSuspended = false
    /// The workbench as last seen (JPEG), shown while a suspended editor reloads.
    private(set) var snapshot: Data?
    var phaseStarted = Date.now
    var installedThisRun = false
    var isTunnelOfferShown = false
    /// Opened from "Open VS Code Through a Remote Tunnel…": ask that first.
    var offerTunnelFirst = false

    /// A click or tap in the web view (it focuses the pane's leaf).
    @ObservationIgnored var onTouch: (() -> Void)?
    @ObservationIgnored private(set) var loadedURL: URL?
    @ObservationIgnored private var loadedPending: URL?
    /// Where a suspended editor comes back to (the page it was on).
    @ObservationIgnored private var resumeURL: URL?
    @ObservationIgnored private var onScreen = 0
    /// Since when no view shows it (nil while shown).
    @ObservationIgnored private(set) var hiddenSince: ContinuousClock.Instant? = .now
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    #if os(macOS)
    @ObservationIgnored private var clickMonitor: Any?
    #endif

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "editor")

    init(member: EditorMember, source: any EditorSource) {
        self.member = member
        self.source = source
        source.onServerLost { [weak self] reason in self?.recover(reason) }
    }

    var webView: WKWebView? { browser?.webView }
    @ObservationIgnored private var browserIsIsolated = false

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host()?.lowercased() ?? "")
    }
    var isOnScreen: Bool { onScreen > 0 }

    /// The web view for `url`, made on first use.
    ///
    /// An editor server on the host (a loopback forward) keeps its own data store per host and
    /// folder (editors on one folder share it, as browser windows on one server): each server's
    /// connection token lives in a `vscode-tkn` cookie, and cookies do not tell ports apart, so in
    /// one shared store the last editor loaded overwrote the others' and their servers answered
    /// "Forbidden". vscode.dev (the Remote Tunnel) uses the shared store,
    /// so one GitHub or Microsoft sign-in serves every tunnel editor.
    @discardableResult
    func makeBrowser(for url: URL) -> TunnelBrowser {
        let isolated = Self.isLoopback(url)
        if let browser, browserIsIsolated == isolated { return browser }
        if browser != nil { tearDown() }
        let store = isolated
            ? WKWebsiteDataStore(forIdentifier: WKWebsiteDataStore.stableIdentifier("unnamed-editor:\(member.hostId):\(member.folder)"))
            : .default()
        browserIsIsolated = isolated
        let browser = TunnelBrowser(dataStore: store)
        browser.onLoad = { [weak self] in self?.workbenchLoaded() }
        browser.onFail = { [weak self] reason in self?.pageFailed(reason) }
        browser.onLost = { [weak self] reason in self?.recover(reason) }
        watchTouches(browser.webView)
        self.browser = browser
        return browser
    }

    // MARK: Following the source

    /// The source's phase moved on: load a new address, note the first install.
    func phaseChanged(_ phase: EditorPhase) {
        phaseStarted = .now
        if phase == .installing { installedThisRun = true }
        if let url = phase.url, url != loadedURL {
            loadedURL = url
            makeBrowser(for: url).load(url)
        }
        if phase.url == nil { isWorkbenchVisible = false }
    }

    /// A file to show in a workbench that could not open it itself (once per address: the view
    /// hands it over again each time it appears).
    func load(pending url: URL) {
        guard url != loadedPending else { return }
        loadedPending = url
        makeBrowser(for: url).load(url)
    }

    /// Starts over on another path (the Remote Tunnel): the next address loads afresh.
    func restart() {
        isWorkbenchVisible = false
        loadedURL = nil
    }

    /// Load failures in a row (a forward just made can refuse the first connections).
    @ObservationIgnored private var failures = 0

    /// The workbench did not load: try again a few times, a second apart, before saying so.
    private func pageFailed(_ reason: String) {
        guard !isWorkbenchVisible, let url = browser?.webView.url ?? loadedURL else { return }
        failures += 1
        guard failures <= 5 else {
            Self.log.error("editor \(self.member.description, privacy: .public) gave up loading: \(reason, privacy: .public)")
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.isWorkbenchVisible else { return }
            self.browser?.load(url)
        }
    }

    private func workbenchLoaded() {
        guard loadedURL != nil else { return }
        failures = 0
        source.didLoad()
        isWorkbenchVisible = true
        if isSuspended {
            isSuspended = false
            snapshot = nil
            Self.log.info("editor \(self.member.description, privacy: .public) resumed")
        }
        keepSnapshots()
    }

    // MARK: On screen, suspended

    func appeared() {
        onScreen += 1
        hiddenSince = nil
        if isSuspended, browser == nil, let url = resumeURL ?? loadedURL {
            makeBrowser(for: url).load(url)
        }
    }

    func disappeared() {
        onScreen = max(0, onScreen - 1)
        if onScreen == 0 { hiddenSince = .now }
    }

    /// Off screen long enough: keep a picture and let the web view (and its web content
    /// process) go. The server keeps running on the host; showing the pane loads it again, and
    /// VS Code restores its open files and unsaved changes itself.
    func suspend() async {
        guard let browser, !isOnScreen, isWorkbenchVisible else { return }
        resumeURL = browser.webView.url ?? loadedURL
        if snapshot == nil { snapshot = await Self.snapshot(of: browser.webView) }
        guard !isOnScreen, self.browser === browser else { return }
        snapshotTask?.cancel()
        unwatchTouches()
        browser.webView.stopLoading()
        self.browser = nil
        isWorkbenchVisible = false
        isSuspended = true
        Self.log.info("editor \(self.member.description, privacy: .public) suspended")
    }

    /// The page cannot go on (its web content process ended, or the workbench lost its session
    /// on the server): the last picture stands in, as for a suspended editor, while the page
    /// loads again, on a new session when the server's is gone.
    func recover(_ reason: String) {
        guard !isRecovering, loadedURL != nil else { return }
        Self.log.error("editor \(self.member.description, privacy: .public) reloads: \(reason, privacy: .public)")
        isRecovering = true
        resumeURL = browser?.webView.url ?? loadedURL
        snapshotTask?.cancel()
        unwatchTouches()
        browser?.webView.stopLoading()
        browser = nil
        isWorkbenchVisible = false
        isSuspended = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.source.reopen()
            self.isRecovering = false
            // A new session's address: on screen it already loaded through `phaseChanged`.
            if let url = self.source.phase.url, url != self.loadedURL {
                self.loadedURL = url
                self.resumeURL = url
            }
            // Else the page loads again here, or when the pane is shown.
            if self.browser == nil, self.isOnScreen, let url = self.resumeURL ?? self.loadedURL {
                self.makeBrowser(for: url).load(url)
            }
        }
    }

    @ObservationIgnored private var isRecovering = false

    /// The pane closed: its web view goes now.
    func tearDown() {
        snapshotTask?.cancel()
        unwatchTouches()
        browser?.webView.stopLoading()
        browser = nil
    }

    /// A fresh picture every minute while the workbench is on screen (a hidden web view may not
    /// draw one any more when the time to suspend comes).
    private func keepSnapshots() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self, let webView = self.webView else { return }
                if self.isOnScreen, self.isWorkbenchVisible, webView.window != nil,
                   let picture = await Self.snapshot(of: webView) {
                    self.snapshot = picture
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// The web view as a small JPEG (at most 900 pt wide).
    static func snapshot(of webView: WKWebView) async -> Data? {
        guard webView.bounds.width > 1 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 900)))
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: 0.6)
        #else
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        #endif
    }

    // MARK: Focus

    /// The leaf took the focus: the web view takes the keyboard (every key goes to VS Code).
    func takeKeyboard() {
        guard let webView, isWorkbenchVisible else { return }
        Task { @MainActor in
            for attempt in 0..<20 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(16)) }
                guard webView.window != nil else { continue }
                #if os(macOS)
                if !Self.hasKeyboard(webView) { webView.window?.makeFirstResponder(webView) }
                #else
                if !webView.isFirstResponder, !(webView.findFirstResponder() != nil) { webView.becomeFirstResponder() }
                #endif
                return
            }
        }
    }

    /// The leaf lost the focus: the web view lets the keyboard go.
    func releaseKeyboard() {
        guard let webView else { return }
        #if os(macOS)
        if Self.hasKeyboard(webView) { webView.window?.makeFirstResponder(nil) }
        #else
        webView.endEditing(true)
        _ = webView.resignFirstResponder()
        #endif
    }

    #if os(macOS)
    /// Whether the window's first responder is the web view or inside it.
    static func hasKeyboard(_ webView: WKWebView) -> Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }
    #endif

    // MARK: Touches

    private func watchTouches(_ webView: WKWebView) {
        #if canImport(UIKit)
        let tap = UITapGestureRecognizer(target: TouchRelay.shared, action: #selector(TouchRelay.touched(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = TouchRelay.shared
        webView.addGestureRecognizer(tap)
        TouchRelay.shared.handlers[ObjectIdentifier(webView)] = { [weak self] in self?.onTouch?() }
        #else
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak webView] event in
            if let webView, event.window === webView.window,
               let hit = webView.window?.contentView?.hitTest(event.locationInWindow),
               hit === webView || hit.isDescendant(of: webView) {
                MainActor.assumeIsolated { self?.onTouch?() }
            }
            return event
        }
        #endif
    }

    private func unwatchTouches() {
        #if canImport(UIKit)
        if let webView { TouchRelay.shared.handlers[ObjectIdentifier(webView)] = nil }
        #else
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        #endif
    }
}

#if canImport(UIKit)
/// Taps in editor web views, seen alongside the page's own (never cancelling them).
@MainActor
private final class TouchRelay: NSObject, UIGestureRecognizerDelegate {
    static let shared = TouchRelay()
    var handlers: [ObjectIdentifier: () -> Void] = [:]

    @objc func touched(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view else { return }
        handlers[ObjectIdentifier(view)]?()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

private extension UIView {
    func findFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.findFirstResponder() { return found }
        }
        return nil
    }
}
#endif

/// A window's open editors, by `EditorMember.id`. A pane (source and web view) is made when its
/// leaf is first shown, so a relaunch restores editor tabs without loading any until they are
/// looked at; it goes when its leaf does.
@MainActor
final class EditorPanes {
    @ObservationIgnored private(set) var panes: [UUID: EditorPane] = [:]
    private let makeSource: (EditorMember) -> any EditorSource
    /// How long an editor may stay off screen before its web view is released (10 min;
    /// `-editorSuspendAfter <seconds>` for tests).
    var suspendAfter: Duration
    private var sweeper: Task<Void, Never>?

    static var defaultSuspendAfter: Duration {
        let seconds = UserDefaults.standard.double(forKey: "editorSuspendAfter")
        return seconds > 0 ? .seconds(seconds) : .seconds(600)
    }

    init(suspendAfter: Duration = EditorPanes.defaultSuspendAfter, makeSource: @escaping (EditorMember) -> any EditorSource) {
        self.suspendAfter = suspendAfter
        self.makeSource = makeSource
    }

    /// The editor's pane, made on first use.
    func pane(for member: EditorMember) -> EditorPane {
        if let pane = panes[member.id] { return pane }
        let pane = EditorPane(member: member, source: makeSource(member))
        panes[member.id] = pane
        startSweeping()
        return pane
    }

    func existing(_ id: UUID) -> EditorPane? { panes[id] }

    /// Lets go of editors whose leaves closed (the servers keep running on their hosts).
    func prune(keeping ids: Set<UUID>) {
        for (id, pane) in panes where !ids.contains(id) {
            panes[id] = nil
            pane.tearDown()
            Task { await pane.source.close(stopServer: false) }
        }
    }

    /// Suspends editors off screen for `suspendAfter` or longer.
    func sweep(now: ContinuousClock.Instant = .now) async {
        for pane in Array(panes.values) where pane.browser != nil && !pane.isOnScreen {
            guard let since = pane.hiddenSince, now - since >= suspendAfter else { continue }
            await pane.suspend()
        }
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        let interval = min(Duration.seconds(30), suspendAfter / 4)
        sweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.sweep()
            }
        }
    }

    func stop() {
        sweeper?.cancel()
        sweeper = nil
        prune(keeping: [])
    }
}

// MARK: - The window's editors

extension WindowModel {
    /// The focused leaf is an editor showing its workbench: every key goes to VS Code, except
    /// the few that lead back out (`WorkspaceAction.passesEditor`).
    var editorHasKeys: Bool {
        guard destination == .terminal, sheet == nil, !isPaletteShown, let editor = activeMixed?.focusedEditor else { return false }
        return editors.existing(editor.id)?.isWorkbenchVisible == true
    }

    /// The editor that has the focus, if any.
    var focusedEditor: EditorPane? {
        guard destination == .terminal, let editor = activeMixed?.focusedEditor else { return nil }
        return editors.existing(editor.id)
    }

    /// Open in VS Code: the focused pane's folder (its worktree's root) on its host, in a new
    /// editor in a tab of its own (`placement` nil: ⌥ held means beside the focused pane); several
    /// may show one folder, as browser windows on one server. With a path, that file opens at the
    /// line, in an editor already holding it when there is one.
    func openEditor(path: String? = nil, line: Int? = nil, column: Int? = nil, placement: EditorPlacement? = nil, tunnelOffer: Bool = false) {
        let placement = placement ?? EditorPlacement.fromModifiers
        sheet = nil
        Task { @MainActor in
            guard let member = await editorTarget(path: path) else { return }
            let pane = showEditor(member, placement: placement)
            if tunnelOffer {
                if pane.source.phase == .idle { pane.offerTunnelFirst = true } else { pane.isTunnelOfferShown = true }
            }
            if let path {
                await pane.source.open(path: path, line: line, column: column)
            }
        }
    }

    /// The editor for the focused pane (or a path): for a path, one already open on its host
    /// whose folder holds it (the focused one first), else a new one on the folder's worktree
    /// root. Nil (said in a toast) without a host.
    func editorTarget(path: String?) async -> EditorMember? {
        if LaunchOptions.mock {
            return EditorMember(hostId: "studio", folder: "~/projects/unnamed")
        }
        var context = HostContext.resolve(app: app, window: self)
        // The window's host may still be connecting: wait a moment for it.
        if context == nil, workspace?.host is DaemonConnection {
            for _ in 0..<150 where context == nil {
                try? await Task.sleep(for: .milliseconds(100))
                context = HostContext.resolve(app: app, window: self)
            }
        }
        guard var context else {
            toasts.show(Toast(HostContext.noHost, systemImage: "network.slash", style: .neutral))
            return nil
        }
        // Just after connecting the panes may not have said where they are yet.
        for _ in 0..<20 where context.directory == nil {
            try? await Task.sleep(for: .milliseconds(100))
            if let again = HostContext.resolve(app: app, window: self), again.hostId == context.hostId { context = again }
        }
        if let path {
            let holders = composites.editors.filter { $0.hostId == context.hostId && $0.contains(path: path) }
            let deepest = holders.map(\.folder.count).max()
            let candidates = holders.filter { $0.folder.count == deepest }
            if let holder = candidates.first(where: { $0.id == activeMixed?.focusedEditor?.id }) ?? candidates.last { return holder }
        }
        let directory: String
        if let path, path.hasPrefix("/") {
            directory = (path as NSString).deletingLastPathComponent
        } else {
            directory = context.directory ?? "~"
        }
        // The worktree's root when the directory is in one (VS Code shows the project).
        var folder = directory
        if let status = try? await context.api().gitStatus(path: directory) { folder = status.root }
        return EditorMember(hostId: context.hostId, folder: folder)
    }

    /// Shows an editor: its leaf when it is open, else a new tab or a leaf beside the focused
    /// pane.
    @discardableResult
    func showEditor(_ member: EditorMember, placement: EditorPlacement) -> EditorPane {
        let pane = editors.pane(for: member)
        destination = .terminal
        if let tab = composites.tab(containingEditor: member.id), let leaf = tab.leaf(forEditor: member.id) {
            noteLeavingTab()
            focusLeaf(leaf, inMixedTab: tab.id)
            return pane
        }
        AppModel.log.info("editor \(member.description, privacy: .public) opens in \(placement == .tab ? "a tab" : "a split", privacy: .public)")
        if placement == .split {
            if let mixed = activeMixed {
                composites.addEditor(member, to: mixed.id)
                syncMixedFocus()
                return pane
            }
            if let open = workspace, let tab = open.session.activeTab {
                let own = currentGroupId
                let id = composites.addEditor(member, besideHost: own, tab: tab)
                if pairedTab == TabRef(hostId: own, tab: tab.id) { pairedTab = nil }
                activeMixedTab = id
                syncMixedFocus()
                return pane
            }
        }
        let id = composites.openEditor(member)
        focus(Self.mixedRef(id))
        return pane
    }

    /// Closes an editor's leaf (⌘W, its bar's ✕). `stopServer` also ends it on the host.
    func closeEditor(_ id: UUID, stopServer: Bool = false) {
        guard let tab = composites.tab(containingEditor: id), let leaf = tab.leaf(forEditor: id) else { return }
        if stopServer, let pane = editors.existing(id) {
            Task { await pane.source.close(stopServer: true) }
        }
        composites.close(leaf: leaf, in: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
    }

    /// The focused editor fills the window: no sidebar, tab strip, toolbar or editor bar. Ends
    /// when another tab or pane takes the focus (`followFullScreen`).
    var isEditorFullScreen: Bool {
        guard let id = fullScreenEditor, destination == .terminal else { return false }
        return activeMixed?.focusedEditor?.id == id
    }

    /// ⌃⌘F, the More menu, the palette: the focused editor full screen, or back.
    func toggleEditorFullScreen() {
        if isEditorFullScreen {
            fullScreenEditor = nil
            fullScreenHints.dismiss()
        } else if destination == .terminal, let editor = activeMixed?.focusedEditor {
            fullScreenEditor = editor.id
            FullScreenHint.showIfNew(on: fullScreenHints)
        }
        #if os(macOS)
        NativeFullScreen.follow(isEditorFullScreen)
        #endif
    }

    /// Full screen ends for good once its editor is no longer the one in front (another tab,
    /// pane or screen, the editor closed): coming back never finds the window bare again.
    func followFullScreen() {
        guard !isClosed else { return }
        if fullScreenEditor != nil, !isEditorFullScreen {
            fullScreenEditor = nil
            #if os(macOS)
            NativeFullScreen.follow(false)
            #endif
        }
        withObservationTracking {
            _ = isEditorFullScreen
            _ = fullScreenEditor
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followFullScreen() }
        }
    }

    /// ⌃⌘` (Return to Terminal): from an editor, the terminal beside it in its tab, else the tab
    /// worked in before the editor's.
    func returnToTerminal() {
        AppModel.log.info("return to terminal from \(self.activeMixed?.focusedEditor?.description ?? "no editor", privacy: .public)")
        guard destination == .terminal, let mixed = activeMixed, mixed.focusedEditor != nil else { return }
        if let leaf = mixed.leaves.first(where: { mixed.members[$0] != nil }) {
            focusLeaf(leaf, inMixedTab: mixed.id)
            return
        }
        let all = groups.tabs
        if let last = lastTerminalTab, all.contains(last) {
            focus(last)
        } else if let other = all.first(where: { !isEditorTab($0) }) {
            focus(other)
        }
    }

    /// Whether a tab holds editors only.
    func isEditorTab(_ ref: TabRef) -> Bool {
        ref.hostId == HostGroups.mixedId && composites.tab(ref.tab)?.isEditorOnly == true
    }

    /// Remembers the tab on screen before another comes forward (Return to Terminal goes back
    /// to it from an editor tab).
    func noteLeavingTab() {
        if let current = currentTab, !isEditorTab(current) { lastTerminalTab = current }
    }

    /// Keeps the open editors to those the window's tabs hold.
    func followEditors() {
        guard !isClosed else { return }
        editors.prune(keeping: Set(composites.editors.map(\.id)))
        browsers.prune(keeping: Set(composites.browsers.map(\.id)))
        withObservationTracking {
            _ = composites.tabs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followEditors() }
        }
    }

    /// Palette commands beside "Open in VS Code".
    var editorPaletteExtras: [(String, String, String, [String]?, () -> Void)] {
        var extras: [(String, String, String, [String]?, () -> Void)] = [
            ("editor-split", "Open in VS Code Beside", "rectangle.split.2x1", ["⌥", "↩"], { [weak self] in
                self?.openEditor(placement: .split)
            }),
            ("editor-tunnel", "Open VS Code Through a Remote Tunnel…", "point.3.connected.trianglepath.dotted", nil, { [weak self] in
                self?.openEditor(placement: .tab, tunnelOffer: true)
            }),
        ]
        if destination == .terminal, activeMixed?.focusedEditor != nil {
            extras.append(("editor-full-screen", isEditorFullScreen ? "Exit Full Screen Editor" : "Full Screen Editor",
                           "arrow.up.left.and.arrow.down.right", WorkspaceAction.fullScreenEditor.shortcut.symbols, { [weak self] in
                self?.toggleEditorFullScreen()
            }))
        }
        #if os(macOS)
        if DesktopVSCode.isInstalled {
            extras.append(("editor-desktop", "Open in Desktop VS Code", "macwindow", nil, { [weak self] in
                self?.openInDesktopVSCode()
            }))
        }
        #endif
        return extras
    }

    #if os(macOS)
    /// The Mac's own full screen goes with the editor's: entered with it unless the window was
    /// already full screen, and left with it only when it was entered so.
    enum NativeFullScreen {
        @MainActor private static weak var entered: NSWindow?

        @MainActor static func follow(_ fullScreen: Bool) {
            if fullScreen {
                guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
                entered = window
                window.toggleFullScreen(nil)
            } else if let window = entered {
                entered = nil
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }

    /// The user's own desktop VS Code (Remote - SSH over our forward) on an editor's folder, or
    /// the focused pane's. Says why in a toast when it cannot.
    func openInDesktopVSCode(_ member: EditorMember? = nil, path: String? = nil, line: Int? = nil, column: Int? = nil) {
        let context: HostContext?
        if let member, let host = HostContext.host(member.hostId, app: app) {
            context = HostContext(hostId: host.hostId, name: host.name, daemon: host.daemon, pane: nil, directory: member.folder)
        } else {
            context = HostContext.resolve(app: app, window: self)
        }
        guard let context else {
            toasts.show(Toast(HostContext.noHost, systemImage: "network.slash", style: .neutral))
            return
        }
        Task { @MainActor in
            let sshUser = app.hosts.record(context.hostId)?.ssh?.user
            if let reason = await DesktopVSCode.open(context: context, sshUser: sshUser, path: path, line: line, column: column) {
                toasts.show(Toast(reason, systemImage: "exclamationmark.triangle"))
            }
        }
    }
    #endif
}
