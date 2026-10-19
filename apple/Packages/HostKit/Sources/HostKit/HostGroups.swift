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
    public static let localId = "local"

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

    private static let log = Logger(subsystem: Log.subsystem, category: "hosts")

    public init(hosts: HostsModel, local: Local? = nil) {
        self.hosts = hosts
        self.local = local
    }

    // MARK: Groups

    /// This device (when it has a shell), then the open hosts, then any other host connected in
    /// this app (opened from another window, a deep link), each in a stable order.
    public var groups: [HostGroup] {
        var result: [HostGroup] = []
        if let local {
            let session = local.layout.session
            result.append(HostGroup(
                id: Self.localId, name: local.name, kind: .local, status: .connected(rtt: nil),
                tabs: session.tabs, activeTabId: session.activeTabId, isReady: true))
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
                tabs: session?.tabs ?? [], activeTabId: session?.activeTabId, isReady: ready,
                failure: connection == nil ? failures[id] : nil))
        }
        return result
    }

    /// The open hosts, then hosts connected elsewhere in the app, in saved-host order.
    private var hostOrder: [String] {
        let others = hosts.records.map(\.id).filter { !openHosts.contains($0) && hosts.connections[$0] != nil }
        return openHosts + others
    }

    public func group(_ id: String) -> HostGroup? {
        groups.first { $0.id == id }
    }

    /// Every tab of every group in sidebar order: the unified list ⌘1…⌘9 and ⇧⌘[ ] walk. A
    /// daemon's tabs follow its repository grouping (tabs outside a repository, then by
    /// repository and worktree), as the sidebar draws them.
    public var tabs: [TabRef] {
        groups.flatMap { group -> [TabRef] in
            if let sidebar = repoSidebar(for: group) {
                return sidebar.orderedTabs.map { group.ref($0) }
            }
            return group.tabs.map { group.ref($0.id) }
        }
    }

    /// A daemon group's tabs grouped by repository and worktree, once the daemon has sent its
    /// repository snapshot (nil otherwise: draw the tabs flat).
    public func repoSidebar(for group: HostGroup) -> RepoSidebar? {
        guard group.kind == .daemon,
              let connection = hosts.connection(group.id) as? DaemonConnection,
              let snapshot = connection.existingWorkspace?.repos,
              !snapshot.worktrees.isEmpty
        else { return nil }
        return RepoSidebar.build(tabs: group.tabs, snapshot: snapshot)
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

    /// Closes a host in this window and drops its connection (it stays saved).
    public func close(_ id: String) {
        openHosts.removeAll { $0 == id }
        failures[id] = nil
        collapsed.remove(id)
        hosts.disconnect(id)
    }

    /// Forgets a host that was removed from the saved hosts.
    public func forget(_ id: String) {
        openHosts.removeAll { $0 == id }
        failures[id] = nil
        collapsed.remove(id)
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
