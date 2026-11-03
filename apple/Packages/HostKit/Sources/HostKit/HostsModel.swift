import Foundation
import Observation
import os
import PaneLayout
import GudoCore

/// One row of the host list, ready to show.
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
    /// The helper is older than the app's, or too old (or new) to work with: what to say and
    /// whether "Update Helper" can do it (`HostsModel.updateHelper`).
    public var helper: HelperAdvice?
    /// "Ubuntu 24.04.1 LTS · x86_64", from the daemon.
    public var machine: String?
    /// An SSH host on a Tailscale tailnet (`100.64.0.0/10`, `*.ts.net`): reachable only while
    /// the Tailscale app is connected on this device.
    public var isTailscale = false
    /// The last dial to a tailnet host failed: say that Tailscale must be connected here.
    public var needsTailscale = false
    /// This device's own helper (the app runs and updates it).
    public var isThisDevice = false
}

/// Everything about hosts the UI binds to: the saved hosts, their live connections, pairing,
/// "just ssh", the helper install, ssh_config import, and the app lifecycle hooks that keep
/// connections healthy.
@MainActor
@Observable
public final class HostsModel {
    public private(set) var records: [HostRecord]
    /// Live connections by host id. Views hold the host id, never a socket.
    public internal(set) var connections: [String: any HostConnection] = [:]
    public private(set) var installs: [String: InstallProgress] = [:]
    /// What the last helper install said the user may want to know (e.g. lingering is off), by
    /// host id; cleared with `dismissNotes`.
    public private(set) var installNotes: [String: [String]] = [:]
    public private(set) var helperUpdates: [String: HelperUpdateProgress] = [:]
    public let keys: KeyStore
    public let hostKeyPrompts = HostKeyPrompts()
    public let network = NetworkMonitor()
    /// Hosts imported from `~/.ssh/config` (aliases), not yet saved.
    public private(set) var sshConfigAliases: [SshHostConfig] = []
    /// How daemons are reached (Settings › Network), for every daemon connection.
    public private(set) var relaySettings: RelaySettings

    public struct Configuration: Sendable {
        /// Relay use for daemon connections (`.disabled` for LAN-only tests).
        public var relay: RelayMode = .default
        /// Keep the core's VT mirror (pane text for tests and diagnostics).
        public var mirrorVt = false
        /// The daemon builds to install (the app bundles gzipped Linux builds).
        public var hostdBinaries: @Sendable () -> HostdBinaries = { HostdBinaries(linuxAarch64: nil, linuxX8664: nil, macosAarch64: nil, macosX8664: nil) }
        /// What those builds are (`hostd-manifest.json`), to tell an older helper; nil when
        /// the app bundles none.
        public var bundledDaemons: @Sendable () -> BundledDaemons? = { nil }
        /// Holds every event from a daemon back this long, in order: a slow link on loopback
        /// (UI tests of echo prediction).
        public var linkDelay: Duration?
        public init() {}
    }

    /// Relay capabilities issued this run, by daemon, token, environment and kind: registering
    /// again with a daemon (new preferences) does not spend the relay's registration budget.
    @ObservationIgnored var pushCapabilities: [String: String] = [:]
    @ObservationIgnored public let secrets: any SecretStore
    @ObservationIgnored private let repository: HostRepository
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private var deviceKey: Data?
    @ObservationIgnored private lazy var knownHosts = KnownHosts.load(from: secrets)
    @ObservationIgnored var dialer: DaemonDialer?
    @ObservationIgnored var joinDialer: DaemonDialer?
    /// Knocks with a knock invite (`knockInvite`); tests replace it.
    @ObservationIgnored var knocker: Knocker?
    /// A URL a host's pane opened, or a browser tool its agent called (the host's id).
    @ObservationIgnored public var onBrowserPush: ((String, BrowserPush) -> Void)?
    /// A new host was paired by the user (not re-paired, not this Mac's own helper): the moment
    /// to ask for notification permission, in context. Called with the host id.
    @ObservationIgnored public var onFirstPairing: ((String) -> Void)?
    /// A program in a pane of a host copied text (OSC 52) after this device typed into it:
    /// the host, the pane and the text.
    @ObservationIgnored public var onClipboard: ((String, PaneId, String) -> Void)?
    /// This device's own helper no longer knows this device (removed with `devices`, or its
    /// pairing was lost): the app pairs it again from the helper itself, and returns true when
    /// it does (the host then shows as connecting, not refused). Remote hosts never pair again
    /// on their own.
    @ObservationIgnored public var onThisDeviceRemoved: ((String) -> Bool)?
    /// Where daemon hosts' workspaces are saved for instant start (nil: not saved).
    @ObservationIgnored public var workspaceCache: WorkspaceCacheStore?
    private static let log = Logger(subsystem: Log.subsystem, category: "hosts")

    public init(secrets: any SecretStore, repository: HostRepository, configuration: Configuration = .init()) {
        self.secrets = secrets
        self.repository = repository
        self.configuration = configuration
        records = repository.load()
        relaySettings = RelaySettings.load(directory: repository.directory, secrets: secrets)
        keys = KeyStore(secrets: secrets, directory: repository.directory)
        network.onChange = { [weak self] in self?.networkChanged() }
    }

    // MARK: The list

    /// Hosts sorted for Home: "Needs you" first, then pinned, then most recently used.
    public var entries: [HostEntry] {
        records.map(entry).sorted { lhs, rhs in
            if (lhs.needsYou != nil) != (rhs.needsYou != nil) { return lhs.needsYou != nil }
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            let (lhsDate, rhsDate) = (lhs.lastConnected ?? .distantPast, rhs.lastConnected ?? .distantPast)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
        let isTailscale = record.kind == .ssh && record.ssh.map(Tailscale.isTailnet) == true
        let dialFailed: Bool = switch status {
        case .reconnecting, .offline: !network.isOffline
        default: false
        }
        return HostEntry(
            id: record.id, name: record.name, kind: record.kind,
            address: record.ssh?.display ?? record.daemonId.map { String($0.prefix(16)) } ?? "",
            status: status, needsYou: needsYou, blockedAgents: blocked.count,
            lastConnected: record.lastConnected, pinned: record.pinned,
            canInstallHelper: record.kind == .ssh,
            helper: helperAdvice(record.id),
            machine: record.machine.map { machine in
                [machine.osName.isEmpty ? machine.os : machine.osName, machine.arch]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            },
            isTailscale: isTailscale,
            needsTailscale: isTailscale && dialFailed,
            isThisDevice: record.isThisDevice)
    }

    /// What to say about a daemon host's helper version, from its latest connection. Nothing
    /// for this device's own helper: it comes with the app.
    public func helperAdvice(_ id: String) -> HelperAdvice? {
        guard let record = record(id), record.kind == .daemon, !record.isThisDevice,
              let daemon = connections[id] as? DaemonConnection
        else { return nil }
        return HelperCheck.assess(
            info: daemon.daemonInfo, reported: daemon.daemonInfoReported, incompatible: daemon.incompatibility,
            bundled: configuration.bundledDaemons(), canSSH: record.ssh != nil, isGuest: record.isGuest,
            appProtocol: protocolLevel(), minDaemonProtocol: minDaemonProtocol())
    }

    // MARK: Connections

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
        let secretKey = record.isGuest ? record.inviteKey : record.ticketKey
        guard let ticket = try secrets.string(for: secretKey) else {
            throw HostError.missingSecret("\(record.isGuest ? "invite" : "pairing ticket") for \(record.name)")
        }
        let connection = DaemonConnection(
            hostId: record.id, ticket: ticket, session: record.sessionId,
            dialer: record.isGuest ? try guestDialer() : try daemonDialer())
        connection.onAttached = { [weak self] session in self?.update(record.id) { $0.sessionId = session } }
        connection.onDaemonInfo = { [weak self] info in self?.daemonReported(record.id, info) }
        connection.browser.onPush = { [weak self] push in self?.onBrowserPush?(record.id, push) }
        connection.onClipboard = { [weak self] pane, text in self?.onClipboard?(record.id, pane, text) }
        connection.isGuest = record.isGuest
        connection.onRefused = { [weak self] reason in
            guard let self, DaemonConnection.meansDeviceRemoved(reason), self.record(record.id)?.isThisDevice == true else { return false }
            return self.onThisDeviceRemoved?(record.id) ?? false
        }
        // A guest's view of someone else's host is never kept on this device.
        if !record.isGuest,
           let cached = workspaceCache?.load(hostId: record.id, daemonId: record.daemonId, sessionId: record.sessionId)
        {
            connection.seed(cached)
        }
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
        let config = clientConfig(key)
        // The app shows native password prompts (AskpassSession), so it asks the daemon for them.
        let options = relaySettings.connectOptions(askpass: true)
        let delay = configuration.linkDelay
        return { ticket, listener in
            let listener = delay.map { DelayedListener(listener, delay: $0) } ?? listener
            return try DaemonClient.connectWith(ticket: ticket, config: config, options: options, listener: listener)
        }
    }

    /// This device's key (created on first use).
    func deviceKeyData() throws -> Data {
        let key = try deviceKey ?? DeviceIdentity.load(from: secrets)
        deviceKey = key
        return key
    }

    /// Dials with an invite (`DaemonClient.join`): the device key proves who redeemed it.
    func guestDialer() throws -> DaemonDialer {
        if let joinDialer { return joinDialer }
        let key = try deviceKey ?? DeviceIdentity.load(from: secrets)
        deviceKey = key
        let config = clientConfig(key)
        let options = relaySettings.connectOptions(askpass: true, guest: true)
        return { invite, listener in
            try DaemonClient.joinWith(invite: invite, config: config, options: options, listener: listener)
        }
    }

    /// The client config for this device's key: the relay settings' direct-only choice wins
    /// over every ticket.
    func clientConfig(_ key: Data, mirrorVt: Bool? = nil) -> ClientConfig {
        ClientConfig(secretKey: key, relay: relaySettings.clientRelay(base: configuration.relay), mirrorVt: mirrorVt ?? configuration.mirrorVt)
    }

    /// Saves new relay settings; open daemon connections redial with them at once.
    public func setRelaySettings(_ settings: RelaySettings) throws {
        try settings.save(directory: repository.directory, secrets: secrets)
        let changed = settings.clientRelay(base: configuration.relay) != relaySettings.clientRelay(base: configuration.relay)
            || settings.connectOptions(askpass: true) != relaySettings.connectOptions(askpass: true)
        relaySettings = settings
        guard changed else { return }
        let relay = settings.clientRelay(base: configuration.relay)
        for case let daemon as DaemonConnection in connections.values {
            let guest = record(daemon.hostId)?.isGuest == true
            daemon.setRelays(relay, options: settings.connectOptions(askpass: true, guest: guest))
        }
    }

    /// Adds the CA certificates in a PEM (one or more blocks) or DER file to the relay
    /// settings. Returns those that were new.
    @discardableResult
    public func importRelayCertificates(_ file: Data) throws -> [RelayCertificate] {
        var settings = relaySettings
        let added = try RelayCertificate.parse(file).filter { certificate in
            guard !settings.certificates.contains(certificate.der) else { return false }
            settings.certificates.append(certificate.der)
            return true
        }
        try setRelaySettings(settings)
        return added
    }

    public func removeRelayCertificate(_ der: Data) throws {
        var settings = relaySettings
        settings.certificates.removeAll { $0 == der }
        try setRelaySettings(settings)
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
        workspaceCache?.remove(hostId: id)
        if let record = record(id) {
            try? secrets.remove(record.ticketKey)
            try? secrets.remove(record.passwordKey)
            try? secrets.remove(record.inviteKey)
        }
        records.removeAll { $0.id == id }
        persist()
    }

    /// A name the user chose: the app never changes it.
    public func rename(_ id: String, to name: String) {
        update(id) {
            $0.name = name
            $0.nameSource = .user
        }
    }

    /// The daemon described itself (on every connection): remember the machine, and name a
    /// host the app named (placeholder) after it, once. Names the user chose stay.
    func daemonReported(_ id: String, _ info: DaemonInfo?) {
        guard let info, !info.hostname.isEmpty, let record = record(id) else { return }
        let machine = HostRecord.Machine(hostname: info.hostname, osName: info.osName, os: info.os, arch: info.arch)
        let source = record.nameSource ?? (MachineName.looksDefault(record) ? .placeholder : .user)
        let name = source == .placeholder ? MachineName.display(info.hostname) : nil
        guard record.machine != machine || record.nameSource != source || name != nil else { return }
        if let name {
            Self.log.info("naming host=\(id, privacy: .public) \(name, privacy: .private) (was \(record.name, privacy: .private))")
        }
        update(id) {
            $0.machine = machine
            $0.nameSource = source
            if let name {
                $0.name = name
                $0.nameSource = .machine
            }
        }
    }

    public func setPinned(_ id: String, _ pinned: Bool) {
        update(id) { $0.pinned = pinned }
    }

    /// The host of this device's own helper, if paired.
    public var thisDeviceId: String? {
        records.first(where: \.isThisDevice)?.id
    }

    /// Pairs with this device's own helper (its ticket from the helper itself) and marks the host
    /// as this device, under `name`. Any older such host for another daemon is removed.
    @discardableResult
    public func pairThisDevice(_ ticket: PairingTicket, name: String) async throws -> String {
        let stale = records.filter { $0.isThisDevice && $0.daemonId != ticket.info.daemonId }.map(\.id)
        let id = try await pair(ticket, name: name, announcing: false)
        update(id) { $0.thisDevice = true }
        for old in stale where old != id { remove(old) }
        return id
    }

    // MARK: Pairing

    /// Pairs with a daemon by ticket (paste, QR, deep link) and connects. A ticket for a
    /// daemon already paired updates that host. Returns the host id once the daemon accepted
    /// the device (`connected`), or throws if it refused.
    @discardableResult
    public func pair(_ ticket: PairingTicket, name: String? = nil, replacing hostId: String? = nil) async throws -> String {
        try await pair(ticket, name: name, replacing: hostId, announcing: true)
    }

    private func pair(_ ticket: PairingTicket, name: String?, replacing hostId: String? = nil, announcing: Bool) async throws -> String {
        let existing = hostId.flatMap(record) ?? records.first { $0.daemonId == ticket.info.daemonId }
        var record = existing ?? HostRecord(name: name ?? ticket.defaultName, kind: .daemon, daemonId: ticket.info.daemonId)
        if existing == nil { record.nameSource = .placeholder }
        record.kind = .daemon
        record.daemonId = ticket.info.daemonId
        record.guest = nil
        if let name {
            record.name = name
            record.nameSource = .user
        }
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
        do {
            try await waitUntilReady(connection)
        } catch {
            Self.log.error("pairing host=\(record.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            // A refused first pairing (the ticket was used, expired or is not this daemon's)
            // leaves no host behind that could never connect: a new ticket starts clean. One
            // that only timed out stays and keeps dialling.
            if existing == nil, case PairingError.refused = error {
                connections[record.id] = nil
                connection.close()
                try? secrets.remove(record.ticketKey)
                records.removeAll { $0.id == record.id }
                persist()
            } else {
                previous?.close()
            }
            throw error
        }
        previous?.close()
        touch(record.id)
        Self.log.info("paired host=\(record.id, privacy: .public) daemon=\(ticket.info.daemonId.prefix(12), privacy: .public)")
        if existing == nil, announcing { onFirstPairing?(record.id) }
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
        // "Alex's host" says more to a guest than the owner's machine name: keep it.
        if existing == nil { record.nameSource = .user }
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
            if case .needsAttention(let reason) = connection.status {
                throw PairingError.refused(connection.refusal.flatMap { DaemonConnection.meansDeviceRemoved($0) ? $0 : nil } ?? reason)
            }
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
        let existing = records.first { $0.ssh?.host == endpoint.host && $0.ssh?.user == endpoint.user && $0.ssh?.port == endpoint.port }
        var record = existing ?? HostRecord(name: name ?? endpoint.host, kind: .ssh, ssh: endpoint)
        if existing == nil { record.nameSource = name == nil ? .placeholder : .user }
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

    // MARK: Helper updates

    /// Updates a daemon host's helper to the app's build (docs/APP-ARCHITECTURE.md §14): over
    /// its saved SSH login when it was set up from SSH (upload and restart, as "Install Helper"
    /// does), else over the daemon connection (the daemon checks the build, swaps it in and
    /// restarts itself; owner only). Returns once the host is back on the new build. A daemon
    /// that can hand off keeps its panes' programs running; an older one restores the layout and
    /// restarts the shells.
    public func updateHelper(_ id: String) async throws {
        guard let record = record(id), let advice = helperAdvice(id), advice.canUpdate else {
            throw HelperUpdateError.unavailable
        }
        guard helperUpdates[id] == nil else { return }
        let started = ContinuousClock.now
        helperUpdates[id] = HelperUpdateProgress(step: .preparing)
        defer { helperUpdates[id] = nil }
        let daemon = connections[id] as? DaemonConnection
        let previousConnections = daemon?.connectionCount
        switch advice.method {
        case .ssh:
            guard try await updateOverSSH(record) else { return }
        case .connection:
            guard let daemon, let bundled = advice.bundled, let manifest = configuration.bundledDaemons() else {
                throw HelperUpdateError.unavailable
            }
            helperUpdates[id]?.step = .uploading(sent: 0, total: 0)
            _ = try await daemon.updateHelper(path: manifest.path(of: bundled), build: bundled.build) { [weak self] sent, total in
                Task { @MainActor in
                    if case .uploading = self?.helperUpdates[id]?.step {
                        self?.helperUpdates[id]?.step = .uploading(sent: sent, total: total)
                    }
                }
            }
        case .none:
            throw HelperUpdateError.unavailable
        }
        helperUpdates[id]?.step = .restarting
        connections[id]?.retry()
        // Back when the daemon has been reconnected to and the session is open again. A hot
        // upgrade keeps the daemon run's epoch, so the reconnection itself is the signal.
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let daemon = connections[id] as? DaemonConnection, daemon.status.isLive,
               previousConnections.map({ daemon.connectionCount > $0 }) ?? true {
                Self.log.info("helper updated host=\(id, privacy: .public) to \(daemon.daemonInfo?.build ?? "?", privacy: .public) in \((ContinuousClock.now - started) / .milliseconds(1), format: .fixed(precision: 0)) ms")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HelperUpdateError.didNotComeBack
    }

    /// Runs the SSH bootstrap with the host's saved login: it uploads the bundled build when
    /// it differs and restarts the service. The device stays paired. Returns whether the
    /// helper restarted (false: it already ran the bundled build).
    private func updateOverSSH(_ record: HostRecord) async throws -> Bool {
        guard let endpoint = record.ssh else { throw HelperUpdateError.unavailable }
        let session = try SshSession.start(
            target: try target(for: endpoint), auth: try auth(for: record, password: nil), knownHosts: knownHosts,
            hostKeys: .ask(delegate: hostKeyPrompts.delegate()), options: defaultSshOptions(), listener: SshStateStream())
        defer { session.close() }
        helperUpdates[record.id]?.step = .connectingSSH
        try await session.connected()
        let id = record.id
        let listener = BootstrapProgressListener { [weak self] step in
            Task { @MainActor in
                guard self?.helperUpdates[id] != nil else { return }
                switch step {
                case .uploading(let size, let sent): self?.helperUpdates[id]?.step = .uploading(sent: sent, total: size)
                case .starting: self?.helperUpdates[id]?.step = .restarting
                case .probing, .pairing: break
                }
            }
        }
        let report = try await session.bootstrap(
            binaries: configuration.hostdBinaries(), ticketMinutes: 1, waitSecs: nil, listener: listener)
        Self.log.info("helper update over ssh host=\(id, privacy: .public) action=\(String(describing: report.action), privacy: .public)")
        installNotes[id] = report.notes.isEmpty ? nil : report.notes
        return report.action != .reused && report.action != .keptNewer
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
            var record = HostRecord(name: host.alias, kind: .ssh, ssh: endpoint)
            record.nameSource = .user
            upsert(record)
        }
    }

    public func dismissNotes(_ id: String) {
        installNotes[id] = nil
    }

    public func clearSSHConfigAliases() {
        sshConfigAliases = []
    }

    #if os(macOS)
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

    // MARK: Lifecycle

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

    /// Shows `connection` as host `record` without saving it (design fixtures, snapshots).
    public func attachPreview(_ record: HostRecord, connection: any HostConnection) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        connections[record.id] = connection
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

public struct InstallProgress: Equatable, Sendable {
    public var step: BootstrapStep
    public var report: BootstrapReport?

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

public struct HelperUpdateProgress: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case preparing
        case connectingSSH
        case uploading(sent: UInt64, total: UInt64)
        /// Swapped in; the helper restarts and the connection comes back.
        case restarting
    }

    public var step: Step

    /// One line for the progress row and notice.
    public var summary: String {
        switch step {
        case .preparing: "Preparing the update…"
        case .connectingSSH: "Signing in over SSH…"
        case .uploading(let sent, let total) where total > 0:
            "Updating helper (\(ByteCountFormatter.string(fromByteCount: Int64(sent), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))"
        case .uploading: "Updating helper…"
        case .restarting: "Restarting helper…"
        }
    }
}

public enum HelperUpdateError: Error, Equatable, LocalizedError {
    /// Nothing to update, or no way to reach the host's helper from here.
    case unavailable
    /// The helper was updated but the host did not answer within a minute.
    case didNotComeBack

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This host's helper can't be updated from here. Reinstall it over SSH."
        case .didNotComeBack: "The helper was updated but the host hasn't come back yet. It retries on its own."
        }
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case refused(String)
    case timedOut
    /// The owner turned a knock away.
    case turnedAway

    public var errorDescription: String? {
        switch self {
        case .refused(let reason) where DaemonConnection.meansDeviceRemoved(reason):
            "This ticket was already used or has expired. Ask the host for a new one (its helper's `pair` command)."
        case .refused(let reason): reason
        case .timedOut: "The host did not answer. Check that it is running and reachable."
        case .turnedAway: "The owner didn't let you in."
        }
    }
}

nonisolated private final class BootstrapProgressListener: BootstrapListener {
    let handler: @Sendable (BootstrapStep) -> Void
    init(_ handler: @escaping @Sendable (BootstrapStep) -> Void) { self.handler = handler }
    func onStep(step: BootstrapStep) { handler(step) }
}
