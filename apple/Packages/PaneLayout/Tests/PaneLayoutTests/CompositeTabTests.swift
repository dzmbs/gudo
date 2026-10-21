import Foundation
import Testing
@testable import PaneLayout

/// Two hosts with their own layouts, answering ops at once or, like a daemon, on `flush()`.
@MainActor
final class Hosts {
    var sessions: [String: Session]
    /// Hosts whose link is down: unknown to the store.
    var down: Set<String> = []
    var deferred = false
    private(set) var sent: [(String, LayoutOp)] = []
    private var queued: [(String, LayoutOp)] = []
    let store = CompositeTabs()
    private(set) var dissolved: [(TabId, CompositeTabs.TabRefParts?)] = []
    private(set) var adopted: [PaneId] = []

    /// alpha: tab 2 holding pane 1; beta: tab 2 holding pane 1 (ids are per host).
    init() {
        sessions = ["alpha": Session(), "beta": Session()]
        store.hostSession = { [unowned self] host in down.contains(host) ? nil : sessions[host] }
        store.send = { [unowned self] host, op in
            guard sessions[host] != nil, !down.contains(host) else { return false }
            sent.append((host, op))
            if deferred { queued.append((host, op)) } else { sessions[host]!.apply(op) }
            return true
        }
        store.onDissolve = { [unowned self] id, rest in dissolved.append((id, rest)) }
        store.onAdopt = { [unowned self] _, leaf in adopted.append(leaf) }
    }

    func flush() {
        for (host, op) in queued { sessions[host]!.apply(op) }
        queued = []
        store.reconcile()
    }

    /// Alpha's first tab made a composite and split with beta.
    func mixed() -> TabId {
        let id = store.make(fromHost: "alpha", tab: sessions["alpha"]!.tabs[0])
        store.split(id, onHost: "beta", axis: .horizontal)
        return id
    }

    func tab(_ id: TabId) -> CompositeTab { store.tab(id)! }
}

@MainActor
@Suite struct CompositeTabTests {
    @Test func aHostTabKeepsItsTreeAsAComposite() {
        var session = Session()
        session.apply(.split(PaneId(1), .vertical))  // p3 below p1
        session.apply(.focus(PaneId(1)))
        let tab = CompositeTab(id: TabId(7), hostId: "alpha", tab: session.tabs[0])
        #expect(tab.id == TabId(7))
        #expect(tab.leaves.count == 2)
        #expect(tab.leaves.compactMap { tab.members[$0] } == [HostPane(hostId: "alpha", pane: PaneId(1)), HostPane(hostId: "alpha", pane: PaneId(3))])
        #expect(tab.focusedMember == HostPane(hostId: "alpha", pane: PaneId(1)))
        #expect(tab.carriers == ["alpha": TabId(2)])
        guard case .split(.vertical, 0.5, _, _) = tab.layout.root else {
            Issue.record("the split's axis and ratio carry over")
            return
        }
    }

    @Test func splitWithHostOpensACarrierTabOnTheOtherHost() {
        let hosts = Hosts()
        let id = hosts.mixed()
        // Beta was asked for a new tab: it becomes beta's carrier, its pane right of alpha's.
        #expect(hosts.sent.map(\.0) == ["beta"])
        #expect(hosts.sent.first?.1 == .newTab)
        let tab = hosts.tab(id)
        #expect(tab.hosts == ["alpha", "beta"])
        #expect(tab.leaves.compactMap { tab.members[$0] } == [HostPane(hostId: "alpha", pane: PaneId(1)), HostPane(hostId: "beta", pane: PaneId(3))])
        #expect(tab.carriers == ["alpha": TabId(2), "beta": TabId(4)])
        #expect(tab.focusedMember?.hostId == "beta", "the new pane takes focus")
        guard case .split(.horizontal, _, _, _) = tab.layout.root else {
            Issue.record("side by side")
            return
        }
        #expect(hosts.store.carriers == ["alpha": [TabId(2)], "beta": [TabId(4)]])
        #expect(hosts.adopted == [tab.focusedLeaf])
    }

    @Test func aDaemonsAnswerIsAdoptedWhenItArrives() {
        let hosts = Hosts()
        hosts.deferred = true
        let id = hosts.mixed()
        #expect(hosts.store.isWaiting(id))
        #expect(hosts.tab(id).leaves.count == 1, "nothing yet: the host has not answered")
        hosts.flush()
        #expect(!hosts.store.isWaiting(id))
        #expect(hosts.tab(id).hosts == ["alpha", "beta"])
    }

    @Test func splitOnALeafSplitsItsPaneOnItsHost() {
        let hosts = Hosts()
        let id = hosts.mixed()
        // Focus is on beta's pane: ⌘D splits it in beta's carrier.
        hosts.store.split(id, axis: .vertical)
        #expect(hosts.sent.last?.0 == "beta")
        #expect(hosts.sent.last?.1 == .split(PaneId(3), .vertical))
        let tab = hosts.tab(id)
        #expect(tab.panes(onHost: "beta") == [PaneId(3), PaneId(5)])
        #expect(tab.focusedMember == HostPane(hostId: "beta", pane: PaneId(5)))
        #expect(hosts.sessions["beta"]!.tabs.first { $0.id == TabId(4) }!.root.panes == [PaneId(3), PaneId(5)], "the host's own tree has both")
        // Focus alpha's leaf, split again: on alpha.
        hosts.store.apply(.focus(tab.leaf(for: HostPane(hostId: "alpha", pane: PaneId(1)))!), to: id)
        #expect(hosts.sent.last?.1 == .focus(PaneId(1)), "focus is told to the pane's host")
        hosts.store.split(id, axis: .horizontal)
        #expect(hosts.sent.last?.0 == "alpha")
        #expect(hosts.tab(id).panes(onHost: "alpha").count == 2)
    }

    @Test func aSecondPaneOnAHostWithACarrierGoesIntoIt() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.store.apply(.focus(hosts.tab(id).leaves[0]), to: id)  // alpha
        hosts.store.split(id, onHost: "beta", axis: .vertical)
        #expect(hosts.sent.last?.1 == .split(PaneId(3), .vertical), "split in beta's carrier, not a new tab")
        #expect(hosts.sessions["beta"]!.tabs.count == 2)
        let tab = hosts.tab(id)
        #expect(tab.panes(onHost: "beta").count == 2)
        // Placed below alpha's pane (the focused leaf), not next to beta's.
        #expect(tab.leaves.compactMap { tab.members[$0]?.hostId } == ["alpha", "beta", "beta"])
    }

    @Test func closingALeafClosesItsPaneOnItsHost() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.store.split(id, axis: .horizontal)  // beta p5
        let leaf = hosts.tab(id).leaf(for: HostPane(hostId: "beta", pane: PaneId(5)))!
        hosts.store.close(leaf: leaf, in: id)
        #expect(hosts.sent.contains { $0.0 == "beta" && $0.1 == .close(PaneId(5)) })
        #expect(hosts.tab(id).panes(onHost: "beta") == [PaneId(3)])
        #expect(hosts.sessions["beta"]!.panes.contains(PaneId(5)) == false)
    }

    @Test func downToOneHostItDissolvesIntoThatHostsTab() {
        let hosts = Hosts()
        let id = hosts.mixed()
        let beta = hosts.tab(id).leaf(for: HostPane(hostId: "beta", pane: PaneId(3)))!
        hosts.store.close(leaf: beta, in: id)
        #expect(hosts.store.tab(id) == nil)
        #expect(hosts.dissolved.first?.0 == id)
        #expect(hosts.dissolved.first?.1 == CompositeTabs.TabRefParts(hostId: "alpha", tab: TabId(2)))
        #expect(hosts.store.carriers.isEmpty, "alpha's tab shows in its group again")
    }

    @Test func aPaneClosedOnItsHostLeavesTheComposite() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.store.split(id, axis: .horizontal)  // beta p5
        // Another device (or the process exiting) closes beta's p5.
        hosts.sessions["beta"]!.apply(.close(PaneId(5)))
        hosts.store.reconcile()
        #expect(hosts.tab(id).panes(onHost: "beta") == [PaneId(3)])
    }

    @Test func aHostThatIsDownKeepsItsLeaves() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.down = ["beta"]
        hosts.sessions["beta"] = Session(tabs: [], activeTabId: nil)  // whatever it holds now is unknown
        hosts.store.reconcile()
        #expect(hosts.tab(id).hosts == ["alpha", "beta"], "beta's leaf stays (shown stale)")
        // Back with a session that no longer has the pane (a restarted daemon): it goes.
        hosts.down = []
        hosts.store.reconcile()
        #expect(hosts.store.tab(id) == nil, "dissolved: alpha alone")
    }

    @Test func aPaneSplitInACarrierElsewhereJoins() {
        let hosts = Hosts()
        let id = hosts.mixed()
        let focused = hosts.tab(id).focusedLeaf
        hosts.sessions["beta"]!.apply(.split(PaneId(3), .vertical))  // another device: p5
        hosts.store.reconcile()
        let tab = hosts.tab(id)
        #expect(tab.panes(onHost: "beta") == [PaneId(3), PaneId(5)])
        #expect(tab.focusedLeaf == focused, "a pane from elsewhere does not take focus")
    }

    @Test func otherCompositesPanesAreNotAdoptedTwice() {
        let hosts = Hosts()
        let first = hosts.mixed()
        hosts.sessions["alpha"]!.apply(.newTab)  // alpha tab 4, pane 3
        let second = hosts.store.make(fromHost: "alpha", tab: hosts.sessions["alpha"]!.tabs.first { $0.id == TabId(4) }!)
        hosts.store.split(second, onHost: "beta", axis: .horizontal)
        #expect(hosts.tab(second).hosts == ["alpha", "beta"])
        #expect(hosts.tab(first).panes(onHost: "beta") == [PaneId(3)])
        #expect(hosts.tab(second).panes(onHost: "beta") == [PaneId(5)])
        #expect(hosts.tab(second).carriers["beta"] != hosts.tab(first).carriers["beta"], "each composite has its own carrier")
    }

    @Test func aRefusedSplitLeavesThePlainTab() {
        let hosts = Hosts()
        hosts.down = ["beta"]
        let id = hosts.store.make(fromHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        hosts.store.split(id, onHost: "beta", axis: .horizontal)
        #expect(hosts.store.tab(id) == nil)
        #expect(hosts.dissolved.first?.1?.hostId == "alpha")
    }

    @Test func anUnansweredSplitTimesOut() async {
        let hosts = Hosts()
        hosts.deferred = true
        hosts.store.answerTimeout = .milliseconds(20)
        let id = hosts.mixed()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hosts.store.tab(id) == nil, "nothing came: back to alpha's tab")
    }

    @Test func layoutOpsArrangeTheCompositeOnly() {
        let hosts = Hosts()
        let id = hosts.mixed()
        let before = hosts.sessions
        hosts.store.apply(.focusDirection(.left), to: id)
        #expect(hosts.tab(id).focusedMember?.hostId == "alpha")
        hosts.store.apply(.resize(hosts.tab(id).focusedLeaf, .right, amount: 0.2), to: id)
        guard case .split(_, let ratio, _, _) = hosts.tab(id).layout.root else { return }
        #expect(abs(ratio - 0.7) < 1e-9)
        hosts.store.apply(.toggleZoom, to: id)
        #expect(hosts.tab(id).visibleLeaves == [hosts.tab(id).focusedLeaf])
        hosts.store.apply(.rename(id, "build + logs"), to: id)
        #expect(hosts.tab(id).title == "build + logs")
        #expect(hosts.sessions["alpha"]!.tabs == before["alpha"]!.tabs.map { tab in
            var tab = tab
            tab.focused = hosts.sessions["alpha"]!.tabs[0].focused
            return tab
        }, "the hosts' trees are untouched")
    }

    @Test func closingTheTabClosesEachCarrier() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.store.closeTab(id)
        #expect(hosts.store.tabs.isEmpty)
        #expect(hosts.sessions["alpha"]!.tabs.isEmpty)
        #expect(hosts.sessions["beta"]!.tabs.map(\.id) == [TabId(2)], "beta's own first tab stays")
    }

    @Test func droppingAHostDissolves() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.store.dropHost("beta")
        #expect(hosts.store.tab(id) == nil)
        #expect(hosts.sessions["beta"]!.panes.contains(PaneId(3)), "the pane stays on its host")
    }

    @Test func compositesRoundTripForRestore() throws {
        let hosts = Hosts()
        _ = hosts.mixed()
        let data = try JSONEncoder().encode(hosts.store.tabs)
        let restored = CompositeTabs()
        restored.restore(try JSONDecoder().decode([CompositeTab].self, from: data))
        #expect(restored.tabs == hosts.store.tabs)
    }
}
