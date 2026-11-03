import Foundation
import HostKit
import Observation
import SwiftUI
import PaneLayout
import WebKit

/// One browser page and the host whose `localhost` its data store routes to.
@MainActor
@Observable
final class BrowserPane: Identifiable {
    let id: UUID
    let page: any BrowserPageContent
    let hostId: String?
    let dataStore: WKWebsiteDataStore
    let initialURL: URL
    /// Sees every main-frame navigation first; true cancels it.
    @ObservationIgnored var intercept: ((URL) -> Bool)?
    @ObservationIgnored var prepare: ((URL) async -> Void)?
    @ObservationIgnored private var started = false

    // MARK: Agents

    var agentActivity: String?
    var agentRequest: AgentRequest?
    var userHasControl = false
    /// Screenshot pixels per CSS pixel of the last screenshot; agent coordinates scale back by it.
    @ObservationIgnored var shotScale = 1.0

    @ObservationIgnored let frames = BrowserFrames()
    /// A page this page opened, shown as a new leaf with `window.opener` intact.
    @ObservationIgnored var onPopupPane: ((BrowserPane) -> Void)?
    /// A popup by URL alone (no `window.opener`): without `onPopupPane`, or before the web view is known.
    @ObservationIgnored var onPopup: ((URL) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private let windows = BrowserWindows()
    @ObservationIgnored private var popupDelegate: PopupDelegate?
    /// While true, file pickers and new windows belong to the agent: its input carries no user
    /// gesture for WebKit's popup blocker.
    @ObservationIgnored var agentActing = false {
        didSet { windows.allowPopups(agentActing) }
    }
    var dialog: PageDialog?
    @ObservationIgnored var fileChooser: FileChooser?

    struct AgentRequest: Identifiable {
        enum Kind { case approve, handoff }
        let id = UUID()
        let kind: Kind
        let message: String
        let answer: (Bool) -> Void
    }

    struct PageDialog: Identifiable {
        enum Kind: String { case alert, confirm, prompt, beforeunload }
        let id = UUID()
        let kind: Kind
        let message: String
        let defaultText: String?
        let answer: (_ accept: Bool, _ text: String?) -> Void
    }

    struct FileChooser {
        let multiple: Bool
        let answer: ([URL]?) -> Void
    }

    /// `popup`: another page opened this one, so it may close itself.
    init(id: UUID = UUID(), url: URL, hostId: String? = nil, dataStore: WKWebsiteDataStore? = nil, popup: Bool = false) {
        self.id = id
        self.hostId = hostId
        initialURL = url
        var configuration = WebPage.Configuration()
        if let dataStore { configuration.websiteDataStore = dataStore }
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        self.dataStore = configuration.websiteDataStore
        BrowserAgentScript.install(in: configuration.userContentController, frames: frames)
        BrowserRecorder.install(in: configuration.userContentController, page: id)
        if popup {
            configuration.userContentController.addUserScript(BrowserWindows.closeScript)
            configuration.userContentController.add(windows, contentWorld: .page, name: BrowserWindows.closeHandler)
        }
        let box = DeciderBox()
        page = WebPage(configuration: configuration, navigationDecider: Decider(box: box), dialogPresenter: Dialogs(box: box))
        box.pane = self
        frames.onWebView = { [windows] in windows.adopt($0) }
        hookUp()
    }

    /// Uses the configuration WebKit gave for the popup, which keeps `window.opener`.
    init(id: UUID = UUID(), popupOf opener: BrowserPane, configuration: WKWebViewConfiguration, url: URL?) {
        self.id = id
        hostId = opener.hostId
        dataStore = configuration.websiteDataStore
        initialURL = url ?? URL(string: "about:blank")!
        // WebKit loads it.
        started = true
        // Scripts and handlers of its own: the opener's would count its frames as theirs.
        let controller = WKUserContentController()
        BrowserAgentScript.install(in: controller, frames: frames)
        BrowserRecorder.install(in: controller, page: id)
        configuration.userContentController = controller
        let popup = PopupPage(configuration: configuration)
        page = popup
        prepare = opener.prepare
        let delegate = PopupDelegate()
        delegate.pane = self
        popupDelegate = delegate
        popup.webView.navigationDelegate = delegate
        popup.webView.uiDelegate = delegate
        windows.adopt(popup.webView)
        hookUp()
    }

    private func hookUp() {
        BrowserRecorder.shared.attach(page, id: id)
        windows.onCreate = { [weak self] in self?.makePopup($0, for: $1) }
        windows.onClose = { [weak self] in self?.onClose?() }
    }

    var webPage: WebPage? { page as? WebPage }
    var popupPage: PopupPage? { page as? PopupPage }

    /// A `WebPage` may be in one `WebView` at a time (WebKit traps on a second), and a view
    /// swapped for another is made before the old one goes: the first to ask keeps it, the others wait.
    @ObservationIgnored private(set) var shownBy: UUID?
    /// Counts the views that let go, so one waiting asks again.
    private var releases = 0

    func mayShow(in view: UUID) -> Bool {
        _ = releases
        if shownBy == nil { shownBy = view }
        return shownBy == view
    }

    func release(_ view: UUID) {
        guard shownBy == view else { return }
        shownBy = nil
        releases += 1
    }

    /// Released when the view is gone, after its `WebView`.
    final class ViewHold {
        let id = UUID()
        private weak var pane: BrowserPane?

        init(_ pane: BrowserPane) { self.pane = pane }

        deinit {
            let id = id
            Task { @MainActor [pane] in pane?.release(id) }
        }
    }

    /// Nil makes WebKit open no window.
    private func makePopup(_ configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView? {
        let url = action.request.url
        guard let onPopupPane else {
            if let url, url.scheme == "http" || url.scheme == "https" { onPopup?(url) }
            return nil
        }
        let popup = BrowserPane(popupOf: self, configuration: configuration, url: url)
        onPopupPane(popup)
        return popup.popupPage?.webView
    }

    /// `newWindow`: there is no frame to load in (a `target=_blank` link).
    func decide(
        _ request: URLRequest, newWindow: Bool, mainFrame: Bool, type: WKNavigationType, download: Bool
    ) async -> WKNavigationActionPolicy {
        guard let url = request.url else { return .allow }
        if newWindow {
            // WebKit asks the UI delegate for the window next (`makePopup`); until the page's
            // web view is known, it opens by URL alone.
            if windows.isAdopted { return .allow }
            if url.scheme == "http" || url.scheme == "https" { onPopup?(url) }
            return .cancel
        }
        guard mainFrame else { return .allow }
        if let intercept, intercept(url) { return .cancel }
        if !agentActing, agentActivity == nil, !download, Self.needsLanguage(request, type: type, from: page.url) {
            var request = request
            request.setValue(WebsiteLanguage.acceptLanguage(WebsiteLanguage.current), forHTTPHeaderField: "Accept-Language")
            // After this one is cancelled, or the cancel would take the new one too.
            Task { @MainActor in self.page.open(request) }
            return .cancel
        }
        await prepare?(url)
        return .allow
    }

    func chooseFiles(multiple: Bool) async -> [URL]? {
        await withCheckedContinuation { continuation in
            fileChooser = FileChooser(multiple: multiple) { [weak self] urls in
                self?.fileChooser = nil
                continuation.resume(returning: urls)
            }
        }
    }

    func present(_ kind: PageDialog.Kind, _ message: String, defaultText: String? = nil) async -> (Bool, String?) {
        dialog?.answer(false, nil)
        return await withCheckedContinuation { continuation in
            var answered = false
            dialog = PageDialog(kind: kind, message: message, defaultText: defaultText) { [weak self] accept, text in
                guard !answered else { return }
                answered = true
                self?.dialog = nil
                continuation.resume(returning: (accept, text))
            }
        }
    }

    /// WebKit leaves without running `beforeunload`, so the handlers run here before a navigation
    /// the app starts.
    func leavingAllowed() async -> Bool {
        let objects = try? await page.run(
            "const e = new Event('beforeunload', { cancelable: true }); dispatchEvent(e); return e.defaultPrevented",
            in: .page) as? Bool
        guard objects == true else { return true }
        return await present(.beforeunload, "Leave site? Changes you made may not be saved.").0
    }

    func start() {
        guard !started else { return }
        started = true
        guard page.url == nil else { return }
        Task {
            await prepare?(initialURL)
            page.open(Self.request(initialURL))
        }
    }

    func load(_ url: URL) {
        started = true
        page.open(Self.request(url))
    }

    nonisolated static func request(_ url: URL, language: String = WebsiteLanguage.current) -> URLRequest {
        var request = URLRequest(url: url)
        if let accept = WebsiteLanguage.acceptLanguage(language), url.scheme == "http" || url.scheme == "https" {
            request.setValue(accept, forHTTPHeaderField: "Accept-Language")
        }
        return request
    }

    /// WebKit has no setting for the language header, so a page's own links and redirects are
    /// reissued with it. Never form posts, history steps, reloads or in-page jumps.
    nonisolated static func needsLanguage(
        _ request: URLRequest, type: WKNavigationType, from current: URL?, language: String = WebsiteLanguage.current
    ) -> Bool {
        guard let accept = WebsiteLanguage.acceptLanguage(language), let url = request.url,
              url.scheme == "http" || url.scheme == "https",
              request.value(forHTTPHeaderField: "Accept-Language") != accept,
              (request.httpMethod ?? "GET") == "GET", request.httpBody == nil,
              type != .backForward, type != .reload, type != .formResubmitted
        else { return false }
        if let current, url.fragment != nil, url.absoluteString.prefix { $0 != "#" } == current.absoluteString.prefix(while: { $0 != "#" }) {
            return false
        }
        return true
    }

    // MARK: Favicon

    var favicon: Image?
    @ObservationIgnored private var faviconPage: URL?

    /// Fetched through the page itself so it uses the page's data store and reaches a host's dev servers.
    func refreshFavicon() async {
        guard let url = page.url, url.scheme == "http" || url.scheme == "https" else {
            favicon = nil
            faviconPage = nil
            return
        }
        guard faviconPage != url else { return }
        faviconPage = url
        let script = """
            const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')]
              .filter(l => l.href && !/svg/.test(l.type) && !/\\.svg($|\\?)/.test(l.href));
            const href = links.length ? links[0].href : new URL('/favicon.ico', location.href).href;
            try {
              const r = await fetch(href, { credentials: 'include' });
              if (!r.ok) return null;
              const blob = await r.blob();
              return await new Promise(done => {
                const reader = new FileReader();
                reader.onload = () => done(reader.result);
                reader.onerror = () => done(null);
                reader.readAsDataURL(blob);
              });
            } catch { return null; }
            """
        let data = (try? await page.run(script, in: Self.faviconWorld) as? String)
            .flatMap { $0.split(separator: ",", maxSplits: 1).last }
            .flatMap { Data(base64Encoded: String($0)) }
        guard page.url == url else { return }
        favicon = data.flatMap(Self.image)
    }

    private static let faviconWorld = WKContentWorld.world(name: "gudo-favicon")

    private static func image(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map { Image(uiImage: $0) }
        #else
        NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    var url: URL { page.url ?? initialURL }

    fileprivate final class DeciderBox {
        weak var pane: BrowserPane?
    }

    private struct Decider: WebPage.NavigationDeciding {
        let box: DeciderBox

        mutating func decidePolicy(
            for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard let pane = box.pane else { return .allow }
            return await pane.decide(
                action.request, newWindow: action.target == nil, mainFrame: action.target?.isMainFrame ?? true,
                type: action.navigationType, download: action.shouldPerformDownload)
        }
    }
}

private struct Dialogs: WebPage.DialogPresenting {
    let box: BrowserPane.DeciderBox

    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        _ = await box.pane?.present(.alert, message)
    }

    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        await box.pane?.present(.confirm, message).0 == true ? .ok : .cancel
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        guard let (accept, text) = await box.pane?.present(.prompt, message, defaultText: defaultText), accept else { return .cancel }
        return .ok(text ?? defaultText ?? "")
    }

    /// Only an acting agent's upload answers the picker.
    func handleFileInputPrompt(parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
        guard let pane = box.pane, pane.agentActing else { return .cancel }
        return await pane.chooseFiles(multiple: parameters.allowsMultipleSelection).map { .selected($0) } ?? .cancel
    }
}

/// A window's browser pages by `BrowserMember.id`, kept across tab switches and gone with the leaf.
@MainActor
final class BrowserPanes {
    private(set) var panes: [UUID: BrowserPane] = [:]
    /// The opener's leaf id and the URL.
    var onPopup: ((UUID, URL) -> Void)?
    /// The opener's leaf id and the new pane, whose id its leaf takes.
    var onPopupPane: ((UUID, BrowserPane) -> Void)?
    var onClose: ((UUID) -> Void)?
    var popups: Set<UUID> = []

    func existing(_ id: UUID) -> BrowserPane? { panes[id] }

    func pane(for member: BrowserMember, app: AppModel) async -> BrowserPane? {
        if let pane = panes[member.id] { return pane }
        guard let url = URL(string: member.url) else { return nil }
        var client: (() throws -> any DaemonWorkspaceAPI)?
        if let hostId = member.hostId, let context = HostContext.host(hostId, app: app) {
            let hub = context.hub
            client = { try hub.client() }
            _ = await DevServerRouting.shared.store(forHost: hostId, client: { try hub.client() })
        }
        let store = DevServerRouting.shared.dataStore(forHost: member.hostId)
        if let pane = panes[member.id] { return pane }
        let pane = BrowserPane(id: member.id, url: url, hostId: member.hostId, dataStore: store, popup: popups.contains(member.id))
        if let hostId = member.hostId, let client {
            pane.prepare = { url in await DevServerRouting.shared.prepareLoopback(url, hostId: hostId, client: client) }
        }
        adopt(pane)
        return pane
    }

    private func adopt(_ pane: BrowserPane) {
        let id = pane.id
        pane.onPopup = { [weak self] url in self?.onPopup?(id, url) }
        pane.onPopupPane = { [weak self] popup in
            guard let self else { return }
            popups.insert(popup.id)
            adopt(popup)
            onPopupPane?(id, popup)
        }
        pane.onClose = { [weak self] in self?.onClose?(id) }
        panes[id] = pane
    }

    func prune(keeping ids: Set<UUID>) {
        for (id, pane) in panes where !ids.contains(id) {
            panes[id] = nil
            pane.page.stopLoading()
            BrowserRecorder.shared.finish(id)
            popups.remove(id)
        }
    }
}
