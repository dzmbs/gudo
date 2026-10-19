import Foundation
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
    /// in the order hetzner, ssh, studio.
    private func fixture() throws -> (HostGroups, [String: FakeConnection], LocalLayoutStore) {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "studio", name: "studio", kind: .daemon, daemonId: "aa"))
        model.upsert(HostRecord(id: "hetzner", name: "hetzner", kind: .daemon, daemonId: "bb"))
        model.upsert(HostRecord(id: "box", name: "box", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "box", identity: .password)))
        let fakes = ["studio": FakeConnection(tabs: 1), "hetzner": FakeConnection(tabs: 2), "box": FakeConnection(tabs: 1)]
        for (id, fake) in fakes { model.connections[id] = fake }
        let local = LocalLayoutStore()
        local.apply(.newTab)
        let groups = HostGroups(hosts: model, local: .init(name: "This Mac", layout: local))
        try groups.open("hetzner")
        try groups.open("box")
        try groups.open("studio")
        return (groups, fakes, local)
    }

    @Test func groupsListThisDeviceThenHostsInOpenOrder() throws {
        let (groups, _, _) = try fixture()
        #expect(groups.groups.map(\.id) == ["local", "hetzner", "box", "studio"])
        #expect(groups.groups.map(\.kind) == [.local, .daemon, .ssh, .daemon])
        #expect(groups.groups.map(\.name) == ["This Mac", "hetzner", "box", "studio"])
        #expect(groups.groups.map(\.tabs.count) == [2, 2, 1, 1])
        // Opening an open host again neither reorders nor duplicates it.
        try groups.open("hetzner")
        #expect(groups.openHosts == ["hetzner", "box", "studio"])
    }

    @Test func shortcutsIndexTheUnifiedListAcrossHosts() throws {
        let (groups, _, local) = try fixture()
        let all = groups.tabs
        #expect(all.count == 6)
        #expect(all.map(\.hostId) == ["local", "local", "hetzner", "hetzner", "box", "studio"])
        #expect(groups.tab(forShortcut: 1) == all[0])
        #expect(groups.tab(forShortcut: 3)?.hostId == "hetzner")
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
        groups.toggleCollapsed("hetzner")
        #expect(groups.collapsed == ["hetzner"])
        #expect(groups.tabs == grown)
    }

    @Test func nextAndPreviousCrossHostBoundariesAndWrap() throws {
        let (groups, _, _) = try fixture()
        let all = groups.tabs
        // Last local tab → first hetzner tab.
        #expect(groups.tab(after: all[1], offset: 1) == all[2])
        // First hetzner tab ← back to the last local tab.
        #expect(groups.tab(after: all[2], offset: -1) == all[1])
        // Wraps both ways.
        #expect(groups.tab(after: all[5], offset: 1) == all[0])
        #expect(groups.tab(after: all[0], offset: -1) == all[5])
        // A tab that is gone: start from the ends.
        let gone = TabRef(hostId: "hetzner", tab: TabId(999))
        #expect(groups.tab(after: gone, offset: 1) == all[0])
        #expect(groups.tab(after: nil, offset: -1) == all[5])
    }

    @Test func statusChangesShowPerGroupWithoutReordering() throws {
        let (groups, fakes, _) = try fixture()
        let order = groups.tabs
        fakes["hetzner"]!.status = .reconnecting(attempt: 2, reason: "connection lost")
        fakes["studio"]!.status = .connected(rtt: .milliseconds(12))
        #expect(groups.group("hetzner")?.status == .reconnecting(attempt: 2, reason: "connection lost"))
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
        let first = try groups.open("hetzner")
        _ = try groups.open("studio")
        let again = try groups.open("hetzner")
        #expect(first === again)
        #expect(fakes.values.allSatisfy { $0.dials == 1 })

        // iOS background suspends every host; foreground resumes every one at once (R3/R5/R1).
        groups.hosts.background()
        #expect(fakes.values.allSatisfy { $0.lifecycle == ["background"] })
        groups.hosts.foreground()
        #expect(fakes.values.allSatisfy { $0.lifecycle == ["background", "foreground"] })
        #expect(fakes.values.allSatisfy { $0.dials == 2 })
    }

    @Test func closeRestoreAndFailures() throws {
        let (groups, fakes, _) = try fixture()
        groups.close("box")
        #expect(groups.groups.map(\.id) == ["local", "hetzner", "studio"])
        #expect(fakes["box"]!.lifecycle == ["close"])
        #expect(groups.hosts.connection("box") == nil)

        // A host connected from elsewhere in the app shows too, after the open ones.
        let other = HostGroups(hosts: groups.hosts, local: nil)
        #expect(other.groups.map(\.id) == ["studio", "hetzner"], "saved-host order")
        #expect(!other.groups.contains { $0.isLocal })

        // Restore: forgotten hosts are dropped; one that cannot open (no password saved) stays
        // listed with the reason.
        let restored = HostGroups(hosts: groups.hosts, local: nil)
        let opened = restored.restore(["studio", "gone", "box", "hetzner"])
        #expect(opened == ["studio", "hetzner"])
        #expect(restored.openHosts == ["studio", "box", "hetzner"])
        let box = try #require(restored.group("box"))
        #expect(box.failure?.contains("password") == true)
        #expect(box.status.needsUser)
        #expect(box.tabs.isEmpty)
    }

    @Test func tabRefsRoundTripForPersistence() throws {
        let ref = TabRef(hostId: "hetzner", tab: TabId(42))
        let data = try JSONEncoder().encode([ref])
        #expect(try JSONDecoder().decode([TabRef].self, from: data) == [ref])
        #expect(ref.description == "hetzner/42")
    }
}
