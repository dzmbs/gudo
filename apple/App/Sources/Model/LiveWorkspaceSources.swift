import DesignSystem
import Foundation
import HostKit
import Observation
import os
import PaneLayout
import UnnamedCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Inbox, Files, Diff review, Editor, Browser ports, Links. Each source resolves "where" when it
// is asked — the window's host and focused pane, else the first connected daemon — so it follows
// the window without being rebuilt. `MockData.swift` holds the `-mock` stand-ins.

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "screens")

// MARK: - Where

/// A daemon host the screens act on, and the pane and directory they start from.
@MainActor
struct HostContext {
    let hostId: String
    let name: String
    let daemon: DaemonConnection
    /// The focused pane on that host (the window's, else the host's active tab's).
    let pane: UInt64?
    /// That pane's directory (OSC 7 / the daemon's cwd), if known.
    let directory: String?

    var hub: DaemonWorkspace { daemon.workspace }
    func api() throws -> any DaemonWorkspaceAPI { try hub.client() }

    /// The window's host when it is a connected daemon, else the first connected daemon.
    static func resolve(app: AppModel, window: WindowModel?) -> HostContext? {
        if let workspace = window?.workspace, let id = workspace.hostId,
           let daemon = workspace.host as? DaemonConnection, daemon.status.isLive || daemon.isReady {
            let pane = workspace.focusedPane
            // An agent pane may not report a directory (no shell integration until it exits):
            // then the tab's other panes say where the work is.
            let tabPanes = workspace.session.activeTab?.root.panes ?? []
            let directory = pane.flatMap { daemon.meta[$0]?.cwd?.nonEmpty }
                ?? pane.flatMap { workspace.panes[$0]?.workingDirectory.nonEmpty }
                ?? tabPanes.lazy.compactMap { daemon.meta[$0]?.cwd?.nonEmpty ?? workspace.panes[$0]?.workingDirectory.nonEmpty }.first
            return HostContext(
                hostId: id, name: app.hosts.record(id)?.name ?? id, daemon: daemon, pane: pane?.rawValue,
                directory: directory?.nonEmpty)
        }
        let candidates = app.hosts.connections.compactMap { id, connection -> (String, DaemonConnection)? in
            guard let daemon = connection as? DaemonConnection, daemon.status.isLive else { return nil }
            return (id, daemon)
        }.sorted { $0.0 < $1.0 }
        guard let (id, daemon) = candidates.first else { return nil }
        let pane = daemon.layout.session.activeTab?.focused
        return HostContext(
            hostId: id, name: app.hosts.record(id)?.name ?? id, daemon: daemon, pane: pane?.rawValue,
            directory: pane.flatMap { daemon.meta[$0]?.cwd }?.nonEmpty)
    }

    static let noHost = "Files, changes, ports and the editor come from a host running the helper. Connect one in Hosts."
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A workspace error in words (the generated `errorDescription` is the Swift reflection).
enum ScreenError {
    static func describe(_ error: any Error) -> String {
        if let error = error as? WorkspaceError {
            switch error {
            case .Denied(let message): return "Not allowed: \(message)"
            case .NotFound(let message): return "Not found: \(message)"
            case .Conflict(let message): return message
            case .Invalid(let message): return message
            case .Unavailable(let message): return message
            case .Failed(let message): return message
            case .Disconnected: return "The host is not connected. It will resume when it is back."
            }
        }
        if let error = error as? MultiplayerError {
            return String(describing: error)
        }
        if let error = error as? HostError { return error.localizedDescription }
        return SshErrorText.describe(error)
    }
}

// MARK: - Inbox

/// The agents of every connected daemon (`PaneMeta.agent`) merged with each daemon's attention
/// feed (finished turns, failures, long commands, unseen counts). Approve and Deny are signed
/// decisions; Reply types through the composer path; New Agent launches a pane.
@MainActor
@Observable
final class LiveAgentFeed: AgentFeed {
    @ObservationIgnored let hosts: HostsModel
    @ObservationIgnored weak var window: WindowModel?
    /// Items the user marked done (hidden until their state changes).
    private var dismissed: [AgentItem.ID: DesignSystem.AgentState] = [:]
    /// Approved or denied: shown as working until the daemon reports the next state.
    private var answered: [AgentItem.ID: UInt64] = [:]
    /// When each item entered its current state.
    @ObservationIgnored private var since: [AgentItem.ID: (DesignSystem.AgentState, Date)] = [:]

    /// History items kept (newest first); the daemon keeps 500.
    static let historyLimit = 40

    init(hosts: HostsModel) {
        self.hosts = hosts
        followConnections()
    }

    /// Every connected daemon gets its workspace hub (attention feed) as soon as it connects.
    private func followConnections() {
        withObservationTracking {
            for connection in hosts.connections.values {
                if let daemon = connection as? DaemonConnection { _ = daemon.workspace }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followConnections() }
        }
    }

    private var daemons: [(id: String, name: String, daemon: DaemonConnection)] {
        hosts.connections.compactMap { id, connection in
            guard let daemon = connection as? DaemonConnection else { return nil }
            return (id, hosts.record(id)?.name ?? id, daemon)
        }.sorted { $0.name < $1.name }
    }

    var items: [AgentItem] {
        var result: [AgentItem] = []
        for (hostId, hostName, daemon) in daemons {
            result += Self.items(
                hostId: hostId, hostName: hostName, meta: daemon.meta,
                attention: daemon.existingWorkspace?.attention ?? [], answered: answered
            ).filter { dismissed[$0.id] != $0.state }
        }
        return result.map { item in
            var item = item
            item.since = entered(item.id, item.state, at: item.since)
            return item
        }.sorted { ($0.state.urgency, $1.since) < ($1.state.urgency, $0.since) }
    }

    /// One host's items: live agents (with their latest attention item for summary and unseen),
    /// then finished history whose pane is gone, and long commands. Pure, for tests.
    static func items(
        hostId: String, hostName: String, meta: [PaneId: PaneMeta], attention: [AttentionItem],
        answered: [AgentItem.ID: UInt64] = [:]
    ) -> [AgentItem] {
        var result: [AgentItem] = []
        let byPane = Dictionary(grouping: attention, by: \.paneId).mapValues { $0.max { $0.id < $1.id }! }
        var livePanes = Set<UInt64>()
        for (pane, meta) in meta {
            guard let agent = meta.agent else { continue }
            livePanes.insert(pane.rawValue)
            let id = "\(hostId)/\(pane.rawValue)"
            var state = DesignSystem.AgentState(agent.state)
            var request: AgentItem.Request?
            var prompt = meta.title
            if case .blocked(let requestId, let summary, let options) = agent.state {
                if answered[id] == requestId {
                    state = .working
                } else {
                    request = options.isEmpty ? .question(summary) : .permission(tool: "Wants to run", detail: summary)
                    // The title often repeats the request (Claude puts it there): say what it waits for.
                    let title = meta.title.trimmingCharacters(in: .whitespaces)
                    let repeats = title.isEmpty || summary.contains(title) || title.contains(summary)
                        || title.lowercased() == agent.kind.lowercased() || title == AgentKind(agent.kind).title
                    prompt = repeats ? (options.isEmpty ? "Has a question" : "Waiting for your approval") : title
                }
            }
            let latest = byPane[pane.rawValue]
            // The pane title is often just the agent's name; say what it is doing instead.
            if prompt.isEmpty || prompt == AgentKind(agent.kind).title || prompt.lowercased() == agent.kind.lowercased() {
                switch state {
                case .working: prompt = "Working…"
                case .idle, .done: prompt = "Waiting for your next prompt"
                default: break
                }
            }
            var summary: String?
            if state == .done || state == .idle, let latest, latest.kind.isFinish {
                summary = latest.body.nonEmpty ?? latest.title.nonEmpty
                if case .agentFailed = latest.kind { state = .error }
            }
            result.append(AgentItem(
                id: id, agent: AgentKind(agent.kind), hostName: hostName,
                sessionTitle: meta.cwd.map { ($0 as NSString).lastPathComponent } ?? meta.title,
                state: state == .idle ? .done : state,
                since: latest.map { Date(timeIntervalSince1970: Double($0.atMs) / 1000) } ?? .now,
                prompt: prompt.nonEmpty ?? AgentKind(agent.kind).title,
                request: request, summary: summary, hostId: hostId, paneId: pane.rawValue,
                unseen: latest.map { !$0.seen } ?? false, canReply: request == nil || options(agent).isEmpty))
        }
        // History: finished agents whose pane is gone, and long commands.
        var history: [AgentItem] = []
        for item in attention.sorted(by: { $0.id > $1.id }) {
            let date = Date(timeIntervalSince1970: Double(item.atMs) / 1000)
            switch item.kind {
            case .agentDone(let agent), .agentFailed(let agent):
                guard !livePanes.contains(item.paneId) else { continue }
                let failed = if case .agentFailed = item.kind { true } else { false }
                history.append(AgentItem(
                    id: "\(hostId)/a\(item.id)", agent: AgentKind(agent), hostName: hostName,
                    sessionTitle: item.title.nonEmpty ?? "Agent", state: failed ? .error : .done, since: date,
                    prompt: item.title.nonEmpty ?? AgentKind(agent).title, summary: item.body.nonEmpty,
                    hostId: hostId, paneId: item.paneId, unseen: !item.seen))
            case .commandFinished(let mark):
                let exit = mark.finished?.exit
                let duration = mark.finished.map { Duration.milliseconds(Int64($0.durationMs)) }
                var words: [String] = []
                if let exit { words.append(exit == 0 ? "Exited 0" : "Exited \(exit)") }
                if let duration { words.append(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))) }
                history.append(AgentItem(
                    id: "\(hostId)/a\(item.id)", agent: .other, hostName: hostName,
                    sessionTitle: mark.cwd.map { ($0 as NSString).lastPathComponent } ?? item.title,
                    state: (exit ?? 0) == 0 ? .done : .error, since: date,
                    prompt: mark.command?.nonEmpty ?? item.title, summary: words.joined(separator: " · ").nonEmpty,
                    hostId: hostId, paneId: item.paneId, unseen: !item.seen, isCommand: true))
            case .agentBlocked:
                continue
            }
            if history.count == historyLimit { break }
        }
        return result + history
    }

    private static func options(_ agent: AgentStatus) -> [DecisionOption] {
        if case .blocked(_, _, let options) = agent.state { return options }
        return []
    }

    private func entered(_ id: AgentItem.ID, _ state: DesignSystem.AgentState, at reported: Date) -> Date {
        if let (known, date) = since[id], known == state { return date }
        // Running agents count from when this device saw them start; the rest from the feed.
        let date = state == .working ? Date.now : reported
        since[id] = (state, date)
        return date
    }

    var unseenByHost: [String: Int] {
        var result: [String: Int] = [:]
        for (_, name, daemon) in daemons {
            if let unseen = daemon.existingWorkspace?.unseen, unseen > 0 { result[name] = unseen }
        }
        return result
    }

    var launchHosts: [LaunchHost] {
        daemons.filter { $0.daemon.status.isLive }.map { id, name, daemon in
            let context = HostContext.resolve(app: AppModel.shared, window: window)
            let directory = context?.hostId == id ? context?.directory : daemon.layout.session.activeTab.flatMap { daemon.meta[$0.focused]?.cwd }
            return LaunchHost(id: id, name: name, directory: directory)
        }
    }

    func approve(_ id: AgentItem.ID) { decide(id, allow: true) }
    func deny(_ id: AgentItem.ID) { decide(id, allow: false) }

    var knocks: [KnockItem] {
        daemons.flatMap { id, name, daemon in
            let session = daemon.multiplayer
            guard session.isOwner else { return [KnockItem]() }
            return session.knocks.map { KnockItem(hostId: id, hostName: name, knock: $0, session: session) }
        }
    }

    func approval(_ id: AgentItem.ID) -> ApprovalContext? {
        guard let (daemon, pane) = try? target(id),
              let agent = daemon.meta[PaneId(pane)]?.agent,
              case .blocked(let request, _, _) = agent.state
        else { return nil }
        let session = daemon.multiplayer
        guard session.me != nil else { return nil }
        // The host classifies each request's risk (from the tool) when the agent blocks.
        let risk = session.approvalStatuses[request]?.risk ?? .any
        let mine = session.approvalStatuses[request]?.claimedBy?.actor.principal == session.myPrincipal
        return ApprovalContext(
            block: session.approvalBlock(requestId: request, risk: risk),
            progress: session.approvalProgress(requestId: request),
            claimMode: session.approvalPolicy.mode == .claim && session.canApprove,
            claimedByMe: mine,
            approvedAlready: session.approvedAlready(requestId: request))
    }

    func claim(_ id: AgentItem.ID, _ claim: Bool) {
        guard let (daemon, pane) = try? target(id),
              case .blocked(let request, _, _)? = daemon.meta[PaneId(pane)]?.agent?.state
        else { return }
        Task { await daemon.multiplayer.claim(request, claim) }
    }

    func reply(_ id: AgentItem.ID, text: String) async throws {
        let (daemon, pane) = try target(id)
        let api = try daemon.workspace.client()
        _ = try await api.prompt(paneId: pane, text: text, submit: true)
    }

    func markDone(_ id: AgentItem.ID) {
        if let item = items.first(where: { $0.id == id }) { dismissed[id] = item.state }
        if let (daemon, pane) = try? target(id) {
            Task { await daemon.workspace.markSeen(pane: pane) }
        }
    }

    func markSeen() {
        for (_, _, daemon) in daemons {
            guard let hub = daemon.existingWorkspace, hub.unseen > 0 else { continue }
            Task { await hub.markSeen() }
        }
    }

    func open(_ id: AgentItem.ID) {
        guard let (daemon, pane) = try? target(id) else { return }
        Task { await daemon.workspace.markSeen(pane: pane) }
        window?.reveal(host: daemon.hostId, pane: pane)
    }

    func launch(_ request: AgentLaunchRequest) async throws -> String? {
        guard let daemon = hosts.connection(request.hostId) as? DaemonConnection else { throw HostError.notConnected }
        let api = try daemon.workspace.client()
        let session = daemon.layout.session
        guard let splitFrom = session.activeTab?.focused ?? session.tabs.first?.root.panes.first else {
            throw WorkspaceError.Unavailable(message: "Open a terminal on \(hosts.record(request.hostId)?.name ?? "the host") first.")
        }
        let directory = launchHosts.first { $0.id == request.hostId }?.directory ?? daemon.meta[splitFrom]?.cwd
        let worktree: String? = nil
        if request.worktree {
            // A new task (git workspace): worktree, branch and its own tab, setup first.
            guard let repo = request.repo ?? directory else {
                throw WorkspaceError.Invalid(message: "The pane has no directory to make a worktree of.")
            }
            guard let session = daemon.layout.sessionId else { throw HostError.notConnected }
            let used = Set(daemon.layout.session.tabs.compactMap(\.title))
            let made = try await daemon.workspace.repoClient().taskCreate(task: TaskCreate(
                repo: repo, sessionId: session, name: request.name?.nonEmpty ?? FriendlyName.make(avoiding: used),
                branch: request.branch?.nonEmpty, base: nil,
                agent: request.shell ? nil : (request.agent == .codex ? .codex : .claude), prompt: nil))
            window?.reveal(host: request.hostId, pane: made.paneId)
            if !request.shell, let prompt = request.prompt.nonEmpty {
                let pane = made.paneId
                let title = request.agent.title
                Task { [weak self] in
                    do {
                        // Setup may run first.
                        try await Self.typeWhenReady(prompt, pane: pane, daemon: daemon, timeout: .seconds(600))
                    } catch {
                        self?.window?.toasts.show(Toast(
                            "\(title) is running, but the prompt was not typed: \(ScreenError.describe(error))",
                            systemImage: "exclamationmark.circle", style: .failure))
                    }
                }
            }
            daemon.workspace.notePort(made.worktree.port, worktree: made.worktree.path)
            return [made.worktree.port.map { "PORT \($0)" }, made.setup.map { "running setup first: \($0)" }]
                .compactMap(\.self).joined(separator: " · ").nonEmpty
        }
        if request.shell {
            guard let session = daemon.layout.sessionId else { throw HostError.notConnected }
            let pane = try await daemon.workspace.repoClient().scriptRun(
                cwd: request.repo ?? directory ?? "~", sessionId: session, name: request.name ?? "", command: "")
            window?.reveal(host: request.hostId, pane: pane)
            return nil
        }
        let started = ContinuousClock.now
        // The pane first (the sheet closes and the pane shows at once); the first prompt is
        // typed through the composer path once the agent reports it is ready.
        let launched = try await api.launchAgentPane(launch: AgentLaunch(
            splitFrom: splitFrom.rawValue, agent: request.agent == .codex ? .codex : .claude, axis: .horizontal,
            worktree: worktree, cwd: worktree == nil ? directory : nil, resume: nil,
            prompt: nil, submit: true, readyTimeoutMs: 30_000))
        log.info("launched \(request.agent.rawValue, privacy: .public) pane=\(launched.paneId) in \((ContinuousClock.now - started) / .milliseconds(1), format: .fixed(precision: 0)) ms")
        window?.reveal(host: request.hostId, pane: launched.paneId)
        if let prompt = request.prompt.nonEmpty {
            let pane = launched.paneId
            let title = request.agent.title
            Task { [weak self] in
                do {
                    try await Self.typeWhenReady(prompt, pane: pane, daemon: daemon)
                } catch {
                    self?.window?.toasts.show(Toast(
                        "\(title) is running, but the prompt was not typed: \(ScreenError.describe(error))",
                        systemImage: "exclamationmark.circle", style: .failure))
                }
            }
        }
        return nil
    }

    /// Waits (up to a minute) for a new agent pane to report idle, then types `prompt` into it.
    static func typeWhenReady(_ prompt: String, pane: UInt64, daemon: DaemonConnection, timeout: Duration = .seconds(60)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let agent = daemon.meta[PaneId(pane)]?.agent, case .idle = agent.state { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let agent = daemon.meta[PaneId(pane)]?.agent, case .idle = agent.state else {
            throw WorkspaceError.Unavailable(message: "the agent did not become ready in time")
        }
        _ = try await daemon.workspace.client().prompt(paneId: pane, text: prompt, submit: true)
    }

    private func target(_ id: AgentItem.ID) throws -> (DaemonConnection, UInt64) {
        guard let item = items.first(where: { $0.id == id }) ?? historyItem(id),
              let hostId = item.hostId, let pane = item.paneId,
              let daemon = hosts.connection(hostId) as? DaemonConnection
        else { throw HostError.notConnected }
        return (daemon, pane)
    }

    private func historyItem(_ id: AgentItem.ID) -> AgentItem? {
        let parts = id.split(separator: "/")
        guard parts.count == 2, let raw = UInt64(parts[1]) else { return nil }
        return AgentItem(id: id, agent: .other, hostName: "", sessionTitle: "", state: .idle, since: .now, prompt: "",
                         hostId: String(parts[0]), paneId: raw)
    }

    private func decide(_ id: AgentItem.ID, allow: Bool) {
        let parts = id.split(separator: "/")
        guard parts.count == 2, let raw = UInt64(parts[1]),
              let daemon = hosts.connection(String(parts[0])) as? DaemonConnection,
              let agent = daemon.meta[PaneId(raw)]?.agent,
              case .blocked(let request, _, let options) = agent.state, !options.isEmpty
        else { return }
        guard let option = Self.option(options, allow: allow) else { return }
        answered[id] = request
        daemon.decide(requestId: request, optionId: option.id)
    }

    // MARK: Approval verbs (edited input, approve all like this)

    /// The live agent behind an item: its daemon, pane, the request it is blocked on and that
    /// request's allow option.
    private func blocked(_ id: AgentItem.ID) -> (daemon: DaemonConnection, pane: UInt64, request: UInt64, allow: UInt32)? {
        let parts = id.split(separator: "/")
        guard parts.count == 2, let raw = UInt64(parts[1]),
              let daemon = hosts.connection(String(parts[0])) as? DaemonConnection,
              let agent = daemon.meta[PaneId(raw)]?.agent,
              case .blocked(let request, _, let options) = agent.state, answered[id] != request,
              let allow = Self.option(options, allow: true)
        else { return nil }
        return (daemon, raw, request, allow.id)
    }

    func approvalOptions(_ id: AgentItem.ID) -> AgentApprovalOptions? {
        guard let target = blocked(id),
              let info = target.daemon.approvals.request(pane: target.pane, blockedOn: target.request)
        else { return nil }
        guard info.editableInput != nil || info.like != nil else { return nil }
        return AgentApprovalOptions(editableInput: info.editableInput, likeThis: info.like?.label)
    }

    func autoApprovals(_ id: AgentItem.ID) -> [AgentAutoApproval] {
        let parts = id.split(separator: "/")
        guard parts.count == 2, let raw = UInt64(parts[1]),
              let daemon = hosts.connection(String(parts[0])) as? DaemonConnection
        else { return [] }
        return (daemon.approvals.rules[raw] ?? []).map { rule in
            AgentAutoApproval(id: rule.id, label: rule.match.label, expiresAt: rule.expiresAt,
                              turnsLeft: rule.turnsLeft, uses: rule.uses, grantedBy: rule.grantedBy)
        }
    }

    func approveEdited(_ id: AgentItem.ID, input: String) async throws {
        guard let target = blocked(id) else { throw HostError.notConnected }
        try await target.daemon.approvals.approveEdited(paneId: target.pane, requestId: target.request, optionId: target.allow, input: input)
        answered[id] = target.request
    }

    func approveAllLikeThis(_ id: AgentItem.ID) async throws {
        guard let target = blocked(id),
              let like = target.daemon.approvals.request(pane: target.pane, blockedOn: target.request)?.like
        else { throw ApprovalUnavailable() }
        try await target.daemon.approvals.approveAllLikeThis(
            paneId: target.pane, requestId: target.request, match: like,
            minutes: AgentAutoApproval.minutes, turns: AgentAutoApproval.turns)
        answered[id] = target.request
    }

    func revokeAutoApproval(_ id: AgentItem.ID, rule: AgentAutoApproval.ID) async throws {
        let parts = id.split(separator: "/")
        guard parts.count == 2, let raw = UInt64(parts[1]),
              let daemon = hosts.connection(String(parts[0])) as? DaemonConnection
        else { throw HostError.notConnected }
        try await daemon.approvals.revoke(paneId: raw, ruleId: rule)
    }

    /// The option that means yes (or no): by its words, else the first (last).
    static func option(_ options: [DecisionOption], allow: Bool) -> DecisionOption? {
        let yes = ["allow", "yes", "approve", "accept", "proceed", "continue"]
        let no = ["deny", "no", "reject", "decline", "cancel", "stop"]
        let words = allow ? yes : no
        let match = options.first { option in
            let label = option.label.lowercased()
            // "No, and tell Claude…" must not match "no" for allow; check whole words.
            let tokens = label.split { !$0.isLetter }.map(String.init)
            return words.contains { tokens.contains($0) }
        }
        return match ?? (allow ? options.first : options.last)
    }
}

extension AttentionKind {
    /// An agent finished or failed (not blocked, not a command).
    var isFinish: Bool {
        switch self {
        case .agentDone, .agentFailed: true
        default: false
        }
    }
}

// MARK: - Files

@MainActor
final class LiveFileSource: FileSource {
    @ObservationIgnored weak var window: WindowModel?
    let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// Tests: where the source acts, instead of the window's host.
    @ObservationIgnored var contextOverride: (() -> HostContext?)?

    private var context: HostContext? {
        if let contextOverride { return contextOverride() }
        return HostContext.resolve(app: app, window: window)
    }

    var root: String { context?.directory ?? "~" }
    var hostName: String { context?.name ?? WindowModel.deviceName }
    var unavailableReason: String? { context == nil ? HostContext.noHost : nil }

    private func api() throws -> any DaemonWorkspaceAPI {
        guard let context else { throw HostError.notConnected }
        return try context.api()
    }

    /// Each host's home directory (`fsStat("~")`), for `display`.
    private var homes: [String: String] = [:]

    func display(_ path: String) -> String {
        guard let id = context?.hostId, let home = homes[id] else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    func list(_ directory: String) async throws -> [FileEntry] {
        let api = try api()
        if let id = context?.hostId, homes[id] == nil, let home = try? await api.fsStat(path: "~") {
            homes[id] = home.path
        }
        let listing = try await api.fsList(path: directory, showHidden: false)
        let status = try? await api.gitStatus(path: listing.path)
        return Self.entries(listing, git: status)
    }

    /// Listing entries with their git letters (a directory gets M when anything under it changed).
    static func entries(_ listing: DirListing, git: UnnamedCore.GitStatus?) -> [FileEntry] {
        var letters: [String: FileEntry.GitStatus] = [:]
        if let git {
            // Shell, git and the daemon may spell the same directory with or without /private.
            let directory = PathMatch.normalized(listing.path)
            let root = PathMatch.normalized(git.root)
            for file in git.files {
                let absolute = root + "/" + file.path
                guard absolute.hasPrefix(directory + "/") else { continue }
                let rest = absolute.dropFirst(directory.count + 1)
                if let slash = rest.firstIndex(of: "/") {
                    let child = directory + "/" + rest[..<slash]
                    if letters[child] == nil { letters[child] = .modified }
                } else {
                    letters[absolute] = FileEntry.GitStatus(file)
                }
            }
        }
        return listing.entries.map { stat in
            let isDirectory = stat.kind == .dir || stat.targetKind == .dir
            return FileEntry(
                path: stat.path, name: stat.name, isDirectory: isDirectory,
                size: isDirectory ? nil : Int64(stat.size),
                modified: Date(timeIntervalSince1970: Double(stat.modifiedMs) / 1000),
                git: letters[PathMatch.normalized(stat.path)], isSymlink: stat.kind == .symlink, isHidden: stat.hidden)
        }
    }

    func read(_ path: String) async throws -> String {
        let chunk = try await api().fsRead(path: path, offset: 0, len: 1 << 20)
        return String(decoding: chunk.data, as: UTF8.self)
    }

    /// Images up to this size are read whole (in 1 MiB requests) for the preview.
    static let imageLimit: UInt64 = 24 << 20

    func preview(_ path: String) async throws -> FilePreview {
        let api = try api()
        let stat = try await api.fsStat(path: path)
        if FilePreviewKind(path: path) == .image, stat.size <= Self.imageLimit {
            var data = Data()
            while UInt64(data.count) < stat.size {
                let chunk = try await api.fsRead(path: path, offset: UInt64(data.count), len: 1 << 20)
                data.append(chunk.data)
                if chunk.eof || chunk.data.isEmpty { break }
            }
            return .image(data)
        }
        let chunk = try await api.fsRead(path: path, offset: 0, len: 1 << 20)
        return Self.preview(chunk.data, size: Int64(stat.size), eof: chunk.eof)
    }

    /// Text when it decodes as UTF-8 without NULs, else binary.
    static func preview(_ data: Data, size: Int64, eof: Bool) -> FilePreview {
        if data.prefix(8192).contains(0) { return .binary(size: size) }
        // A chunk can end inside a multi-byte character: drop up to 3 trailing bytes.
        for trim in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                return .text(text, truncated: !eof)
            }
        }
        return .binary(size: size)
    }

    func mkdir(_ path: String) async throws {
        _ = try await api().fsMkdir(path: path, parents: false)
    }

    func rename(_ path: String, to name: String) async throws {
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        _ = try await api().fsRename(from: path, to: target, overwrite: false)
    }

    func trash(_ path: String) async throws {
        try await api().fsDelete(path: path, mode: .trash, recursive: true)
    }

    func upload(_ local: URL, to directory: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let api = try api()
        let scoped = local.startAccessingSecurityScopedResource()
        defer { if scoped { local.stopAccessingSecurityScopedResource() } }
        let name = local.lastPathComponent
        let reporter = TransferProgressHandler { done, total in
            let fraction = total == 0 ? 1 : Double(done) / Double(total)
            Task { @MainActor in progress(fraction) }
        }
        // Never replace a file: "name 2.ext" when the name is taken.
        for attempt in 1...50 {
            let candidate = attempt == 1 ? name : Self.numbered(name, attempt)
            let target = WriteTarget(
                path: (directory as NSString).appendingPathComponent(candidate), ifMatch: nil, createNew: true,
                mkdirs: false, mode: nil)
            do {
                _ = try await api.uploadFile(localPath: local.path, target: target, progress: reporter)
                return
            } catch WorkspaceError.Conflict {
                continue
            }
        }
        throw WorkspaceError.Conflict(message: "\(name) exists.")
    }

    static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
    }

    func download(_ path: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let api = try api()
        let folder = FileManager.default.temporaryDirectory.appending(path: "downloads/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appending(path: (path as NSString).lastPathComponent)
        let reporter = TransferProgressHandler { done, total in
            let fraction = total == 0 ? 1 : Double(done) / Double(total)
            Task { @MainActor in progress(fraction) }
        }
        _ = try await api.downloadFile(remotePath: path, localPath: local.path, offset: 0, len: nil, progress: reporter)
        return local
    }

    func watch(_ directory: String, onChange: @escaping @MainActor () -> Void) async -> FileWatch? {
        guard let hub = context?.hub else { return nil }
        do {
            let id = try await hub.watch(directory) { _ in onChange() }
            return FileWatch { [weak hub] in hub?.unwatch(id) }
        } catch {
            log.error("watch \(directory, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension FileEntry.GitStatus {
    init(_ file: GitFileStatus) {
        let change = file.unstaged == .unmodified ? file.staged : file.unstaged
        self.init(change)
    }

    init(_ change: FileChange) {
        switch change {
        case .added, .copied: self = .added
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        case .untracked: self = .untracked
        default: self = .modified
        }
    }
}

/// How a file previews, by its name.
enum FilePreviewKind {
    case image, other

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "ico": self = .image
        default: self = .other
        }
    }
}

// MARK: - Diff review

@MainActor
final class LiveDiffSource: DiffSource {
    @ObservationIgnored weak var window: WindowModel?
    let app: AppModel
    /// The repository root found by the last `repository()`.
    private var root: String?

    init(app: AppModel) {
        self.app = app
    }

    /// Tests: where the source acts, instead of the window's host.
    @ObservationIgnored var contextOverride: (() -> HostContext?)?

    private var context: HostContext? {
        if let contextOverride { return contextOverride() }
        return HostContext.resolve(app: app, window: window)
    }

    var title: String { "Changes" }
    var unavailableReason: String? { context == nil ? HostContext.noHost : nil }

    private func api() throws -> any DaemonWorkspaceAPI {
        guard let context else { throw HostError.notConnected }
        return try context.api()
    }

    func repository() async throws -> DiffRepository {
        guard let context else { throw HostError.notConnected }
        let status = try await context.api().gitStatus(path: context.directory ?? "~")
        root = status.root
        return DiffRepository(
            root: status.root, branch: status.branch, ahead: Int(status.ahead), behind: Int(status.behind),
            changedFiles: status.files.count)
    }

    func files(_ scope: DiffScope) async throws -> [DiffFile] {
        let api = try api()
        let path = try await repositoryRoot()
        let diff: GitDiff
        switch scope {
        case .workingTree:
            diff = try await api.gitDiff(request: GitDiffRequest(path: path, base: .head, files: [], context: 3, hunks: true))
        case .staged:
            diff = try await api.gitDiff(request: GitDiffRequest(path: path, base: .staged, files: [], context: 3, hunks: true))
        case .turn(let pane, let turn):
            diff = try await api.turnDiff(paneId: pane, turn: turn, context: 3, hunks: true)
        }
        return diff.files.map(DiffFile.init)
    }

    private func repositoryRoot() async throws -> String {
        if let root { return root }
        return try await repository().root
    }

    /// Agent panes on this host whose directory is in the repository.
    private func agentPanes() -> [(pane: UInt64, agent: String)] {
        guard let daemon = context?.daemon else { return [] }
        return daemon.meta.compactMap { pane, meta in
            guard let agent = meta.agent else { return nil }
            if let root, let cwd = meta.cwd, !PathMatch.isInside(cwd, root) { return nil }
            return (pane.rawValue, AgentKind(agent.kind).title)
        }.sorted { $0.pane < $1.pane }
    }

    func turns() async throws -> [DiffTurn] {
        let api = try api()
        _ = try await repositoryRoot()
        var result: [DiffTurn] = []
        for (pane, agent) in agentPanes() {
            guard let turns = try? await api.listTurns(paneId: pane) else { continue }
            for turn in turns where root == nil || PathMatch.isInside(turn.root, root!) || PathMatch.isInside(root!, turn.root) {
                result.append(DiffTurn(
                    pane: pane, turn: turn.turn, agent: agent,
                    started: Date(timeIntervalSince1970: Double(turn.startedAtMs) / 1000),
                    ended: turn.endedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }))
            }
        }
        return result.sorted { $0.started > $1.started }
    }

    private func reviewPane(for scope: DiffScope) -> (pane: UInt64, agent: String)? {
        let panes = agentPanes()
        if case .turn(let pane, _) = scope { return panes.first { $0.pane == pane } }
        if let focused = context?.pane, let match = panes.first(where: { $0.pane == focused }) { return match }
        return panes.first
    }

    func reviewer(for scope: DiffScope) -> String? { reviewPane(for: scope)?.agent }

    func sendReview(_ notes: [ReviewNote], scope: DiffScope, preamble: String?) async throws {
        guard let target = reviewPane(for: scope) else {
            throw WorkspaceError.Unavailable(message: "No agent is running in this repository.")
        }
        let request = ReviewRequest(
            paneId: target.pane, preamble: preamble?.nonEmpty,
            notes: notes.map {
                UnnamedCore.ReviewNote(
                    path: $0.path, startLine: UInt32($0.startLine), endLine: UInt32($0.endLine), oldSide: $0.oldSide,
                    quote: $0.quote, note: $0.note)
            },
            submit: true)
        _ = try await api().sendReview(review: request)
    }
}

/// Paths from the shell (OSC 7) and from git (physical) can differ by a symlinked prefix:
/// macOS's `/var` and `/tmp` are `/private/var` and `/private/tmp`.
enum PathMatch {
    static func normalized(_ path: String) -> String {
        var path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst("/private".count))
        }
        return path
    }

    /// `path` is `directory` or inside it.
    static func isInside(_ path: String, _ directory: String) -> Bool {
        let path = normalized(path), directory = normalized(directory)
        return path == directory || path.hasPrefix(directory + "/")
    }
}

extension DiffFile {
    /// A daemon file diff with old/new line numbers counted from each hunk's start.
    init(_ file: FileDiff) {
        var hunks: [DiffHunk] = []
        var lineId = 0
        for (index, hunk) in file.hunks.enumerated() {
            var old = Int(hunk.oldStart)
            var new = Int(hunk.newStart)
            var lines: [DiffLine] = []
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    lines.append(DiffLine(id: lineId, kind: .context, oldNumber: old, newNumber: new, text: line.text))
                    old += 1
                    new += 1
                case .added:
                    lines.append(DiffLine(id: lineId, kind: .added, oldNumber: nil, newNumber: new, text: line.text))
                    new += 1
                case .removed:
                    lines.append(DiffLine(id: lineId, kind: .removed, oldNumber: old, newNumber: nil, text: line.text))
                    old += 1
                case .noNewline:
                    continue
                }
                lineId += 1
            }
            let range = "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
            hunks.append(DiffHunk(id: index, header: hunk.header.isEmpty ? range : "\(range) \(hunk.header)", lines: lines))
        }
        self.init(
            path: file.path, status: FileEntry.GitStatus(file.change), additions: Int(file.additions),
            deletions: Int(file.deletions), hunks: hunks, oldPath: file.oldPath, isBinary: file.binary,
            hunksOmitted: file.hunksOmitted)
    }
}

// MARK: - Ports

@MainActor
@Observable
final class LivePortSource: PortSource {
    @ObservationIgnored weak var window: WindowModel? {
        didSet { follow() }
    }
    @ObservationIgnored let app: AppModel
    private(set) var offer: DetectedPort?
    /// Ports seen per host, so only new ones are offered.
    @ObservationIgnored private var known: [String: Set<UInt16>] = [:]
    @ObservationIgnored private var observed: Set<ObjectIdentifier> = []

    init(app: AppModel) {
        self.app = app
    }

    /// Tests: where the source acts, instead of the window's host.
    @ObservationIgnored var contextOverride: (() -> HostContext?)?

    private var context: HostContext? {
        if let contextOverride { return contextOverride() }
        return HostContext.resolve(app: app, window: window)
    }

    var hostName: String { context?.name ?? "" }

    var ports: [DetectedPort] {
        guard let context else { return [] }
        return Self.ports(context.hub.ports, meta: context.daemon.meta)
    }

    static func ports(_ ports: [PortInfo], meta: [PaneId: PaneMeta]) -> [DetectedPort] {
        ports.map { info in
            DetectedPort(
                port: info.port, process: info.process, url: info.url,
                isHTTP: info.kind == .http || info.kind == .https, loopbackOnly: info.loopbackOnly,
                pane: info.paneId.flatMap { meta[PaneId($0)]?.title.nonEmpty })
        }.sorted { ($0.isHTTP ? 0 : 1, $0.port) < ($1.isHTTP ? 0 : 1, $1.port) }
    }

    /// Watches the window's daemon for new HTTP ports (the offer).
    private func follow() {
        withObservationTracking {
            if let context {
                let hub = context.hub
                let id = ObjectIdentifier(hub)
                if !observed.contains(id) {
                    observed.insert(id)
                    known[context.hostId] = Set(hub.ports.map(\.port))
                    let hostId = context.hostId
                    hub.observePorts { [weak self] ports in self?.portsChanged(hostId, ports) }
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.follow() }
        }
    }

    func portsChanged(_ hostId: String, _ ports: [PortInfo]) {
        let before = known[hostId] ?? []
        known[hostId] = Set(ports.map(\.port))
        guard context?.hostId == hostId else { return }
        let fresh = ports.filter { !before.contains($0.port) && ($0.kind == .http || $0.kind == .https) }
        if let new = fresh.first, let port = Self.ports([new], meta: context?.daemon.meta ?? [:]).first {
            offer = port
        } else if let offer, !ports.contains(where: { $0.port == offer.port }) {
            self.offer = nil
        }
    }

    func dismissOffer() { offer = nil }

    func open(_ port: DetectedPort) async throws -> URL {
        guard let context else { throw HostError.notConnected }
        let api = try context.api()
        let local: UInt16
        if let existing = api.forwards().first(where: { if case .tcp(let p) = $0.target { p == port.port } else { false } }) {
            local = existing.localPort
        } else {
            do {
                local = try api.forward(localPort: port.port, target: .tcp(port: port.port))
            } catch {
                local = try api.forward(localPort: 0, target: .tcp(port: port.port))
            }
        }
        offer = nil
        return Self.url(for: port, localPort: local)
    }

    /// `http://localhost:<local>` plus the path of the URL the server printed. A printed
    /// `*.localhost` name is kept (S-BR1's fallback): it resolves to loopback, so it reaches the
    /// forward, and a server that routes by name (`app.localhost`) still sees it.
    static func url(for port: DetectedPort, localPort: UInt16) -> URL {
        var components = URLComponents()
        components.scheme = port.url.flatMap { URL(string: $0)?.scheme } == "https" ? "https" : "http"
        components.host = "localhost"
        components.port = Int(localPort)
        if let printed = port.url.flatMap(URLComponents.init(string:)) {
            if let host = printed.host?.lowercased(), host.hasSuffix(".localhost") { components.host = host }
            components.path = printed.path
            components.query = printed.query
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url ?? URL(string: "http://localhost:\(localPort)/")!
    }
}

// MARK: - Links, command output, search

@MainActor
final class LiveLinkSource: LinkSource {
    @ObservationIgnored weak var window: WindowModel?
    let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// The window's focused daemon pane (links are about what this window shows).
    private var target: (hub: DaemonWorkspace, pane: UInt64)? {
        guard let workspace = window?.workspace, let daemon = workspace.host as? DaemonConnection,
              let pane = workspace.focusedPane else { return nil }
        return (daemon.workspace, pane.rawValue)
    }

    var isAvailable: Bool { target != nil }

    func links() async throws -> [DetectedLink] {
        guard let target else { return localLinks() }
        let links = try await target.hub.links(pane: target.pane, commands: 20)
        return Self.links(links)
    }

    static func links(_ links: Links) -> [DetectedLink] {
        var seen = Set<String>()
        return links.links.enumerated().compactMap { index, link in
            guard seen.insert(link.text).inserted else { return nil }
            var fromCommand = false
            if case .command = link.source { fromCommand = true }
            return DetectedLink(
                kind: link.kind == .path ? .path : .url, text: link.text, line: fromCommand ? -(index + 1) : 0,
                target: link.target, targetLine: link.line.map(Int.init), targetColumn: link.column.map(Int.init),
                exists: link.exists, fromCommand: fromCommand)
        }
    }

    /// A local pane: URLs and paths in its visible text.
    private func localLinks() -> [DetectedLink] {
        guard let workspace = window?.workspace, let id = workspace.focusedPane, let pane = workspace.panes[id] else { return [] }
        return Self.scan(pane.view.surface.terminal.visibleText())
    }

    static func scan(_ text: String) -> [DetectedLink] {
        var result: [DetectedLink] = []
        var seen = Set<String>()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.reversed().enumerated() {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "'" || $0 == "\"" || $0 == "(" || $0 == ")" }) {
                var word = String(token)
                while let last = word.last, ".,;>]".contains(last) { word.removeLast() }
                guard word.count > 2, !seen.contains(word) else { continue }
                if word.hasPrefix("http://") || word.hasPrefix("https://") {
                    seen.insert(word)
                    result.append(DetectedLink(kind: .url, text: word, line: -offset))
                } else if word.hasPrefix("/") || word.hasPrefix("~/") || word.hasPrefix("./") {
                    seen.insert(word)
                    result.append(DetectedLink(kind: .path, text: word, line: -offset))
                }
            }
        }
        return result
    }

    func lastCommandOutput() async throws -> (command: String?, output: String) {
        guard let target else { throw WorkspaceError.Unavailable(message: "Command output comes from panes on a host with the helper.") }
        let output = try await target.hub.commandOutput(pane: target.pane)
        return (output.mark.command, output.text)
    }

    func countMatches(_ needle: String, caseSensitive: Bool) async throws -> Int? {
        guard let target, !needle.isEmpty else { return nil }
        let page = try await target.hub.search(
            pane: target.pane, query: SearchQuery(pattern: needle, mode: .plain, case: caseSensitive ? .sensitive : .insensitive), limit: 1)
        return Int(page.total)
    }
}

// MARK: - Window helpers

extension WindowModel {
    /// Puts the focused pane's last command output on the pasteboard (the daemon's command
    /// marks, so only the output, not the prompt).
    func copyLastCommandOutput() async {
        await copyCommandOutput { try await self.links.lastCommandOutput() }
    }

    /// Puts a command's output on the pasteboard and says how much (the palette's last
    /// command, a command block's Copy Output).
    func copyCommandOutput(_ fetch: () async throws -> (command: String?, output: String)) async {
        do {
            let (command, output) = try await fetch()
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                toasts.show(Toast("\(command.map { "`\($0)`" } ?? "The command") printed nothing", systemImage: "doc.on.clipboard", style: .neutral))
                return
            }
            #if canImport(UIKit)
            UIPasteboard.general.string = output
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            #endif
            let lines = output.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).count
            let what = command.map { "`\($0)`" } ?? "the last command"
            toasts.show(Toast("Copied \(lines) \(lines == 1 ? "line" : "lines") of \(what)", systemImage: "doc.on.clipboard", style: .success))
        } catch {
            toasts.show(Toast("Nothing to copy: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
        }
    }

    /// Applies the needle to the searched pane (highlights, its own count) and counts matches
    /// over the daemon's whole scrollback (debounced; `searchTotal` stays nil for local and
    /// plain-SSH panes, whose terminal holds all of it).
    func updateSearchCount() {
        applySearch()
        searchCountTask?.cancel()
        let needle = searchNeedle, caseSensitive = searchCaseSensitive
        if needle.isEmpty { searchTotal = nil }
        searchCountTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            let total = try? await self.links.countMatches(needle, caseSensitive: caseSensitive)
            guard !Task.isCancelled, self.searchNeedle == needle, self.searchCaseSensitive == caseSensitive else { return }
            self.searchTotal = total ?? nil
        }
    }
    /// Shows a host's pane in this window: switches to the host, then focuses the pane once
    /// its layout has it.
    func reveal(host: String, pane: UInt64) {
        destination = .terminal
        sheet = nil
        if workspace?.hostId != host { show(.host(host)) }
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                if let workspace = self?.workspace, workspace.hostId == host,
                   workspace.session.tabs.contains(where: { $0.root.panes.contains(PaneId(pane)) }) {
                    workspace.apply(.focus(PaneId(pane)))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
