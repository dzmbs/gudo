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
    /// This device: a login shell on the Mac, the scratch echo on iPhone and iPad.
    case local
}

/// What a host row and the window's notice say about the host's helper version.
nonisolated struct HelperOffer: Hashable, Sendable {
    /// One line: "A newer helper is available.", "This host's helper is too old for this app…".
    var message: String
    /// The app cannot work with the helper until it is updated (or the app is).
    var required: Bool
    /// "Update Helper" can do it from here.
    var canUpdate: Bool
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
    /// The one-line reason this host needs the user ("Claude wants to run `rm -rf build`", a
    /// refused pairing, a failed login).
    var needsYou: String?
    /// The last line of output of its most recent session.
    var lastLine: String?
    var lastSeen: Date
    var isPinned: Bool
    /// The connection in words ("Connected · 64 ms"), when there is more to say than the dot.
    var statusLine: String?
    /// A helper install in progress, in words ("Uploading helper (1.2 MB sent…)").
    var progress: String?
    /// A plain-SSH host that can be upgraded to the daemon ("Install Helper").
    var canInstallHelper = false
    /// The host's helper is older than the app's, or cannot work with it ("Update Helper").
    var helper: HelperOffer?

    var needsYouCount: Int {
        max((agentCounts[.blocked] ?? 0) + (agentCounts[.error] ?? 0), needsYou == nil ? 0 : 1)
    }

    /// This device's own shell: it cannot be forgotten, pinned or renamed.
    var isLocal: Bool { kind == .local }
}

@MainActor
protocol HostDirectory: AnyObject, Observable {
    var hosts: [HostSummary] { get }
    /// The device has no network; hosts resume when it is back.
    var isOffline: Bool { get }
    /// Opens the host in this window.
    func connect(_ id: HostSummary.ID)
    func forget(_ id: HostSummary.ID)
    func togglePin(_ id: HostSummary.ID)
    func rename(_ id: HostSummary.ID, to name: String)
    /// Redial now and reset the backoff (04-mobile-ux R9).
    func retry(_ id: HostSummary.ID)
    /// Drops the connection; the host stays saved.
    func disconnect(_ id: HostSummary.ID)
    /// Upgrades a plain-SSH host to the daemon (upload, start, pair) and switches to it.
    func installHelper(_ id: HostSummary.ID) async throws
    /// Updates a daemon host's helper to the app's build (over SSH or the connection); returns
    /// once the host is back.
    func updateHelper(_ id: HostSummary.ID) async throws
    /// `user@host[:port]` typed into the quick-connect field: asks how to sign in, then connects.
    func quickConnect(_ destination: String)
    /// A pairing ticket pasted, scanned from the host's QR code or from a deep link; returns the
    /// paired host's id.
    func pair(ticket: String, name: String?) async throws -> HostSummary.ID
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
    /// The host and pane it runs in (live items); nil for mock items and for finished history
    /// whose pane is gone.
    var hostId: String?
    var paneId: UInt64?
    /// The host's attention feed has not shown this on any device yet.
    var unseen = false
    /// A live agent pane: Reply types into it through the composer path.
    var canReply = false
    /// A long command that finished unseen (attention feed), not an agent.
    var isCommand = false
}

/// A host an agent can start on (a connected daemon).
nonisolated struct LaunchHost: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Where a plain launch runs: the focused pane's directory there.
    var directory: String?
}

/// What "New Agent" starts.
nonisolated struct AgentLaunchRequest: Hashable, Sendable {
    var agent: AgentKind
    var hostId: String
    var prompt: String
    /// Run in a fresh git worktree (its own branch and `PORT`).
    var worktree = false
    /// The worktree's branch; nil derives it from `name`.
    var branch: String?
    /// The task's name: the new tab's and the worktree's (a friendly generated one by default).
    var name: String?
    /// The repository (any directory in it) for the worktree; the focused pane's when nil.
    var repo: String?
    /// Open a shell instead of starting `agent`.
    var shell = false
}

@MainActor
protocol AgentFeed: AnyObject, Observable {
    var items: [AgentItem] { get }
    /// Unseen attention items per host name, only hosts with any.
    var unseenByHost: [String: Int] { get }
    /// Connected daemons an agent can start on.
    var launchHosts: [LaunchHost] { get }
    func approve(_ id: AgentItem.ID)
    func deny(_ id: AgentItem.ID)
    /// Types `text` into the agent's pane (composer path) and submits it.
    func reply(_ id: AgentItem.ID, text: String) async throws
    func markDone(_ id: AgentItem.ID)
    /// The inbox is on screen: what it shows counts as seen, on every device.
    func markSeen()
    /// Shows the agent's pane in this window.
    func open(_ id: AgentItem.ID)
    /// Starts Claude Code or Codex in a new pane; returns a note when the first prompt could not
    /// be typed (the pane runs either way).
    func launch(_ request: AgentLaunchRequest) async throws -> String?
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
    /// Line in the scrollback it was last seen on (negative = above the viewport; 0 = on screen).
    var line: Int
    /// What it points at: the URL, or the path resolved against the pane's directory.
    var target: String? = nil
    /// `path:line:col` positions.
    var targetLine: Int? = nil
    var targetColumn: Int? = nil
    /// For a path: whether it exists on the host (nil: not checked).
    var exists: Bool? = nil
    /// Found in the output of a finished command rather than on screen.
    var fromCommand = false

    /// The resolved target, else the text as printed.
    var resolved: String { target ?? text }
}

/// The focused pane's links, its last command's output, and search over its whole scrollback
/// (the daemon's pane RPCs, DAEMON.md "Search and links").
@MainActor
protocol LinkSource: AnyObject {
    /// Whether the focused pane can answer (a daemon pane).
    var isAvailable: Bool { get }
    func links() async throws -> [DetectedLink]
    /// The last finished command and its output (`command`, `output`).
    func lastCommandOutput() async throws -> (command: String?, output: String)
    /// How many matches `needle` has in the focused pane's scrollback (nil when unknown).
    func countMatches(_ needle: String) async throws -> Int?
}

// MARK: - Files

nonisolated struct FileEntry: Identifiable, Hashable, Sendable {
    enum GitStatus: String, Sendable { case modified = "M", added = "A", deleted = "D", untracked = "U", renamed = "R" }
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var modified: Date?
    var git: GitStatus?
    var isSymlink = false
    var isHidden = false
}

/// What a file shows in the preview.
nonisolated enum FilePreview: Hashable, Sendable {
    /// UTF-8 text (`truncated` past the first MiB).
    case text(String, truncated: Bool)
    /// An image's bytes.
    case image(Data)
    /// Neither: name, size and a download.
    case binary(size: Int64)
}

/// A directory watch; `cancel()` ends it.
@MainActor
final class FileWatch {
    private let onCancel: () -> Void
    private var cancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}

@MainActor
protocol FileSource: AnyObject {
    /// Where browsing starts: the focused pane's directory (`~` without one).
    var root: String { get }
    /// The host the files are on, for titles ("studio").
    var hostName: String { get }
    /// Nil when files can be browsed; else why not, in words.
    var unavailableReason: String? { get }
    func list(_ directory: String) async throws -> [FileEntry]
    func read(_ path: String) async throws -> String
    func preview(_ path: String) async throws -> FilePreview
    func mkdir(_ path: String) async throws
    func rename(_ path: String, to name: String) async throws
    /// Moves to the host's trash (`~/.Trash`, the XDG trash).
    func trash(_ path: String) async throws
    /// Uploads a local file into `directory`; `progress` gets 0…1.
    func upload(_ local: URL, to directory: String, progress: @escaping @MainActor (Double) -> Void) async throws
    /// Downloads into a temporary file and returns it (share sheet / Save to Files).
    func download(_ path: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL
    /// Calls `onChange` when the directory's entries change (not recursive).
    func watch(_ directory: String, onChange: @escaping @MainActor () -> Void) async -> FileWatch?
    /// A path as the user reads it: the host's home as `~`.
    func display(_ path: String) -> String
}

extension FileSource {
    func display(_ path: String) -> String { path }
}

// MARK: - Diffs

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
    /// Previous path of a rename.
    var oldPath: String? = nil
    var isBinary = false
    /// Hunks left out (over the 1 MiB per-file cap).
    var hunksOmitted = false
}

/// What a review compares.
nonisolated enum DiffScope: Hashable, Sendable {
    /// Everything not committed: HEAD vs the working tree (untracked included).
    case workingTree
    /// What is staged: HEAD vs the index.
    case staged
    /// What one agent turn changed (`listTurns` / `turnDiff`).
    case turn(pane: UInt64, turn: UInt64)
}

/// One agent turn with its snapshot pair.
nonisolated struct DiffTurn: Identifiable, Hashable, Sendable {
    var id: String { "\(pane)/\(turn)" }
    var pane: UInt64
    var turn: UInt64
    /// "Claude Code" etc.
    var agent: String
    var started: Date
    var ended: Date?
    var scope: DiffScope { .turn(pane: pane, turn: turn) }
}

/// A note on lines of a diff, sent to the agent as a numbered review prompt.
nonisolated struct ReviewNote: Identifiable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var startLine: Int
    var endLine: Int
    /// The line numbers are the old side's (a removed line).
    var oldSide: Bool
    var quote: String?
    var note: String
}

/// The repository a review is about.
nonisolated struct DiffRepository: Hashable, Sendable {
    var root: String
    var branch: String?
    var ahead: Int = 0
    var behind: Int = 0
    var changedFiles: Int = 0
}

@MainActor
protocol DiffSource: AnyObject {
    /// What the diff is against, e.g. "Working tree vs HEAD".
    var title: String { get }
    /// Nil when there is a repository to review; else why not, in words.
    var unavailableReason: String? { get }
    func repository() async throws -> DiffRepository
    func files(_ scope: DiffScope) async throws -> [DiffFile]
    /// Turns of the agents in this repository, newest first.
    func turns() async throws -> [DiffTurn]
    /// The agent that review notes go to for a scope, by name ("Claude Code"), or nil.
    func reviewer(for scope: DiffScope) -> String?
    /// Types the notes into the agent as one numbered prompt and submits it.
    func sendReview(_ notes: [ReviewNote], scope: DiffScope, preamble: String?) async throws
}

// MARK: - Editor

/// Where the editor is, in words the progress view shows.
nonisolated enum EditorPhase: Hashable, Sendable {
    case idle
    /// Microsoft's licence terms for this host have not been accepted yet: the first-use sheet
    /// is up, and nothing of Microsoft's is installed or started until the user accepts.
    case needsLicence
    /// Asking the host what it has.
    case checking
    /// First run: VS Code's CLI is downloading on the host.
    case installing
    /// The server is starting in the folder.
    case starting
    /// Remote Tunnel (opt-in): the tunnel is starting or connecting.
    case connectingTunnel
    /// Remote Tunnel: the host waits for the user to sign in with this device code (in their
    /// own browser; the app never completes it).
    case signingIn(EditorDeviceCode)
    /// The workbench is loading in the web view.
    case loading(URL)
    case ready(URL)
    case failed(String)

    var url: URL? {
        switch self {
        case .loading(let url), .ready(let url): url
        default: nil
        }
    }
}

/// How the editor reaches the host.
nonisolated enum EditorMode: Hashable, Sendable {
    /// `code serve-web` over our direct forward: the default, never a sign-in.
    case server
    /// VS Code Remote Tunnels through vscode.dev: opt-in, signed in with the user's own GitHub or
    /// Microsoft account.
    case tunnel
}

/// The account a Remote Tunnel signs in with.
nonisolated enum EditorTunnelAccount: String, Hashable, Sendable, CaseIterable {
    case github, microsoft

    var title: String {
        switch self {
        case .github: "GitHub"
        case .microsoft: "Microsoft"
        }
    }
}

/// A device-code sign-in the host is waiting for (Remote Tunnel only).
nonisolated struct EditorDeviceCode: Hashable, Sendable {
    var account: EditorTunnelAccount
    /// Where the user enters the code (`github.com/login/device`, `microsoft.com/devicelogin`).
    var verificationURL: URL
    var code: String
}

/// VS Code for the window's project: `code serve-web` over a forward to the host by default
/// (never a sign-in); the Remote Tunnel through vscode.dev when the user picks it.
@MainActor
protocol EditorSource: AnyObject, Observable {
    var phase: EditorPhase { get }
    /// Which path the editor took.
    var mode: EditorMode { get }
    /// The user accepted Microsoft's licence terms for this host in the first-use sheet:
    /// remember it for the host and go on with what was asked.
    func acceptLicence() async
    /// The user cancelled the first-use sheet: nothing is installed or started.
    func declineLicence()
    /// Opens the folder through a VS Code Remote Tunnel instead (opt-in; the host signs in with
    /// the user's own account by device code).
    func openTunnel(account: EditorTunnelAccount) async
    /// Desktop VS Code's URI for what the tunnel shows (`vscode://vscode-remote/tunnel+…`).
    var tunnelDesktopURI: URL? { get }
    /// The folder the editor shows.
    var folder: String { get }
    var hostName: String { get }
    /// Nil when the editor can open; else why not.
    var unavailableReason: String? { get }
    /// Starts (or reuses) the editor for the window's folder.
    func open() async
    /// Opens a file at a line in the running editor (starting it first if needed).
    func open(path: String, line: Int?, column: Int?) async
    /// The workbench finished loading.
    func didLoad()
    /// Leaves the editor; `stopServer` also ends it on the host.
    func close(stopServer: Bool) async
    /// A URL the web view should load next (a file opened in a window not showing yet).
    var pendingURL: URL? { get }
}

// MARK: - Ports and the browser

nonisolated struct DetectedPort: Identifiable, Hashable, Sendable {
    var id: UInt16 { port }
    var port: UInt16
    /// The listening process ("node", "python3").
    var process: String
    /// The URL it printed, if any.
    var url: String?
    var isHTTP: Bool
    /// Bound only on the host's loopback.
    var loopbackOnly: Bool
    /// The pane it belongs to, by title.
    var pane: String?
}

@MainActor
protocol PortSource: AnyObject, Observable {
    var ports: [DetectedPort] { get }
    var hostName: String { get }
    /// A port that appeared since the user last looked (the "open it?" offer).
    var offer: DetectedPort? { get }
    func dismissOffer()
    /// A local URL for the port: a forward to the host's `localhost:<port>`, on the same port
    /// number when it is free here so the app's own absolute URLs keep working.
    func open(_ port: DetectedPort) async throws -> URL
}
