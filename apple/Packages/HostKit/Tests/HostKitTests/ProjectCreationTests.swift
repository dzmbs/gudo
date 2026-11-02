import Foundation
@testable import HostKit
import PaneLayout
import Testing

@Suite struct ProjectNamingTests {
    @Test func homeFoldersAndTheirParentsNeverName() {
        for path in ["/", "", "~", "~/src", "/Users", "/Users/me", "/Users/me/", "/home", "/home/me", "/root", "/var/root", "/var/home/me"] {
            #expect(ProjectNaming.isHomeOrAbove(path, home: nil), "\(path)")
        }
        #expect(ProjectNaming.isHomeOrAbove("/opt", home: "/opt/me"), "above a known home")
        #expect(ProjectNaming.isHomeOrAbove("/opt/me", home: "/opt/me"))
        #expect(!ProjectNaming.isHomeOrAbove("/opt/me/app", home: "/opt/me"))
        #expect(!ProjectNaming.isHomeOrAbove("/Users/me/projects", home: nil))
        #expect(ProjectNaming.sharedName(["/Users/me", "/Users/me"]) == nil)
        #expect(ProjectNaming.sharedName(["/srv/app/", "/srv/app"]) == "app")
        #expect(ProjectNaming.sharedName(["/srv/app", "/srv/web"]) == nil)
        #expect(ProjectNaming.sharedName(["/srv/app", nil]) == nil)
    }

    /// Ghostty's shell integration reports `kitty-shell-cwd://host/path`: read as a path, a
    /// shell in home is home (read as a URL it once named two projects after the user).
    @Test func workingDirectoryURLsAreReadAsPaths() {
        let paths = ["kitty-shell-cwd://mac.local/Users/me", "file://mac.local/Users/me/"].map { ProjectNaming.directory(fromOSC7: $0) }
        #expect(paths == ["/Users/me", "/Users/me/"])
        #expect(ProjectNaming.sharedName(paths) == nil)
        #expect(ProjectSuggestion.find(paths.enumerated().map { (TabRef(hostId: "local", tab: TabId(UInt64($0.offset))), $0.element) }).isEmpty)
        #expect(ProjectNaming.directory(fromOSC7: "file://h/Users/a%20b") == "/Users/a b")
        #expect(ProjectNaming.directory(fromOSC7: "kitty-shell-cwd://h/src/a%20b") == "/src/a%20b")
        #expect(ProjectNaming.directory(fromOSC7: "/srv/app") == "/srv/app")
        #expect(ProjectNaming.directory(fromOSC7: "rm -rf ~") == nil)
    }

    @Test func theRepositoryRootNamesItButNeverAHomeRepository() {
        let repos: Set<String> = ["/Users/me/src/gudo/.git", "/Users/me/.git"]
        let exists = { repos.contains($0) }
        #expect(ProjectNaming.gitRoot(of: "/Users/me/src/gudo/apple/App", home: "/Users/me", exists: exists) == "/Users/me/src/gudo")
        #expect(ProjectNaming.gitRoot(of: "/Users/me/notes", home: "/Users/me", exists: exists) == nil, "dotfiles in home")
        #expect(ProjectNaming.gitRoot(of: "/tmp/x", home: "/Users/me", exists: exists) == nil)
    }

    @Test func namesAreNeverTaken() {
        #expect(ProjectNaming.unique("app", taken: ["web"]) == "app")
        #expect(ProjectNaming.unique("app", taken: ["App", "app 2"]) == "app 3")
    }
}

/// No project is ever made without being asked for: new tabs, restores and reconnects leave the
/// projects as they were; drops and New Project name them by the rules.
@MainActor
@Suite struct ProjectCreationTests {
    /// This Mac (2 tabs), hetzner (a daemon record, 2 tabs, kept in the window's copy), box (SSH,
    /// 1 tab).
    private func fixture(_ hosts: HostsModel? = nil) throws -> (HostGroups, HostsModel) {
        let model = hosts ?? HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "hetzner", name: "hetzner", kind: .daemon, daemonId: "bb"))
        model.upsert(HostRecord(id: "box", name: "box", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "box", identity: .password)))
        model.connections["hetzner"] = FakeConnection(tabs: 2)
        model.connections["box"] = FakeConnection(tabs: 1)
        let store = LocalLayoutStore()
        store.apply(.newTab)
        let groups = HostGroups(hosts: model, local: .init(name: "This Mac", layout: store))
        try groups.open("hetzner")
        try groups.open("box")
        return (groups, model)
    }

    @Test func newTabsOnAnyHostStayLoose() throws {
        let (groups, model) = try fixture()
        let tabs = groups.tabs
        groups.commit(.group(tabs[1], onto: tabs[0])) { _, _ in nil }
        let before = groups.projects
        groups.local?.layout.apply(.newTab)
        groups.local?.layout.apply(.newTab)
        (model.connections["hetzner"] as? FakeConnection)?.layout.apply(.newTab)
        #expect(groups.claimNewTabs().isEmpty)
        #expect(groups.projects == before)
    }

    @Test func aTabAskedForInAProjectJoinsItAndNoOtherDoes() throws {
        let (groups, _) = try fixture()
        let tabs = groups.tabs
        let id = try #require(groups.commit(.group(tabs[1], onto: tabs[0])) { _, _ in nil })
        groups.expectNewTab(on: "local", joining: id, at: 1)
        groups.local?.layout.apply(.newTab)
        let joined = groups.claimNewTabs()
        #expect(joined.count == 1)
        #expect(groups.project(id)?.tabs == [tabs[0], joined[0], tabs[1]])
        // The next one, asked for anywhere else, stays loose.
        groups.local?.layout.apply(.newTab)
        #expect(groups.claimNewTabs().isEmpty)
        #expect(groups.project(id)?.tabs.count == 3)
    }

    @Test func membershipsOfAnotherRunNeverClaimTodaysTabs() throws {
        let (groups, model) = try fixture()
        let tabs = groups.tabs
        groups.commit(.group(tabs[1], onto: tabs[0])) { _, _ in "mac" }
        groups.commit(.group(tabs[4], onto: tabs[3])) { _, _ in "mixed" }
        var saved = groups.projectsState
        // The same run (another window, a scene restored): kept.
        let (same, _) = try fixture(model)
        same.projectsState = saved
        #expect(same.projects.map(\.name) == ["mac", "mixed"])
        // The next run: this Mac's and the SSH host's tab ids start over and name other tabs.
        saved.launch = "an earlier run"
        let (next, _) = try fixture(model)
        next.projectsState = saved
        #expect(next.projects.map(\.name) == ["mixed"])
        #expect(next.projects.first?.tabs == [tabs[3]], "the daemon's tab keeps its project")
    }

    @Test func aReconnectedSSHHostStartsLoose() throws {
        let (groups, model) = try fixture()
        let tabs = groups.tabs
        groups.commit(.group(tabs[4], onto: tabs[0])) { _, _ in nil }
        groups.close("box")
        model.connections["box"] = FakeConnection(tabs: 1)
        try groups.open("box")
        #expect(groups.projects.first?.tabs == [tabs[0]])
    }

    @Test func groupingJoinsTheProjectOfThatNameAndNeverDuplicatesOne() throws {
        let (groups, _) = try fixture()
        let tabs = groups.tabs
        groups.commit(.group(tabs[1], onto: tabs[0])) { _, _ in "app" }
        groups.commit(.group(tabs[3], onto: tabs[2])) { _, _ in "app" }
        #expect(groups.projects.map(\.name) == ["app"])
        #expect(groups.projects.first?.tabs == [tabs[0], tabs[1], tabs[2], tabs[3]])
        let target = groups.groupTarget(tabs[4], onto: tabs[2]) { _, _ in nil }
        #expect(target?.name == "app")

        let made = try #require(groups.commit(.group(tabs[2], onto: tabs[4])) { _, _ in nil })
        #expect(groups.project(made)?.name == "New Project")
        groups.updateProject(made, name: "APP")
        #expect(groups.project(made)?.name == "APP 2", "a rename never takes another's name")
    }

    @Test func aProjectMadeFromNothingWaitsForItsFirstTab() throws {
        let (groups, _) = try fixture()
        let tabs = groups.tabs
        let first = groups.createEmptyProject()
        let second = groups.createEmptyProject()
        #expect(groups.projects.map(\.name) == ["New Project", "New Project 2"])
        #expect(groups.projects.allSatisfy { $0.tabs.isEmpty })
        #expect(groups.projects.first?.color != groups.projects.last?.color)
        #expect(groups.sections.first?.container == .project(first))

        groups.updateProject(first, name: "web")
        groups.moveProject(second, to: 0)
        #expect(groups.projects.map(\.name) == ["New Project 2", "web"])
        groups.commit(.insert(tabs[3], into: .project(first), at: 0)) { _, _ in nil }
        #expect(groups.project(first)?.tabs == [tabs[3]])
        #expect(groups.project(first)?.name == "web")
        #expect(groups.emptyProjects.map(\.id) == [second], "held by its host now")
        #expect(groups.projectsState.empty?.map(\.id) == [second])

        groups.ungroupProject(second)
        #expect(groups.projects.map(\.name) == ["web"])
    }
}
