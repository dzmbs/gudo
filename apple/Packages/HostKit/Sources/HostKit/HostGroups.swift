import Foundation
import Observation
import os
import PaneLayout

/// A tab anywhere in a window: the host it lives on (`HostGroups.localId` for this device) and
/// its id there. Tab ids are per host, so two hosts can both have a "tab 1".
nonisolated public struct TabRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var hostId: String
    public var tab: TabId

    public init(hostId: String, tab: TabId) {
        self.hostId = hostId
        self.tab = tab
    }

    public var description: String { "\(hostId)/\(tab.rawValue)" }
}

/// One host as the multi-host sidebar shows it: its name, kind, live status and tabs.
nonisolated public struct HostGroup: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// This device (a login shell on the Mac).
        case local
        case daemon
        case ssh
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var status: ConnectionStatus
    /// The host's tabs in its own order (empty until a daemon's first layout).
    public var tabs: [Tab]
    /// The tab the host itself has active (each host keeps its own).
    public var activeTabId: TabId?
    /// False until there is a layout (a daemon before its first `LayoutChanged`).
    public var isReady: Bool
    /// Why the host could not be opened (a missing secret, a bad ticket), if it could not.
    public var failure: String?
    /// The tabs are the ones this device saved, until the host's layout arrives.
    public var isCached = false

    public var isLocal: Bool { kind == .local }

    public func ref(_ tab: TabId) -> TabRef { TabRef(hostId: id, tab: tab) }
}

/// Every host a window shows at once (owner, 2026-10-18: "hosts are isolated — I always have to
/// click Hosts and connect to switch"): this device first, then each open host in the order it
/// was opened. Open hosts keep their `HostConnection` (HostsModel) for as long as they are open,
/// so switching to any tab on any host is a selection, never a reconnect. The iOS lifecycle
/// (suspend in the background, resume every host on foreground: R3/R5/R1) stays in
/// `HostsModel.background()/foreground()`, which covers every connection.
///
/// It also owns the unified tab order the shortcuts use: ⌘1…⌘8 index it across hosts, ⌘9 is the
/// last tab, ⇧⌘[ / ⇧⌘] step across host boundaries and wrap. Collapsing a group hides its rows
/// only; numbers stay stable.
@MainActor
@Observable
public final class HostGroups {
    nonisolated public static let localId = "local"
    /// The pseudo-host of mixed tabs (`TabRef(hostId: mixedId, tab: composite id)`).
    nonisolated public static let mixedId = "mixed"

    /// This device's group: its name ("This Mac") and layout, or nil where the device has no
    /// shell of its own (iPhone, iPad).
    public struct Local {
        public var name: String
        public var layout: any LayoutStore
        public init(name: String, layout: any LayoutStore) {
            self.name = name
            self.layout = layout
        }
    }

    public let hosts: HostsModel
    public var local: Local?
    /// Hosts opened in this window, in the order they were opened (persisted per window).
    public private(set) var openHosts: [String] = []
    /// Groups the user collapsed (their tabs still count for ⌘N).
    public var collapsed: Set<String> = []
    /// Hosts that failed to open, with the reason (shown on the group, cleared on success).
    public private(set) var failures: [String: String] = [:]
    /// This window's mixed tabs (panes from several hosts in one tab). They lead the unified
    /// order; the host tabs carrying their panes are left out of their groups.
    public let composites = CompositeTabs()

    private static let log = Logger(subsystem: Log.subsystem, category: "hosts")

    /// Whether this device's helper serves it (the Mac's "This Mac"): an empty local group then
    /// gives way to the helper's host.
    @ObservationIgnored public var helperServesLocal: () -> Bool = { false }

    public init(hosts: HostsModel, local: Local? = nil) {
        self.hosts = hosts
        self.local = local
    }

    // MARK: Groups

    /// This device (when it has a shell), then the open hosts, then any other host connected in
    /// this app (opened from another window, a deep link), each in a stable order.
    public var groups: [HostGroup] {
        var result: [HostGroup] = []
        let carriers = composites.carriers
        if let local, !(local.layout.session.tabs.isEmpty && helperServesLocal()) {
            let session = local.layout.session
            result.append(HostGroup(
                id: Self.localId, name: local.name, kind: .local, status: .connected(rtt: nil),
                tabs: session.tabs.filter { !(carriers[Self.localId]?.contains($0.id) ?? false) && !hiddenTabs.contains(TabRef(hostId: Self.localId, tab: $0.id)) },
                activeTabId: session.activeTabId, isReady: true))
        }
        for id in hostOrder {
            guard let record = hosts.record(id) else { continue }
            let connection = hosts.connection(id)
            let ready = connection?.isReady ?? false
            let cached = !ready && connection?.showsCachedLayout == true
            let session = ready || cached ? connection?.layoutStore.session : nil
            var status = connection?.status ?? .idle
            if connection == nil, let failure = failures[id] { status = .needsAttention(reason: failure) }
            result.append(HostGroup(
                id: id, name: record.name, kind: record.kind == .daemon ? .daemon : .ssh, status: status,
                tabs: (session?.tabs ?? []).filter { !(carriers[id]?.contains($0.id) ?? false) && !hiddenTabs.contains(TabRef(hostId: id, tab: $0.id)) },
                activeTabId: session?.activeTabId, isReady: ready,
                failure: connection == nil ? failures[id] : nil, isCached: cached))
        }
        return result
    }

    /// This device's helper first, then the open hosts, then hosts connected elsewhere in the
    /// app, in saved-host order.
    private var hostOrder: [String] {
        let others = hosts.records.map(\.id).filter { !openHosts.contains($0) && hosts.connections[$0] != nil }
        let order = openHosts + others
        let thisDevice = order.filter { hosts.record($0)?.isThisDevice == true }
        return thisDevice + order.filter { !thisDevice.contains($0) }
    }

    public func group(_ id: String) -> HostGroup? {
        groups.first { $0.id == id }
    }

    /// Every tab in sidebar order: the unified list ⌘1…⌘9 and ⇧⌘[ ] walk. Projects first (in
    /// their order, tabs by rank), then the window's loose tabs, then each host's loose tabs;
    /// a daemon's follow its repository grouping, as the sidebar draws them.
    public var tabs: [TabRef] {
        let groups = groups
        let projects = projects(in: groups)
        let grouped = Set(projects.flatMap(\.tabs))
        return projects.flatMap(\.tabs)
            + mixedTabs.filter { !grouped.contains($0) }
            + groups.flatMap { looseTabs(of: $0, grouped: grouped) }
    }

    /// A group's tabs that are in no project, in sidebar order.
    public func looseTabs(of group: HostGroup, grouped: Set<TabRef>? = nil) -> [TabRef] {
        let grouped = grouped ?? Set(projects.flatMap(\.tabs))
        let loose = group.tabs.filter { !grouped.contains(group.ref($0.id)) }
        if let sidebar = repoSidebar(for: group, tabs: loose) {
            return sidebar.orderedTabs.map { group.ref($0) }
        }
        return loose.map { group.ref($0.id) }
    }

    /// The window's own tabs: VS Code tabs, then mixed tabs, each in the order they were made.
    public var mixedTabs: [TabRef] {
        composites.ordered.map { TabRef(hostId: Self.mixedId, tab: $0.id) }
    }

    /// A daemon group's tabs grouped by repository and worktree, once the daemon has sent its
    /// repository snapshot (nil otherwise: draw the tabs flat). `tabs` defaults to all of them.
    public func repoSidebar(for group: HostGroup, tabs: [Tab]? = nil) -> RepoSidebar? {
        guard group.kind == .daemon,
              let connection = hosts.connection(group.id) as? DaemonConnection,
              let snapshot = connection.existingWorkspace?.repos,
              !snapshot.worktrees.isEmpty
        else { return nil }
        return RepoSidebar.build(tabs: tabs ?? group.tabs, snapshot: snapshot)
    }

    // MARK: Projects

    /// Projects of tabs without a daemon that keeps them (this device, plain SSH, window tabs,
    /// older daemons), by host id. Persisted with the window.
    public var windowProjects: [String: HostProjects] = [:]
    /// Projects the user collapsed in this window.
    public var collapsedProjects: Set<String> = []
    /// Suggestions the user dismissed (their shared roots).
    public var dismissedSuggestions: Set<String> = []

    /// Projects made from nothing (New Project) that no tab has joined yet. They live in the
    /// window until the first tab joins, then on that tab's host like any other.
    public var emptyProjects: [ProjectInfo] = []

    /// This run of the app: tab ids of this device and plain-SSH hosts start over with each
    /// run, so their memberships are only restored within the run that made them.
    nonisolated public static let launch = UUID().uuidString

    /// What a window saves of its projects.
    public struct ProjectsState: Codable, Equatable, Sendable {
        public var windowProjects: [String: HostProjects]
        public var collapsed: [String]
        public var dismissed: [String]
        public var empty: [ProjectInfo]?
        /// The run that saved it (`HostGroups.launch`).
        public var launch: String?
    }

    public var projectsState: ProjectsState {
        get {
            ProjectsState(
                windowProjects: windowProjects, collapsed: collapsedProjects.sorted(), dismissed: dismissedSuggestions.sorted(),
                empty: emptyProjects, launch: Self.launch)
        }
        set {
            // A tab id of another run names some other tab now: its memberships would put new
            // tabs into old projects.
            windowProjects = newValue.launch == Self.launch ? newValue.windowProjects : newValue.windowProjects.filter { outlivesTheApp($0.key) }
            collapsedProjects = Set(newValue.collapsed)
            dismissedSuggestions = Set(newValue.dismissed)
            emptyProjects = newValue.empty ?? []
        }
    }

    /// Whether a host's tabs keep their ids across runs of the app: a daemon's (it keeps them)
    /// and the window's own (restored with it); not this device's or a plain-SSH host's.
    private func outlivesTheApp(_ host: String) -> Bool {
        host == Self.mixedId || hosts.record(host)?.kind == .daemon
    }

    /// Every project in the window, merged across hosts.
    public var projects: [Project] { projects(in: groups) }

    public func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    public func project(of ref: TabRef) -> Project? { projects.first { $0.tabs.contains(ref) } }

    /// The project called `name` (ignoring case), if one is.
    public func project(named name: String) -> Project? {
        projects.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// `base`, made unique among the window's projects (`except` may keep its own name).
    public func uniqueProjectName(_ base: String, except id: String? = nil) -> String {
        ProjectNaming.unique(base, taken: projects.filter { $0.id != id }.map(\.name))
    }

    private func projects(in groups: [HostGroup]) -> [Project] {
        let (sources, existing) = projectSources(groups)
        let merged = ProjectMerge.merge(sources, existing: existing)
        let ids = Set(merged.map(\.id))
        let empty = emptyProjects.filter { !ids.contains($0.id) }.map { Project(info: $0, tabs: []) }
        guard !empty.isEmpty else { return merged }
        return (merged + empty).sorted { $0.info.order != $1.info.order ? $0.info.order < $1.info.order : $0.id < $1.id }
    }

    /// A new project with no tabs (New Project), after the others. Returns its id.
    @discardableResult
    public func createEmptyProject(name: String? = nil, now: Date = .now) -> String {
        let planner = planner(now: now)
        let info = ProjectInfo(
            id: UUID().uuidString, name: uniqueProjectName(name ?? ProjectNaming.fallback), color: planner.nextColor,
            order: planner.nextOrder, updated: planner.now)
        emptyProjects.append(info)
        return info.id
    }

    /// Renames or recolours a project, wherever it lives. A name another project has gets a
    /// number, so two projects never read the same.
    public func updateProject(_ id: String, name: String? = nil, color: Int? = nil) {
        let name = name.map { uniqueProjectName($0, except: id) }
        if let index = emptyProjects.firstIndex(where: { $0.id == id }) {
            if let name { emptyProjects[index].name = String(name.prefix(ProjectInfo.maxNameLength)) }
            if let color { emptyProjects[index].color = color }
            return
        }
        apply(planner().update(id, name: name, color: color))
    }

    /// Ungroups a project's tabs (an empty project just goes).
    public func ungroupProject(_ id: String) {
        emptyProjects.removeAll { $0.id == id }
        apply(planner().ungroup(id))
    }

    /// Moves a project among the projects.
    public func moveProject(_ id: String, to index: Int) {
        let planner = planner()
        apply(planner.moveProject(id, to: index))
        // Empty projects have no host to keep their order: set it here.
        var order = planner.projects.filter { $0.id != id }
        if let moving = planner.project(id) { order.insert(moving, at: min(max(index, 0), order.count)) }
        for (i, project) in order.enumerated() {
            if let e = emptyProjects.firstIndex(where: { $0.id == project.id }) {
                emptyProjects[e].order = Int64(i) * ProjectPlanner.rankStep
            }
        }
    }

    /// Each host's projects (its daemon's, else the window's copy) and every tab that exists.
    private func projectSources(_ groups: [HostGroup]) -> ([String: HostProjects], Set<TabRef>) {
        var sources: [String: HostProjects] = [:]
        var existing = Set<TabRef>()
        for group in groups {
            existing.formUnion(group.tabs.map { group.ref($0.id) })
            sources[group.id] = daemonProjects(group.id) ?? windowProjects[group.id]
        }
        existing.formUnion(mixedTabs)
        sources[Self.mixedId] = windowProjects[Self.mixedId]
        return (sources.compactMapValues { $0 }, existing)
    }

    /// The daemon's own store when it keeps projects.
    private func daemonStore(_ host: String) -> DaemonLayoutStore? {
        guard let store = (hosts.connection(host) as? DaemonConnection)?.layout, store.supportsProjects else { return nil }
        return store
    }

    private func daemonProjects(_ host: String) -> HostProjects? { daemonStore(host)?.projects }

    /// A planner over the window's current projects.
    public func planner(now: Date = .now) -> ProjectPlanner {
        let groups = groups
        let (sources, _) = projectSources(groups)
        return ProjectPlanner(
            projects: projects(in: groups), sources: sources,
            now: UInt64(max(0, now.timeIntervalSince1970 * 1000)))
    }

    /// Sends each change to its host's daemon, or keeps it in the window's copy.
    public func apply(_ changes: [ProjectPlanner.Change]) {
        var copies: [String: HostProjects] = [:]
        for (host, change) in changes {
            if let store = daemonStore(host) {
                store.apply(change)
            } else {
                copies[host, default: windowProjects[host] ?? HostProjects()].apply(change)
            }
        }
        defer {
            // A project made from nothing lives on its tabs' hosts once one has joined.
            if !emptyProjects.isEmpty {
                let (sources, existing) = projectSources(groups)
                let held = Set(ProjectMerge.merge(sources, existing: existing).map(\.id))
                emptyProjects.removeAll { held.contains($0.id) }
            }
        }
        guard !copies.isEmpty else { return }
        // Pruned once all changes are in: a definition is put before its first member joins.
        let tabsByHost = Dictionary(grouping: tabRefsForPruning(), by: \.hostId).mapValues { Set($0.map(\.tab)) }
        for (host, var copy) in copies {
            copy.keep(tabs: tabsByHost[host] ?? [])
            windowProjects[host] = copy.isEmpty ? nil : copy
        }
    }

    private func tabRefsForPruning() -> [TabRef] {
        groups.flatMap { group in group.tabs.map { group.ref($0.id) } } + mixedTabs + Array(hiddenTabs)
    }

    // MARK: Hidden tabs ("A New Terminal" at launch)

    /// Tabs this window keeps out of sight: those found at launch under "A New Terminal". They
    /// keep running on their hosts; Restore brings them back, selecting one brings it back.
    public var hiddenTabs: Set<TabRef> = []
    /// The Restore row was dismissed (the tabs stay hidden; History still restores them).
    public var restoreDismissed = false

    /// Hidden tabs that still exist on their hosts.
    public var restorableTabs: [TabRef] {
        guard !hiddenTabs.isEmpty else { return [] }
        return hiddenTabs.filter { ref in sessionTabs(of: ref.hostId)?.contains { $0.id == ref.tab } ?? false }
            .sorted { ($0.hostId, $0.tab.rawValue) < ($1.hostId, $1.tab.rawValue) }
    }

    /// Every tab a host has, hidden ones included (nil before its first layout).
    public func sessionTabs(of host: String) -> [Tab]? {
        if host == Self.localId { return local?.layout.session.tabs }
        guard let connection = hosts.connection(host), connection.isReady else { return nil }
        return connection.layoutStore.session.tabs
    }

    /// Brings every hidden tab back.
    public func restoreHiddenTabs() {
        hiddenTabs = []
        restoreDismissed = false
    }

    /// Brings one tab back (it was selected: an agent toast, Go to Tab, Handoff).
    public func unhide(_ ref: TabRef) {
        hiddenTabs.remove(ref)
    }

    // MARK: Recently closed tabs

    /// Where a tab sits now, for bringing it back there once closed: its project and its place
    /// in it, its place among its host's tabs.
    public func closedTab(
        _ ref: TabRef, title: String, name: String?, hostName: String, pane: UInt64?, directory: String?,
        agent: String?, batch: UUID? = nil, now: Date = .now
    ) -> ClosedTab {
        let project = project(of: ref)
        return ClosedTab(
            title: title, name: name, hostId: ref.hostId, hostName: hostName, pane: pane, directory: directory, agent: agent,
            project: project.map { ClosedProject(id: $0.id, name: $0.name, color: $0.color) },
            projectIndex: project?.tabs.firstIndex(of: ref),
            hostIndex: sessionTabs(of: ref.hostId)?.firstIndex { $0.id == ref.tab },
            closedAt: now, batch: batch)
    }

    /// Puts a reopened tab back where `closed` was: at its old place among its host's tabs, and
    /// in its project at its old place (a project of the same name if that one is gone, else a
    /// new one with its name and colour).
    public func place(_ ref: TabRef, as closed: ClosedTab) {
        if let index = closed.hostIndex, let store = layoutStore(ref.hostId), let count = sessionTabs(of: ref.hostId)?.count, count > 0 {
            store.apply(.moveTab(ref.tab, to: min(index, count - 1)))
        }
        guard let was = closed.project else { return }
        let index = closed.projectIndex ?? .max
        if let project = project(was.id) ?? project(named: was.name) {
            apply(planner().move(ref, into: project.id, at: index))
        } else {
            let id = UUID().uuidString
            apply(planner().create([ref], name: uniqueProjectName(was.name), id: id))
            updateProject(id, color: was.color)
        }
    }

    /// The sidebar's draggable runs of rows, top to bottom: projects, the window's loose tabs,
    /// then each host's loose tabs.
    public var sections: [SidebarSection] {
        let groups = groups
        let projects = projects(in: groups)
        let grouped = Set(projects.flatMap(\.tabs))
        return projects.map { SidebarSection(.project($0.id), rows: $0.tabs) }
            + [SidebarSection(.window, rows: mixedTabs.filter { !grouped.contains($0) })]
            + groups.map { SidebarSection(.host($0.id), rows: looseTabs(of: $0, grouped: grouped)) }
    }

    /// What dropping `ref` onto `target` groups them into: the target's project, else the
    /// project already named for the folder they share (`name`), else nil (a new project).
    public func groupTarget(_ ref: TabRef, onto target: TabRef, name: (TabRef, TabRef) -> String?) -> Project? {
        project(of: target) ?? name(target, ref).flatMap(project(named:))
    }

    /// Tabs grouped on purpose (a drop, a suggestion) under the folder they share: into the
    /// project of that name when there is one (the same work: one project for it), else a new
    /// one named for it (or "New Project"). Returns the id of a project it made.
    @discardableResult
    public func groupTabs(_ refs: [TabRef], name: String?) -> String? {
        guard !refs.isEmpty else { return nil }
        if let name, let existing = project(named: name) {
            for ref in refs where !existing.tabs.contains(ref) {
                apply(planner().move(ref, into: existing.id, at: .max))
            }
            return nil
        }
        let id = UUID().uuidString
        apply(planner().create(refs, name: uniqueProjectName(name ?? ProjectNaming.fallback), id: id))
        return id
    }

    /// Carries out a drop. `name` names the folder two tabs share (nil: none). Returns the id
    /// of a project the drop made.
    @discardableResult
    public func commit(_ drop: SidebarDrop, name: (TabRef, TabRef) -> String?) -> String? {
        let planner = planner()
        switch drop {
        case .group(let ref, let target):
            if let project = planner.project(of: target) {
                let index = (project.tabs.filter { $0 != ref }.firstIndex(of: target) ?? project.tabs.count) + 1
                apply(planner.move(ref, into: project.id, at: index))
            } else {
                return groupTabs([target, ref], name: name(target, ref))
            }
        case .insert(let ref, .project(let id), let index):
            apply(planner.move(ref, into: id, at: index))
        case .insert(let ref, .window, _):
            apply(planner.remove(ref))
        case .insert(let ref, .host(let host), let index):
            guard ref.hostId == host, let group = group(host) else { return nil }
            apply(planner.remove(ref))
            var loose = sections.first { $0.container == .host(host) }?.rows.filter { $0 != ref } ?? []
            loose.insert(ref, at: min(max(index, 0), loose.count))
            if let store = layoutStore(host),
               let to = SidebarDrop.sessionIndex(for: ref.tab, loose: loose.map(\.tab), session: group.tabs.map(\.id))
            {
                store.apply(.moveTab(ref.tab, to: to))
            }
        }
        return nil
    }

    /// Moves a tab one row up (-1) or down (+1) within its section (⌃⌘↑ / ⌃⌘↓).
    public func moveTab(_ ref: TabRef, by offset: Int) {
        guard let section = sections.first(where: { $0.rows.contains(ref) }),
              let index = section.rows.firstIndex(of: ref)
        else { return }
        let to = index + offset
        guard section.rows.indices.contains(to) else { return }
        commit(.insert(ref, into: section.container, at: to), name: { _, _ in nil })
    }

    /// The layout a host's tabs live in.
    public func layoutStore(_ host: String) -> (any LayoutStore)? {
        if host == Self.localId { return local?.layout }
        guard let connection = hosts.connection(host), connection.isReady else { return nil }
        return connection.layoutStore
    }

    /// A tab asked for in a project (its +, ⌘T from one of its tabs): the next tab `host` makes
    /// joins `project` at `index`.
    public struct PendingJoin: Sendable {
        public var host: String
        public var project: String
        public var index: Int
        public var known: Set<TabId>
        public var until: Date
    }

    @ObservationIgnored public private(set) var pendingJoins: [PendingJoin] = []

    /// Notes that the next tab `host` makes belongs in `project` (call before asking for it).
    public func expectNewTab(on host: String, joining project: String, at index: Int = .max, now: Date = .now) {
        let known = Set(group(host)?.tabs.map(\.id) ?? [])
        pendingJoins.append(PendingJoin(host: host, project: project, index: index, known: known, until: now.addingTimeInterval(10)))
    }

    /// Puts tabs that arrived for a pending join into their project. Returns the tabs joined.
    @discardableResult
    public func claimNewTabs(now: Date = .now) -> [TabRef] {
        let pending = pendingJoins.filter { $0.until >= now && project($0.project) != nil }
        var waiting: [PendingJoin] = []
        var joined: [TabRef] = []
        for join in pending {
            guard let group = group(join.host) else {
                waiting.append(join)
                continue
            }
            let fresh = group.tabs.map(\.id).filter { !join.known.contains($0) && !joined.contains(group.ref($0)) }
            // The host selects the tab it made; another device's new tab would not be selected.
            guard let tab = fresh.first(where: { $0 == group.activeTabId }) ?? fresh.first else {
                waiting.append(join)
                continue
            }
            let ref = group.ref(tab)
            apply(planner().move(ref, into: join.project, at: join.index))
            joined.append(ref)
        }
        pendingJoins = waiting
        return joined
    }

    public func toggleCollapsed(project id: String) {
        if collapsedProjects.contains(id) { collapsedProjects.remove(id) } else { collapsedProjects.insert(id) }
    }

    // MARK: Opening and closing hosts

    /// Opens a host in this window (connecting it if needed) and keeps it open. Opening an open
    /// host returns its existing connection: nothing redials.
    @discardableResult
    public func open(_ id: String) throws -> any HostConnection {
        do {
            let connection = try hosts.open(id)
            failures[id] = nil
            if !openHosts.contains(id) { openHosts.append(id) }
            return connection
        } catch {
            if hosts.record(id) != nil {
                failures[id] = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                if !openHosts.contains(id) { openHosts.append(id) }
            }
            throw error
        }
    }

    /// Reopens the hosts a window had open (launch restore). Unknown (forgotten) hosts are
    /// dropped; hosts that fail to open stay listed with the reason. Returns the ids opened.
    @discardableResult
    public func restore(_ ids: [String]) -> [String] {
        var opened: [String] = []
        for id in ids where hosts.record(id) != nil {
            do {
                try open(id)
                opened.append(id)
            } catch {
                Self.log.error("restore host \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return opened
    }

    /// Whether another window still shows a host (its connection then stays up when this
    /// window closes it). Set by the app, which knows every window.
    @ObservationIgnored public var isOpenElsewhere: (String) -> Bool = { _ in false }

    /// Closes a host in this window and drops its connection (it stays saved), unless another
    /// window still shows it.
    public func close(_ id: String) {
        composites.dropHost(id)
        openHosts.removeAll { $0 == id }
        failures[id] = nil
        collapsed.remove(id)
        // A plain-SSH host's next connection numbers its tabs afresh.
        if !outlivesTheApp(id) { windowProjects[id] = nil }
        if !isOpenElsewhere(id) { hosts.disconnect(id) }
    }

    /// Forgets a host that was removed from the saved hosts.
    public func forget(_ id: String) {
        composites.dropHost(id)
        openHosts.removeAll { $0 == id }
        failures[id] = nil
        collapsed.remove(id)
        windowProjects[id] = nil
    }

    public func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    // MARK: The unified tab order

    /// ⌘`number`: 1…8 is the tab at that position across all hosts, 9 the last tab (Ghostty and
    /// browsers). Nil when there is no such tab.
    public func tab(forShortcut number: Int) -> TabRef? {
        let all = tabs
        if number == 9 { return all.last }
        guard (1...8).contains(number), all.indices.contains(number - 1) else { return nil }
        return all[number - 1]
    }

    /// The ⌘N a tab answers to (1…8), or nil past the eighth.
    public func shortcutNumber(of ref: TabRef) -> Int? {
        guard let index = tabs.firstIndex(of: ref), index < 8 else { return nil }
        return index + 1
    }

    /// The position of a tab in the unified list (0-based).
    public func index(of ref: TabRef) -> Int? {
        tabs.firstIndex(of: ref)
    }

    /// The tab `offset` steps from `current` in the unified list, wrapping around across host
    /// boundaries (⇧⌘] is +1, ⇧⌘[ is -1). Without a current tab (or one no longer listed), the
    /// first tab of `fallbackHost`'s neighbourhood: the first (+1) or last (-1) tab overall.
    public func tab(after current: TabRef?, offset: Int) -> TabRef? {
        let all = tabs
        guard !all.isEmpty else { return nil }
        guard let current, let index = all.firstIndex(of: current) else {
            return offset >= 0 ? all.first : all.last
        }
        let count = all.count
        return all[((index + offset) % count + count) % count]
    }

    /// The host a new tab opens on when none is named: `preferred` if it can open tabs, else the
    /// first group that can.
    public func newTabHost(preferred: String?) -> String? {
        let candidates = groups.filter { $0.isLocal || $0.isReady }
        if let preferred, candidates.contains(where: { $0.id == preferred }) { return preferred }
        return candidates.first?.id
    }
}
