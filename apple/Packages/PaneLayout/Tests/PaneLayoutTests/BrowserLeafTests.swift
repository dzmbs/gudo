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
    @Test func aBrowserTabMergesIntoAHostTabBesideAPane() throws {
        let hosts = Hosts()
        let source = hosts.store.openBrowser(docs)
        hosts.store.addBrowser(app, to: source, axis: .vertical)
        let hostTab = hosts.sessions["alpha"]!.tabs[0]
        let id = try #require(hosts.store.merge(source, intoHost: "alpha", tab: hostTab, beside: PaneId(1), side: .left))
        #expect(hosts.store.tab(source) == nil, "the browser tab goes")
        let tab = hosts.tab(id)
        #expect(tab.leaves.count == 3)
        #expect(tab.leaves.compactMap { tab.browsers[$0] } == [docs, app], "its pages keep their order")
        #expect(tab.members[tab.leaves[2]] == HostPane(hostId: "alpha", pane: PaneId(1)), "on the left of the pane")
        guard case .split(.horizontal, _, .split(.vertical, _, _, _), .leaf) = tab.layout.root else {
            Issue.record("the pages keep their own arrangement: \(tab.layout.root)")
            return
        }
        #expect(tab.focusedBrowser != nil)
        #expect(hosts.sent.isEmpty, "no host pane opens or closes")
        hosts.store.reconcile()
        #expect(hosts.store.tab(id) != nil)
    }

    @Test func aBrowserTabMergesIntoAnotherWindowTab() throws {
        let hosts = Hosts()
        let target = hosts.store.openBrowser(docs)
        let source = hosts.store.openBrowser(app)
        #expect(hosts.store.merge(source, into: target))
        #expect(hosts.store.tabs.map(\.id) == [target])
        let tab = hosts.tab(target)
        #expect(tab.leaves.compactMap { tab.browsers[$0] } == [docs, app], "on the right by default")
        #expect(tab.focusedBrowser == app)
    }

    @Test func aTabWithHostPanesDoesNotMergeAsAWindowTab() {
        let hosts = Hosts()
        let mixed = hosts.mixed()
        let target = hosts.store.openBrowser(docs)
        #expect(!hosts.store.merge(mixed, into: target))
        #expect(!hosts.store.merge(target, into: target))
        #expect(hosts.store.tabs.count == 2)
    }
}
