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
                tabs: session.tabs.filter { !(carriers[Self.localId]?.contains($0.id) ?? false) },
                activeTabId: session.activeTabId, isReady: true))
        }
        for id in hostOrder {
            guard let record = hosts.record(id) else { continue }
            let connection = hosts.connection(id)
            let ready = connection?.isReady ?? false
            let session = ready ? connection?.layoutStore.session : nil
            var status = connection?.status ?? .idle
            if connection == nil, let failure = failures[id] { status = .needsAttention(reason: failure) }
            result.append(HostGroup(
                id: id, name: record.name, kind: record.kind == .daemon ? .daemon : .ssh, status: status,
                tabs: (session?.tabs ?? []).filter { !(carriers[id]?.contains($0.id) ?? false) },
                activeTabId: session?.activeTabId, isReady: ready,
                failure: connection == nil ? failures[id] : nil))
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

    /// What a window saves of its projects.
    public struct ProjectsState: Codable, Equatable, Sendable {
        public var windowProjects: [String: HostProjects]
        public var collapsed: [String]
        public var dismissed: [String]
    }

    public var projectsState: ProjectsState {
        get { ProjectsState(windowProjects: windowProjects, collapsed: collapsedProjects.sorted(), dismissed: dismissedSuggestions.sorted()) }
        set {
            windowProjects = newValue.windowProjects
            collapsedProjects = Set(newValue.collapsed)
            dismissedSuggestions = Set(newValue.dismissed)
        }
    }

    /// Every project in the window, merged across hosts.
    public var projects: [Project] { projects(in: groups) }

    public func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    public func project(of ref: TabRef) -> Project? { projects.first { $0.tabs.contains(ref) } }

    private func projects(in groups: [HostGroup]) -> [Project] {
        let (sources, existing) = projectSources(groups)
        return ProjectMerge.merge(sources, existing: existing)
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
        let (sources, existing) = projectSources(groups)
        return ProjectPlanner(
            projects: ProjectMerge.merge(sources, existing: existing), sources: sources,
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
        guard !copies.isEmpty else { return }
        // Pruned once all changes are in: a definition is put before its first member joins.
        let tabsByHost = Dictionary(grouping: tabRefsForPruning(), by: \.hostId).mapValues { Set($0.map(\.tab)) }
        for (host, var copy) in copies {
            copy.keep(tabs: tabsByHost[host] ?? [])
            windowProjects[host] = copy.isEmpty ? nil : copy
        }
    }

    private func tabRefsForPruning() -> [TabRef] {
        groups.flatMap { group in group.tabs.map { group.ref($0.id) } } + mixedTabs
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

    /// Carries out a drop. `name` names a new project made of two tabs.
    public func commit(_ drop: SidebarDrop, name: (TabRef, TabRef) -> String) {
        let planner = planner()
        switch drop {
        case .group(let ref, let target):
            if let project = planner.project(of: target) {
                let index = (project.tabs.filter { $0 != ref }.firstIndex(of: target) ?? project.tabs.count) + 1
                apply(planner.move(ref, into: project.id, at: index))
            } else {
                apply(planner.create([target, ref], name: name(target, ref)))
            }
        case .insert(let ref, .project(let id), let index):
            apply(planner.move(ref, into: id, at: index))
        case .insert(let ref, .window, _):
            apply(planner.remove(ref))
        case .insert(let ref, .host(let host), let index):
            guard ref.hostId == host, let group = group(host) else { return }
            apply(planner.remove(ref))
            var loose = sections.first { $0.container == .host(host) }?.rows.filter { $0 != ref } ?? []
            loose.insert(ref, at: min(max(index, 0), loose.count))
            if let store = layoutStore(host),
               let to = SidebarDrop.sessionIndex(for: ref.tab, loose: loose.map(\.tab), session: group.tabs.map(\.id))
            {
                store.apply(.moveTab(ref.tab, to: to))
            }
        }
    }

    /// Moves a tab one row up (-1) or down (+1) within its section (⌃⌘↑ / ⌃⌘↓).
    public func moveTab(_ ref: TabRef, by offset: Int) {
        guard let section = sections.first(where: { $0.rows.contains(ref) }),
              let index = section.rows.firstIndex(of: ref)
        else { return }
        let to = index + offset
        guard section.rows.indices.contains(to) else { return }
        commit(.insert(ref, into: section.container, at: to), name: { _, _ in "" })
    }

    /// The layout a host's tabs live in.
    func layoutStore(_ host: String) -> (any LayoutStore)? {
        if host == Self.localId { return local?.layout }
        guard let connection = hosts.connection(host), connection.isReady else { return nil }
        return connection.layoutStore
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
