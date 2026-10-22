import Foundation
import Observation
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
    @ObservationIgnored private var started = false

    init(id: UUID = UUID(), url: URL, hostId: String? = nil, dataStore: WKWebsiteDataStore? = nil) {
        self.id = id
        self.hostId = hostId
        initialURL = url
        var configuration = WebPage.Configuration()
        if let dataStore { configuration.websiteDataStore = dataStore }
        let box = DeciderBox()
        page = WebPage(configuration: configuration, navigationDecider: Decider(box: box))
        box.pane = self
    }

    /// Loads the first page once (a view showing it again keeps where it is).
    func start() {
        guard !started else { return }
        started = true
        if page.url == nil { page.load(URLRequest(url: initialURL)) }
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
            guard action.target?.isMainFrame != false, let url = action.request.url, let pane = box.pane,
                  let intercept = pane.intercept else { return .allow }
            return intercept(url) ? .cancel : .allow
        }
    }
}
