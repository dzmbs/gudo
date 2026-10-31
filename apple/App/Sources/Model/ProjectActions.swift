import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI

// Projects in a window (docs/APP-ARCHITECTURE.md §23): what the sidebar's gestures, menus and
// keys do. The model is `HostGroups`' (merged across hosts, routed per host). A project is only
// ever made by an explicit ask: New Project, New Project from Tab, a drop onto a tab, a
// suggestion's tap. A new terminal joins one only when asked for from it (its +, ⌘T in it).

extension WindowModel {
    var projects: [Project] { groups.projects }

    /// The tab's name, whatever kind of tab it is.
    func title(ofTab ref: TabRef) -> String {
        if ref.hostId == HostGroups.mixedId {
            return composites.tab(ref.tab).map(title(ofMixedTab:)) ?? "Tab"
        }
        guard let tab = groups.group(ref.hostId)?.tabs.first(where: { $0.id == ref.tab }) else { return "Tab" }
        return workspace(ofGroup: ref.hostId)?.title(of: tab) ?? tab.title ?? "Shell"
    }

    /// The host's home folder, where known (this Mac's own).
    private func home(of host: String) -> String? {
        #if os(macOS)
        if host == HostGroups.localId || app.hosts.record(host)?.isThisDevice == true { return NSHomeDirectory() }
        #endif
        return nil
    }

    /// The repository root a tab works in (the daemon's repositories, or a `.git` above a local
    /// tab's folder), else its folder; nil for a home folder or above, which says nothing.
    func projectRoot(of ref: TabRef) -> String? {
        guard ref.hostId != HostGroups.mixedId, let group = groups.group(ref.hostId),
              let tab = group.tabs.first(where: { $0.id == ref.tab })
        else { return nil }
        return projectRoot(of: tab, in: group, sidebar: groups.repoSidebar(for: group))
    }

    /// `projectRoot(of:)` with the host's group and repositories resolved once by the caller:
    /// resolving them costs a pass over every host's tabs, too much to repeat for each tab.
    private func projectRoot(of tab: Tab, in group: HostGroup, sidebar: RepoSidebar?) -> String? {
        #if os(iOS)
        // This device runs no real shell here: its tabs' folders say nothing about the work.
        if group.id == HostGroups.localId { return nil }
        #endif
        let ref = group.ref(tab.id)
        let home = home(of: ref.hostId)
        if let sidebar,
           let repo = sidebar.repos.first(where: { $0.worktrees.contains { $0.tabs.contains(ref.tab) } }),
           !ProjectNaming.isHomeOrAbove(repo.id, home: home)
        {
            return repo.id
        }
        guard let directory = workspace(ofGroup: ref.hostId)?.absoluteDirectory(of: tab),
              !ProjectNaming.isHomeOrAbove(directory, home: home)
        else { return nil }
        #if os(macOS)
        if ref.hostId == HostGroups.localId,
           let root = ProjectNaming.gitRoot(of: directory, home: home, exists: { FileManager.default.fileExists(atPath: $0) })
        {
            return root
        }
        #endif
        return directory
    }

    /// The name of the folder `refs` all work in (repository root first), else nil.
    func projectName(for refs: [TabRef]) -> String? {
        ProjectNaming.sharedName(refs.map(projectRoot(of:)))
    }

    /// New Project from Tab: a new project of `refs`, named for their folder (else "New
    /// Project", never a name another project has), its name then typed in place.
    func newProject(from refs: [TabRef], name: String? = nil, naming: Bool = true) {
        guard !refs.isEmpty else { return }
        let id = UUID().uuidString
        let name = groups.uniqueProjectName(name ?? projectName(for: refs) ?? ProjectNaming.fallback)
        groups.apply(groups.planner().create(refs, name: name, id: id))
        if naming { startNaming(id) }
    }

    /// New Project (⌃⌘N): an empty project, its name typed in place; tabs are dragged in or
    /// made with its +.
    func newEmptyProject() {
        let id = groups.createEmptyProject()
        if widthBucket != .compact { isSidebarShown = true }
        startNaming(id)
    }

    /// The name field of a project just made opens focused, its name selected (Finder's New
    /// Folder, Safari's New Tab Group).
    func startNaming(_ id: String) {
        groups.collapsedProjects.remove(id)
        namingProject = id
    }

    func move(_ ref: TabRef, toProject id: String) {
        guard let project = groups.project(id), !project.tabs.contains(ref) else { return }
        groups.apply(groups.planner().move(ref, into: id, at: project.tabs.count))
    }

    func removeFromProject(_ ref: TabRef) {
        groups.apply(groups.planner().remove(ref))
    }

    func renameProject(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != groups.project(id)?.name else { return }
        groups.updateProject(id, name: name)
    }

    func setProjectColor(_ id: String, _ color: Int) {
        groups.updateProject(id, color: color)
    }

    func ungroupProject(_ id: String) {
        groups.ungroupProject(id)
    }

    func moveProject(_ id: String, to index: Int) {
        groups.moveProject(id, to: index)
    }

    /// Closes every tab of a project (the project goes with its last tab).
    func closeProject(_ id: String) {
        guard let project = groups.project(id) else { return }
        for ref in project.tabs {
            if ref.hostId == HostGroups.mixedId {
                closeWindowTab(ref.tab, undoable: false)
            } else {
                closeTab(ref, undoable: false)
            }
        }
    }

    /// A new terminal in a project (its +, ⌘T from one of its tabs): on the current tab's host
    /// when that tab is in the project (joining right after it), else on the host of its first
    /// tab (else the window's), at its end.
    func newTab(inProject id: String) {
        guard let project = groups.project(id) else { return }
        let current = currentTab.flatMap { project.tabs.contains($0) && $0.hostId != HostGroups.mixedId ? $0 : nil }
        let preferred = current?.hostId ?? project.tabs.first(where: { $0.hostId != HostGroups.mixedId })?.hostId
        guard let host = groups.newTabHost(preferred: preferred ?? currentGroupId) else {
            newTab(onGroup: preferred ?? currentGroupId)
            return
        }
        let index = current.flatMap { project.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? .max
        groups.expectNewTab(on: host, joining: id, at: index)
        newTab(onGroup: host)
        claimJoinedTabs()
    }

    /// Joins tabs that arrived for a project's + or ⌘T, and keeps watching while any is due
    /// (a daemon makes its tab a round trip later).
    private func claimJoinedTabs() {
        let joined = withAnimation(DS.Motion.reorder) { groups.claimNewTabs() }
        for ref in joined {
            if let project = groups.project(of: ref) { groups.collapsedProjects.remove(project.id) }
            flashJoined(ref)
        }
        guard !groups.pendingJoins.isEmpty, !followsJoins else { return }
        followsJoins = true
        withObservationTracking {
            for join in groups.pendingJoins { _ = groups.group(join.host)?.tabs }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                followsJoins = false
                claimJoinedTabs()
            }
        }
    }

    /// The row of a tab that joined a project lights in its colour a moment, so the join shows.
    private func flashJoined(_ ref: TabRef) {
        joinedTab = ref
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, joinedTab == ref else { return }
            withAnimation(DS.Motion.overlay) { joinedTab = nil }
        }
    }

    /// ⌃⌘↑ / ⌃⌘↓: the current tab one row up or down within its section.
    func moveCurrentTab(by offset: Int) {
        guard let currentTab else { return }
        groups.moveTab(currentTab, by: offset)
    }

    /// Loose tabs that share a repository or directory, worth a one-tap project.
    var projectSuggestions: [ProjectSuggestion] {
        let grouped = Set(projects.flatMap(\.tabs))
        var loose: [(TabRef, String?)] = []
        for group in groups.groups where group.id != HostGroups.mixedId {
            let refs = groups.looseTabs(of: group, grouped: grouped)
            guard !refs.isEmpty else { continue }
            let sidebar = groups.repoSidebar(for: group)
            let tabs = Dictionary(group.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for ref in refs {
                loose.append((ref, tabs[ref.tab].flatMap { projectRoot(of: $0, in: group, sidebar: sidebar) }))
            }
        }
        return ProjectSuggestion.find(loose, dismissed: groups.dismissedSuggestions)
    }

    /// The project a suggestion's tabs would join (one already named for their folder).
    func existingProject(for suggestion: ProjectSuggestion) -> Project? {
        groups.project(named: suggestion.name)
    }

    func accept(_ suggestion: ProjectSuggestion) {
        if let id = groups.groupTabs(suggestion.tabs, name: suggestion.name) { startNaming(id) }
    }

    func dismiss(_ suggestion: ProjectSuggestion) {
        groups.dismissedSuggestions.insert(suggestion.key)
    }

    /// What dropping `ref` onto `target` will do, in a word or two: "Add to app" or "Group".
    func groupLabel(_ ref: TabRef, onto target: TabRef) -> String {
        groups.groupTarget(ref, onto: target) { [unowned self] a, b in projectName(for: [a, b]) }
            .map { "Add to \($0.name)" } ?? "Group"
    }

    /// Carries out a sidebar drop.
    func commit(_ drop: SidebarDrop) {
        // A selection dragged by one of its rows lands together, in sidebar order.
        let carried = carriedTabs(dragging: drop.dragged)
        var made: String?
        for step in drop.carrying(carried, in: groups.sections) {
            if let project = groups.commit(step, name: { [unowned self] a, b in projectName(for: [a, b]) }) { made = project }
        }
        if !carried.isEmpty { tabSelection.clear() }
        if let made { startNaming(made) }
    }
}
