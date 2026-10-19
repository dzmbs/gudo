import Foundation
import Observation
import os
import UnnamedCore

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
    /// Repositories, worktrees, branches and pull requests of the host's panes, as last pushed
    /// (`WorkspaceEvent.repos`); nil until the first snapshot.
    public internal(set) var repos: RepoSnapshot?

    @ObservationIgnored private let resolve: () -> (any DaemonWorkspaceAPI)?
    @ObservationIgnored private var installedOn: ObjectIdentifier?
    @ObservationIgnored private var watches: [UInt64: (path: String, handler: (FsChange) -> Void)] = [:]
    @ObservationIgnored private var pending: [UInt64: CheckedContinuation<ClientEvent, Never>] = [:]
    @ObservationIgnored private var hubToken: UUID?
    @ObservationIgnored private weak var hub: WorkspaceEventHub?
    @ObservationIgnored private var portObservers: [UUID: ([PortInfo]) -> Void] = [:]
    @ObservationIgnored private var attentionObservers: [UUID: (AttentionUpdate) -> Void] = [:]

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

    /// The client of the moment.
    public var api: (any DaemonWorkspaceAPI)? {
        install()
        return resolve()
    }

    /// The client or `HostError.notConnected`.
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
    }

    // MARK: Observers (other features)

    /// Calls `handler` with every ports push; returns a token for `removeObserver`.
    @discardableResult
    public func observePorts(_ handler: @escaping ([PortInfo]) -> Void) -> UUID {
        let id = UUID()
        portObservers[id] = handler
        return id
    }

    /// Calls `handler` with every attention update.
    @discardableResult
    public func observeAttention(_ handler: @escaping (AttentionUpdate) -> Void) -> UUID {
        let id = UUID()
        attentionObservers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        portObservers[id] = nil
        attentionObservers[id] = nil
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
            apply(update)
            for observer in attentionObservers.values { observer(update) }
        case .vsCodeTunnel:
            break
        case .repos(let snapshot):
            repos = snapshot
        }
    }

    // MARK: Repositories (git-native workspace)

    /// The repository API of the client of the moment, or `HostError.notConnected`.
    public func repoClient() throws -> any DaemonRepoAPI {
        guard let api = api as? any DaemonRepoAPI else { throw HostError.notConnected }
        return api
    }

    /// Re-reads git state now and the pull request of `path` (every one when nil).
    public func refreshRepos(path: String? = nil) async {
        guard let api = try? repoClient() else { return }
        do {
            repos = try await api.repoRefresh(path: path)
        } catch {
            Self.log.error("repo refresh host=\(self.hostId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The worktree a pane is in.
    public func worktree(ofPane pane: UInt64) -> WorktreeState? {
        guard let repos, let path = repos.panes.first(where: { $0.paneId == pane })?.worktree else { return nil }
        return repos.worktrees.first { $0.path == path }
    }

    /// A worktree by path.
    public func worktree(_ path: String) -> WorktreeState? {
        repos?.worktrees.first { $0.path == path }
    }

    /// Applies a pull request a request returned, so the UI shows it before the next push.
    public func applyPR(_ pr: PullRequest?, to path: String) {
        guard var snapshot = repos, let i = snapshot.worktrees.firstIndex(where: { $0.path == path }) else { return }
        snapshot.worktrees[i].pr = pr
        repos = snapshot
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
            Task { await refresh() }
            rewatch()
        case .searchResult(let id, _, _, _), .links(let id, _, _, _), .commands(let id, _, _, _),
             .commandOutput(let id, _, _, _):
            pending.removeValue(forKey: id)?.resume(returning: event)
        case .disconnected:
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
        if let list { return list }
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
}

@MainActor
enum DaemonWorkspaceRegistry {
    struct Entry {
        let hub: DaemonWorkspace
        weak var connection: DaemonConnection?
    }

    static var hubs: [ObjectIdentifier: Entry] = [:]
}
