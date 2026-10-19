import Foundation
import Observation
import os
import PaneLayout
import UnnamedCore

/// One row of the host list, ready to show (04-mobile-ux C2).
public struct HostEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: HostRecord.Kind
    /// `user@host[:port]`, or the daemon id for hosts paired by ticket.
    public var address: String
    public var status: ConnectionStatus
    /// Why the host is in "Needs you" (a blocked agent, a connection that needs the user), or
    /// nil.
    public var needsYou: String?
    public var blockedAgents: Int
    public var lastConnected: Date?
    public var pinned: Bool
    /// SSH hosts without the helper: offer "Install helper".
    public var canInstallHelper: Bool
}

/// Everything about hosts the UI binds to: the saved hosts, their live connections, pairing,
/// "just ssh", the helper install, ssh_config import, and the app lifecycle hooks that keep
/// connections healthy (04-mobile-ux R1–R12).
@MainActor
@Observable
public final class HostsModel {
    public private(set) var records: [HostRecord]
    /// Live connections by host id. Views hold the host id, never a socket (R7).
    public internal(set) var connections: [String: any HostConnection] = [:]
    /// Helper installs in progress, by host id.
    public private(set) var installs: [String: InstallProgress] = [:]
    /// What the last helper install said the user may want to know (e.g. lingering is off), by
    /// host id; cleared with `dismissNotes`.
    public private(set) var installNotes: [String: [String]] = [:]
    public let keys: KeyStore
    public let hostKeyPrompts = HostKeyPrompts()
    public let network = NetworkMonitor()
    /// Hosts imported from `~/.ssh/config` (aliases), not yet saved.
    public private(set) var sshConfigAliases: [SshHostConfig] = []

    public struct Configuration: Sendable {
        /// Relay use for daemon connections (`.disabled` for LAN-only tests).
        public var relay: RelayMode = .default
        /// Keep the core's VT mirror (pane text for tests and diagnostics).
        public var mirrorVt = false
        /// The daemon builds to install (the app bundles gzipped Linux builds).
        public var hostdBinaries: @Sendable () -> HostdBinaries = { HostdBinaries(linuxAarch64: nil, linuxX8664: nil, macosAarch64: nil, macosX8664: nil) }
        public init() {}
    }

    @ObservationIgnored public let secrets: any SecretStore
    @ObservationIgnored private let repository: HostRepository
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private var deviceKey: Data?
    @ObservationIgnored private lazy var knownHosts = KnownHosts.load(from: secrets)
    @ObservationIgnored var dialer: DaemonDialer?
    @ObservationIgnored var joinDialer: DaemonDialer?
    private static let log = Logger(subsystem: Log.subsystem, category: "hosts")

    public init(secrets: any SecretStore, repository: HostRepository, configuration: Configuration = .init()) {
        self.secrets = secrets
        self.repository = repository
        self.configuration = configuration
        records = repository.load()
        keys = KeyStore(secrets: secrets, directory: repository.directory)
        network.onChange = { [weak self] in self?.networkChanged() }
    }

    // MARK: The list

    /// Hosts sorted for Home: "Needs you" first, then pinned, then most recently used.
    public var entries: [HostEntry] {
        records.map(entry).sorted { a, b in
            if (a.needsYou != nil) != (b.needsYou != nil) { return a.needsYou != nil }
            if a.pinned != b.pinned { return a.pinned }
            let (da, db) = (a.lastConnected ?? .distantPast, b.lastConnected ?? .distantPast)
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func record(_ id: String) -> HostRecord? {
        records.first { $0.id == id }
    }

    private func entry(_ record: HostRecord) -> HostEntry {
        let connection = connections[record.id]
        let status = connection?.status ?? .idle
        let blocked = (connection as? DaemonConnection)?.blockedAgents ?? [:]
        var needsYou: String?
        if let agent = blocked.values.first, case .blocked(_, let summary, _) = agent.state {
            needsYou = "\(agent.kind.capitalized): \(summary)"
        } else if status.needsUser {
            needsYou = status.summary
        } else if case .reconnecting = status {
            needsYou = status.summary
        }
        return HostEntry(
            id: record.id, name: record.name, kind: record.kind,
            address: record.ssh?.display ?? record.daemonId.map { String($0.prefix(16)) } ?? "",
            status: status, needsYou: needsYou, blockedAgents: blocked.count,
            lastConnected: record.lastConnected, pinned: record.pinned,
            canInstallHelper: record.kind == .ssh)
    }

    // MARK: Connections

    /// The live connection for a host, connecting it if needed.
    @discardableResult
    public func open(_ id: String) throws -> any HostConnection {
        if let existing = connections[id] { return existing }
        guard let record = record(id) else { throw HostError.notConnected }
        let connection: any HostConnection
        switch record.kind {
        case .daemon:
            connection = try openDaemon(record)
        case .ssh:
            connection = try openSSH(record, password: nil)
        }
        touch(id)
        return connection
    }

    public func connection(_ id: String) -> (any HostConnection)? {
        connections[id]
    }

    private func openDaemon(_ record: HostRecord) throws -> DaemonConnection {
        let key = record.isGuest ? record.inviteKey : record.ticketKey
        guard let ticket = try secrets.string(for: key) else {
            throw HostError.missingSecret("\(record.isGuest ? "invite" : "pairing ticket") for \(record.name)")
        }
        let connection = DaemonConnection(
            hostId: record.id, ticket: ticket, session: record.sessionId,
            dialer: record.isGuest ? try guestDialer() : try daemonDialer())
        connection.onAttached = { [weak self] session in self?.update(record.id) { $0.sessionId = session } }
        connections[record.id] = connection
        do {
            try connection.connect()
        } catch {
            // Never leave a dead connection behind: the host shows why it could not open.
            connections[record.id] = nil
            throw error
        }
        return connection
    }

    func daemonDialer() throws -> DaemonDialer {
        if let dialer { return dialer }
        let key = try deviceKey ?? DeviceIdentity.load(from: secrets)
        deviceKey = key
        let config = ClientConfig(secretKey: key, relay: configuration.relay, mirrorVt: configuration.mirrorVt)
        return { ticket, listener in try DaemonClient.connect(ticket: ticket, config: config, listener: listener) }
    }

    /// Dials with an invite (`DaemonClient.join`): the device key proves who redeemed it.
    func guestDialer() throws -> DaemonDialer {
        if let joinDialer { return joinDialer }
        let key = try deviceKey ?? DeviceIdentity.load(from: secrets)
        deviceKey = key
        let config = ClientConfig(secretKey: key, relay: configuration.relay, mirrorVt: configuration.mirrorVt)
        return { invite, listener in try DaemonClient.join(invite: invite, config: config, listener: listener) }
    }

    private func openSSH(_ record: HostRecord, password: String?) throws -> SshConnection {
        guard let endpoint = record.ssh else { throw HostError.notConnected }
        // Credentials first: a host without them must not keep an idle connection.
        let target = try target(for: endpoint)
        let auth = try auth(for: record, password: password)
        let connection = SshConnection(hostId: record.id)
        connections[record.id] = connection
        do {
            try connection.connect(
                target: target, auth: auth, knownHosts: knownHosts, hostKeys: .ask(delegate: hostKeyPrompts.delegate()))
        } catch {
            connections[record.id] = nil
            throw error
        }
        return connection
    }

    func target(for endpoint: SSHEndpoint) throws -> SshTarget {
        if let alias = endpoint.alias, let text = repository.loadSSHConfig() {
            let config = try SshConfigFile.parse(text: text, home: Self.homeDirectory, localUser: endpoint.user)
            return try config.target(destination: alias, defaultUser: endpoint.user)
        }
        return SshTarget(jumps: [], host: SshHostSpec(host: endpoint.host, port: endpoint.port, user: endpoint.user, hostKeyAlias: nil))
    }

    func auth(for record: HostRecord, password: String?) throws -> [SshAuth] {
        guard let endpoint = record.ssh else { return [] }
        switch endpoint.identity {
        case .password:
            guard let password = try password ?? secrets.string(for: record.passwordKey) else {
                throw HostError.missingSecret("password for \(endpoint.display)")
            }
            return [.password(password: password)]
        case .key(let id), .secureEnclave(let id):
            return [try keys.auth(for: id)]
        case .keyFile(let path):
            return [.keyFile(path: path, passphrase: nil)]
        case .agent:
            return [.agent(socketPath: nil)]
        }
    }

    /// Drops a host's connection (it stays saved).
    public func disconnect(_ id: String) {
        connections.removeValue(forKey: id)?.close()
    }

    public func remove(_ id: String) {
        disconnect(id)
        if let record = record(id) {
            try? secrets.remove(record.ticketKey)
            try? secrets.remove(record.passwordKey)
            try? secrets.remove(record.inviteKey)
        }
        records.removeAll { $0.id == id }
        persist()
    }

    public func rename(_ id: String, to name: String) {
        update(id) { $0.name = name }
    }

    public func setPinned(_ id: String, _ pinned: Bool) {
        update(id) { $0.pinned = pinned }
    }

    // MARK: Pairing

    /// Pairs with a daemon by ticket (paste, QR, deep link) and connects. A ticket for a
    /// daemon already paired updates that host. Returns the host id once the daemon accepted
    /// the device (`connected`), or throws if it refused.
    @discardableResult
    public func pair(_ ticket: PairingTicket, name: String? = nil, replacing hostId: String? = nil) async throws -> String {
        let existing = hostId.flatMap(record) ?? records.first { $0.daemonId == ticket.info.daemonId }
        var record = existing ?? HostRecord(name: name ?? ticket.defaultName, kind: .daemon, daemonId: ticket.info.daemonId)
        record.kind = .daemon
        record.daemonId = ticket.info.daemonId
        record.guest = nil
        if let name { record.name = name }
        try secrets.set(ticket.text, for: record.ticketKey)
        let previous = connections[record.id]
        connections[record.id] = nil
        upsert(record)
        let connection: DaemonConnection
        do {
            connection = try openDaemon(record)
        } catch {
            if let previous { connections[record.id] = previous }
            throw error
        }
        try await waitUntilReady(connection)
        previous?.close()
        touch(record.id)
        Self.log.info("paired host=\(record.id, privacy: .public) daemon=\(ticket.info.daemonId.prefix(12), privacy: .public)")
        return record.id
    }

    // MARK: Joining (multiplayer guest)

    /// Joins someone's host with an invite link or QR text (`<scheme>://join/…`), as the roles
    /// it grants. Saved as a guest host (re-dialled with the same invite; the daemon binds it to
    /// this device on first use). Returns the host id once attached, or throws the refusal
    /// (expired, revoked, used up).
    @discardableResult
    public func join(invite: String, name: String? = nil) async throws -> String {
        let text = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try inspectInvite(invite: text)
        let existing = records.first { $0.daemonId == info.daemonId && $0.isGuest }
        var record = existing ?? HostRecord(name: name ?? Self.guestHostName(info), kind: .daemon, daemonId: info.daemonId)
        record.guest = true
        record.inviter = info.inviter.isEmpty ? nil : info.inviter
        if let name { record.name = name }
        try secrets.set(text, for: record.inviteKey)
        let previous = connections[record.id]
        connections[record.id] = nil
        upsert(record)
        let connection: DaemonConnection
        do {
            connection = try openDaemon(record)
        } catch {
            if let previous { connections[record.id] = previous }
            throw error
        }
        do {
            try await waitUntilReady(connection)
        } catch {
            // A refused first join leaves nothing behind.
            if existing == nil {
                connections[record.id] = nil
                connection.close()
                try? secrets.remove(record.inviteKey)
                records.removeAll { $0.id == record.id }
                persist()
            }
            throw error
        }
        previous?.close()
        touch(record.id)
        Self.log.info("joined host=\(record.id, privacy: .public) daemon=\(info.daemonId.prefix(12), privacy: .public) as \(roleWords(info.roles), privacy: .public)")
        return record.id
    }

    /// "Alex's host" for an invite from Alex.
    nonisolated static func guestHostName(_ info: InviteInfo) -> String {
        let inviter = info.inviter.trimmingCharacters(in: .whitespaces)
        return inviter.isEmpty ? "Shared host" : "\(inviter)’s host"
    }

    /// Waits for the first layout (paired, attached), or a refusal.
    private func waitUntilReady(_ connection: DaemonConnection, timeout: Duration = .seconds(45)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if connection.isReady { return }
            if case .needsAttention(let reason) = connection.status { throw PairingError.refused(reason) }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PairingError.timedOut
    }

    // MARK: Just ssh

    /// Saves (or finds) an SSH host for `endpoint` and connects it. With a password, it is
    /// saved for reconnects when `rememberPassword`.
    @discardableResult
    public func connectSSH(
        _ endpoint: SSHEndpoint, name: String? = nil, password: String? = nil, rememberPassword: Bool = true
    ) throws -> String {
        var record = records.first { $0.ssh?.host == endpoint.host && $0.ssh?.user == endpoint.user && $0.ssh?.port == endpoint.port }
            ?? HostRecord(name: name ?? endpoint.host, kind: .ssh, ssh: endpoint)
        record.ssh = endpoint
        if let password, rememberPassword { try secrets.set(password, for: record.passwordKey) }
        upsert(record)
        disconnect(record.id)
        if record.kind == .daemon {
            try open(record.id)
        } else {
            _ = try openSSH(record, password: password)
            touch(record.id)
        }
        return record.id
    }

    /// Installs (or reuses/upgrades) the helper on an SSH host over its live session, pairs
    /// with the ticket it returns, and switches the host to daemon mode. The SSH connection
    /// stays up until the daemon's layout is ready, so the window never goes blank.
    @discardableResult
    public func installHelper(_ id: String) async throws -> BootstrapReport {
        guard let ssh = connections[id] as? SshConnection, let session = ssh.session else { throw HostError.notConnected }
        installs[id] = InstallProgress(step: .probing)
        defer { installs[id] = nil }
        let listener = BootstrapProgressListener { [weak self] step in
            Task { @MainActor in self?.installs[id]?.step = step }
        }
        let started = ContinuousClock.now
        let report = try await session.bootstrap(
            binaries: configuration.hostdBinaries(), ticketMinutes: nil, waitSecs: nil, listener: listener)
        Self.log.info("bootstrap host=\(id, privacy: .public) action=\(String(describing: report.action), privacy: .public) in \((ContinuousClock.now - started) / .milliseconds(1), format: .fixed(precision: 0)) ms")
        installs[id]?.report = report
        installNotes[id] = report.notes.isEmpty ? nil : report.notes
        let ticket = try PairingTicket(report.ticket)
        try await pair(ticket, replacing: id)
        ssh.close()
        return report
    }

    // MARK: ~/.ssh/config

    /// Reads `~/.ssh/config` text (pasted, from Files, or read directly on macOS) and lists its
    /// concrete host aliases for import.
    public func loadSSHConfig(_ text: String) throws {
        let config = try SshConfigFile.parse(text: text, home: Self.homeDirectory, localUser: nil)
        try repository.saveSSHConfig(text)
        sshConfigAliases = config.hostAliases().map { config.resolve(alias: $0) }
    }

    /// Saves the chosen aliases as SSH hosts (key files from IdentityFile on macOS; on iOS a
    /// key or password is chosen at first connect).
    public func importSSHHosts(_ aliases: [String]) {
        for host in sshConfigAliases where aliases.contains(host.alias) {
            guard !records.contains(where: { $0.ssh?.alias == host.alias }) else { continue }
            #if os(macOS)
            let identity = host.identityFiles.first(where: { FileManager.default.fileExists(atPath: $0) })
                .map(SSHIdentity.keyFile) ?? .agent
            #else
            let identity = SSHIdentity.password
            #endif
            let endpoint = SSHEndpoint(
                user: host.user ?? NSUserName(), host: host.hostName, port: host.port, alias: host.alias, identity: identity)
            upsert(HostRecord(name: host.alias, kind: .ssh, ssh: endpoint))
        }
    }

    public func dismissNotes(_ id: String) {
        installNotes[id] = nil
    }

    /// Dismisses the import list.
    public func clearSSHConfigAliases() {
        sshConfigAliases = []
    }

    #if os(macOS)
    /// macOS reads the user's config directly.
    public func loadUserSSHConfig() throws {
        let url = URL(fileURLWithPath: Self.homeDirectory).appending(path: ".ssh/config")
        try loadSSHConfig(String(contentsOf: url, encoding: .utf8))
    }
    #endif

    nonisolated static var homeDirectory: String {
        #if os(macOS)
        // The real home, not a sandbox container.
        String(cString: getpwuid(getuid()).pointee.pw_dir)
        #else
        NSHomeDirectory()
        #endif
    }

    // MARK: Lifecycle (R1, R3, R5, R10)

    public func foreground() {
        network.start()
        for connection in connections.values { connection.foreground() }
    }

    public func background() {
        for connection in connections.values { connection.background() }
    }

    public func networkChanged() {
        for connection in connections.values { connection.networkChanged() }
    }

    // MARK: Persistence

    func upsert(_ record: HostRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    func update(_ id: String, _ body: (inout HostRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        persist()
    }

    private func touch(_ id: String) {
        update(id) { $0.lastConnected = Date() }
    }

    private func persist() {
        do {
            try repository.save(records)
        } catch {
            Self.log.error("saving hosts: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// A helper install's progress.
public struct InstallProgress: Equatable, Sendable {
    public var step: BootstrapStep
    public var report: BootstrapReport?

    /// One line for the progress row.
    public var summary: String {
        switch step {
        case .probing: "Checking the host…"
        case .uploading(let size, let sent):
            "Uploading helper (\(ByteCountFormatter.string(fromByteCount: Int64(sent), countStyle: .file)) sent, \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) binary)"
        case .starting: "Starting the service…"
        case .pairing: "Pairing…"
        }
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case refused(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .refused(let reason): "The host refused this device (\(reason)). Ask it for a new ticket (its helper's `pair` command)."
        case .timedOut: "The host did not answer. Check that it is running and reachable."
        }
    }
}

nonisolated private final class BootstrapProgressListener: BootstrapListener {
    let handler: @Sendable (BootstrapStep) -> Void
    init(_ handler: @escaping @Sendable (BootstrapStep) -> Void) { self.handler = handler }
    func onStep(step: BootstrapStep) { handler(step) }
}
