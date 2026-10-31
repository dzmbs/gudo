import Foundation
import Observation
import PaneLayout

// Tab history: what the app opens with, recently closed tabs (⇧⌘T), and the idle-tab
// suggestion (docs/APP-ARCHITECTURE.md §24).

// MARK: Launch

/// What a window opens with at launch (Settings ▸ General, Safari's "Safari opens with").
nonisolated public enum LaunchTabs: String, CaseIterable, Sendable {
    /// Every tab the window had (the default).
    case previous
    /// One new terminal; the other tabs keep running on their hosts, a tap away.
    case newTerminal

    public static let key = "launch-tabs"

    public var title: String {
        switch self {
        case .previous: "Your Previous Tabs"
        case .newTerminal: "A New Terminal"
        }
    }

    public static var current: LaunchTabs {
        UserDefaults.standard.string(forKey: key).flatMap(LaunchTabs.init(rawValue:)) ?? .previous
    }
}

/// What runs in a tab, for deciding whether it may stay out of sight.
nonisolated public struct TabActivity: Equatable, Sendable {
    /// An agent (Claude Code, Codex, any program reporting status) is in one of its panes.
    public var agent: Bool
    /// One of its panes runs something other than its shell at a prompt.
    public var command: Bool

    public init(agent: Bool = false, command: Bool = false) {
        self.agent = agent
        self.command = command
    }

    public var isBusy: Bool { agent || command }
}

/// The launch decision: which of the tabs a window found at launch stay hidden.
nonisolated public enum RestoreDecision {
    /// Under "A New Terminal", every tab found at launch is hidden except those running an
    /// agent or a command: running work is never put out of sight. Under "Your Previous Tabs",
    /// none.
    public static func hidden(_ found: [TabRef], setting: LaunchTabs, activity: (TabRef) -> TabActivity) -> Set<TabRef> {
        guard setting == .newTerminal else { return [] }
        return Set(found.filter { !activity($0).isBusy })
    }
}

// MARK: Recently closed

/// A project a closed tab was in, by id and by what it looked like.
nonisolated public struct ClosedProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: Int

    public init(id: String, name: String, color: Int) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// What reopening a closed tab needs. No terminal contents: names, places and ids only.
nonisolated public struct ClosedTab: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The tab's name as the sidebar showed it.
    public var title: String
    /// The name to give it back (the user's rename or its generated name), if it had one.
    public var name: String?
    public var hostId: String
    public var hostName: String
    /// The pane the host reopens (its agent resumes; a daemon host only).
    public var pane: UInt64?
    /// Its last directory.
    public var directory: String?
    /// The agent that ran there ("claude", "codex"), shown in the list.
    public var agent: String?
    public var project: ClosedProject?
    /// Its place in the project and among its host's tabs.
    public var projectIndex: Int?
    public var hostIndex: Int?
    public var closedAt: Date
    /// Tabs closed together (Close Tabs, Close 6 Idle Tabs) share one, so one Undo or ⇧⌘T
    /// brings them all back.
    public var batch: UUID?

    public init(
        id: UUID = UUID(), title: String, name: String? = nil, hostId: String, hostName: String, pane: UInt64? = nil,
        directory: String? = nil, agent: String? = nil, project: ClosedProject? = nil, projectIndex: Int? = nil,
        hostIndex: Int? = nil, closedAt: Date = .now, batch: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.name = name
        self.hostId = hostId
        self.hostName = hostName
        self.pane = pane
        self.directory = directory
        self.agent = agent
        self.project = project
        self.projectIndex = projectIndex
        self.hostIndex = hostIndex
        self.closedAt = closedAt
        self.batch = batch
    }

    /// "studio · app · 5 min ago": where it was and when it closed.
    public func subtitle(now: Date = .now) -> String {
        let age = RelativeDateTimeFormatter().localizedString(for: closedAt, relativeTo: max(now, closedAt))
        return [hostName, project?.name, age].compactMap(\.self).joined(separator: " · ")
    }
}

/// The app's recently closed tabs, newest first, kept across launches on this device only
/// (never sent to a host, so guests never see them). App-wide like Safari's History: a tab
/// closed in one window reopens in whichever window asks.
@MainActor
@Observable
public final class RecentlyClosed {
    public static let limit = 20
    public static let shared = RecentlyClosed(defaults: .standard)

    public private(set) var tabs: [ClosedTab] = []
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let key: String

    /// `defaults` nil keeps the list in memory only (tests, design fixtures).
    public init(defaults: UserDefaults?, key: String = "recently-closed-tabs") {
        self.defaults = defaults
        self.key = key
        if let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode([ClosedTab].self, from: data) {
            tabs = Array(saved.prefix(Self.limit))
        }
    }

    public func record(_ tab: ClosedTab) {
        record([tab])
    }

    /// Tabs closed at once, in the order they were closed.
    public func record(_ closed: [ClosedTab]) {
        guard !closed.isEmpty else { return }
        tabs.insert(contentsOf: closed.reversed(), at: 0)
        if tabs.count > Self.limit { tabs.removeLast(tabs.count - Self.limit) }
        save()
    }

    /// Takes one entry out (it is being reopened).
    @discardableResult
    public func take(_ id: UUID) -> ClosedTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        save()
        return tab
    }

    /// Takes the last close out (⇧⌘T): the newest tab, with every tab closed alongside it, in
    /// the order they were closed.
    public func takeLatest() -> [ClosedTab] {
        guard let newest = tabs.first else { return [] }
        let taken = newest.batch.map { batch in tabs.filter { $0.batch == batch } } ?? [newest]
        let ids = Set(taken.map(\.id))
        tabs.removeAll { ids.contains($0.id) }
        save()
        return taken.reversed()
    }

    /// Takes every tab of one close out.
    public func take(batch: UUID) -> [ClosedTab] {
        let taken = tabs.filter { $0.batch == batch }
        tabs.removeAll { $0.batch == batch }
        save()
        return taken.reversed()
    }

    /// A host was forgotten: its tabs cannot come back.
    public func forget(host id: String) {
        let before = tabs.count
        tabs.removeAll { $0.hostId == id }
        if tabs.count != before { save() }
    }

    public func removeAll() {
        tabs = []
        save()
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(try? JSONEncoder().encode(tabs), forKey: key)
    }
}

// MARK: Idle tabs

/// What the idle-tab rule knows about a tab.
nonisolated public struct TabIdleFacts: Equatable, Sendable {
    public var activity: TabActivity
    /// Every pane's shell sits at its prompt (shell integration, or the shell in front).
    public var atPrompt: Bool
    /// The last time this device showed the tab, or first saw it.
    public var touched: Date
    /// The last time any pane's foreground changed on the host (a command ran, from any device).
    public var foregroundSince: Date?

    public init(activity: TabActivity, atPrompt: Bool, touched: Date, foregroundSince: Date? = nil) {
        self.activity = activity
        self.atPrompt = atPrompt
        self.touched = touched
        self.foregroundSince = foregroundSince
    }
}

/// Tabs worth suggesting to close: idle at a prompt, untouched for `days`, nothing running.
nonisolated public enum IdleTabRule {
    public static let days = 3

    public static func isIdle(_ facts: TabIdleFacts, now: Date = .now, days: Int = days) -> Bool {
        guard !facts.activity.isBusy, facts.atPrompt else { return false }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let last = max(facts.touched, facts.foregroundSince ?? .distantPast)
        return last <= cutoff
    }
}

/// When this device last showed each tab (or first saw it), kept across launches: "untouched".
@MainActor
public final class TabTouches {
    public static let shared = TabTouches(defaults: .standard)

    private var touched: [String: Date]
    private let defaults: UserDefaults?
    private let key = "tab-touches"
    private var dirty = false

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.dictionary(forKey: key) as? [String: Double] ?? [:]
        touched = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// The tab was shown now.
    public func touch(_ ref: TabRef, now: Date = .now) {
        touched[ref.description] = now
        save()
    }

    /// When the tab was last shown, else first seen (seeing it now starts its clock).
    public func touched(_ ref: TabRef, now: Date = .now) -> Date {
        if let date = touched[ref.description] { return date }
        touched[ref.description] = now
        save()
        return now
    }

    /// Drops tabs that no longer exist on `host` (its `existing` tab ids).
    public func keep(host: String, existing: Set<TabId>) {
        let prefix = host + "/"
        let before = touched.count
        touched = touched.filter { key, _ in
            guard key.hasPrefix(prefix), let id = UInt64(key.dropFirst(prefix.count)) else { return true }
            return existing.contains(TabId(id))
        }
        if touched.count != before { save() }
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(touched.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}

// MARK: Selection

/// Tabs selected in the sidebar (Finder's model): a click selects one, ⌘-click toggles,
/// ⇧-click extends from the anchor over the rows between, ⌘A selects every visible row.
nonisolated public struct TabSelection: Equatable, Sendable {
    public private(set) var selected: Set<TabRef> = []
    /// Where ⇧-click ranges start.
    public private(set) var anchor: TabRef?

    public init() {}

    /// More than one row: bulk actions apply.
    public var isMultiple: Bool { selected.count > 1 }

    public func contains(_ ref: TabRef) -> Bool { selected.contains(ref) }

    /// A plain click: just this row (the current tab).
    public mutating func select(_ ref: TabRef) {
        selected = [ref]
        anchor = ref
    }

    /// ⌘-click: in or out of the selection. `current` is the tab on screen, which a selection
    /// starting from it includes.
    public mutating func toggle(_ ref: TabRef, current: TabRef?) {
        if selected.isEmpty, let current, current != ref { selected = [current] }
        if selected.contains(ref) {
            selected.remove(ref)
            if anchor == ref { anchor = selected.first }
        } else {
            selected.insert(ref)
            anchor = ref
        }
    }

    /// ⇧-click: every row from the anchor (else `current`) to `ref`, in `order`.
    public mutating func extend(to ref: TabRef, current: TabRef?, in order: [TabRef]) {
        let start = anchor ?? current ?? ref
        guard let from = order.firstIndex(of: start), let to = order.firstIndex(of: ref) else {
            select(ref)
            return
        }
        selected = Set(order[min(from, to)...max(from, to)])
        anchor = start
    }

    /// ⌘A: every visible row.
    public mutating func selectAll(_ order: [TabRef]) {
        selected = Set(order)
        anchor = order.first
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// Rows that went away leave the selection.
    public mutating func keep(_ existing: Set<TabRef>) {
        selected.formIntersection(existing)
        if let anchor, !existing.contains(anchor) { self.anchor = selected.first }
    }

    /// The selection in sidebar order.
    public func ordered(_ order: [TabRef]) -> [TabRef] {
        order.filter { selected.contains($0) }
    }
}
