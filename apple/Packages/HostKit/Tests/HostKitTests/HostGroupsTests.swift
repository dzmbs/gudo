import Foundation
import GudoCore
@testable import HostKit
import Observation
import PaneLayout
import Synchronization
import Testing

/// A host connection with a local layout and a status the test sets.
@MainActor
@Observable
final class FakeConnection: HostConnection {
    var status: ConnectionStatus = .connected(rtt: nil)
    let layout: LocalLayoutStore
    var isReady = true
    var repoSnapshot: RepoSnapshot?
    var layoutStore: any LayoutStore { layout }
    @ObservationIgnored var dials = 1
    @ObservationIgnored var lifecycle: [String] = []

    init(tabs: Int) {
        layout = LocalLayoutStore()
        for _ in 1..<max(tabs, 1) { layout.apply(.newTab) }
    }

    func makeBackend(for pane: PaneId) throws -> any PaneBackend { throw HostError.notConnected }
    func retry() { dials += 1 }
    func foreground() {
        lifecycle.append("foreground")
        if !status.isLive { dials += 1 }
    }
    func background() {
        lifecycle.append("background")
        status = .suspended
    }
    func networkChanged() { lifecycle.append("network") }
    func close() { lifecycle.append("close") }
}

@MainActor
@Suite struct HostGroupsTests {
    /// This Mac with two tabs, two daemons (2 and 1 tabs) and one plain-SSH host (1 tab), opened
    /// in the order cloud, ssh, studio.
    private func fixture() throws -> (HostGroups, [String: FakeConnection], LocalLayoutStore) {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "studio", name: "studio", kind: .daemon, daemonId: "aa"))
        model.upsert(HostRecord(id: "cloud", name: "cloud", kind: .daemon, daemonId: "bb"))
        model.upsert(HostRecord(id: "box", name: "box", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "box", identity: .password)))
        let fakes = ["studio": FakeConnection(tabs: 1), "cloud": FakeConnection(tabs: 2), "box": FakeConnection(tabs: 1)]
        for (id, fake) in fakes { model.connections[id] = fake }
        let local = LocalLayoutStore()
        local.apply(.newTab)
        let groups = HostGroups(hosts: model, local: .init(name: "This Mac", layout: local))
        try groups.open("cloud")
        try groups.open("box")
        try groups.open("studio")
        return (groups, fakes, local)
    }

    @Test func groupsListThisDeviceThenHostsInOpenOrder() throws {
        let (groups, _, _) = try fixture()
        #expect(groups.groups.map(\.id) == ["local", "cloud", "box", "studio"])
        #expect(groups.groups.map(\.kind) == [.local, .daemon, .ssh, .daemon])
        #expect(groups.groups.map(\.name) == ["This Mac", "cloud", "box", "studio"])
        #expect(groups.groups.map(\.tabs.count) == [2, 2, 1, 1])
        // Opening an open host again neither reorders nor duplicates it.
        try groups.open("cloud")
        #expect(groups.openHosts == ["cloud", "box", "studio"])
    }

    /// A tab in a repository is a tab like any other: its host's rows and ⌘-numbers keep host
    /// order, and its worktree is context for its row.
    @Test func tabsInRepositoriesKeepTheirPlaceAmongTheHostsTabs() throws {
        let (groups, fakes, _) = try fixture()
        let cloud = try #require(fakes["cloud"])
        let tabs = cloud.layout.session.tabs
        let before = groups.tabs
        let pane = try #require(tabs.first?.root.panes.first)
        cloud.repoSnapshot = RepoSnapshot(
            rev: 1, panes: [PaneRepo(paneId: pane.rawValue, worktree: "/src/lab")],
            worktrees: [RepoSidebarTests.worktree("/src/lab", repo: "/src/lab", main: true, branch: "main")], gh: .unknown)
        #expect(groups.repoSidebar(for: try #require(groups.group("cloud")))?.repos.count == 1)
        #expect(groups.tabs == before)
        #expect(groups.sections.first { $0.container == .host("cloud") }?.rows == tabs.map { TabRef(hostId: "cloud", tab: $0.id) })
        #expect(groups.worktree(of: TabRef(hostId: "cloud", tab: tabs[0].id))?.branch == "main")
        #expect(groups.worktree(of: TabRef(hostId: "cloud", tab: tabs[1].id)) == nil)
    }

    @Test func shortcutsIndexTheUnifiedListAcrossHosts() throws {
        let (groups, _, local) = try fixture()
        let all = groups.tabs
        #expect(all.count == 6)
        #expect(all.map(\.hostId) == ["local", "local", "cloud", "cloud", "box", "studio"])
        #expect(groups.tab(forShortcut: 1) == all[0])
        #expect(groups.tab(forShortcut: 3)?.hostId == "cloud")
        #expect(groups.tab(forShortcut: 5)?.hostId == "box")
        #expect(groups.tab(forShortcut: 6)?.hostId == "studio")
        #expect(groups.tab(forShortcut: 7) == nil)
        #expect(groups.tab(forShortcut: 9) == all.last)
        #expect(groups.shortcutNumber(of: all[4]) == 5)

        // Past eight tabs: ⌘8 is the eighth, ⌘9 the last; the ninth tab has no number.
        for _ in 0..<4 { local.apply(.newTab) }
        let grown = groups.tabs
        #expect(grown.count == 10)
        #expect(groups.tab(forShortcut: 8) == grown[7])
        #expect(groups.tab(forShortcut: 9) == grown[9])
        #expect(groups.shortcutNumber(of: grown[8]) == nil)

        // Collapsing hides rows, not numbers.
        groups.toggleCollapsed("cloud")
        #expect(groups.collapsed == ["cloud"])
        #expect(groups.tabs == grown)
    }

    @Test func nextAndPreviousCrossHostBoundariesAndWrap() throws {
        let (groups, _, _) = try fixture()
        let all = groups.tabs
        // Last local tab → first cloud tab.
        #expect(groups.tab(after: all[1], offset: 1) == all[2])
        // First cloud tab ← back to the last local tab.
        #expect(groups.tab(after: all[2], offset: -1) == all[1])
        // Wraps both ways.
        #expect(groups.tab(after: all[5], offset: 1) == all[0])
        #expect(groups.tab(after: all[0], offset: -1) == all[5])
        // A tab that is gone: start from the ends.
        let gone = TabRef(hostId: "cloud", tab: TabId(999))
        #expect(groups.tab(after: gone, offset: 1) == all[0])
        #expect(groups.tab(after: nil, offset: -1) == all[5])
    }

    @Test func statusChangesShowPerGroupWithoutReordering() throws {
        let (groups, fakes, _) = try fixture()
        let order = groups.tabs
        fakes["cloud"]!.status = .reconnecting(attempt: 2, reason: "connection lost")
        fakes["studio"]!.status = .connected(rtt: .milliseconds(12))
        #expect(groups.group("cloud")?.status == .reconnecting(attempt: 2, reason: "connection lost"))
        #expect(groups.group("box")?.status.isLive == true)
        #expect(groups.group("studio")?.status == .connected(rtt: .milliseconds(12)))
        #expect(groups.tabs == order, "a host going down keeps every tab's number")

        // A daemon before its first layout: listed, no tabs yet, not a new-tab target.
        fakes["studio"]!.isReady = false
        #expect(groups.group("studio")?.tabs.isEmpty == true)
        #expect(groups.newTabHost(preferred: "studio") == "local")
        #expect(groups.newTabHost(preferred: "box") == "box")

        // The group's status is observable (the sidebar's dot follows it).
        let changed = Mutex(false)
        withObservationTracking { _ = groups.groups } onChange: { changed.withLock { $0 = true } }
        fakes["box"]!.status = .offline(reason: "no network")
        #expect(changed.withLock { $0 })
    }

    @Test func switchingNeverRedialsAndLifecycleReachesEveryHost() throws {
        let (groups, fakes, _) = try fixture()
        // Going between hosts is a lookup of the open connection, never a new one.
        let first = try groups.open("cloud")
        _ = try groups.open("studio")
        let again = try groups.open("cloud")
        #expect(first === again)
        #expect(fakes.values.allSatisfy { $0.dials == 1 })

        // iOS background suspends every host; foreground resumes every one at once.
        groups.hosts.background()
        #expect(fakes.values.allSatisfy { $0.lifecycle == ["background"] })
        groups.hosts.foreground()
        #expect(fakes.values.allSatisfy { $0.lifecycle == ["background", "foreground"] })
        #expect(fakes.values.allSatisfy { $0.dials == 2 })
    }

    @Test func closeRestoreAndFailures() throws {
        let (groups, fakes, _) = try fixture()
        groups.close("box")
        #expect(groups.groups.map(\.id) == ["local", "cloud", "studio"])
        #expect(fakes["box"]!.lifecycle == ["close"])
        #expect(groups.hosts.connection("box") == nil)

        // A host connected from elsewhere in the app shows too, after the open ones.
        let other = HostGroups(hosts: groups.hosts, local: nil)
        #expect(other.groups.map(\.id) == ["studio", "cloud"], "saved-host order")
        #expect(!other.groups.contains { $0.isLocal })

        // Restore: forgotten hosts are dropped; one that cannot open (no password saved) stays
        // listed with the reason.
        let restored = HostGroups(hosts: groups.hosts, local: nil)
        let opened = restored.restore(["studio", "gone", "box", "cloud"])
        #expect(opened == ["studio", "cloud"])
        #expect(restored.openHosts == ["studio", "box", "cloud"])
        let box = try #require(restored.group("box"))
        #expect(box.failure?.contains("password") == true)
        #expect(box.status.needsUser)
        #expect(box.tabs.isEmpty)
    }

    /// Windows: a host another window still shows keeps its connection when one window closes it.
    @Test func closingAHostAnotherWindowShowsKeepsItsConnection() throws {
        let (groups, fakes, _) = try fixture()
        groups.isOpenElsewhere = { $0 == "studio" }
        groups.close("studio")
        #expect(!groups.openHosts.contains("studio"))
        #expect(fakes["studio"]!.lifecycle.isEmpty)
        #expect(groups.hosts.connection("studio") != nil)
        groups.close("cloud")
        #expect(groups.hosts.connection("cloud") == nil)
    }

    @Test func tabRefsRoundTripForPersistence() throws {
        let ref = TabRef(hostId: "cloud", tab: TabId(42))
        let data = try JSONEncoder().encode([ref])
        #expect(try JSONDecoder().decode([TabRef].self, from: data) == [ref])
        #expect(ref.description == "cloud/42")
    }

    /// A mixed tab (this Mac's first tab split with studio): it leads the unified order, and the
    /// host tabs carrying its panes leave their groups; closing studio in the window dissolves it.
    @Test func mixedTabsLeadAndHideTheirCarriers() throws {
        let (groups, fakes, local) = try fixture()
        let composites = groups.composites
        composites.hostSession = { id in id == HostGroups.localId ? local.session : fakes[id]?.layout.session }
        composites.send = { id, op in
            if id == HostGroups.localId { local.apply(op) } else { fakes[id]?.layout.apply(op) }
            return true
        }
        let first = local.session.tabs[0]
        let id = composites.make(fromHost: HostGroups.localId, tab: first)
        composites.split(id, onHost: "studio", axis: .horizontal)
        #expect(composites.tab(id)?.hosts == ["local", "studio"])
        // studio opened a carrier tab: its group still lists only its own first tab.
        #expect(fakes["studio"]!.layout.session.tabs.count == 2)
        #expect(groups.group("studio")?.tabs.count == 1)
        #expect(groups.group(HostGroups.localId)?.tabs.map(\.id) == [local.session.tabs[1].id])
        #expect(groups.tabs.first == TabRef(hostId: HostGroups.mixedId, tab: id))
        #expect(groups.tab(forShortcut: 1) == TabRef(hostId: HostGroups.mixedId, tab: id))
        #expect(groups.tabs.count == 6, "the composite stands in for its two carriers")
        // Closing studio in this window: the composite dissolves into this Mac's tab.
        groups.close("studio")
        #expect(composites.tabs.isEmpty)
        #expect(groups.group(HostGroups.localId)?.tabs.count == 2)
    }
}
