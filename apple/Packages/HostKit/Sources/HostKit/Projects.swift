import Foundation
import PaneLayout

/// A project's definition: a named, coloured group of tabs that may span hosts. Each host
/// holding one of its tabs keeps a copy; copies merge by `id`, the newest `updated` winning.
nonisolated public struct ProjectInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// An index into the theme's project colours (`ProjectInfo.colorCount`).
    public var color: Int
    /// The project's place among projects (ascending).
    public var order: Int64
    /// Unix milliseconds of the last rename, recolour or reorder.
    public var updated: UInt64

    public static let colorCount = 8
    public static let maxNameLength = 128
    /// The order new projects take colours in, each far in hue from the ones before (Blue,
    /// Orange, Green, Purple, Red, Cyan, Yellow, Grey), so neighbours never look alike.
    public static let colorOrder = [0, 6, 3, 1, 5, 2, 4, 7]

    public init(id: String, name: String, color: Int, order: Int64, updated: UInt64) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.updated = updated
    }

    /// Whether this copy wins over `other` (last writer wins; a tie goes to the larger name so
    /// every device picks the same one).
    func supersedes(_ other: ProjectInfo) -> Bool {
        updated != other.updated ? updated > other.updated : (name, color, order) > (other.name, other.color, other.order)
    }
}

/// A tab's place in a project.
nonisolated public struct Membership: Codable, Hashable, Sendable {
    public var project: String
    /// Position within the project (ascending), across hosts.
    public var rank: Int64

    public init(project: String, rank: Int64) {
        self.project = project
        self.rank = rank
    }
}

/// One change to a host's projects, mirroring the daemon's ops (`SetTabProject`, `PutProject`,
/// `RemoveProject`).
nonisolated public enum ProjectChange: Hashable, Sendable {
    case put(ProjectInfo)
    case setTab(TabId, Membership?)
    case remove(String)
}

/// What one host (or the window, for tabs without a daemon) knows: definitions and which of its
/// tabs are in which project. Applies changes with the daemon's rules, so an optimistic copy and
/// the daemon's answer agree.
nonisolated public struct HostProjects: Codable, Hashable, Sendable {
    public var projects: [String: ProjectInfo]
    public var members: [TabId: Membership]

    public init(projects: [String: ProjectInfo] = [:], members: [TabId: Membership] = [:]) {
        self.projects = projects
        self.members = members
    }

    public var isEmpty: Bool { projects.isEmpty && members.isEmpty }

    public mutating func apply(_ change: ProjectChange) {
        switch change {
        case .put(let info):
            if let stored = projects[info.id], stored.supersedes(info) { return }
            projects[info.id] = info
        case .setTab(let tab, let membership):
            // A membership needs its definition first (the daemon refuses it otherwise).
            if let membership, projects[membership.project] == nil { return }
            members[tab] = membership
            collect()
        case .remove(let id):
            projects[id] = nil
            members = members.filter { $0.value.project != id }
        }
    }

    /// Keeps only memberships of `tabs` (closed tabs leave) and drops definitions no tab uses.
    public mutating func keep(tabs: Set<TabId>) {
        members = members.filter { tabs.contains($0.key) }
        collect()
    }

    private mutating func collect() {
        let used = Set(members.values.map(\.project))
        projects = projects.filter { used.contains($0.key) }
    }
}

/// A project as the window shows it: the merged definition and its tabs in rank order.
nonisolated public struct Project: Identifiable, Hashable, Sendable {
    public var info: ProjectInfo
    public var tabs: [TabRef]
    public var id: String { info.id }
    public var name: String { info.name }
    public var color: Int { info.color }
    public var hosts: [String] {
        var seen: [String] = []
        for tab in tabs where !seen.contains(tab.hostId) { seen.append(tab.hostId) }
        return seen
    }
}

nonisolated public enum ProjectMerge {
    /// Merges every host's report. `sources` maps a host id to its projects; `existing` lists the
    /// tabs that exist (a membership of a closed tab is ignored). Projects come in `order`, ties
    /// by id; tabs by rank, then host and tab id, so every device draws the same list.
    public static func merge(_ sources: [String: HostProjects], existing: Set<TabRef>) -> [Project] {
        var infos: [String: ProjectInfo] = [:]
        var tabs: [String: [(ref: TabRef, rank: Int64)]] = [:]
        for (host, source) in sources {
            for (tab, membership) in source.members {
                let ref = TabRef(hostId: host, tab: tab)
                guard existing.contains(ref), let info = source.projects[membership.project] else { continue }
                if let current = infos[info.id] {
                    if info.supersedes(current) { infos[info.id] = info }
                } else {
                    infos[info.id] = info
                }
                tabs[info.id, default: []].append((ref, membership.rank))
            }
        }
        return infos.values
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
            .map { info in
                let members = (tabs[info.id] ?? []).sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                    if lhs.ref.hostId != rhs.ref.hostId { return lhs.ref.hostId < rhs.ref.hostId }
                    return lhs.ref.tab.rawValue < rhs.ref.tab.rawValue
                }
                return Project(info: info, tabs: members.map(\.ref))
            }
    }
}

/// The changes each gesture sends, per host. Pure: the caller routes each `(host, change)` to
/// the host's daemon or to the window's own store.
nonisolated public struct ProjectPlanner {
    public var projects: [Project]
    /// What each host already holds (to know where a definition must be put first).
    public var sources: [String: HostProjects]
    public var now: UInt64

    public static let rankStep: Int64 = 1024

    public init(projects: [Project], sources: [String: HostProjects], now: UInt64) {
        self.projects = projects
        self.sources = sources
        self.now = now
    }

    public typealias Change = (host: String, change: ProjectChange)

    public func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    public func project(of ref: TabRef) -> Project? { projects.first { $0.tabs.contains(ref) } }

    /// Puts `ref` into project `id` at `index` (clamped), renumbering the project's ranks.
    public func move(_ ref: TabRef, into id: String, at index: Int) -> [Change] {
        guard let target = project(id) else { return [] }
        var order = target.tabs.filter { $0 != ref }
        order.insert(ref, at: min(max(index, 0), order.count))
        return assign(order, to: target.info)
    }

    /// A new project holding `refs` in that order.
    public func create(_ refs: [TabRef], name: String, id: String = UUID().uuidString) -> [Change] {
        let info = ProjectInfo(id: id, name: name, color: nextColor, order: nextOrder, updated: now)
        var changes: [Change] = []
        // Tabs leave their old projects through the new membership; nothing else to send.
        changes += assign(refs, to: info)
        return changes
    }

    /// Takes `ref` out of its project.
    public func remove(_ ref: TabRef) -> [Change] {
        guard project(of: ref) != nil else { return [] }
        return [(ref.hostId, .setTab(ref.tab, nil))]
    }

    /// Ungroups every tab of a project.
    public func ungroup(_ id: String) -> [Change] {
        guard let target = project(id) else { return [] }
        return target.hosts.map { ($0, .remove(id)) }
    }

    /// Renames or recolours a project on every host holding one of its tabs.
    public func update(_ id: String, name: String? = nil, color: Int? = nil) -> [Change] {
        guard var info = project(id)?.info else { return [] }
        if let name { info.name = String(name.prefix(ProjectInfo.maxNameLength)) }
        if let color { info.color = color }
        info.updated = stamp(after: info)
        return project(id)!.hosts.map { ($0, .put(info)) }
    }

    /// Moves project `id` to `index` among the projects; every project whose order changes is
    /// put again on its hosts.
    public func moveProject(_ id: String, to index: Int) -> [Change] {
        guard let moving = project(id) else { return [] }
        var order = projects.filter { $0.id != id }
        order.insert(moving, at: min(max(index, 0), order.count))
        var changes: [Change] = []
        for (position, project) in order.enumerated() {
            let wanted = Int64(position) * Self.rankStep
            guard project.info.order != wanted else { continue }
            var info = project.info
            info.order = wanted
            info.updated = stamp(after: info)
            changes += project.hosts.map { ($0, .put(info)) }
        }
        return changes
    }

    /// Memberships for `order` in `info`, with the definition put first on hosts lacking it.
    private func assign(_ order: [TabRef], to info: ProjectInfo) -> [Change] {
        var changes: [Change] = []
        var defined = Set(sources.compactMap { $0.value.projects[info.id] != nil ? $0.key : nil })
        for (position, ref) in order.enumerated() {
            let membership = Membership(project: info.id, rank: Int64(position) * Self.rankStep)
            if !defined.contains(ref.hostId) {
                changes.append((ref.hostId, .put(info)))
                defined.insert(ref.hostId)
            }
            if sources[ref.hostId]?.members[ref.tab] != membership {
                changes.append((ref.hostId, .setTab(ref.tab, membership)))
            }
        }
        return changes
    }

    /// A change's time: now, but always after the copy it replaces, so two edits within one
    /// millisecond (or against a host whose clock runs ahead) still win.
    private func stamp(after info: ProjectInfo) -> UInt64 {
        max(now, info.updated + 1)
    }

    /// The first colour no project uses (in `ProjectInfo.colorOrder`), else cycling.
    var nextColor: Int {
        let used = Set(projects.map(\.color))
        let order = ProjectInfo.colorOrder
        return order.first { !used.contains($0) } ?? order[projects.count % order.count]
    }

    var nextOrder: Int64 {
        (projects.map(\.info.order).max() ?? -Self.rankStep) + Self.rankStep
    }
}

/// Tabs that could become a project: two or more loose tabs sharing a repository root or
/// working directory.
nonisolated public struct ProjectSuggestion: Hashable, Sendable, Identifiable {
    /// The shared root.
    public var key: String
    public var name: String
    public var tabs: [TabRef]
    public var id: String { key }

    public init(key: String, name: String, tabs: [TabRef]) {
        self.key = key
        self.name = name
        self.tabs = tabs
    }

    /// `roots` gives each loose tab's repository root or directory (nil: none known), in
    /// sidebar order. Home and `/` never count; dismissed keys are skipped.
    public static func find(_ roots: [(TabRef, String?)], dismissed: Set<String> = []) -> [ProjectSuggestion] {
        var order: [String] = []
        var byKey: [String: [TabRef]] = [:]
        for (ref, root) in roots {
            guard let root = root.map(ProjectNaming.normalize), !ProjectNaming.isHomeOrAbove(root, home: nil), !dismissed.contains(root)
            else { continue }
            if byKey[root] == nil { order.append(root) }
            byKey[root, default: []].append(ref)
        }
        return order.compactMap { key in
            guard let tabs = byKey[key], tabs.count >= 2 else { return nil }
            return ProjectSuggestion(key: key, name: displayName(key), tabs: tabs)
        }
    }

    static func displayName(_ key: String) -> String {
        ProjectNaming.folderName(key) ?? key
    }
}

/// How projects are named: after the repository or folder their tabs share, never after a home
/// folder or one above it (every shell starts there, so it says nothing about the work), else
/// "New Project"; and never twice the same.
nonisolated public enum ProjectNaming {
    public static let fallback = "New Project"

    /// The path of an OSC 7 working directory: `file://host/path` (percent-decoded),
    /// `kitty-shell-cwd://host/path` (Ghostty's shell integration, verbatim) or a bare path.
    /// Anything else is not a directory.
    public static func directory(fromOSC7 value: String) -> String? {
        if value.hasPrefix("/") { return value }
        for scheme in ["file://", "kitty-shell-cwd://"] where value.hasPrefix(scheme) {
            let rest = value.dropFirst(scheme.count)
            let path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
            return scheme == "file://" ? (path.removingPercentEncoding ?? path) : path
        }
        return nil
    }

    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Whether `path` is a home folder or above one: `home` and its ancestors when the host's
    /// home is known, and anywhere the usual homes and their parents (`/Users/x`, `/home/x`,
    /// `/var/home/x`, `/root`, `/Users`, `/`).
    public static func isHomeOrAbove(_ path: String, home: String?) -> Bool {
        let path = normalize(path)
        guard path.hasPrefix("/"), path != "/" else { return true }
        if let home = home.map(normalize), path == home || home.hasPrefix(path + "/") { return true }
        let parts = path.split(separator: "/")
        switch parts.count {
        case 1: return ["Users", "home", "var", "root"].contains(parts[0])
        case 2: return parts[0] == "Users" || parts[0] == "home" || parts == ["var", "home"] || parts == ["var", "root"]
        case 3: return parts[0] == "var" && parts[1] == "home"
        default: return false
        }
    }

    /// A path's last component, or nil for a home folder or above.
    public static func folderName(_ path: String, home: String? = nil) -> String? {
        guard !isHomeOrAbove(path, home: home) else { return nil }
        return normalize(path).split(separator: "/").last.map(String.init)
    }

    /// The name for tabs working in `roots` (each tab's repository root, else its folder): the
    /// folder they all share, else nil.
    public static func sharedName(_ roots: [String?], home: String? = nil) -> String? {
        let unique = Set(roots.map { $0.map(normalize) })
        guard unique.count == 1, let root = unique.first ?? nil else { return nil }
        return folderName(root, home: home)
    }

    /// The repository holding `path`: the nearest folder at or above it with a `.git`, short of
    /// home (a dotfiles repository in home is not a project).
    public static func gitRoot(of path: String, home: String?, exists: (String) -> Bool) -> String? {
        var current = normalize(path)
        while !isHomeOrAbove(current, home: home) {
            if exists(current + "/.git") { return current }
            guard let slash = current.lastIndex(of: "/") else { return nil }
            current = String(current[..<slash])
        }
        return nil
    }

    /// `base`, else "base 2", "base 3"…, whichever no name in `taken` has (ignoring case).
    public static func unique(_ base: String, taken: some Sequence<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0.lowercased()) }!
    }
}
