import Foundation
import Observation
import os
import GudoCore

/// The developer-workflow half of `GudoCore.DaemonClient` the app uses (docs/DAEMON.md §5,
/// docs/APPLE-FFI.md "Workspace", "Editor"), so the screens' models can be tested against a
/// fake. The names are the generated ones: `DaemonClient` conforms as is.
nonisolated public protocol DaemonWorkspaceAPI: AnyObject, Sendable {
    // Ports and forwards
    func ports() -> [PortInfo]
    func listPorts() async throws -> [PortInfo]
    func forward(localPort: UInt16, target: ForwardTarget) throws -> UInt16
    func stopForward(localPort: UInt16) -> Bool
    func forwards() -> [ForwardInfo]

    // Git, turns, review
    func gitStatus(path: String) async throws -> GitStatus
    func gitDiff(request: GitDiffRequest) async throws -> GitDiff
    func listTurns(paneId: UInt64) async throws -> [TurnInfo]
    func turnDiff(paneId: UInt64, turn: UInt64?, context: UInt32, hunks: Bool) async throws -> GitDiff
    func sendReview(review: ReviewRequest) async throws -> String

    // Agents
    func launchAgentPane(launch: AgentLaunch) async throws -> AgentLaunched
    func worktreeCreate(create: WorktreeCreate) async throws -> WorktreeInfo
    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32
    func decide(requestId: UInt64, optionId: UInt32)

    // Files
    func fsList(path: String, showHidden: Bool) async throws -> DirListing
    func fsStat(path: String) async throws -> FileStat
    func fsRead(path: String, offset: UInt64, len: UInt32) async throws -> FileChunk
    func fsWrite(target: WriteTarget, data: Data) async throws -> FileStat
    func fsMkdir(path: String, parents: Bool) async throws -> FileStat
    func fsRename(from: String, to: String, overwrite: Bool) async throws -> FileStat
    func fsDelete(path: String, mode: DeleteMode, recursive: Bool) async throws
    func fsWatch(path: String) async throws -> UInt64
    func fsUnwatch(watchId: UInt64) async throws
    func uploadFile(localPath: String, target: WriteTarget, progress: TransferProgress?) async throws -> FileStat
    func downloadFile(remotePath: String, localPath: String, offset: UInt64, len: UInt64?, progress: TransferProgress?) async throws -> FileStat

    // Attention
    func attentionList() async throws -> AttentionList
    func attentionSeen(seen: AttentionSeen) async throws -> AttentionList

    // Editor (serve-web over a forward; never a sign-in)
    func editorStatus() async throws -> EditorList
    func openEditor(folder: String, acceptVscodeLicense: Bool) async throws -> EditorSession
    func closeEditor(session: EditorSession, stopServer: Bool) async throws
    func editorOpenInSession(session: EditorSession, path: String, line: UInt32?, column: UInt32?) async throws -> String?

    // Pane RPCs answered as `ClientEvent`s (search, links, commands, command output)
    func links(paneId: UInt64, commands: UInt16) -> UInt64
    func commands(paneId: UInt64) -> UInt64
    func commandOutput(paneId: UInt64, commandId: UInt64?) -> UInt64
    func search(paneId: UInt64, query: SearchQuery, cursor: UInt32, limit: UInt32) -> UInt64
}

extension DaemonClient: DaemonWorkspaceAPI {}

/// The repository root of a path without a `git status` (helpers that `offersRepoRoot`).
nonisolated public protocol DaemonRepoRootAPI: AnyObject, Sendable {
    func offersRepoRoot() -> Bool
    func repoRoot(path: String) async throws -> String?
}

extension DaemonClient: DaemonRepoRootAPI {}

extension DaemonWorkspaceAPI {
    /// The repository root holding `path`, nil outside one or when the host cannot say.
    public func repositoryRoot(of path: String) async -> String? {
        if let roots = self as? any DaemonRepoRootAPI, roots.offersRepoRoot() {
            return try? await roots.repoRoot(path: path)
        }
        return try? await gitStatus(path: path).root
    }
}

/// Agent plan usage (daemons whose `DaemonInfo.agentUsage` is true). Kept out of
/// `DaemonWorkspaceAPI`'s list so fakes that do not care need nothing.
nonisolated public protocol DaemonUsageAPI: AnyObject, Sendable {
    func usageWatch() async throws -> AgentUsageReport
    func usageUnwatch() async throws
}

extension DaemonClient: DaemonUsageAPI {}

/// Paths a pane printed, resolved where the printing command ran (daemons that offer it).
nonisolated public protocol DaemonPathAPI: AnyObject, Sendable {
    func resolvePaths(paneId: UInt64, commandId: UInt64?, paths: [String]) async throws -> [ResolvedPath]
    func offersResolvePaths() -> Bool
}

extension DaemonClient: DaemonPathAPI {}

/// Whether each agent's command is on the host (helpers too old to check answer
/// `Unavailable` without being asked).
nonisolated public protocol DaemonAgentInstallAPI: AnyObject, Sendable {
    func agentInstalls() async throws -> [AgentInstall]
    /// The vendors' commands that add the host's MCP server to each installed agent's
    /// user-wide configuration (`register`), or remove it; nothing runs (`agentMcp` helpers).
    func agentMcpCommands(register: Bool) async throws -> [AgentMcpCommand]
}

extension DaemonClient: DaemonAgentInstallAPI {}

/// The VS Code Remote Tunnel: the opt-in fallback editor path (vscode.dev, signed in with the
/// user's own GitHub or Microsoft account by device code). Kept out of `DaemonWorkspaceAPI`'s
/// list so fakes that do not care need nothing; the state arrives as `vsCodeTunnel` pushes.
nonisolated public protocol DaemonTunnelAPI: AnyObject, Sendable {
    func vscodeTunnelStatus() async throws -> VsCodeTunnelStatus
    func vscodeCliInstall(acceptLicense: Bool) async throws -> VsCodeTunnelStatus
    func vscodeTunnelStart(start: VsCodeTunnelStart) async throws -> VsCodeTunnelStatus
    func vscodeTunnelStop() async throws -> VsCodeTunnelStatus
    func vscodeTunnelOpen(open: VsCodeTunnelOpen) async throws -> VsCodeTunnelOpened
}

extension DaemonClient: DaemonTunnelAPI {}

/// A repository's worktrees with their `PORT` (`WorktreeList`, docs/DAEMON.md §5.5). The
/// repository push (`RepoSnapshot`) does not carry ports and its structs are frozen on the wire,
/// so the hub asks when a repository's set of worktrees changes. Kept out of `DaemonRepoAPI`
/// so fakes that do not care need nothing.
nonisolated public protocol DaemonWorktreeListAPI: AnyObject, Sendable {
    func worktreeList(repo: String) async throws -> [WorktreeInfo]
}

extension DaemonClient: DaemonWorktreeListAPI {}

/// One daemon's workspace pushes and pane RPCs, shared by every window and screen: detected
/// ports, the attention feed with its unseen count, directory watches, and the request/answer
/// pairing for `links` / `search` / `commandOutput` (answers arrive as `ClientEvent`s).
///
/// One per `DaemonConnection` (`connection.workspace`). Pushes come from the connection's shared
/// `workspaceEvents` hub (the daemon takes one `WorkspaceListener` per connection; never set
/// another); `observePorts` / `observeAttention` relay the parsed state to other screens.
@MainActor
@Observable
public final class DaemonWorkspace {
    public let hostId: String
    /// Listening ports on the host, as last pushed (`PortsChanged`).
    public private(set) var ports: [PortInfo] = []
    /// The attention feed, newest first (the daemon keeps the last 500, in memory).
    public private(set) var attention: [AttentionItem] = []
    /// Unseen attention items: the host's inbox badge.
    public private(set) var unseen = 0
    /// Bumped on each (re)connect, so screens can reload.
    public private(set) var generation = 0
    /// The host's agents' plan usage, while something shows it (`beginWatchingUsage`); nil when
    /// not watched, not offered by the daemon, not allowed (guests) or not answered yet.
    public private(set) var usage: AgentUsageReport?
    /// Whether the daemon answers usage requests (its `DaemonInfo.agentUsage`).
    @ObservationIgnored public var supportsUsage: () -> Bool = { false }
    /// The host's agent accounts (`Accounts.swift`), as last pushed or read; nil until then,
    /// for guests and for daemons without accounts.
    public internal(set) var accounts: AccountsReport?
    /// Usage per account, while usage is watched.
    public internal(set) var accountUsage: AccountUsageReport?
    /// Whether the daemon keeps accounts (its `DaemonInfo.accounts`).
    @ObservationIgnored public var supportsAccounts: () -> Bool = { false }
    @ObservationIgnored var accountsLoading = false
    @ObservationIgnored private var usageViewers = 0
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    /// A watch was sent on this connection (so stopping must say so).
    @ObservationIgnored private var usageWatchSent = false
    /// Repositories, worktrees, branches and pull requests of the host's panes, as last pushed
    /// (`WorkspaceEvent.repos`); nil until the first snapshot.
    public internal(set) var repos: RepoSnapshot?
    /// Each worktree's `PORT` (the daemon gives one to every worktree it made), by the
    /// snapshot's worktree path; see `port(ofWorktree:)`.
    public private(set) var worktreePorts: [String: UInt16] = [:]
    /// The worktree paths of each repository the ports were last read for.
    @ObservationIgnored private var worktreePortsLoaded: [String: Set<String>] = [:]
    /// The workflow files' revision as last pushed (`WorkspaceEvent.workflowsChanged`); lists
    /// read before it are stale. See `Workflows.swift`.
    public internal(set) var workflowsRev: UInt64 = 0
    @ObservationIgnored var workflowObservers: [UUID: (UInt64) -> Void] = [:]
    @ObservationIgnored var timelineChannels: [UInt64: TimelineChannel] = [:]

    @ObservationIgnored private let resolve: () -> (any DaemonWorkspaceAPI)?
    @ObservationIgnored private var installedOn: ObjectIdentifier?
    @ObservationIgnored private var watches: [UInt64: (path: String, handler: (FsChange) -> Void)] = [:]
    @ObservationIgnored private var pending: [UInt64: CheckedContinuation<ClientEvent, Never>] = [:]
    @ObservationIgnored private var hubToken: UUID?
    @ObservationIgnored private weak var hub: WorkspaceEventHub?
    @ObservationIgnored private var portObservers: [UUID: ([PortInfo]) -> Void] = [:]
    @ObservationIgnored private var attentionObservers: [UUID: (AttentionUpdate) -> Void] = [:]
    @ObservationIgnored private var markObservers: [UUID: (CommandMark) -> Void] = [:]
    @ObservationIgnored private var tunnelObservers: [UUID: (VsCodeTunnelStatus) -> Void] = [:]
    /// The host's VS Code tunnel, as last pushed (nil until one is).
    public private(set) var vsCodeTunnel: VsCodeTunnelStatus?
    /// Each pane's running shell command (OSC 133), from the attached session's command
    /// marks and the command lists screens ask for; the sidebar shows how long it has run.
    public private(set) var runningCommands: [UInt64: CommandMark] = [:]

    private static let log = Logger(subsystem: Log.subsystem, category: "workspace")

    /// - Parameters:
    ///   - events: the connection's workspace push hub (observed, never replaced).
    ///   - resolve: the daemon client of the moment (nil while not connected).
    public init(hostId: String, events: WorkspaceEventHub, resolve: @escaping () -> (any DaemonWorkspaceAPI)?) {
        self.hostId = hostId
        self.resolve = resolve
        hub = events
        hubToken = events.observe { [weak self] event in self?.receive(event) }
        install()
    }

    isolated deinit {
        if let hubToken { hub?.remove(hubToken) }
    }

    public var api: (any DaemonWorkspaceAPI)? {
        install()
        return resolve()
    }

    public func client() throws -> any DaemonWorkspaceAPI {
        guard let api else { throw HostError.notConnected }
        return api
    }

    private func install() {
        guard let client = resolve() else { return }
        let identity = ObjectIdentifier(client)
        guard installedOn != identity else { return }
        installedOn = identity
        ports = client.ports()
        if let repoClient = client as? any DaemonRepoAPI, let snapshot = repoClient.repos() { repos = snapshot }
        // A new connection (maybe a restarted daemon): read the ports again.
        worktreePortsLoaded = [:]
        loadWorktreePortsIfNeeded()
    }

    // MARK: Observers (other features)

    /// Calls `handler` with every ports push; returns a token for `removeObserver`.
    @discardableResult
    public func observePorts(_ handler: @escaping ([PortInfo]) -> Void) -> UUID {
        let id = UUID()
        portObservers[id] = handler
        return id
    }

    @discardableResult
    public func observeAttention(_ handler: @escaping (AttentionUpdate) -> Void) -> UUID {
        let id = UUID()
        attentionObservers[id] = handler
        return id
    }

    /// Calls `handler` with every command start and end in the attached session's panes.
    @discardableResult
    public func observeCommandMarks(_ handler: @escaping (CommandMark) -> Void) -> UUID {
        let id = UUID()
        markObservers[id] = handler
        return id
    }

    /// Calls `handler` with every VS Code tunnel state push (device code, running, failed).
    @discardableResult
    public func observeTunnel(_ handler: @escaping (VsCodeTunnelStatus) -> Void) -> UUID {
        let id = UUID()
        tunnelObservers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        tunnelObservers[id] = nil
        portObservers[id] = nil
        attentionObservers[id] = nil
        markObservers[id] = nil
        workflowObservers[id] = nil
    }

    // MARK: Commands (shell integration)

    /// A pane's command list was read: what it says runs now replaces what was known (after a
    /// reconnect, marks pushed while away are missed).
    public func noteCommands(_ list: CommandList, pane: UInt64) {
        let running = CommandBlocks.running(list)
        if runningCommands[pane] != running { runningCommands[pane] = running }
    }

    func noteMark(_ mark: CommandMark) {
        if mark.finished == nil {
            runningCommands[mark.paneId] = mark
        } else if runningCommands[mark.paneId]?.commandId == mark.commandId {
            runningCommands[mark.paneId] = nil
        }
        for observer in markObservers.values { observer(mark) }
    }

    // MARK: Events

    /// A workspace push (main actor, in order).
    func receive(_ event: WorkspaceEvent) {
        switch event {
        case .portsChanged(let ports):
            self.ports = ports
            for observer in portObservers.values { observer(ports) }
        case .fsChanged(let change):
            watches[change.watchId]?.handler(change)
        case .attention(let update):
            // Observers (notifications) hear every item; the views get them paced.
            pendingAttention.append(update)
            attentionPacing.note()
            for observer in attentionObservers.values { observer(update) }
        case .vsCodeTunnel(let status):
            vsCodeTunnel = status
            for observer in tunnelObservers.values { observer(status) }
        case .agentUsage(let report):
            if usageViewers > 0 { usage = report }
        case .accounts(let report):
            accounts = report
        case .accountUsage(let report):
            if usageViewers > 0 { accountUsage = report }
        case .repos(let snapshot):
            repos = snapshot
            loadWorktreePortsIfNeeded()
        case .timeline(let pane, let json):
            timelineChannels[pane]?.receive(json)
        case .workflowsChanged(let rev):
            workflowsRev = rev
            for observer in workflowObservers.values { observer(rev) }
        }
    }

    // MARK: Repositories (git-native workspace)

    public func repoClient() throws -> any DaemonRepoAPI {
        guard let api = api as? any DaemonRepoAPI else { throw HostError.notConnected }
        return api
    }

    /// Re-reads git state now and the pull request of `path` (every one when nil).
    public func refreshRepos(path: String? = nil) async {
        guard let api = try? repoClient() else { return }
        do {
            repos = try await api.repoRefresh(path: path)
            loadWorktreePortsIfNeeded()
        } catch {
            Self.log.error("repo refresh host=\(self.hostId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    public func worktree(ofPane pane: UInt64) -> WorktreeState? {
        guard let repos, let path = repos.panes.first(where: { $0.paneId == pane })?.worktree else { return nil }
        return repos.worktrees.first { $0.path == path }
    }

    public func worktree(_ path: String) -> WorktreeState? {
        repos?.worktrees.first { $0.path == path }
    }

    /// The worktree's `PORT` on the host, if the daemon gave it one (the main checkout and
    /// worktrees made outside the app have none).
    public func port(ofWorktree path: String) -> UInt16? {
        worktreePorts[Self.normalized(path)]
    }

    /// Records a port a request returned (`TaskCreated`, a restore) before the next read.
    public func notePort(_ port: UInt16?, worktree path: String) {
        guard let port else { return }
        worktreePorts[Self.normalized(path)] = port
    }

    /// `/private/var/…` and `/var/…` are one directory on macOS hosts; git and the daemon do
    /// not always print the same one.
    nonisolated static func normalized(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Reads `PORT`s for the repositories whose worktrees changed since the last read.
    private func loadWorktreePortsIfNeeded() {
        guard let repos, let api = resolve() as? any DaemonWorktreeListAPI else { return }
        let byRepo = Dictionary(grouping: repos.worktrees, by: \.repo).mapValues { Set($0.map(\.path)) }
        for (repo, paths) in byRepo where worktreePortsLoaded[repo] != paths {
            worktreePortsLoaded[repo] = paths
            let worktrees = repos.worktrees.filter { $0.repo == repo }
            Task { [weak self] in
                do {
                    let listed = try await api.worktreeList(repo: repo)
                    self?.applyPorts(listed, to: worktrees)
                } catch {
                    // Asked again with the next snapshot.
                    self?.worktreePortsLoaded[repo] = nil
                    Self.log.debug("worktree ports \(repo, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Ports by the snapshot's paths: matched on the path, else on the checked-out branch (git
    /// checks a branch out in one worktree at most).
    func applyPorts(_ listed: [WorktreeInfo], to worktrees: [WorktreeState]) {
        var ports = worktreePorts
        for state in worktrees {
            let key = Self.normalized(state.path)
            let match = listed.first { Self.normalized($0.path) == key }
                ?? state.branch.flatMap { branch in listed.first { $0.branch == branch } }
            ports[key] = match?.port
        }
        if ports != worktreePorts { worktreePorts = ports }
    }

    /// Applies a pull request a request returned, so the UI shows it before the next push.
    public func applyPR(_ pr: PullRequest?, to path: String) {
        guard var snapshot = repos, let index = snapshot.worktrees.firstIndex(where: { $0.path == path }) else { return }
        snapshot.worktrees[index].pr = pr
        repos = snapshot
    }

    @ObservationIgnored private var pendingAttention: [AttentionUpdate] = []
    @ObservationIgnored private lazy var attentionPacing = UpdateThrottle(interval: DaemonConnection.paneStatusInterval) { [weak self] in
        self?.applyPendingAttention()
    }

    private func applyPendingAttention() {
        let updates = pendingAttention
        pendingAttention = []
        for update in updates { apply(update) }
    }

    func apply(_ update: AttentionUpdate) {
        switch update {
        case .added(let item, let unseen):
            attention.removeAll { $0.id == item.id }
            attention.insert(item, at: 0)
            if attention.count > 500 { attention.removeLast(attention.count - 500) }
            self.unseen = Int(unseen)
        case .seen(let ids, let unseen):
            let seen = Set(ids)
            for index in attention.indices where seen.contains(attention[index].id) {
                attention[index].seen = true
            }
            self.unseen = Int(unseen)
        }
    }

    /// A non-pane-stream `ClientEvent` from the connection (main actor).
    public func receive(client event: ClientEvent) {
        switch event {
        case .connected:
            install()
            generation += 1
            for channel in timelineChannels.values { channel.reconnect() }
            Task { await refresh() }
            rewatch()
            if usageViewers > 0 { watchUsage() }
        case .searchResult(let id, _, _, _), .links(let id, _, _, _), .commands(let id, _, _, _),
             .commandOutput(let id, _, _, _):
            pending.removeValue(forKey: id)?.resume(returning: event)
        case .commandMark(let mark):
            noteMark(mark)
        case .paneClosed(let pane):
            runningCommands[pane] = nil
            timelineChannels.removeValue(forKey: pane)?.close()
        case .disconnected:
            for channel in timelineChannels.values { channel.disconnected() }
            // Requests in flight get no answer on this connection.
            let waiting = pending
            pending.removeAll()
            for continuation in waiting.values {
                continuation.resume(returning: .disconnected(reason: "disconnected"))
            }
        default:
            break
        }
    }

    // MARK: Attention

    /// Reloads ports and the attention feed (after connecting).
    public func refresh() async {
        guard let api else { return }
        if let list = try? await api.attentionList() {
            attention = list.items.sorted { $0.id > $1.id }
            unseen = Int(list.unseen)
        }
        if let ports = try? await api.listPorts() { self.ports = ports }
    }

    /// Marks items seen on every device (`ids`), or everything up to the newest item.
    public func markSeen(_ ids: [UInt64]? = nil, pane: UInt64? = nil) async {
        guard let api else { return }
        let request: AttentionSeen
        if let ids {
            guard !ids.isEmpty else { return }
            request = AttentionSeen(ids: ids, upTo: nil, paneId: pane)
        } else if let pane {
            request = AttentionSeen(ids: [], upTo: nil, paneId: pane)
        } else {
            guard unseen > 0, let newest = attention.map(\.id).max() else { return }
            request = AttentionSeen(ids: [], upTo: newest, paneId: nil)
        }
        do {
            let list = try await api.attentionSeen(seen: request)
            attention = list.items.sorted { $0.id > $1.id }
            unseen = Int(list.unseen)
        } catch {
            Self.log.error("attention seen host=\(self.hostId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Agent usage

    /// Something on screen shows this host's usage: the daemon refreshes it (at most once a
    /// minute) and pushes changes while anything watches. Balance with `endWatchingUsage`.
    public func beginWatchingUsage() {
        usageViewers += 1
        if usageViewers == 1 { watchUsage() }
    }

    public func endWatchingUsage() {
        guard usageViewers > 0 else { return }
        usageViewers -= 1
        guard usageViewers == 0 else { return }
        usageTask?.cancel()
        guard usageWatchSent else { return }
        usageWatchSent = false
        let api = resolve() as? any DaemonUsageAPI
        Task { try? await api?.usageUnwatch() }
    }

    private func watchUsage() {
        guard supportsUsage(), let api = resolve() as? any DaemonUsageAPI else { return }
        usageWatchSent = true
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            do {
                let report = try await api.usageWatch()
                guard !Task.isCancelled, let self, self.usageViewers > 0 else { return }
                self.usage = report
            } catch {
                // Quiet: no meter (a guest, an old daemon, a dropped link). The log says why.
                Self.log.info("usage host=\(self?.hostId ?? "", privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Tests: a report as if pushed.
    func setUsage(_ report: AgentUsageReport?) { usage = report }

    // MARK: Watches

    /// Watches a directory (not recursive); `handler` runs on the main actor for each change.
    /// Watches are re-established after a reconnect.
    public func watch(_ path: String, handler: @escaping (FsChange) -> Void) async throws -> UInt64 {
        let id = try await client().fsWatch(path: path)
        watches[id] = (path, handler)
        return id
    }

    public func unwatch(_ id: UInt64) {
        guard watches.removeValue(forKey: id) != nil else { return }
        let api = api
        Task { try? await api?.fsUnwatch(watchId: id) }
    }

    private func rewatch() {
        let old = watches
        watches.removeAll()
        guard !old.isEmpty else { return }
        Task {
            for (_, watch) in old {
                // A fresh id; the handler is told to rescan.
                if let id = try? await client().fsWatch(path: watch.path) {
                    watches[id] = watch
                    watch.handler(FsChange(watchId: id, paths: [], rescan: true))
                }
            }
        }
    }

    // MARK: Pane RPCs

    /// Links and paths on a pane's screen and in its last `commands` commands' output.
    public func links(pane: UInt64, commands: UInt16 = 20) async throws -> Links {
        let api = try client()
        let event = await request { api.links(paneId: pane, commands: commands) }
        guard case .links(_, _, let links, let error) = event else { throw HostError.notConnected }
        if let links { return links }
        throw PaneRpcError(error)
    }

    /// The commands in a pane's scrollback (shell integration marks), oldest first.
    public func commands(pane: UInt64) async throws -> CommandList {
        let api = try client()
        let event = await request { api.commands(paneId: pane) }
        guard case .commands(_, _, let list, let error) = event else { throw HostError.notConnected }
        if let list {
            noteCommands(list, pane: pane)
            return list
        }
        throw PaneRpcError(error)
    }

    /// A command's output (`nil`: the last finished command).
    public func commandOutput(pane: UInt64, command: UInt64? = nil) async throws -> CommandOutput {
        let api = try client()
        let event = await request { api.commandOutput(paneId: pane, commandId: command) }
        guard case .commandOutput(_, _, let output, let error) = event else { throw HostError.notConnected }
        if let output { return output }
        throw PaneRpcError(error)
    }

    /// Matches in a pane's whole screen, scrollback included, newest first.
    public func search(pane: UInt64, query: SearchQuery, limit: UInt32 = 1000) async throws -> SearchPage {
        let api = try client()
        let event = await request { api.search(paneId: pane, query: query, cursor: 0, limit: limit) }
        guard case .searchResult(_, _, let page, let error) = event else { throw HostError.notConnected }
        if let page { return page }
        throw PaneRpcError(error)
    }

    /// Sends a request and waits for the answer with its id (or a disconnect, or 10 s).
    private func request(_ send: () -> UInt64) async -> ClientEvent {
        let id = send()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.pending.removeValue(forKey: id)?.resume(returning: .disconnected(reason: "timed out"))
        }
        return await withCheckedContinuation { pending[id] = $0 }
    }
}

/// A failed pane RPC (`RpcError`) in words.
public struct PaneRpcError: Error, LocalizedError, Equatable {
    public let message: String

    init(_ error: RpcError?) {
        switch error {
        case .unknownPane?: message = "That pane is gone."
        case .badRequest(let text)?: message = text
        case .notFound?: message = "Nothing found."
        case .internal(let text)?: message = text
        case nil: message = "No answer from the host."
        }
    }

    public var errorDescription: String? { message }
}

/// `TransferProgress` → closure (runtime thread, every 64 KiB).
nonisolated public final class TransferProgressHandler: TransferProgress {
    private let handler: @Sendable (UInt64, UInt64) -> Void

    public init(_ handler: @escaping @Sendable (_ done: UInt64, _ total: UInt64) -> Void) {
        self.handler = handler
    }

    public func onProgress(done: UInt64, total: UInt64) {
        handler(done, total)
    }
}

extension DaemonConnection {
    /// This daemon's workspace hub (created on first use; one per connection).
    public var workspace: DaemonWorkspace {
        if let existing = existingWorkspace { return existing }
        let hub = DaemonWorkspace(hostId: hostId, events: workspaceEvents) { [weak self] in self?.client as? any DaemonWorkspaceAPI }
        hub.supportsUsage = { [weak self] in self?.daemonInfo?.agentUsage ?? false }
        hub.supportsAccounts = { [weak self] in self?.daemonInfo?.accounts ?? false }
        DaemonWorkspaceRegistry.hubs = DaemonWorkspaceRegistry.hubs.filter { $0.value.connection != nil }
        DaemonWorkspaceRegistry.hubs[ObjectIdentifier(self)] = .init(hub: hub, connection: self)
        let previous = onEvent
        onEvent = { [weak hub] event in
            previous?(event)
            hub?.receive(client: event)
        }
        return hub
    }

    /// The hub if one was made, without making one (for views' bodies).
    public var existingWorkspace: DaemonWorkspace? {
        // An identifier can be reused by a later connection at the same address: check it is us.
        guard let entry = DaemonWorkspaceRegistry.hubs[ObjectIdentifier(self)], entry.connection === self else { return nil }
        return entry.hub
    }

    public var repoSnapshot: RepoSnapshot? { existingWorkspace?.repos }
}

@MainActor
enum DaemonWorkspaceRegistry {
    struct Entry {
        let hub: DaemonWorkspace
        weak var connection: DaemonConnection?
    }

    static var hubs: [ObjectIdentifier: Entry] = [:]
}
