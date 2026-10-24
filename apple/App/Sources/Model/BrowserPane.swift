import Foundation
import HostKit
import Observation
import SwiftUI
import PaneLayout
import WebKit

/// One browser page: its `WebPage`, the host whose dev servers it reaches (its data store
/// routes `localhost` there, `DevServerRouting`), and a hook on where it navigates. A sheet's
/// browser owns one; a browser leaf's lives as long as the leaf (`BrowserPanes`).
@MainActor
@Observable
final class BrowserPane: Identifiable {
    let id: UUID
    /// A `WebPage`, or a `PopupPage` for a page another one opened.
    let page: any BrowserPageContent
    /// The host the page's `localhost` goes to, if any.
    let hostId: String?
    /// Where it started (shown until the page has a URL of its own).
    let initialURL: URL
    /// Sees every navigation of the main frame first; true keeps it from loading (a sign-in
    /// code taken from its callback page).
    @ObservationIgnored var intercept: ((URL) -> Bool)?
    /// Runs before a navigation loads (a host's `localhost` port made to reach the host).
    @ObservationIgnored var prepare: ((URL) async -> Void)?
    @ObservationIgnored private var started = false

    // MARK: Agents (`BrowserAgent`)

    /// What an agent is doing on the page now ("Clicking “Sign in”"), shown on the page.
    var agentActivity: String?
    /// The agent waits for the user: to approve a step, or to do it themselves.
    var agentRequest: AgentRequest?
    /// The user took the page over: agents wait until they hand it back.
    var userHasControl = false
    /// Screenshot pixels per CSS pixel of the last screenshot (coordinates scale back by it).
    @ObservationIgnored var shotScale = 1.0

    /// The frames running the agent's script, to call into them.
    @ObservationIgnored let frames = BrowserFrames()
    /// A page this page opened (`window.open`, `target=_blank`), to show as a new leaf with
    /// `window.opener` intact.
    @ObservationIgnored var onPopupPane: ((BrowserPane) -> Void)?
    /// The same by its URL alone (no `window.opener`): without `onPopupPane`, or before the
    /// page's web view is known.
    @ObservationIgnored var onPopup: ((URL) -> Void)?
    /// The page closed itself (`window.close()` in a page another opened).
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private let windows = BrowserWindows()
    /// A popup's navigation and dialogs (a `WebPage` has its own).
    @ObservationIgnored private var popupDelegate: PopupDelegate?
    /// An agent's action is running on the page (a file picker it opens is the agent's, and
    /// so are new windows: its input carries no user gesture for WebKit's popup blocker).
    @ObservationIgnored var agentActing = false {
        didSet { windows.allowPopups(agentActing) }
    }
    /// An `alert`, `confirm` or `prompt` the page waits on; the user or the agent answers it.
    var dialog: PageDialog?
    /// A file picker an agent's action opened; `browser_upload` answers it.
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
        /// Accept (with the prompt's text) or dismiss.
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

    /// A page `opener` opened, in the web view made with the configuration WebKit gave for it:
    /// that keeps `window.opener`, so the page can `postMessage` back and close itself.
    init(id: UUID = UUID(), popupOf opener: BrowserPane, configuration: WKWebViewConfiguration, url: URL?) {
        self.id = id
        hostId = opener.hostId
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

    /// The page as SwiftUI's `WebView` shows it; nil for a popup.
    var webPage: WebPage? { page as? WebPage }
    var popupPage: PopupPage? { page as? PopupPage }

    /// A new window this page asked for: a pane of its own, or nil (WebKit then opens none).
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

    /// Whether a navigation goes ahead, for both kinds of page. `newWindow`: it has no frame
    /// to load in (a `target=_blank` link).
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

    /// The agent's files for a file input its action opened (`browser_upload`); nil: none.
    func chooseFiles(multiple: Bool) async -> [URL]? {
        await withCheckedContinuation { continuation in
            fileChooser = FileChooser(multiple: multiple) { [weak self] urls in
                self?.fileChooser = nil
                continuation.resume(returning: urls)
            }
        }
    }

    /// Shows a page's dialog until it is answered.
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

    /// Whether the page lets itself be left: a `beforeunload` handler that objects (unsaved
    /// changes) asks first, as browsers do. WebKit leaves without asking, so the handlers are
    /// run here before a navigation the app starts.
    func leavingAllowed() async -> Bool {
        let objects = try? await page.run(
            "const e = new Event('beforeunload', { cancelable: true }); dispatchEvent(e); return e.defaultPrevented",
            in: .page) as? Bool
        guard objects == true else { return true }
        return await present(.beforeunload, "Leave site? Changes you made may not be saved.").0
    }

    /// Loads the first page once (a view showing it again keeps where it is).
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

    /// A request in the language chosen for websites (`WebsiteLanguage`).
    nonisolated static func request(_ url: URL, language: String = WebsiteLanguage.current) -> URLRequest {
        var request = URLRequest(url: url)
        if let accept = WebsiteLanguage.acceptLanguage(language), url.scheme == "http" || url.scheme == "https" {
            request.setValue(accept, forHTTPHeaderField: "Accept-Language")
        }
        return request
    }

    /// Whether a main-frame navigation should be loaded again with the language header: WebKit
    /// has no setting for it, so a page's own links and redirects are reissued. Never a form
    /// post, a history step, a reload, a jump within the page, or what an agent's action set off.
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

    /// The page's icon, for its tab.
    var favicon: Image?
    @ObservationIgnored private var faviconPage: URL?

    /// Reads the page's icon (its `link rel=icon`, else `/favicon.ico`) through the page itself,
    /// so it comes from the page's own data store and reaches a host's dev servers.
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

    private static let faviconWorld = WKContentWorld.world(name: "unnamed-favicon")

    private static func image(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map { Image(uiImage: $0) }
        #else
        NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    /// The page's URL, or where it is going.
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

    /// While an agent acts, its upload answers the picker; else as WebKit's default.
    func handleFileInputPrompt(parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
        guard let pane = box.pane, pane.agentActing else { return .cancel }
        return await pane.chooseFiles(multiple: parameters.allowsMultipleSelection).map { .selected($0) } ?? .cancel
    }
}

/// A window's browser leaves' pages, by `BrowserMember.id`: made when a leaf is first shown,
/// kept across tab switches, gone with the leaf.
@MainActor
final class BrowserPanes {
    private(set) var panes: [UUID: BrowserPane] = [:]
    /// A page opened another by URL alone (its leaf's id, the URL).
    var onPopup: ((UUID, URL) -> Void)?
    /// A page opened another as a pane of its own (the opener's leaf id, the pane, whose id
    /// its leaf takes).
    var onPopupPane: ((UUID, BrowserPane) -> Void)?
    /// A page closed itself (its leaf's id).
    var onClose: ((UUID) -> Void)?
    /// Leaves whose pages another page opened.
    var popups: Set<UUID> = []

    func existing(_ id: UUID) -> BrowserPane? { panes[id] }

    /// The leaf's page, made on first use (on a host, with its data store and `localhost`).
    func pane(for member: BrowserMember, app: AppModel) async -> BrowserPane? {
        if let pane = panes[member.id] { return pane }
        guard let url = URL(string: member.url) else { return nil }
        var store: WKWebsiteDataStore?
        var client: (() throws -> any DaemonWorkspaceAPI)?
        if let hostId = member.hostId, let context = HostContext.host(hostId, app: app) {
            let hub = context.hub
            client = { try hub.client() }
            store = await DevServerRouting.shared.store(forHost: hostId, client: { try hub.client() })
        }
        if let pane = panes[member.id] { return pane }
        let pane = BrowserPane(id: member.id, url: url, hostId: member.hostId, dataStore: store, popup: popups.contains(member.id))
        if let hostId = member.hostId, let client {
            pane.prepare = { url in await DevServerRouting.shared.prepareLoopback(url, hostId: hostId, client: client) }
        }
        adopt(pane)
        return pane
    }

    /// Keeps `pane` for the leaf of its id, and the pages it opens.
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

    /// Lets go of pages whose leaves closed.
    func prune(keeping ids: Set<UUID>) {
        for (id, pane) in panes where !ids.contains(id) {
            panes[id] = nil
            pane.page.stopLoading()
            BrowserRecorder.shared.finish(id)
            popups.remove(id)
        }
    }
}
