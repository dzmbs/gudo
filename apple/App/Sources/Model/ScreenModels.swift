import DesignSystem
import Foundation

// Data the upcoming screens show, behind protocols. The views only read these types; the wiring
// (daemon, SSH, agent hooks) replaces the mocks in MockData.swift without touching a view.

// MARK: - Hosts

nonisolated enum HostKind: String, Sendable {
    /// Runs our daemon: sessions survive, agents report status.
    case daemon
    /// Plain SSH: one shell per connection.
    case ssh
    /// This device (macOS only).
    case local
}

nonisolated struct HostSummary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// `user@host:port` or a tailnet name, shown in SF Mono.
    var address: String
    var kind: HostKind
    var connection: ConnectionState
    var sessionCount: Int
    var agentCounts: [AgentState: Int]
    /// The one-line reason this host needs the user ("Claude wants to run `rm -rf build`").
    var needsYou: String?
    /// The last line of output of its most recent session.
    var lastLine: String?
    var lastSeen: Date
    var isPinned: Bool

    var needsYouCount: Int { (agentCounts[.blocked] ?? 0) + (agentCounts[.error] ?? 0) }
}

@MainActor
protocol HostDirectory: AnyObject, Observable {
    var hosts: [HostSummary] { get }
    func connect(_ id: HostSummary.ID)
    func forget(_ id: HostSummary.ID)
    func togglePin(_ id: HostSummary.ID)
    /// `user@host[:port]` typed into the quick-connect field.
    func quickConnect(_ destination: String)
    /// A pairing ticket pasted or scanned from another device's QR code.
    func pair(ticket: String) async throws -> HostSummary
}

// MARK: - Agents

nonisolated enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex, other

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .other: "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .other: "terminal"
        }
    }
}

nonisolated struct AgentItem: Identifiable, Hashable, Sendable {
    enum Request: Hashable, Sendable {
        /// A tool call waiting for approval, e.g. a shell command.
        case permission(tool: String, detail: String)
        /// A free-text question the agent asked.
        case question(String)
    }

    var id: String
    var agent: AgentKind
    var hostName: String
    var sessionTitle: String
    var state: AgentState
    /// When the current state began.
    var since: Date
    /// The prompt the agent is working on.
    var prompt: String
    var request: Request?
    /// One-line result summary for done/failed items.
    var summary: String?
}

@MainActor
protocol AgentFeed: AnyObject, Observable {
    var items: [AgentItem] { get }
    func approve(_ id: AgentItem.ID)
    func deny(_ id: AgentItem.ID)
    func reply(_ id: AgentItem.ID, text: String)
    func markDone(_ id: AgentItem.ID)
    func launch(_ agent: AgentKind, host: String, prompt: String)
}

// MARK: - Panes: status, links, search

@MainActor
protocol PaneStatusSource: AnyObject, Observable {
    /// What the program in a pane reports (OSC 7501 / agent hooks); nil for a plain shell.
    func state(of pane: String) -> AgentState?
    /// The foreground program's name, for the sidebar's pane rows.
    func program(of pane: String) -> String?
}

nonisolated struct DetectedLink: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case url, path }
    var id: String { text }
    var kind: Kind
    /// As printed, e.g. `src/app.rs:42:7` or `https://…`.
    var text: String
    /// Line in the scrollback it was last seen on (negative = above the viewport).
    var line: Int
}

// MARK: - Files and diffs

nonisolated struct FileEntry: Identifiable, Hashable, Sendable {
    enum GitStatus: String, Sendable { case modified = "M", added = "A", deleted = "D", untracked = "U", renamed = "R" }
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var modified: Date?
    var git: GitStatus?
}

@MainActor
protocol FileSource: AnyObject {
    var root: String { get }
    func list(_ directory: String) async throws -> [FileEntry]
    func read(_ path: String) async throws -> String
}

nonisolated struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case context, added, removed }
    var id: Int
    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}

nonisolated struct DiffHunk: Identifiable, Hashable, Sendable {
    var id: Int
    var header: String
    var lines: [DiffLine]
}

nonisolated struct DiffFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var status: FileEntry.GitStatus
    var additions: Int
    var deletions: Int
    var hunks: [DiffHunk]
}

@MainActor
protocol DiffSource: AnyObject {
    /// What the diff is against, e.g. "Working tree vs HEAD".
    var title: String { get }
    func files() async throws -> [DiffFile]
}
