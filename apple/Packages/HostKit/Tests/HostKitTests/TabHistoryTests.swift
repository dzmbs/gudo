import Foundation
@testable import HostKit
import PaneLayout
import Testing

private func ref(_ host: String, _ tab: UInt64) -> TabRef { TabRef(hostId: host, tab: TabId(tab)) }

/// What a window opens with: "A New Terminal" never hides running work.
@Suite struct RestoreDecisionTests {
    private let found = [ref("studio", 1), ref("studio", 2), ref("studio", 3), ref("box", 1)]
    private func activity(_ ref: TabRef) -> TabActivity {
        switch (ref.hostId, ref.tab.rawValue) {
        case ("studio", 2): TabActivity(agent: true)
        case ("studio", 3): TabActivity(command: true)
        default: TabActivity()
        }
    }

    @Test func previousTabsHideNothing() {
        #expect(RestoreDecision.hidden(found, setting: .previous, activity: activity).isEmpty)
    }

    @Test func aNewTerminalHidesOnlyIdleTabs() {
        let hidden = RestoreDecision.hidden(found, setting: .newTerminal, activity: activity)
        #expect(hidden == [ref("studio", 1), ref("box", 1)])
    }

    @Test func theSettingDefaultsToPreviousTabs() {
        #expect(LaunchTabs(rawValue: "nonsense") == nil)
        #expect(LaunchTabs.allCases.map(\.title) == ["Your Previous Tabs", "A New Terminal"])
    }
}

/// The recently closed list: newest first, capped, kept across launches, closes undone as one.
@MainActor
@Suite struct RecentlyClosedTests {
    private func defaults() -> UserDefaults {
        let name = "recently-closed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func closed(_ title: String, batch: UUID? = nil) -> ClosedTab {
        ClosedTab(title: title, hostId: "studio", hostName: "studio", pane: 7, directory: "/srv/app", agent: "claude", batch: batch)
    }

    @Test func newestFirstAndCapped() {
        let store = RecentlyClosed(defaults: nil)
        for i in 0..<(RecentlyClosed.limit + 5) { store.record(closed("tab \(i)")) }
        #expect(store.tabs.count == RecentlyClosed.limit)
        #expect(store.tabs.first?.title == "tab \(RecentlyClosed.limit + 4)")
        #expect(store.tabs.last?.title == "tab 5", "the oldest go first")
    }

    @Test func keptAcrossLaunchesWithWhatReopeningNeeds() throws {
        let defaults = defaults()
        let project = ClosedProject(id: "p1", name: "app", color: 3)
        let tab = ClosedTab(
            title: "api", name: "quiet-otter", hostId: "studio", hostName: "studio", pane: 42, directory: "/srv/app",
            agent: "codex", project: project, projectIndex: 1, hostIndex: 2, closedAt: Date(timeIntervalSince1970: 1_800_000_000))
        RecentlyClosed(defaults: defaults).record(tab)
        let relaunched = RecentlyClosed(defaults: defaults)
        #expect(relaunched.tabs == [tab])
        // Only names, places and ids: nothing a terminal printed.
        let saved = try #require(defaults.data(forKey: "recently-closed-tabs"))
        let keys = try #require(JSONSerialization.jsonObject(with: saved) as? [[String: Any]]).first?.keys.sorted()
        #expect(keys == ["agent", "closedAt", "directory", "hostId", "hostIndex", "hostName", "id", "name", "pane", "project", "projectIndex", "title"])
    }

    @Test func reopenTakesTheLastCloseWholeAndOldestFirst() {
        let store = RecentlyClosed(defaults: nil)
        store.record(closed("earlier"))
        let batch = UUID()
        store.record([closed("a", batch: batch), closed("b", batch: batch), closed("c", batch: batch)])
        #expect(store.tabs.map(\.title) == ["c", "b", "a", "earlier"])
        #expect(store.takeLatest().map(\.title) == ["a", "b", "c"], "in the order they were closed")
        #expect(store.takeLatest().map(\.title) == ["earlier"])
        #expect(store.takeLatest().isEmpty)
    }

    @Test func oneEntryAndForgottenHosts() {
        let store = RecentlyClosed(defaults: nil)
        let keep = closed("keep")
        store.record(keep)
        store.record(ClosedTab(title: "gone", hostId: "old", hostName: "old"))
        store.forget(host: "old")
        #expect(store.tabs == [keep])
        #expect(store.take(keep.id) == keep)
        #expect(store.tabs.isEmpty)
    }
}

/// Idle tabs: at a prompt, untouched for days, nothing running.
@Suite struct IdleTabRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func untouchedAtAPromptForThreeDaysIsIdle() {
        #expect(IdleTabRule.isIdle(TabIdleFacts(activity: TabActivity(), atPrompt: true, touched: daysAgo(3)), now: now))
        #expect(!IdleTabRule.isIdle(TabIdleFacts(activity: TabActivity(), atPrompt: true, touched: daysAgo(2.9)), now: now))
    }

    @Test func runningWorkIsNeverIdle() {
        let old = daysAgo(30)
        #expect(!IdleTabRule.isIdle(TabIdleFacts(activity: TabActivity(agent: true), atPrompt: true, touched: old), now: now))
        #expect(!IdleTabRule.isIdle(TabIdleFacts(activity: TabActivity(command: true), atPrompt: true, touched: old), now: now))
        #expect(!IdleTabRule.isIdle(TabIdleFacts(activity: TabActivity(), atPrompt: false, touched: old), now: now))
    }

    /// A command run from another device starts the clock again (the host's foreground changed).
    @Test func aCommandOnTheHostCountsAsATouch() {
        let facts = TabIdleFacts(activity: TabActivity(), atPrompt: true, touched: daysAgo(10), foregroundSince: daysAgo(1))
        #expect(!IdleTabRule.isIdle(facts, now: now))
    }

    @MainActor
    @Test func touchesStartOnFirstSightAndAreKept() {
        let name = "touches-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let touches = TabTouches(defaults: defaults)
        let tab = ref("studio", 4)
        #expect(touches.touched(tab, now: daysAgo(5)) == daysAgo(5), "first seen")
        #expect(TabTouches(defaults: defaults).touched(tab, now: now) == daysAgo(5), "kept across launches")
        touches.touch(tab, now: now)
        #expect(touches.touched(tab, now: now) == now)
        touches.keep(host: "studio", existing: [])
        #expect(touches.touched(tab, now: daysAgo(1)) == daysAgo(1), "a closed tab's clock is dropped")
        defaults.removePersistentDomain(forName: name)
    }
}

/// The sidebar's multi-selection (Finder's rules).
@Suite struct TabSelectionTests {
    private let order = (1...6).map { ref("studio", UInt64($0)) }

    @Test func commandClickTogglesStartingFromTheCurrentTab() {
        var selection = TabSelection()
        selection.toggle(order[3], current: order[0])
        #expect(selection.selected == [order[0], order[3]])
        #expect(selection.isMultiple)
        selection.toggle(order[0], current: order[0])
        #expect(selection.selected == [order[3]])
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        var selection = TabSelection()
        selection.select(order[1])
        selection.extend(to: order[4], current: nil, in: order)
        #expect(selection.ordered(order) == Array(order[1...4]))
        selection.extend(to: order[0], current: nil, in: order)
        #expect(selection.ordered(order) == Array(order[0...1]), "the anchor stays, the range flips")
        // From nothing selected: the range starts at the tab on screen.
        var fresh = TabSelection()
        fresh.extend(to: order[2], current: order[5], in: order)
        #expect(fresh.ordered(order) == Array(order[2...5]))
    }

    @Test func selectAllAndRowsThatGoAway() {
        var selection = TabSelection()
        selection.selectAll(order)
        #expect(selection.selected.count == 6)
        selection.keep(Set(order.prefix(2)))
        #expect(selection.ordered(order) == Array(order.prefix(2)))
        selection.clear()
        #expect(!selection.isMultiple && selection.anchor == nil)
    }
}

/// Dragging a selection by one of its rows: the rest land right after it, together.
@Suite struct CarriedDropTests {
    private let a = ref("studio", 1), b = ref("studio", 2), c = ref("studio", 3), d = ref("studio", 4), x = ref("box", 1)

    @Test func insertsLandInARowAfterTheDraggedOne() {
        let sections = [SidebarSection(.project("p"), rows: [a]), SidebarSection(.host("studio"), rows: [b, c, d]), SidebarSection(.host("box"), rows: [x])]
        let drops = SidebarDrop.insert(c, into: .project("p"), at: 0).carrying([b, x], in: sections)
        let after = drops.reduce(sections) { $1.applied(to: $0) }
        #expect(after[0].rows == [c, b, x, a])
        #expect(after[1].rows == [d])
    }

    @Test func aHostSectionTakesOnlyItsOwnTabs() {
        let sections = [SidebarSection(.project("p"), rows: [a, x]), SidebarSection(.host("studio"), rows: [b])]
        let drops = SidebarDrop.insert(a, into: .host("studio"), at: 1).carrying([x], in: sections)
        #expect(drops.count == 1)
        #expect(drops.reduce(sections) { $1.applied(to: $0) }[0].rows == [x])
    }

    @Test func aGroupDropTakesEveryRowOntoTheSameTarget() {
        let drops = SidebarDrop.group(a, onto: d).carrying([b, d], in: [])
        #expect(drops == [.group(a, onto: d), .group(b, onto: d)])
    }
}

/// A reopened tab comes back where it was: its project and place, its place on its host.
@MainActor
@Suite struct ReopenPlacementTests {
    private func fixture() throws -> (HostGroups, LocalLayoutStore) {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "hetzner", name: "hetzner", kind: .daemon, daemonId: "bb"))
        let connection = FakeConnection(tabs: 4)
        model.connections["hetzner"] = connection
        let groups = HostGroups(hosts: model)
        try groups.open("hetzner")
        return (groups, connection.layout)
    }

    private func tabs(_ groups: HostGroups) -> [TabRef] {
        groups.group("hetzner")!.tabs.map { groups.group("hetzner")!.ref($0.id) }
    }

    @Test func intoItsProjectAtItsPlaceAndItsPlaceOnTheHost() throws {
        let (groups, store) = try fixture()
        let all = tabs(groups)
        let project = try #require(groups.groupTabs([all[0], all[2], all[3]], name: "app"))
        // The middle tab of the project, second on its host... closes.
        let entry = groups.closedTab(all[2], title: "web", name: "web", hostName: "hetzner", pane: 3, directory: "/srv/web", agent: nil)
        #expect(entry.project?.id == project && entry.project?.name == "app")
        #expect(entry.projectIndex == 1 && entry.hostIndex == 2)
        store.apply(.closeTab(all[2].tab))
        // ...and a new tab takes its place.
        store.apply(.newTab)
        let back = try #require(tabs(groups).first { !all.contains($0) })
        groups.place(back, as: entry)
        #expect(groups.project(project)?.tabs == [all[0], back, all[3]])
        #expect(store.session.tabs.map(\.id)[2] == back.tab)
    }

    @Test func aProjectGoneWithItsLastTabComesBackByName() throws {
        let (groups, store) = try fixture()
        let all = tabs(groups)
        let project = try #require(groups.groupTabs([all[1]], name: "infra"))
        groups.updateProject(project, color: 5)
        let entry = groups.closedTab(all[1], title: "deploy", name: nil, hostName: "hetzner", pane: 2, directory: nil, agent: "claude")
        store.apply(.closeTab(all[1].tab))
        #expect(groups.project(project) == nil, "a project goes with its last tab")
        store.apply(.newTab)
        let back = try #require(tabs(groups).first { !all.contains($0) })
        groups.place(back, as: entry)
        let again = try #require(groups.project(of: back))
        #expect(again.name == "infra" && again.color == 5)
    }

    @Test func hiddenTabsLeaveTheListUntilRestored() throws {
        let (groups, _) = try fixture()
        let all = tabs(groups)
        groups.hiddenTabs = [all[0], all[1]]
        #expect(groups.tabs == [all[2], all[3]])
        #expect(groups.restorableTabs == [all[0], all[1]])
        groups.unhide(all[1])
        #expect(groups.tabs == [all[1], all[2], all[3]])
        groups.restoreHiddenTabs()
        #expect(groups.tabs == all && groups.restorableTabs.isEmpty)
    }
}
