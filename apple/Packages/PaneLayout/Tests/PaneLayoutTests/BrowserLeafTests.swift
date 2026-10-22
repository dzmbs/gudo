import Foundation
import Testing
@testable import PaneLayout

/// Browser pages as leaves of a window's tabs: a tab of their own or beside a terminal, kept
/// where they navigated, and saved for a relaunch.
@MainActor
@Suite struct BrowserLeafTests {
    private let docs = BrowserMember(hostId: nil, url: "https://example.com/docs")
    private let app = BrowserMember(hostId: "alpha", url: "http://localhost:3000/")

    @Test func aPageOpensInATabOfItsOwn() {
        let hosts = Hosts()
        let id = hosts.store.openBrowser(docs)
        let tab = hosts.tab(id)
        #expect(tab.isBrowserOnly && !tab.isEditorOnly)
        #expect(tab.focusedBrowser == docs)
        #expect(tab.hosts.isEmpty, "a page on the web belongs to no host")
        #expect(hosts.sent.isEmpty)
        hosts.store.reconcile()
        #expect(hosts.store.tabs.count == 1, "a browser tab never dissolves")
        #expect(hosts.store.ordered.map(\.id) == [id])
    }

    @Test func besideATerminalTheHostTabBecomesAComposite() {
        let hosts = Hosts()
        let id = hosts.store.addBrowser(app, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        let tab = hosts.tab(id)
        #expect(!tab.isBrowserOnly)
        #expect(tab.members[tab.leaves[0]] == HostPane(hostId: "alpha", pane: PaneId(1)))
        #expect(tab.browsers[tab.leaves[1]] == app)
        #expect(tab.focusedBrowser == app, "the page takes focus")
        hosts.store.reconcile()
        #expect(hosts.store.tab(id) != nil, "one host plus a page stays a composite")
        // Closing the page gives the host tab back; no host pane closes.
        hosts.store.close(leaf: tab.leaf(forBrowser: app.id)!, in: id)
        #expect(!hosts.sent.contains { if case .close = $0.1 { true } else { false } })
        #expect(hosts.dissolved.first?.1 == CompositeTabs.TabRefParts(hostId: "alpha", tab: TabId(2)))
    }

    @Test func aPageKeepsWhereItNavigatedAndIsRestored() throws {
        let hosts = Hosts()
        let id = hosts.store.openBrowser(app)
        hosts.store.addBrowser(docs, to: id, axis: .vertical)
        var moved = app
        moved.url = "http://localhost:3000/settings"
        hosts.store.update(browser: moved)
        #expect(hosts.store.browsers == [moved, docs])
        let data = try JSONEncoder().encode(hosts.store.tabs)
        let back = try JSONDecoder().decode([CompositeTab].self, from: data)
        #expect(back == hosts.store.tabs)
        #expect(back[0].browsers.values.contains(moved))
    }

    @Test func droppingItsHostClosesAHostsPage() {
        let hosts = Hosts()
        let id = hosts.store.openBrowser(docs)
        hosts.store.addBrowser(app, to: id)
        hosts.store.dropHost("alpha")
        #expect(hosts.store.browsers == [docs], "the web page stays, the host's dev server goes")
    }
}
