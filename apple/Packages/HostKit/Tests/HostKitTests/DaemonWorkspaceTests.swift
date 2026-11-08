import Foundation
import Synchronization
import Testing
@testable import HostKit
import GudoCore

/// The workspace hub over a fake client: one listener per client, pushes fanned out, attention
/// unseen counts, seen requests, directory watches re-established after a reconnect, and pane
/// RPC answers matched to their requests.
@MainActor
struct DaemonWorkspaceTests {
    @Test func timelineObserversArePaneScopedAndRemovable() async throws {
        let (connection, _) = try connected()
        let hub = connection.workspace
        var received: [String] = []
        let token = hub.observeTimeline(pane: 7) { received.append($0) }
        hub.receive(.timeline(paneId: 8, updateJson: "other pane"))
        #expect(received.isEmpty)
        hub.receive(.timeline(paneId: 7, updateJson: "watched pane"))
        #expect(received == ["watched pane"])
        hub.removeObserver(token)
        hub.receive(.timeline(paneId: 7, updateJson: "removed"))
        #expect(received == ["watched pane"])
    }

    @Test func pushesUpdatePortsAndAttention() async throws {
        let (connection, client) = try connected()
        let hub = connection.workspace
        #expect(client.listenerCount == 1)
        _ = connection.workspace
        #expect(client.listenerCount == 1, "one listener per client")

        var observed: [[UInt16]] = []
        hub.observePorts { observed.append($0.map(\.port)) }
        client.push(.portsChanged(ports: [port(5173)]))
        try await eventually("ports") { hub.ports.map(\.port) == [5173] }
        #expect(observed == [[5173]])

        client.push(.attention(update: .added(item: item(1), unseen: 1)))
        client.push(.attention(update: .added(item: item(2), unseen: 2)))
        try await eventually("added") { hub.unseen == 2 }
        #expect(hub.attention.map(\.id) == [2, 1], "newest first")
        client.push(.attention(update: .seen(ids: [1], unseen: 1)))
        try await eventually("seen") { hub.unseen == 1 }
        #expect(hub.attention.first { $0.id == 1 }?.seen == true)
    }

    /// A flood of attention items: every one reaches the observers (notifications), the list
    /// the views read changes at a bounded rate and ends with the newest 500.
    @Test func anAttentionFloodIsPacedForTheViews() async throws {
        let (connection, client) = try connected()
        let hub = connection.workspace
        var heard = 0
        hub.observeAttention { _ in heard += 1 }
        let renders = Invalidations()
        renders.watch { _ = hub.attention }
        let start = ContinuousClock.now
        for id in 1...2_000 as ClosedRange<UInt64> {
            client.push(.attention(update: .added(item: item(id), unseen: UInt32(id))))
            if id % 100 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await eventually("the last item") { hub.attention.first?.id == 2_000 }
        let windows = Int((ContinuousClock.now - start) / DaemonConnection.paneStatusInterval) + 3
        #expect(heard == 2_000)
        #expect(renders.count <= windows, "\(renders.count) renders")
        #expect(hub.attention.count == 500)
        #expect(hub.unseen == 2_000)
    }

    @Test func markSeenAsksTheDaemonUpToTheNewest() async throws {
        let (connection, client) = try connected()
        client.state.withLock { $0.attention = AttentionList(items: [item(3), item(4)], unseen: 2) }
        let hub = connection.workspace
        await hub.refresh()
        #expect(hub.unseen == 2)
        await hub.markSeen()
        let request = try #require(client.state.withLock { $0.seen.last })
        #expect(request.upTo == 4)
        #expect(hub.unseen == 0)
        await hub.markSeen(pane: 9)
        #expect(client.state.withLock { $0.seen.last?.paneId } == 9)
    }

    @Test func paneRpcAnswersMatchTheirRequests() async throws {
        let (connection, client) = try connected()
        let hub = connection.workspace
        async let links = hub.links(pane: 1)
        try await eventually("asked") { client.state.withLock { $0.asked.contains(41) } }
        // An unrelated answer first, then ours.
        client.send(.links(reqId: 40, paneId: 1, links: Links(cwd: nil, links: []), error: nil))
        client.send(.links(reqId: 41, paneId: 1, links: Links(cwd: "/p", links: [
            Link(kind: .url, text: "http://x", target: "http://x", line: nil, column: nil, exists: nil, source: .screen),
        ]), error: nil))
        let answer = try await links
        #expect(answer.cwd == "/p")
        #expect(answer.links.count == 1)

        let output = Task { try await hub.commandOutput(pane: 1) }
        try await eventually("asked output") { client.state.withLock { $0.asked.contains(43) } }
        client.send(.commandOutput(reqId: 43, paneId: 1, output: nil, error: .unknownPane))
        await #expect(throws: PaneRpcError.self) { try await output.value }
    }

    @Test func watchesComeBackAfterAReconnect() async throws {
        let (connection, client) = try connected()
        let hub = connection.workspace
        var changes: [FsChange] = []
        let id = try await hub.watch("/p") { changes.append($0) }
        client.push(.fsChanged(change: FsChange(watchId: id, paths: ["/p/a"], rescan: false)))
        try await eventually("change") { changes.count == 1 }
        // Reconnected: the daemon dropped the watch; the hub watches again and says rescan.
        client.send(.connected(epoch: 2, resumed: false))
        try await eventually("rewatch") { changes.count == 2 }
        #expect(changes.last?.rescan == true)
        #expect(client.state.withLock { $0.watched } == ["/p", "/p"])
    }

    @Test func worktreePortsAreReadWhenARepositorysWorktreesChange() async throws {
        let (connection, client) = try connected()
        let hub = connection.workspace
        client.state.withLock {
            $0.worktreeLists["/r"] = [
                WorktreeInfo(path: "/r", branch: "main", head: nil, main: true, locked: false, prunable: false, port: nil),
                WorktreeInfo(path: "/private/var/w/feat", branch: "feat", head: nil, main: false, locked: false, prunable: false, port: 4101),
            ]
        }
        let main = RepoSidebarTests.worktree("/r", main: true, branch: "main")
        let feat = RepoSidebarTests.worktree("/var/w/feat", branch: "feat")
        client.push(.repos(snapshot: RepoSnapshot(rev: 1, panes: [], worktrees: [main, feat], gh: .unknown)))
        try await eventually("ports") { hub.port(ofWorktree: "/var/w/feat") == 4101 }
        #expect(hub.port(ofWorktree: "/private/var/w/feat") == 4101, "/private/var and /var are one directory")
        #expect(hub.port(ofWorktree: "/r") == nil, "the main checkout has no PORT")

        // A push that only changes counts does not ask again; a new worktree does.
        var busier = feat
        busier.added = 3
        client.push(.repos(snapshot: RepoSnapshot(rev: 2, panes: [], worktrees: [main, busier], gh: .unknown)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.state.withLock { $0.listed } == ["/r"])
        let fix = RepoSidebarTests.worktree("/w/fix", branch: "fix")
        client.state.withLock {
            $0.worktreeLists["/r"]?.append(WorktreeInfo(path: "/w/fix", branch: "fix", head: nil, main: false, locked: false, prunable: false, port: 4102))
        }
        client.push(.repos(snapshot: RepoSnapshot(rev: 3, panes: [], worktrees: [main, busier, fix], gh: .unknown)))
        try await eventually("new worktree") { hub.port(ofWorktree: "/w/fix") == 4102 }
        #expect(client.state.withLock { $0.listed } == ["/r", "/r"])

        // A port a request returned shows before the next read.
        hub.notePort(4200, worktree: "/w/new")
        #expect(hub.port(ofWorktree: "/w/new") == 4200)
    }

    // MARK: Helpers

    private func connected() throws -> (DaemonConnection, FakeWorkspaceAPI) {
        let client = FakeWorkspaceAPI()
        let connection = DaemonConnection(hostId: "h", ticket: "t") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        return (connection, client)
    }

    @Test func theRepositoryRootSkipsGitStatusWhereTheHelperOffersIt() async {
        let api = FakeWorkspaceAPI()
        #expect(await api.repositoryRoot(of: "/r/src") == nil, "an older helper answers through git status")
        api.state.withLock { $0.offersRepoRoot = true }
        #expect(await api.repositoryRoot(of: "/r/src") == "/r")
        #expect(await api.repositoryRoot(of: "/tmp") == nil)
    }

    private func port(_ number: UInt16) -> PortInfo {
        PortInfo(port: number, loopbackOnly: true, paneId: nil, pid: 1, process: "node", kind: .http, url: nil)
    }

    private func item(_ id: UInt64) -> AttentionItem {
        AttentionItem(id: id, atMs: id, paneId: 1, sessionId: nil, kind: .agentDone(agent: "claude"), title: "t", body: "b", seen: false, whileViewed: false)
    }
}

/// The workspace half of a daemon client, answering from `state`.
nonisolated final class FakeWorkspaceAPI: DaemonClientAPI, DaemonWorkspaceAPI, WorkspaceEventSource, @unchecked Sendable {
    struct State {
        var listeners: [any WorkspaceListener] = []
        var events: (any ClientEventListener)?
        var attention = AttentionList(items: [], unseen: 0)
        var seen: [AttentionSeen] = []
        var asked: Set<UInt64> = []
        var watched: [String] = []
        var nextWatch: UInt64 = 1
        /// `usageWatch` calls, `usageUnwatch` calls, and the report.
        var usageWatches = 0
        var usageUnwatches = 0
        var usage = AgentUsageReport(agents: [])
        /// `worktreeList` answers by repository, and the repositories asked.
        var worktreeLists: [String: [WorktreeInfo]] = [:]
        var listed: [String] = []
        var offersRepoRoot = false
    }

    let state = Mutex(State())
    var listenerCount: Int { state.withLock { $0.listeners.count } }

    func push(_ event: WorkspaceEvent) { state.withLock { $0.listeners.last }?.onWorkspaceEvent(event: event) }
    func send(_ event: ClientEvent) { state.withLock { $0.events }?.onEvent(event: event) }

    // DaemonClientAPI
    func attach(sessionId: UInt64?) {}
    func op(op: GudoCore.LayoutOp) -> UInt64 { 0 }
    func subscribe(paneId: UInt64) {}
    func unsubscribe(paneId: UInt64) {}
    func setView(focused: UInt64?, visible: [UInt64]) {}
    func resize(paneId: UInt64, size: PaneSize) {}
    func sendInput(paneId: UInt64, data: Data) {}
    func sendPaste(paneId: UInt64, text: String) {}
    func fetchHistory(paneId: UInt64, maxBytes: UInt32) -> Bool { false }
    func decide(requestId: UInt64, optionId: UInt32) {}
    func reconnect() {}
    func suspend() {}
    func paneText(paneId: UInt64) -> String? { nil }

    // DaemonWorkspaceAPI
    func setWorkspaceListener(listener: any WorkspaceListener) { state.withLock { $0.listeners.append(listener) } }
    func ports() -> [PortInfo] { [] }
    func listPorts() async throws -> [PortInfo] { [] }
    func forward(localPort: UInt16, target: ForwardTarget) throws -> UInt16 { localPort }
    func stopForward(localPort: UInt16) -> Bool { true }
    func forwards() -> [ForwardInfo] { [] }
    func gitStatus(path: String) async throws -> GudoCore.GitStatus { throw WorkspaceError.Disconnected }
    func gitDiff(request: GitDiffRequest) async throws -> GitDiff { throw WorkspaceError.Disconnected }
    func listTurns(paneId: UInt64) async throws -> [TurnInfo] { [] }
    func turnDiff(paneId: UInt64, turn: UInt64?, context: UInt32, hunks: Bool) async throws -> GitDiff { throw WorkspaceError.Disconnected }
    func sendReview(review: ReviewRequest) async throws -> String { "" }
    func launchAgentPane(launch: AgentLaunch) async throws -> AgentLaunched { throw WorkspaceError.Disconnected }
    func worktreeCreate(create: WorktreeCreate) async throws -> WorktreeInfo { throw WorkspaceError.Disconnected }
    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32 { 0 }
    func fsList(path: String, showHidden: Bool) async throws -> DirListing { throw WorkspaceError.Disconnected }
    func fsStat(path: String) async throws -> FileStat { throw WorkspaceError.Disconnected }
    func fsRead(path: String, offset: UInt64, len: UInt32) async throws -> FileChunk { throw WorkspaceError.Disconnected }
    func fsWrite(target: WriteTarget, data: Data) async throws -> FileStat { throw WorkspaceError.Disconnected }
    func fsMkdir(path: String, parents: Bool) async throws -> FileStat { throw WorkspaceError.Disconnected }
    func fsRename(from: String, to: String, overwrite: Bool) async throws -> FileStat { throw WorkspaceError.Disconnected }
    func fsDelete(path: String, mode: DeleteMode, recursive: Bool) async throws {}
    func fsWatch(path: String) async throws -> UInt64 {
        state.withLock { state in
            state.watched.append(path)
            defer { state.nextWatch += 1 }
            return state.nextWatch
        }
    }
    func fsUnwatch(watchId: UInt64) async throws {}
    func uploadFile(localPath: String, target: WriteTarget, progress: (any TransferProgress)?) async throws -> FileStat { throw WorkspaceError.Disconnected }
    func downloadFile(remotePath: String, localPath: String, offset: UInt64, len: UInt64?, progress: (any TransferProgress)?) async throws -> FileStat { throw WorkspaceError.Disconnected }
    func attentionList() async throws -> AttentionList { state.withLock { $0.attention } }
    func attentionSeen(seen: AttentionSeen) async throws -> AttentionList {
        state.withLock { state in
            state.seen.append(seen)
            for index in state.attention.items.indices { state.attention.items[index].seen = true }
            state.attention.unseen = 0
            return state.attention
        }
    }
    func editorStatus() async throws -> EditorList { EditorList(available: [], running: []) }
    func openEditor(folder: String, acceptVscodeLicense: Bool) async throws -> EditorSession { throw WorkspaceError.Disconnected }
    func closeEditor(session: EditorSession, stopServer: Bool) async throws {}
    func editorOpenInSession(session: EditorSession, path: String, line: UInt32?, column: UInt32?) async throws -> String? { nil }
    func links(paneId: UInt64, commands: UInt16) -> UInt64 { asked(41) }
    func commands(paneId: UInt64) -> UInt64 { asked(42) }
    func commandOutput(paneId: UInt64, commandId: UInt64?) -> UInt64 { asked(43) }
    func search(paneId: UInt64, query: SearchQuery, cursor: UInt32, limit: UInt32) -> UInt64 { asked(44) }

    private func asked(_ id: UInt64) -> UInt64 {
        state.withLock { _ = $0.asked.insert(id) }
        return id
    }
}

extension FakeWorkspaceAPI: DaemonUsageAPI {
    func usageWatch() async throws -> AgentUsageReport {
        state.withLock { state in
            state.usageWatches += 1
            return state.usage
        }
    }

    func usageUnwatch() async throws {
        state.withLock { $0.usageUnwatches += 1 }
    }
}

extension FakeWorkspaceAPI: DaemonWorktreeListAPI {
    func worktreeList(repo: String) async throws -> [WorktreeInfo] {
        state.withLock { state in
            state.listed.append(repo)
            return state.worktreeLists[repo] ?? []
        }
    }
}

extension FakeWorkspaceAPI: DaemonRepoRootAPI {
    func offersRepoRoot() -> Bool { state.withLock { $0.offersRepoRoot } }
    func repoRoot(path: String) async throws -> String? { path.hasPrefix("/r/") ? "/r" : nil }
}
