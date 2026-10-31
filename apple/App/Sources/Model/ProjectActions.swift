import Foundation
import HostKit
import PaneLayout

// Projects in a window (docs/APP-ARCHITECTURE.md §23): what the sidebar's gestures, menus and
// keys do. The model is `HostGroups`' (merged across hosts, routed per host).

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

    /// The repository root a tab works in (the daemon's repositories), else its directory.
    func projectRoot(of ref: TabRef) -> String? {
        #if os(iOS)
        // This device runs no real shell here: its tabs' folders say nothing about the work.
        if ref.hostId == HostGroups.localId { return nil }
        #endif
        guard ref.hostId != HostGroups.mixedId, let group = groups.group(ref.hostId),
              let tab = group.tabs.first(where: { $0.id == ref.tab })
        else { return nil }
        if let sidebar = groups.repoSidebar(for: group),
           let repo = sidebar.repos.first(where: { $0.worktrees.contains { $0.tabs.contains(ref.tab) } })
        {
            return repo.id
        }
        return workspace(ofGroup: ref.hostId)?.absoluteDirectory(of: tab)
    }

    /// A new project's name: the folder its tabs share, else "Project N".
    func projectName(for refs: [TabRef]) -> String {
        let roots = Set(refs.map(projectRoot(of:)))
        if roots.count == 1, let root = roots.first ?? nil,
           let name = ProjectSuggestion.find([(refs[0], root), (refs[0], root)]).first?.name
        {
            return name
        }
        let taken = Set(projects.map(\.name))
        return (1...).lazy.map { "Project \($0)" }.first { !taken.contains($0) }!
    }

    func newProject(from refs: [TabRef], name: String? = nil) {
        guard !refs.isEmpty else { return }
        groups.apply(groups.planner().create(refs, name: name ?? projectName(for: refs)))
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
        guard !name.isEmpty else { return }
        groups.apply(groups.planner().update(id, name: name))
    }

    func setProjectColor(_ id: String, _ color: Int) {
        groups.apply(groups.planner().update(id, color: color))
    }

    func ungroupProject(_ id: String) {
        groups.apply(groups.planner().ungroup(id))
    }

    func moveProject(_ id: String, to index: Int) {
        groups.apply(groups.planner().moveProject(id, to: index))
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

    /// A new terminal in a project: on the host of its current (else first) tab, joining once
    /// the host has made it.
    func newTab(inProject id: String) {
        guard let project = groups.project(id) else { return }
        let current = currentTab.flatMap { project.tabs.contains($0) && $0.hostId != HostGroups.mixedId ? $0.hostId : nil }
        guard let host = current ?? project.tabs.first(where: { $0.hostId != HostGroups.mixedId })?.hostId else { return }
        let before = Set(groups.group(host)?.tabs.map(\.id) ?? [])
        newTab(onGroup: host)
        Task { [weak self] in
            for _ in 0..<50 {
                guard let self else { return }
                if let new = groups.group(host)?.tabs.first(where: { !before.contains($0.id) }) {
                    move(TabRef(hostId: host, tab: new.id), toProject: id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
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
        let loose = groups.groups.flatMap { groups.looseTabs(of: $0, grouped: grouped) }
        return ProjectSuggestion.find(loose.map { ($0, projectRoot(of: $0)) }, dismissed: groups.dismissedSuggestions)
    }

    func accept(_ suggestion: ProjectSuggestion) {
        newProject(from: suggestion.tabs, name: suggestion.name)
    }

    func dismiss(_ suggestion: ProjectSuggestion) {
        groups.dismissedSuggestions.insert(suggestion.key)
    }

    /// Carries out a sidebar drop.
    func commit(_ drop: SidebarDrop) {
        groups.commit(drop) { [unowned self] a, b in projectName(for: [a, b]) }
    }
}
