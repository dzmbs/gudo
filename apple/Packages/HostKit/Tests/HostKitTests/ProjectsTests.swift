import Foundation
@testable import HostKit
import PaneLayout
import Testing
import GudoCore

private func ref(_ host: String, _ tab: UInt64) -> TabRef { TabRef(hostId: host, tab: TabId(tab)) }

private func info(_ id: String, _ name: String, color: Int = 0, order: Int64 = 0, updated: UInt64 = 1) -> ProjectInfo {
    ProjectInfo(id: id, name: name, color: color, order: order, updated: updated)
}

/// A daemon session with tabs `ids`, one pane each (pane = tab × 100).
private func tabsLayout(revision: UInt64, _ ids: [UInt64], session: UInt64 = 7) -> SessionLayout {
    SessionLayout(
        sessionId: session, name: "main", revision: revision, activeTab: ids.first,
        tabs: ids.map { TabLayout(tabId: $0, name: "", nodes: [.leaf(paneId: $0 * 100)], focused: $0 * 100, zoomed: nil) })
}

@Suite struct ProjectModelTests {
    @Test func membershipNeedsADefinitionAndEmptyProjectsGo() {
        var host = HostProjects()
        host.apply(.setTab(TabId(1), Membership(project: "p", rank: 0)))
        #expect(host.members.isEmpty, "the daemon refuses a membership without its definition")
        host.apply(.put(info("p", "app")))
        host.apply(.setTab(TabId(1), Membership(project: "p", rank: 0)))
        host.apply(.setTab(TabId(2), Membership(project: "p", rank: 1024)))
        host.apply(.setTab(TabId(1), nil))
        #expect(host.projects["p"] != nil)
        host.keep(tabs: [TabId(1)])
        #expect(host.isEmpty, "the last member closed: the project goes with it")
    }

    @Test func theNewestDefinitionWins() {
        var host = HostProjects()
        host.apply(.put(info("p", "new", updated: 5)))
        host.apply(.put(info("p", "old", updated: 3)))
        #expect(host.projects["p"]?.name == "new")
    }

    @Test func projectsMergeAcrossHostsById() {
        // The same project on two hosts, renamed on one while the other was away.
        let hostA = HostProjects(projects: ["p": info("p", "app", updated: 1)], members: [TabId(1): Membership(project: "p", rank: 2048)])
        let hostB = HostProjects(
            projects: ["p": info("p", "web app", color: 3, updated: 9), "q": info("q", "infra", order: -1024)],
            members: [TabId(1): Membership(project: "p", rank: 1024), TabId(2): Membership(project: "q", rank: 0), TabId(3): Membership(project: "p", rank: 0)])
        let merged = ProjectMerge.merge(["a": hostA, "b": hostB], existing: [ref("a", 1), ref("b", 1), ref("b", 2), ref("b", 3)])
        #expect(merged.map(\.name) == ["infra", "web app"])
        #expect(merged[1].color == 3)
        // Tabs of both hosts interleave by rank.
        #expect(merged[1].tabs == [ref("b", 3), ref("b", 1), ref("a", 1)])
        #expect(merged[1].hosts == ["b", "a"])
        // A closed tab is not listed, and a project left with none is gone.
        let fewer = ProjectMerge.merge(["a": hostA, "b": hostB], existing: [ref("a", 1), ref("b", 3)])
        #expect(fewer.map(\.name) == ["web app"])
    }

    @Test func grouping_puts_the_definition_on_every_host_first() {
        let planner = ProjectPlanner(projects: [], sources: [:], now: 42)
        let changes = planner.create([ref("a", 1), ref("b", 7)], name: "app", id: "p")
        #expect(changes.map(\.host) == ["a", "a", "b", "b"])
        guard case .put(let put) = changes[0].change else {
            Issue.record("definition first")
            return
        }
        #expect(put.name == "app" && put.updated == 42)
        #expect(changes[3].change == .setTab(TabId(7), Membership(project: "p", rank: 1024)))
    }

    @Test func movingWithinAProjectRenumbersOnlyWhatChanged() {
        let project = Project(info: info("p", "app"), tabs: [ref("a", 1), ref("b", 2), ref("a", 3)])
        let sources = [
            "a": HostProjects(projects: ["p": project.info], members: [TabId(1): .init(project: "p", rank: 0), TabId(3): .init(project: "p", rank: 2048)]),
            "b": HostProjects(projects: ["p": project.info], members: [TabId(2): .init(project: "p", rank: 1024)]),
        ]
        let planner = ProjectPlanner(projects: [project], sources: sources, now: 1)
        // a/3 to the top: a/3 → 0, a/1 → 1024, b/2 → 2048.
        let changes = planner.move(ref("a", 3), into: "p", at: 0)
        #expect(changes.count == 3)
        #expect(changes.contains { $0.host == "a" && $0.change == .setTab(TabId(3), .init(project: "p", rank: 0)) })
        #expect(changes.contains { $0.host == "b" && $0.change == .setTab(TabId(2), .init(project: "p", rank: 2048)) })
        // Renaming and reordering reach every host holding a member.
        #expect(planner.update("p", name: "web").map(\.host) == ["a", "b"])
        #expect(planner.ungroup("p").count == 2)
    }

    @Test func reorderingProjectsTouchesOnlyMovedOnes() {
        let projects = [
            Project(info: info("p", "p", order: 0), tabs: [ref("a", 1)]),
            Project(info: info("q", "q", order: 1024), tabs: [ref("a", 2)]),
            Project(info: info("r", "r", order: 2048), tabs: [ref("b", 3)]),
        ]
        let changes = ProjectPlanner(projects: projects, sources: [:], now: 9).moveProject("r", to: 0)
        let orders: [String: Int64] = Dictionary(changes.compactMap { if case .put(let info) = $0.change { (info.id, info.order) } else { nil } }, uniquingKeysWith: { first, _ in first })
        #expect(orders == ["r": 0, "p": 1024, "q": 2048])
    }

    @Test func suggestionsNeedTwoTabsUnderOneRoot() {
        let found = ProjectSuggestion.find([
            (ref("a", 1), "/src/app/"), (ref("b", 2), "/src/app"), (ref("a", 3), "~"), (ref("a", 4), "/src/other"), (ref("a", 5), nil),
            (ref("a", 6), "/Users/me"), (ref("b", 7), "/Users/me"), (ref("b", 8), "/home/me/"), (ref("b", 9), "/home/me"),
        ])
        #expect(found.map(\.name) == ["app"])
        #expect(found[0].tabs == [ref("a", 1), ref("b", 2)])
        #expect(ProjectSuggestion.find([(ref("a", 1), "/src/app"), (ref("b", 2), "/src/app")], dismissed: ["/src/app"]).isEmpty)
    }
}

@Suite struct SidebarDropTests {
    private let sections = [
        SidebarSection(.project("p"), rows: [ref("a", 1), ref("b", 2)]),
        SidebarSection(.window, rows: []),
        SidebarSection(.host("a"), rows: [ref("a", 3), ref("a", 4), ref("a", 5)]),
        SidebarSection(.host("b"), rows: [ref("b", 6)]),
    ]

    @Test func edgesOpenAGapAndTheMiddleGroups() {
        let host = sections[2]
        // a/5 over the top edge of a/3: before it.
        #expect(SidebarDrop.plan(dragging: ref("a", 5), over: ref("a", 3), at: 0.1, in: host) == .insert(ref("a", 5), into: .host("a"), at: 0))
        // a/3 over the bottom edge of a/4: after it.
        #expect(SidebarDrop.plan(dragging: ref("a", 3), over: ref("a", 4), at: 0.9, in: host) == .insert(ref("a", 3), into: .host("a"), at: 1))
        // A drop that leaves the row where it is: nothing.
        #expect(SidebarDrop.plan(dragging: ref("a", 4), over: ref("a", 3), at: 0.9, in: host) == nil)
        // The middle: group with it.
        #expect(SidebarDrop.plan(dragging: ref("a", 3), over: ref("a", 4), at: 0.5, in: host) == .group(ref("a", 3), onto: ref("a", 4)))
        // Another host's section never takes the tab: any part of its row groups.
        #expect(SidebarDrop.plan(dragging: ref("a", 3), over: ref("b", 6), at: 0.1, in: sections[3]) == .group(ref("a", 3), onto: ref("b", 6)))
        // Inside its own project the middle reorders rather than regroups.
        #expect(SidebarDrop.plan(dragging: ref("a", 1), over: ref("b", 2), at: 0.6, in: sections[0]) == .insert(ref("a", 1), into: .project("p"), at: 1))
    }

    @Test func aPlanMovesTheRowBetweenSections() {
        let drop = SidebarDrop.insert(ref("a", 4), into: .project("p"), at: 1)
        let after = drop.applied(to: sections)
        #expect(after[0].rows == [ref("a", 1), ref("a", 4), ref("b", 2)])
        #expect(after[2].rows == [ref("a", 3), ref("a", 5)])
        #expect(SidebarDrop.group(ref("a", 4), onto: ref("b", 6)).applied(to: sections) == sections)
    }

    @Test func looseOrderMapsToTheSessionIndex() {
        // Session 3 7 4 5 (7 is in a project); loose rows become 4 3 5.
        let session = [3, 7, 4, 5].map { TabId($0) }
        let to = SidebarDrop.sessionIndex(for: TabId(3), loose: [4, 3, 5].map { TabId($0) }, session: session)
        var moved = Session(tabs: session.map { Tab(id: $0, root: .leaf(PaneId($0.rawValue)), focused: PaneId($0.rawValue)) }, activeTabId: nil)
        moved.apply(.moveTab(TabId(3), to: try! #require(to)))
        #expect(moved.tabs.map(\.id.rawValue).filter { $0 != 7 } == [4, 3, 5])
        #expect(SidebarDrop.sessionIndex(for: TabId(4), loose: [3, 4, 5].map { TabId($0) }, session: session) == nil, "already there")
    }
}

@MainActor
@Suite struct ProjectStoreTests {
    @Test func anOldEchoNeverPutsAMovedTabBack() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.receive(tabsLayout(revision: 1, [1, 2, 3]))
        store.apply(.focus(PaneId(200)))
        let focusOp = UInt64(sent.count)
        store.apply(.moveTab(TabId(1), to: 2))
        let moveOp = UInt64(sent.count)
        #expect(store.session.tabs.map(\.id.rawValue) == [2, 3, 1])
        // The focus's echo carries the old order: the move stays on screen.
        store.receive(tabsLayout(revision: 2, [1, 2, 3]))
        store.acknowledge(focusOp, failed: false)
        #expect(store.session.tabs.map(\.id.rawValue) == [2, 3, 1])
        // The move's own echo: nothing moves again.
        store.receive(tabsLayout(revision: 3, [2, 3, 1]))
        store.acknowledge(moveOp, failed: false)
        #expect(store.session.tabs.map(\.id.rawValue) == [2, 3, 1])
        // A later order from another device is the truth.
        store.receive(tabsLayout(revision: 4, [3, 2, 1]))
        #expect(store.session.tabs.map(\.id.rawValue) == [3, 2, 1])
    }

    @Test func aRefusedMoveGoesBack() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.receive(tabsLayout(revision: 1, [1, 2]))
        store.apply(.moveTab(TabId(2), to: 0))
        #expect(store.session.tabs.map(\.id.rawValue) == [2, 1])
        store.acknowledge(UInt64(sent.count), failed: true)
        #expect(store.session.tabs.map(\.id.rawValue) == [1, 2])
    }

    @Test func projectChangesShowAtOnceAndReconcileWithTheDaemon() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.supportsProjects = true
        store.receive(tabsLayout(revision: 1, [1, 2]))
        store.apply(.put(info("p", "app")))
        store.apply(.setTab(TabId(1), Membership(project: "p", rank: 0)))
        #expect(sent.last == .setTabProject(tabId: 1, projectId: "p", rank: 0))
        #expect(store.projects.members[TabId(1)]?.project == "p")
        // A report from before the change does not hide it.
        store.receive(DaemonProjects(sessionId: 7, revision: 1, projects: [], tabs: []))
        #expect(store.projects.members[TabId(1)]?.project == "p")
        // The daemon's report with it, then the answers: the same state, nothing flickers.
        store.receive(DaemonProjects(
            sessionId: 7, revision: 2,
            projects: [DaemonProject(id: "p", name: "app", color: 0, order: 0, updatedMs: 1)],
            tabs: [DaemonTabProject(tabId: 1, projectId: "p", rank: 0)]))
        store.acknowledge(1, failed: false)
        store.acknowledge(2, failed: false)
        #expect(store.projects.members[TabId(1)]?.project == "p")
        #expect(store.projects.projects["p"]?.name == "app")
        // A refused change goes.
        store.apply(.setTab(TabId(2), Membership(project: "p", rank: 1024)))
        #expect(store.projects.members.count == 2)
        store.acknowledge(UInt64(sent.count), failed: true)
        #expect(store.projects.members.count == 1)
    }

    /// The daemon sends a layout, its projects, then its floats: the first layout of a session
    /// is still held for its floats when the projects arrive.
    @Test func projectsArrivingWhileTheFirstLayoutWaitsForFloatsShow() {
        let store = DaemonLayoutStore { _ in 1 }
        store.supportsProjects = true
        store.supportsFloats = true
        store.receive(tabsLayout(revision: 1, [1, 2]))
        store.receive(DaemonProjects(
            sessionId: 7, revision: 1,
            projects: [DaemonProject(id: "p", name: "app", color: 0, order: 0, updatedMs: 1)],
            tabs: [DaemonTabProject(tabId: 2, projectId: "p", rank: 1024)]))
        #expect(!store.hasLayout)
        store.receive(DaemonFloats(sessionId: 7, revision: 1, floats: []))
        #expect(store.session.tabs.map(\.id.rawValue) == [1, 2])
        #expect(store.projects.projects["p"]?.name == "app")
        #expect(store.projects.members[TabId(2)]?.rank == 1024)
    }

    @Test func aDaemonWithoutProjectsIsNeverSentThem() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.receive(tabsLayout(revision: 1, [1]))
        store.apply(.put(info("p", "app")))
        #expect(sent.isEmpty)
    }
}

@MainActor
@Suite struct HostGroupsProjectTests {
    /// This Mac (2 tabs), cloud (2 tabs), box (SSH, 1 tab); none keeps projects on a daemon,
    /// so memberships live in the window's copy.
    private func fixture() throws -> HostGroups {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "cloud", name: "cloud", kind: .daemon, daemonId: "bb"))
        model.upsert(HostRecord(id: "box", name: "box", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "box", identity: .password)))
        model.connections["cloud"] = FakeConnection(tabs: 2)
        model.connections["box"] = FakeConnection(tabs: 1)
        let local = LocalLayoutStore()
        local.apply(.newTab)
        let groups = HostGroups(hosts: model, local: .init(name: "This Mac", layout: local))
        try groups.open("cloud")
        try groups.open("box")
        return groups
    }

    @Test func droppingATabOnAnotherMakesAProjectThatLeadsTheOrder() throws {
        let groups = try fixture()
        let before = groups.tabs
        let mac2 = before[1], cloud2 = before[3], box = before[4]
        groups.commit(.group(box, onto: cloud2)) { _, _ in "api" }
        #expect(groups.projects.map(\.name) == ["api"])
        #expect(groups.projects[0].tabs == [cloud2, box])
        // Projects lead ⌘1…; the rest keep their host order.
        #expect(groups.tabs == [cloud2, box, before[0], mac2, before[2]])
        #expect(groups.tab(forShortcut: 1) == cloud2)
        #expect(groups.sections.first { $0.container == .host("box") }?.rows == [])

        // Onto a project's tab: joins after it.
        groups.commit(.group(mac2, onto: cloud2)) { _, _ in "unused" }
        #expect(groups.projects[0].tabs == [cloud2, mac2, box])

        // Back onto its host's section: leaves, at the place it was dropped.
        groups.commit(.insert(mac2, into: .host("local"), at: 0)) { _, _ in "" }
        #expect(groups.projects[0].tabs == [cloud2, box])
        let local = try #require(groups.group("local"))
        #expect(local.tabs.map { local.ref($0.id) } == [mac2, before[0]])

        // ⌃⌘↓ within the project.
        groups.moveTab(cloud2, by: 1)
        #expect(groups.projects[0].tabs == [box, cloud2])

        // The last members leave: the project is gone, nothing is left behind.
        groups.commit(.insert(box, into: .host("box"), at: 0)) { _, _ in "" }
        groups.commit(.insert(cloud2, into: .host("cloud"), at: 1)) { _, _ in "" }
        #expect(groups.projects.isEmpty)
        #expect(groups.windowProjects.isEmpty)
    }

    /// What the rows show while dragging is exactly what the drop leaves: no second move.
    @Test func aPreviewIsWhatTheCommitLeaves() throws {
        let groups = try fixture()
        let tabs = groups.tabs
        groups.commit(.group(tabs[3], onto: tabs[2])) { _, _ in "api" }
        let project = try #require(groups.projects.first)
        let drops: [SidebarDrop] = [
            .insert(tabs[4], into: .project(project.id), at: 1),
            .insert(tabs[3], into: .project(project.id), at: 0),
            .insert(tabs[1], into: .host("local"), at: 0),
            .insert(tabs[2], into: .host("cloud"), at: 0),
        ]
        for drop in drops {
            let preview = drop.applied(to: groups.sections)
            groups.commit(drop) { _, _ in "" }
            #expect(groups.sections == preview, "\(drop)")
        }
    }

    @Test func renameRecolourAndReorderProjects() throws {
        let groups = try fixture()
        let tabs = groups.tabs
        groups.commit(.group(tabs[1], onto: tabs[0])) { _, _ in "one" }
        groups.commit(.group(tabs[3], onto: tabs[2])) { _, _ in "two" }
        #expect(groups.projects.map(\.name) == ["one", "two"])
        #expect(Set(groups.projects.map(\.color)).count == 2, "a new project takes an unused colour")
        let two = groups.projects[1].id
        groups.apply(groups.planner().moveProject(two, to: 0))
        #expect(groups.projects.map(\.name) == ["two", "one"])
        groups.apply(groups.planner().update(two, name: "backend", color: 5))
        #expect(groups.project(two)?.name == "backend")
        #expect(groups.project(two)?.color == 5)
        groups.apply(groups.planner().ungroup(two))
        #expect(groups.projects.map(\.name) == ["one"])
    }
}
