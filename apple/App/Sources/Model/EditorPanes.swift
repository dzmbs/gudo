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

extension ProgramIdentity {
    /// A neutral code glyph: Microsoft's logo is not ours to use.
    static let vscode = ProgramIdentity(id: "vscode", displayName: "VS Code", kind: .language)
}

enum EditorPlacement: Equatable {
    case tab
    /// Beside the focused pane, in its tab.
    case split

    /// ⌥ held while choosing the command means beside the focused pane.
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

/// One open editor. Lives as long as its leaf, so a tab switch never reloads it.
@MainActor
@Observable
final class EditorPane: Identifiable {
    let member: EditorMember
    let source: any EditorSource
    var id: UUID { member.id }

    /// Nil until first shown, and while suspended.
    private(set) var browser: TunnelBrowser?
    var isWorkbenchVisible = false
    /// Not left in a view that went away.
    var isWebViewShown = false
    /// The snapshot stands in until the workbench is back.
    private(set) var isSuspended = false
    /// JPEG, shown while the workbench loads.
    private(set) var snapshot: Data?
    var phaseStarted = Date.now
    var installedThisRun = false
    var isTunnelOfferShown = false
    var offerTunnelFirst = false

    @ObservationIgnored var onTouch: (() -> Void)?
    @ObservationIgnored private(set) var loadedURL: URL?
    @ObservationIgnored private var loadedPending: URL?
    @ObservationIgnored private var resumeURL: URL?
    @ObservationIgnored private var onScreen = 0
    @ObservationIgnored private(set) var hiddenSince: ContinuousClock.Instant? = .now
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    #if os(macOS)
    @ObservationIgnored private var clickMonitor: Any?
    #endif

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "editor")

    @ObservationIgnored private let snapshots: EditorSnapshots

    init(member: EditorMember, source: any EditorSource, snapshots: EditorSnapshots = .shared) {
        self.member = member
        self.source = source
        self.snapshots = snapshots
        snapshot = snapshots.load(for: member)
        source.onServerLost { [weak self] reason in self?.recover(reason) }
    }

    var webView: WKWebView? { browser?.webView }
    @ObservationIgnored private var browserIsIsolated = false

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host()?.lowercased() ?? "")
    }
    var isOnScreen: Bool { onScreen > 0 }

    /// An editor server behind a loopback forward gets its own data store per host and folder:
    /// each server's connection token lives in a `vscode-tkn` cookie, and cookies do not tell
    /// ports apart, so a shared store would make other servers answer "Forbidden". vscode.dev uses
    /// the shared store, so one sign-in serves every tunnel editor.
    @discardableResult
    func makeBrowser(for url: URL) -> TunnelBrowser {
        let isolated = Self.isLoopback(url)
        if let browser, browserIsIsolated == isolated { return browser }
        if browser != nil { tearDown() }
        let store = isolated
            ? WKWebsiteDataStore(forIdentifier: WKWebsiteDataStore.stableIdentifier("gudo-editor:\(member.hostId):\(member.folder)"))
            : .default()
        browserIsIsolated = isolated
        let browser = TunnelBrowser(dataStore: store, phoneLayout: EditorPhoneLayout.isPhone)
        browser.onLoad = { [weak self] in self?.workbenchLoaded() }
        browser.onFail = { [weak self] reason in self?.pageFailed(reason) }
        browser.onLost = { [weak self] reason in self?.recover(reason) }
        browser.desktopURI = { [weak self] in self?.source.tunnelDesktopURI }
        watchTouches(browser.webView)
        self.browser = browser
        return browser
    }

    // MARK: Following the source

    func phaseChanged(_ phase: EditorPhase) {
        phaseStarted = .now
        if phase == .installing { installedThisRun = true }
        if let url = phase.url, url != loadedURL {
            loadedURL = url
            makeBrowser(for: url).load(url)
        }
        if phase.url == nil { isWorkbenchVisible = false }
    }

    /// Once per address: the view hands it over again each time it appears.
    func load(pending url: URL) {
        guard url != loadedPending else { return }
        loadedPending = url
        makeBrowser(for: url).load(url)
    }

    func restart() {
        isWorkbenchVisible = false
        loadedURL = nil
    }

    /// In a row: a forward just made can refuse the first connections.
    @ObservationIgnored private var failures = 0

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

    /// Keeps a picture and lets the web view and its content process go. The server keeps running
    /// on the host, and VS Code restores open files and unsaved changes itself.
    func suspend() async {
        guard let browser, !isOnScreen, isWorkbenchVisible else { return }
        resumeURL = browser.webView.url ?? loadedURL
        if snapshot == nil, let picture = await Self.snapshot(of: browser.webView) { await keep(picture) }
        guard !isOnScreen, self.browser === browser else { return }
        snapshotTask?.cancel()
        unwatchTouches()
        browser.webView.stopLoading()
        self.browser = nil
        isWorkbenchVisible = false
        isSuspended = true
        Self.log.info("editor \(self.member.description, privacy: .public) suspended")
    }

    /// The web content process ended or the workbench lost its server session: the last picture
    /// stands in while the page loads again, on a new session when the server's is gone.
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
            // On screen, a new session's address already loaded through `phaseChanged`.
            if let url = self.source.phase.url, url != self.loadedURL {
                self.loadedURL = url
                self.resumeURL = url
            }
            if self.browser == nil, self.isOnScreen, let url = self.resumeURL ?? self.loadedURL {
                self.makeBrowser(for: url).load(url)
            }
        }
    }

    @ObservationIgnored private var isRecovering = false

    func tearDown() {
        snapshotTask?.cancel()
        unwatchTouches()
        browser?.webView.stopLoading()
        browser = nil
    }

    /// A hidden web view may no longer draw a picture when the time to suspend comes.
    private func keepSnapshots() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self, let webView = self.webView else { return }
                if self.isOnScreen, self.isWorkbenchVisible, webView.window != nil,
                   let picture = await Self.snapshot(of: webView) {
                    await self.keep(picture)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func keep(_ picture: Data) async {
        snapshot = picture
        await snapshots.save(picture, for: member)
    }

    /// The words over the last picture while the workbench loads; nil shows the progress instead.
    var lastPictureCaption: String? {
        guard !isWorkbenchVisible else { return nil }
        if isSuspended { return "Resuming VS Code" }
        guard snapshot != nil else { return nil }
        switch source.phase {
        case .checking, .starting, .loading: return "Opening VS Code"
        default: return nil
        }
    }

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

    func takeKeyboard() {
        guard let webView, isWorkbenchVisible else { return }
        webView.claimKeyboard()
    }

    func releaseKeyboard() {
        webView?.releaseKeyboard()
    }

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
/// Sees taps in editor web views without cancelling the page's own.
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

#endif

/// A window's open editors, made when a leaf is first shown so a relaunch loads none until looked at.
@MainActor
final class EditorPanes {
    @ObservationIgnored private(set) var panes: [UUID: EditorPane] = [:]
    private let makeSource: (EditorMember) -> any EditorSource
    private let snapshots: EditorSnapshots
    /// Off-screen time before the web view is released; `-editorSuspendAfter <seconds>` for tests.
    var suspendAfter: Duration
    private var sweeper: Task<Void, Never>?

    static var defaultSuspendAfter: Duration {
        let seconds = UserDefaults.standard.double(forKey: "editorSuspendAfter")
        return seconds > 0 ? .seconds(seconds) : .seconds(600)
    }

    init(
        suspendAfter: Duration = EditorPanes.defaultSuspendAfter, snapshots: EditorSnapshots = .shared,
        makeSource: @escaping (EditorMember) -> any EditorSource
    ) {
        self.suspendAfter = suspendAfter
        self.snapshots = snapshots
        self.makeSource = makeSource
    }

    func pane(for member: EditorMember) -> EditorPane {
        if let pane = panes[member.id] { return pane }
        let pane = EditorPane(member: member, source: makeSource(member), snapshots: snapshots)
        panes[member.id] = pane
        startSweeping()
        return pane
    }

    func existing(_ id: UUID) -> EditorPane? { panes[id] }

    /// The servers keep running on their hosts.
    func prune(keeping ids: Set<UUID>) {
        for (id, pane) in panes where !ids.contains(id) {
            panes[id] = nil
            pane.tearDown()
            Task { await pane.source.close(stopServer: false) }
        }
    }

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

extension WindowModel {
    /// Every key goes to VS Code except the few in `WorkspaceAction.passesEditor`.
    var editorHasKeys: Bool {
        guard destination == .terminal, sheet == nil, !isPaletteShown, let editor = activeMixed?.focusedEditor else { return false }
        return editors.existing(editor.id)?.isWorkbenchVisible == true
    }

    var focusedEditor: EditorPane? {
        guard destination == .terminal, let editor = activeMixed?.focusedEditor else { return nil }
        return editors.existing(editor.id)
    }

    /// Opens the focused pane's worktree root on its host; nil `placement` reads ⌥. A path opens
    /// in an editor already holding it when there is one.
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

    /// For a path, an open editor whose folder holds it (the focused one first), else a new one on
    /// the worktree root. Nil, with a toast, without a host.
    func editorTarget(path: String?) async -> EditorMember? {
        if LaunchOptions.mock {
            return EditorMember(hostId: "studio", folder: "~/projects/gudo")
        }
        var context = HostContext.resolve(app: app, window: self)
        // The window's host may still be connecting.
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
        var folder = directory
        if let root = await (try? context.api())?.repositoryRoot(of: directory) { folder = root }
        return EditorMember(hostId: context.hostId, folder: folder)
    }

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
            if let workspace, let tab = workspace.session.activeTab {
                let groupId = currentGroupId
                let id = composites.addEditor(member, besideHost: groupId, tab: tab)
                if pairedTab == TabRef(hostId: groupId, tab: tab.id) { pairedTab = nil }
                activeMixedTab = id
                syncMixedFocus()
                return pane
            }
        }
        let id = composites.openEditor(member)
        focus(Self.mixedRef(id))
        return pane
    }

    /// `stopServer` also ends it on the host.
    func closeEditor(_ id: UUID, stopServer: Bool = false) {
        guard let tab = composites.tab(containingEditor: id), let leaf = tab.leaf(forEditor: id) else { return }
        if stopServer, let pane = editors.existing(id) {
            Task { await pane.source.close(stopServer: true) }
        }
        composites.close(leaf: leaf, in: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
    }

    /// No sidebar, tab strip, toolbar or editor bar. Ends when another tab or pane takes the focus.
    var isEditorFullScreen: Bool {
        guard let id = fullScreenEditor, destination == .terminal else { return false }
        return activeMixed?.focusedEditor?.id == id
    }

    func toggleEditorFullScreen() {
        #if os(macOS)
        // Without an editor in front, ⌃⌘F is the window's own full screen, as everywhere on the Mac.
        if !isEditorFullScreen, destination != .terminal || activeMixed?.focusedEditor == nil {
            NSApp.keyWindow?.toggleFullScreen(nil)
            return
        }
        #endif
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

    /// Full screen ends for good once its editor is no longer in front, so coming back never finds
    /// the window bare.
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

    /// The terminal beside the editor in its tab, else the tab worked in before.
    func returnToTerminal() {
        AppModel.log.info("return to terminal from \(self.activeMixed?.focusedEditor?.description ?? "no editor", privacy: .public)")
        guard destination == .terminal, let mixed = activeMixed, mixed.focusedEditor != nil else { return }
        if let leaf = mixed.leaves.first(where: { mixed.members[$0] != nil }) {
            focusLeaf(leaf, inMixedTab: mixed.id)
            return
        }
        let tabs = groups.tabs
        if let last = lastTerminalTab, tabs.contains(last) {
            focus(last)
        } else if let other = tabs.first(where: { !isEditorTab($0) }) {
            focus(other)
        }
    }

    func isEditorTab(_ ref: TabRef) -> Bool {
        ref.hostId == HostGroups.mixedId && composites.tab(ref.tab)?.isEditorOnly == true
    }

    /// Return to Terminal goes back to this tab from an editor tab.
    func noteLeavingTab() {
        if let current = currentTab, !isEditorTab(current) { lastTerminalTab = current }
    }

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
    /// The window's own full screen follows the editor's, and is left only if entered for it.
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

    /// On an editor's folder, or the focused pane's.
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
