import Foundation
import HostKit
import Synchronization
import GudoCore
@testable import App

/// A daemon client for the screens' models: the layout half does nothing, the workspace half
/// answers from canned values and records what was asked.
nonisolated final class FakeWorkspaceClient: DaemonClientAPI, DaemonWorkspaceAPI, WorkspaceEventSource, @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var listings: [String: DirListing] = [:]
        var files: [String: Data] = [:]
        var status: GudoCore.GitStatus?
        var diff: GitDiff?
        var turns: [UInt64: [TurnInfo]] = [:]
        var reviews: [ReviewRequest] = []
        var prompts: [(UInt64, String)] = []
        var launches: [AgentLaunch] = []
        var worktrees: [WorktreeCreate] = []
        var uploads: [WriteTarget] = []
        /// Upload targets that exist already (`createNew` → Conflict).
        var existing: Set<String> = []
        var forwards: [ForwardInfo] = []
        /// Local ports that are taken (forward to them fails).
        var takenPorts: Set<UInt16> = []
        var nextPort: UInt16 = 50_000
        var editorInstalled = false
        var editorDelay: Duration = .zero
        var attention = AttentionList(items: [], unseen: 0)
        var seen: [AttentionSeen] = []
        var ports: [PortInfo] = []
        var listener: (any WorkspaceListener)?
        var events: (any ClientEventListener)?
    }

    let state = Mutex(State())

    /// Delivers a `ClientEvent` as the core would (runtime thread → the connection's pump).
    func send(_ event: ClientEvent) {
        state.withLock { $0.events }?.onEvent(event: event)
    }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    var calls: [String] { state.withLock { $0.calls } }

    // MARK: DaemonClientAPI (layout; unused here)

    func attach(sessionId: UInt64?) {}
    func op(op: GudoCore.LayoutOp) -> UInt64 { 1 }
    func subscribe(paneId: UInt64) {}
    func unsubscribe(paneId: UInt64) {}
    func setView(focused: UInt64?, visible: [UInt64]) {}
    func resize(paneId: UInt64, size: PaneSize) {}
    func sendInput(paneId: UInt64, data: Data) {}
    func sendPaste(paneId: UInt64, text: String) {}
    func fetchHistory(paneId: UInt64, maxBytes: UInt32) -> Bool { false }
    func decide(requestId: UInt64, optionId: UInt32) { record("decide \(requestId) \(optionId)") }
    func reconnect() {}
    func suspend() {}
    func paneText(paneId: UInt64) -> String? { nil }

    // MARK: Workspace

    func setWorkspaceListener(listener: any WorkspaceListener) { state.withLock { $0.listener = listener } }
    func ports() -> [PortInfo] { state.withLock { $0.ports } }
    func listPorts() async throws -> [PortInfo] { ports() }

    func forward(localPort: UInt16, target: ForwardTarget) throws -> UInt16 {
        try state.withLock { state in
            if localPort != 0, state.takenPorts.contains(localPort) {
                throw WorkspaceError.Failed(message: "address in use")
            }
            let port = localPort == 0 ? state.nextPort : localPort
            if localPort == 0 { state.nextPort += 1 }
            state.forwards.append(ForwardInfo(localPort: port, target: target))
            state.calls.append("forward \(localPort)")
            return port
        }
    }

    func stopForward(localPort: UInt16) -> Bool { true }
    func forwards() -> [ForwardInfo] { state.withLock { $0.forwards } }

    func gitStatus(path: String) async throws -> GudoCore.GitStatus {
        record("gitStatus \(path)")
        guard let status = state.withLock({ $0.status }) else { throw WorkspaceError.NotFound(message: "not a git repository") }
        return status
    }

    func gitDiff(request: GitDiffRequest) async throws -> GitDiff {
        record("gitDiff \(request.base)")
        return state.withLock { $0.diff } ?? GitDiff(root: "/r", from: "a", to: "b", files: [], truncated: false)
    }

    func listTurns(paneId: UInt64) async throws -> [TurnInfo] { state.withLock { $0.turns[paneId] ?? [] } }

    func turnDiff(paneId: UInt64, turn: UInt64?, context: UInt32, hunks: Bool) async throws -> GitDiff {
        record("turnDiff \(paneId) \(turn.map(String.init) ?? "-")")
        return state.withLock { $0.diff } ?? GitDiff(root: "/r", from: "a", to: "b", files: [], truncated: false)
    }

    func sendReview(review: ReviewRequest) async throws -> String {
        state.withLock { $0.reviews.append(review) }
        return "ok"
    }

    func launchAgentPane(launch: AgentLaunch) async throws -> AgentLaunched {
        state.withLock { $0.launches.append(launch) }
        return AgentLaunched(paneId: 99, promptChars: launch.prompt.map { UInt32($0.count) }, promptError: nil)
    }

    func worktreeCreate(create: WorktreeCreate) async throws -> WorktreeInfo {
        state.withLock { $0.worktrees.append(create) }
        return WorktreeInfo(path: "/wt/\(create.branch ?? "gudo")", branch: create.branch, head: nil, main: false, locked: false, prunable: false, port: 4100)
    }

    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32 {
        state.withLock { $0.prompts.append((paneId, text)) }
        return UInt32(text.count)
    }

    func fsList(path: String, showHidden: Bool) async throws -> DirListing {
        guard let listing = state.withLock({ $0.listings[path] }) else { throw WorkspaceError.NotFound(message: path) }
        return listing
    }

    func fsStat(path: String) async throws -> FileStat {
        let size = state.withLock { $0.files[path]?.count } ?? 0
        return Self.stat(path, size: UInt64(size))
    }

    func fsRead(path: String, offset: UInt64, len: UInt32) async throws -> FileChunk {
        guard let data = state.withLock({ $0.files[path] }) else { throw WorkspaceError.NotFound(message: path) }
        let start = min(Int(offset), data.count)
        let end = min(start + Int(len), data.count)
        return FileChunk(stat: Self.stat(path, size: UInt64(data.count)), offset: offset, data: data.subdata(in: start..<end), eof: end == data.count)
    }

    func fsWrite(target: WriteTarget, data: Data) async throws -> FileStat { Self.stat(target.path, size: UInt64(data.count)) }
    func fsMkdir(path: String, parents: Bool) async throws -> FileStat {
        record("mkdir \(path)")
        return Self.stat(path, size: 0, kind: .dir)
    }
    func fsRename(from: String, to: String, overwrite: Bool) async throws -> FileStat {
        record("rename \(from) \(to)")
        return Self.stat(to, size: 0)
    }
    func fsDelete(path: String, mode: DeleteMode, recursive: Bool) async throws { record("delete \(path) \(mode)") }
    func fsWatch(path: String) async throws -> UInt64 {
        record("watch \(path)")
        return 7
    }
    func fsUnwatch(watchId: UInt64) async throws { record("unwatch \(watchId)") }

    func uploadFile(localPath: String, target: WriteTarget, progress: (any TransferProgress)?) async throws -> FileStat {
        let exists = state.withLock { state -> Bool in
            state.uploads.append(target)
            return state.existing.contains(target.path)
        }
        if exists, target.createNew { throw WorkspaceError.Conflict(message: "exists") }
        progress?.onProgress(done: 5, total: 10)
        progress?.onProgress(done: 10, total: 10)
        return Self.stat(target.path, size: 10)
    }

    func downloadFile(remotePath: String, localPath: String, offset: UInt64, len: UInt64?, progress: (any TransferProgress)?) async throws -> FileStat {
        let data = state.withLock { $0.files[remotePath] } ?? Data()
        try data.write(to: URL(fileURLWithPath: localPath))
        progress?.onProgress(done: UInt64(data.count), total: UInt64(data.count))
        return Self.stat(remotePath, size: UInt64(data.count))
    }

    func attentionList() async throws -> AttentionList { state.withLock { $0.attention } }
    func attentionSeen(seen: AttentionSeen) async throws -> AttentionList {
        state.withLock { state in
            state.seen.append(seen)
            for index in state.attention.items.indices where seen.upTo.map({ state.attention.items[index].id <= $0 }) ?? seen.ids.contains(state.attention.items[index].id) {
                state.attention.items[index].seen = true
            }
            state.attention.unseen = UInt32(state.attention.items.filter { !$0.seen }.count)
            return state.attention
        }
    }

    func editorStatus() async throws -> EditorList {
        let installed = state.withLock { $0.editorInstalled }
        return EditorList(
            available: [EditorAvailability(kind: .vsCode, installed: installed, downloadable: true, path: nil, version: nil, note: nil)],
            running: [])
    }

    func openEditor(folder: String, acceptVscodeLicense: Bool) async throws -> EditorSession {
        record("openEditor \(folder) \(acceptVscodeLicense)")
        let delay = state.withLock { $0.editorDelay }
        try await Task.sleep(for: delay)
        guard acceptVscodeLicense else { throw WorkspaceError.Unavailable(message: "licence") }
        let instance = EditorInstance(kind: .vsCode, folder: folder, port: 8123, token: "t", urlPath: "/?tkn=t", pid: 1, startedAtMs: 0)
        let installed = !state.withLock { $0.editorInstalled }
        state.withLock { $0.editorInstalled = true }
        return EditorSession(url: "http://localhost:8123/?tkn=t&folder=\(folder)", localPort: 8123, instance: instance, installedCli: installed, fallbackReason: nil)
    }

    func closeEditor(session: EditorSession, stopServer: Bool) async throws { record("closeEditor \(stopServer)") }

    func editorOpenInSession(session: EditorSession, path: String, line: UInt32?, column: UInt32?) async throws -> String? {
        record("editorOpen \(path):\(line ?? 0)")
        return "http://localhost:8123/?payload=\(path)"
    }

    func links(paneId: UInt64, commands: UInt16) -> UInt64 { 41 }
    func commands(paneId: UInt64) -> UInt64 { 42 }
    func commandOutput(paneId: UInt64, commandId: UInt64?) -> UInt64 { 43 }
    func search(paneId: UInt64, query: SearchQuery, cursor: UInt32, limit: UInt32) -> UInt64 { 44 }

    static func stat(_ path: String, size: UInt64, kind: FileKind = .file, modifiedMs: UInt64 = 1_700_000_000_000) -> FileStat {
        FileStat(
            path: path, name: (path as NSString).lastPathComponent, kind: kind, size: size, modifiedMs: modifiedMs,
            mode: 0o644, hidden: (path as NSString).lastPathComponent.hasPrefix("."), linkTarget: nil, targetKind: nil,
            version: "1-\(size)-0")
    }
}

/// The VS Code Remote Tunnel half: a CLI is there, nobody is signed in, starting asks for a
/// device code; `pushTunnel` delivers what the daemon would push next.
extension FakeWorkspaceClient: DaemonTunnelAPI {
    static func tunnel(_ state: TunnelState) -> VsCodeTunnelStatus {
        VsCodeTunnelStatus(
            cli: VsCodeCli(path: "/usr/bin/code", version: "1.105.0", commit: nil, sha256: nil, managed: false),
            cliDownloadable: true, state: state, provider: .gitHub)
    }

    func pushTunnel(_ state: TunnelState) {
        self.state.withLock { $0.listener }?.onWorkspaceEvent(event: .vsCodeTunnel(status: Self.tunnel(state)))
    }

    func vscodeTunnelStatus() async throws -> VsCodeTunnelStatus {
        record("tunnelStatus")
        return Self.tunnel(.stopped)
    }

    func vscodeCliInstall(acceptLicense: Bool) async throws -> VsCodeTunnelStatus {
        record("cliInstall \(acceptLicense)")
        return Self.tunnel(.stopped)
    }

    func vscodeTunnelStart(start: VsCodeTunnelStart) async throws -> VsCodeTunnelStatus {
        record("tunnelStart \(start.acceptServerLicense) \(start.provider)")
        return Self.tunnel(.needsLogin(login: DeviceLogin(
            provider: start.provider, verificationUrl: "https://github.com/login/device", userCode: "ABCD-1234", atMs: 0)))
    }

    func vscodeTunnelStop() async throws -> VsCodeTunnelStatus {
        record("tunnelStop")
        return Self.tunnel(.stopped)
    }

    func vscodeTunnelOpen(open: VsCodeTunnelOpen) async throws -> VsCodeTunnelOpened {
        record("tunnelOpen \(open.path):\(open.line ?? 0)")
        return VsCodeTunnelOpened(
            name: "studio", folder: open.folder ?? "/home/me/proj",
            webUrl: "https://vscode.dev/tunnel/studio\(open.folder ?? "/home/me/proj")",
            desktopUri: "vscode://vscode-remote/tunnel+studio\(open.path)", inWindow: false)
    }
}

/// A connected `DaemonConnection` over the fake, and a context on it.
@MainActor
func fakeContext(_ client: FakeWorkspaceClient, directory: String? = "/home/me/proj", pane: UInt64? = 1) throws -> HostContext {
    let connection = DaemonConnection(hostId: "h1", ticket: "t") { _, listener in
        client.state.withLock { $0.events = listener }
        return client
    }
    try connection.connect()
    return HostContext(hostId: "h1", name: "studio", daemon: connection, pane: pane, directory: directory)
}
