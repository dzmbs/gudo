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

    struct AgentRequest: Identifiable {
        enum Kind { case approve, handoff }
        let id = UUID()
        let kind: Kind
        let message: String
        let answer: (Bool) -> Void
    }

    init(id: UUID = UUID(), url: URL, hostId: String? = nil, dataStore: WKWebsiteDataStore? = nil) {
        self.id = id
        self.hostId = hostId
        initialURL = url
        var configuration = WebPage.Configuration()
        if let dataStore { configuration.websiteDataStore = dataStore }
        BrowserAgentScript.install(in: configuration.userContentController)
        BrowserRecorder.install(in: configuration.userContentController, page: id)
        let box = DeciderBox()
        page = WebPage(configuration: configuration, navigationDecider: Decider(box: box))
        box.pane = self
        BrowserRecorder.shared.attach(page, id: id)
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

    private final class DeciderBox {
        weak var pane: BrowserPane?
    }

    private struct Decider: WebPage.NavigationDeciding {
        let box: DeciderBox

        mutating func decidePolicy(
            for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.target?.isMainFrame != false, let url = action.request.url, let pane = box.pane else { return .allow }
            if let intercept = pane.intercept, intercept(url) { return .cancel }
            await pane.prepare?(url)
            return .allow
        }
    }
}

/// A window's browser leaves' pages, by `BrowserMember.id`: made when a leaf is first shown,
/// kept across tab switches, gone with the leaf.
@MainActor
final class BrowserPanes {
    private(set) var panes: [UUID: BrowserPane] = [:]

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
        let pane = BrowserPane(id: member.id, url: url, hostId: member.hostId, dataStore: store)
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
        }
    }
}
