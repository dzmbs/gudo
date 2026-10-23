import Foundation
import HostKit
import Observation
import PaneLayout
import WebKit

/// One browser page: its `WebPage`, the host whose dev servers it reaches (its data store
/// routes `localhost` there, `DevServerRouting`), and a hook on where it navigates. A sheet's
/// browser owns one; a browser leaf's lives as long as the leaf (`BrowserPanes`).
@MainActor
@Observable
final class BrowserPane: Identifiable {
    let id: UUID
    let page: WebPage
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
    /// A page this page opened (`window.open`, `target=_blank`), to show as a new leaf.
    @ObservationIgnored var onPopup: ((URL) -> Void)?
    /// The page closed itself (`window.close()` in a page another opened).
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private let windows = BrowserWindows()
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
        BrowserRecorder.shared.attach(page, id: id)
        frames.onWebView = { [windows] in windows.adopt($0) }
        windows.onOpen = { [weak self] in self?.onPopup?($0) }
        windows.onClose = { [weak self] in self?.onClose?() }
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
        let objects = try? await page.callJavaScript(
            "const e = new Event('beforeunload', { cancelable: true }); dispatchEvent(e); return e.defaultPrevented",
            contentWorld: .page) as? Bool
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
            page.load(URLRequest(url: initialURL))
        }
    }

    func load(_ url: URL) {
        started = true
        page.load(URLRequest(url: url))
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
            guard let url = action.request.url, let pane = box.pane else { return .allow }
            // A new window: a leaf beside this one (pages have no windows of their own).
            if action.target == nil {
                if url.scheme == "http" || url.scheme == "https" { pane.onPopup?(url) }
                return .cancel
            }
            guard action.target?.isMainFrame != false else { return .allow }
            if let intercept = pane.intercept, intercept(url) { return .cancel }
            await pane.prepare?(url)
            return .allow
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
        let urls: [URL]? = await withCheckedContinuation { continuation in
            pane.fileChooser = BrowserPane.FileChooser(multiple: parameters.allowsMultipleSelection) { [weak pane] urls in
                pane?.fileChooser = nil
                continuation.resume(returning: urls)
            }
        }
        return urls.map { .selected($0) } ?? .cancel
    }
}

/// A window's browser leaves' pages, by `BrowserMember.id`: made when a leaf is first shown,
/// kept across tab switches, gone with the leaf.
@MainActor
final class BrowserPanes {
    private(set) var panes: [UUID: BrowserPane] = [:]
    /// A page opened another (its leaf's id, the URL).
    var onPopup: ((UUID, URL) -> Void)?
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
        pane.onPopup = { [weak self] url in self?.onPopup?(member.id, url) }
        pane.onClose = { [weak self] in self?.onClose?(member.id) }
        if let hostId = member.hostId, let client {
            pane.prepare = { url in await DevServerRouting.shared.prepareLoopback(url, hostId: hostId, client: client) }
        }
        panes[member.id] = pane
        return pane
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
