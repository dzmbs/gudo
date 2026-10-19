import DesignSystem
import Foundation
import HostKit
import Observation
import PaneLayout
import UnnamedCore

// The screens' data sources over the real models (HostKit's `HostsModel` and the daemons'
// pane metadata). `MockData.swift` holds the `-mock` stand-ins; the screens cannot tell them
// apart. The Inbox, Files, Diff, Editor, Browser and Links sources are in
// `LiveWorkspaceSources.swift` (docs/APP-ARCHITECTURE.md §10).

// MARK: - Hosts

/// `HostsModel` as the Hosts screen, the palette and the sidebar see it: this device first, then
/// the saved hosts with their live status, agents and helper installs.
@MainActor
@Observable
final class LiveHostDirectory: HostDirectory {
    static let localId = "local"

    @ObservationIgnored let app: AppModel
    @ObservationIgnored weak var window: WindowModel?

    init(app: AppModel) {
        self.app = app
    }

    var hosts: [HostSummary] {
        (LaunchOptions.hasLocalShell ? [local] : []) + app.hosts.entries.map(summary)
    }

    var isOffline: Bool { app.hosts.network.isOffline }

    private var local: HostSummary {
        #if os(macOS)
        let address = "\(NSUserName())@localhost · login shell"
        #else
        let address = "scratch shell · local echo"
        #endif
        return HostSummary(
            id: Self.localId, name: WindowModel.deviceName, address: address, kind: .local, connection: .connected,
            sessionCount: app.existingWorkspace(for: .local)?.session.tabs.count ?? 0, agentCounts: [:],
            lastSeen: .now, isPinned: false)
    }

    private func summary(_ entry: HostEntry) -> HostSummary {
        let connection = app.hosts.connection(entry.id)
        let daemon = connection as? DaemonConnection
        var counts: [DesignSystem.AgentState: Int] = [:]
        for meta in daemon?.meta.values ?? [:].values {
            if let agent = meta.agent { counts[DesignSystem.AgentState(agent.state), default: 0] += 1 }
        }
        let sessions: Int
        if let daemon, daemon.isReady {
            sessions = daemon.layout.session.tabs.count
        } else if connection is SshConnection, entry.status.isLive {
            sessions = 1
        } else {
            sessions = 0
        }
        var needsYou: String?
        if let blocked = daemon?.blockedAgents.values.first, case .blocked(_, let summary, _) = blocked.state {
            needsYou = "\(AgentKind(blocked.kind).title): \(summary)"
        } else if entry.status.needsUser {
            needsYou = entry.status.summary
        }
        let statusLine: String? = switch entry.status {
        case .connected(let rtt?): "Connected · \(Int((rtt / .milliseconds(1)).rounded())) ms"
        case .idle: entry.lastConnected == nil ? "Not connected yet" : nil
        case .suspended: "Paused while in the background"
        default: nil
        }
        return HostSummary(
            id: entry.id, name: entry.name, address: entry.address,
            kind: entry.kind == .daemon ? .daemon : .ssh,
            connection: ConnectionState(listing: entry.status),
            sessionCount: sessions, agentCounts: counts, needsYou: needsYou,
            lastSeen: entry.lastConnected ?? .distantPast, isPinned: entry.pinned,
            statusLine: statusLine, progress: app.hosts.installs[entry.id]?.summary,
            canInstallHelper: entry.canInstallHelper)
    }

    func connect(_ id: HostSummary.ID) {
        window?.destination = .terminal
        window?.show(id == Self.localId ? .local : .host(id))
    }

    func forget(_ id: HostSummary.ID) {
        guard id != Self.localId else { return }
        let shown = window?.workspace?.hostId == id
        app.hosts.remove(id)
        if shown { window?.show(.local) }
    }

    func togglePin(_ id: HostSummary.ID) {
        guard let record = app.hosts.record(id) else { return }
        app.hosts.setPinned(id, !record.pinned)
    }

    func rename(_ id: HostSummary.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, app.hosts.record(id) != nil else { return }
        app.hosts.rename(id, to: trimmed)
    }

    func retry(_ id: HostSummary.ID) {
        if let connection = app.hosts.connection(id) {
            connection.retry()
        } else {
            _ = try? app.hosts.open(id)
        }
    }

    func disconnect(_ id: HostSummary.ID) {
        let shown = window?.workspace?.hostId == id
        app.hosts.disconnect(id)
        if shown { window?.show(.local) }
    }

    func installHelper(_ id: HostSummary.ID) async throws {
        // The install runs over the host's live SSH session: connect first if needed.
        if let ssh = try app.hosts.open(id) as? SshConnection {
            try await ssh.connected()
        }
        try await app.hosts.installHelper(id)
    }

    func quickConnect(_ destination: String) {
        window?.addHost(mode: .ssh, destination: destination)
    }

    func pair(ticket: String, name: String?) async throws -> HostSummary.ID {
        let trimmed = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try URL(string: trimmed).flatMap(PairingTicket.init(url:)) ?? PairingTicket(trimmed)
        return try await app.hosts.pair(parsed, name: name)
    }
}

extension ConnectionState {
    /// A saved host's status for the hosts list, where "not connected" is a state of its own.
    init(listing status: ConnectionStatus) {
        if case .idle = status {
            self = .disconnected
        } else {
            self.init(status, since: .now)
        }
    }
}

// MARK: - Agents

extension DesignSystem.AgentState {
    /// The daemon's agent state (OSC 7501 / hooks, through `PaneMeta.agent`).
    init(_ state: UnnamedCore.AgentState) {
        switch state {
        case .idle: self = .idle
        case .running: self = .working
        case .blocked: self = .blocked
        case .done: self = .done
        }
    }
}

extension AgentKind {
    init(_ kind: String) {
        switch kind.lowercased() {
        case let name where name.contains("claude"): self = .claude
        case let name where name.contains("codex"): self = .codex
        default: self = .other
        }
    }
}

/// Status glyphs for the panes of the window's daemon (`PaneMeta.agent`); nothing for local and
/// plain-SSH panes, which do not report status.
@MainActor
@Observable
final class LivePaneStatus: PaneStatusSource {
    @ObservationIgnored weak var window: WindowModel?

    private func meta(of pane: String) -> PaneMeta? {
        guard let daemon = window?.workspace?.host as? DaemonConnection else { return nil }
        return daemon.meta.first { $0.key.description == pane }?.value
    }

    func state(of pane: String) -> DesignSystem.AgentState? {
        meta(of: pane)?.agent.map { DesignSystem.AgentState($0.state) }
    }

    func program(of pane: String) -> String? {
        meta(of: pane)?.agent?.kind
    }
}

