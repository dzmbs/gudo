import Foundation
import Observation
import GudoCore

/// The SSH host form, for adding a host and editing one. One smart address field takes an
/// ssh_config alias, `host`, `user@host:port`, `ssh://…` or a pasted `ssh -p 2222 -i key
/// user@host` command and fills the editable User, Port and Jump Host fields; suggestions come
/// from `~/.ssh/config`, saved hosts and known_hosts. Then: how to sign in, an optional test,
/// the host-key prompt (`HostsModel.hostKeyPrompts`), and a plain-SSH terminal.
@MainActor
@Observable
public final class JustSSHFlow {
    public enum Step: Equatable, Sendable {
        case enterDestination
        case connecting
        /// Connected (or saved, when editing): the host id.
        case connected(String)
        case failed(String)
    }

    public enum AuthChoice: Hashable, Sendable {
        case password
        /// A key the app holds (generated, imported or Secure Enclave).
        case key(id: String)
        /// A key file on disk, used in place (macOS).
        case keyFile(path: String)
        /// Any key the SSH agent holds (macOS).
        case agent
        /// One key the SSH agent holds, by fingerprint (macOS).
        case agentKey(fingerprint: String)
    }

    public enum TestResult: Equatable, Sendable {
        case running
        case succeeded(Duration)
        case failed(String)
    }

    /// A suggestion under the address field.
    public struct Suggestion: Identifiable, Hashable, Sendable {
        public enum Source: Hashable, Sendable {
            /// A `Host` alias in `~/.ssh/config`.
            case sshConfig
            /// A saved host (its id).
            case saved(String)
            /// A host in `~/.ssh/known_hosts`.
            case knownHosts
        }

        public var source: Source
        /// What fills the address field.
        public var value: String
        /// `user@host:port via jump`, or nil when it would only repeat `value`.
        public var detail: String?
        public var id: String { "\(source)|\(value)|\(detail ?? "")" }
    }

    /// The address field as typed.
    public var destination = "" {
        didSet { if destination != oldValue, !applying { applyDestination() } }
    }
    public var user = "" {
        didSet { if user != oldValue, !applying { userEdited = true } }
    }
    /// Empty: 22.
    public var port = "" {
        didSet { if port != oldValue, !applying { portEdited = true } }
    }
    /// `-J` syntax; empty for none.
    public var proxyJump = "" {
        didSet { if proxyJump != oldValue, !applying { proxyJumpEdited = true } }
    }
    /// The host's name in the list; empty: the alias or the address.
    public var name = ""
    public var auth = AuthChoice.password {
        didSet { if auth != oldValue, !applying { authEdited = true } }
    }
    public var password = ""
    public var rememberPassword = true
    /// For an encrypted key file the agent does not hold.
    public var passphrase = ""
    public var rememberPassphrase = true

    /// The `~/.ssh/config` alias the address names, if any.
    public private(set) var alias: String?
    public private(set) var step = Step.enterDestination
    public private(set) var test: TestResult?
    /// The key just generated or imported in this flow, to show its public key.
    public private(set) var newKey: SSHKey?
    /// The saved host being edited, or nil when adding.
    public let editingHostId: String?

    public let hosts: HostsModel
    public var inventory: SSHInventory { hosts.sshInventory }

    @ObservationIgnored private var applying = false
    @ObservationIgnored private var userEdited = false
    @ObservationIgnored private var portEdited = false
    @ObservationIgnored private var proxyJumpEdited = false
    @ObservationIgnored private var authEdited = false
    /// `-i` from a pasted command.
    @ObservationIgnored private var typedIdentityFile: String?

    public init(hosts: HostsModel) {
        self.hosts = hosts
        editingHostId = nil
        applying = true
        user = inventory.localUser ?? ""
        auth = defaultAuth()
        applying = false
    }

    /// The form for editing a saved SSH host.
    public init(hosts: HostsModel, editing record: HostRecord) {
        self.hosts = hosts
        editingHostId = record.id
        guard let endpoint = record.ssh else { return }
        applying = true
        destination = endpoint.alias ?? endpoint.host
        alias = endpoint.alias
        user = endpoint.user
        port = endpoint.port == 22 ? "" : String(endpoint.port)
        proxyJump = endpoint.proxyJump ?? ""
        name = record.name
        auth = Self.choice(for: endpoint)
        applying = false
        userEdited = true
        portEdited = true
        proxyJumpEdited = endpoint.proxyJump != nil
        authEdited = true
    }

    private static func choice(for endpoint: SSHEndpoint) -> AuthChoice {
        switch endpoint.identity {
        case .password: .password
        case .key(let id), .secureEnclave(let id): .key(id: id)
        case .keyFile(let path): .keyFile(path: path)
        case .agent: endpoint.agentKey.map { .agentKey(fingerprint: $0) } ?? .agent
        }
    }

    // MARK: Address

    /// Fills User, Port, Jump Host and the sign-in from the address as typed. Values the user
    /// typed into those fields win over defaults, never over what the address states.
    private func applyDestination() {
        test = nil
        let input = try? parseSshHostInput(text: destination)
        let typedHost = input?.host ?? ""
        let config = typedHost.isEmpty ? nil : resolvedConfig(typedHost)
        applying = true
        defer { applying = false }
        alias = typedHost.isEmpty ? nil : inventory.configHost(typedHost)?.alias
        typedIdentityFile = input?.identityFile.map(expandTilde)
        if let typedUser = input?.user {
            user = typedUser
            userEdited = true
        } else if !userEdited {
            user = config?.user ?? inventory.localUser ?? ""
        }
        if let typedPort = input?.port {
            port = typedPort == 22 ? "" : String(typedPort)
            portEdited = true
        } else if !portEdited {
            port = config.map { $0.port == 22 ? "" : String($0.port) } ?? ""
        }
        if let typedJump = input?.proxyJump {
            proxyJump = typedJump
            proxyJumpEdited = true
        } else if !proxyJumpEdited {
            proxyJump = config?.proxyJump.joined(separator: ",") ?? ""
        }
        if !authEdited || typedIdentityFile != nil {
            auth = defaultAuth(config: config)
        }
    }

    /// What ssh_config says for a host: its alias block, or the `Host` patterns it matches.
    private func resolvedConfig(_ host: String) -> SshHostConfig? {
        inventory.configHost(host) ?? inventory.config?.resolve(alias: host)
    }

    /// Rewrites the address to the bare host or alias once its parts are in their fields
    /// (on submit or leaving the field).
    public func tidyDestination() {
        guard let input = try? parseSshHostInput(text: destination), input.host != destination else { return }
        applying = true
        destination = input.host
        applying = false
    }

    /// The host part of the address, or nil when it does not parse.
    public var typedHost: String? {
        (try? parseSshHostInput(text: destination))?.host
    }

    /// The real host name an alias stands for (shown under the field).
    public var aliasHostName: String? {
        alias.flatMap { inventory.configHost($0)?.hostName }
    }

    /// Matches for what is typed: ssh_config aliases, saved hosts, known_hosts, at most `limit`.
    public func suggestions(limit: Int = 6) -> [Suggestion] {
        let query = (typedHost ?? destination).trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ texts: String?...) -> Bool {
            query.isEmpty || texts.contains { $0?.lowercased().contains(query) == true }
        }
        var seen = Set<String>()
        var found: [Suggestion] = []
        func add(_ suggestion: Suggestion) {
            guard suggestion.value.lowercased() != query || query.isEmpty, seen.insert(suggestion.value.lowercased()).inserted else { return }
            found.append(suggestion)
        }
        for host in inventory.configHosts where matches(host.alias, host.hostName) {
            add(Suggestion(source: .sshConfig, value: host.alias, detail: Self.detail(user: host.user, host: host.hostName, port: host.port, jump: host.proxyJump)))
        }
        let saved = hosts.records
            .filter { $0.ssh != nil && $0.id != editingHostId }
            .sorted { ($0.lastConnected ?? $0.created) > ($1.lastConnected ?? $1.created) }
        for record in saved {
            guard let endpoint = record.ssh, matches(record.name, endpoint.host, endpoint.alias) else { continue }
            add(Suggestion(source: .saved(record.id), value: endpoint.alias ?? endpoint.host, detail: Self.detail(
                user: endpoint.user, host: endpoint.host, port: endpoint.port, jump: endpoint.proxyJump.map { [$0] } ?? [])))
        }
        if !query.isEmpty {
            for known in inventory.knownHosts where matches(known.host) {
                add(Suggestion(source: .knownHosts, value: known.port == 22 ? known.host : SSHAddress.text(user: nil, host: known.host, port: known.port), detail: nil))
            }
        }
        return Array(found.prefix(limit))
    }

    private static func detail(user: String?, host: String, port: UInt16, jump: [String]) -> String {
        let address = SSHAddress.text(user: user, host: host, port: port)
        return jump.isEmpty ? address : "\(address) via \(jump.joined(separator: ", "))"
    }

    public func choose(_ suggestion: Suggestion) {
        if case .saved(let id) = suggestion.source, let record = hosts.record(id), let endpoint = record.ssh {
            applying = true
            destination = endpoint.alias ?? endpoint.host
            alias = endpoint.alias
            user = endpoint.user
            port = endpoint.port == 22 ? "" : String(endpoint.port)
            proxyJump = endpoint.proxyJump ?? ""
            auth = Self.choice(for: endpoint)
            applying = false
            userEdited = true
            portEdited = true
            authEdited = true
            return
        }
        userEdited = false
        portEdited = false
        proxyJumpEdited = false
        authEdited = false
        destination = suggestion.value
        tidyDestination()
    }

    // MARK: Sign-in

    /// The IdentityFile from the address or ssh_config, else the agent if it has keys, else
    /// the first key pair in `~/.ssh`, else a key the app holds, else a password.
    private func defaultAuth(config: SshHostConfig? = nil) -> AuthChoice {
        if inventory.isDesktop {
            let files = [typedIdentityFile].compactMap { $0 } + (config?.identityFiles ?? [])
            if let file = files.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return .keyFile(path: file)
            }
            if !inventory.agentKeys.isEmpty, config?.identityAgent?.lowercased() != "none" { return .agent }
            if let key = inventory.localKeys.first { return .keyFile(path: key.path) }
        }
        if let key = hosts.keys.keys.first { return .key(id: key.id) }
        return .password
    }

    /// Picks the default again once the agent's keys are known (they load asynchronously).
    public func refreshInventory() async {
        await inventory.refresh()
        guard !authEdited else { return }
        applying = true
        auth = defaultAuth(config: typedHost.flatMap(resolvedConfig))
        applying = false
    }

    /// The chosen key file is encrypted and the agent does not hold it: ask for the
    /// passphrase.
    public var needsPassphrase: Bool {
        if case .key(let id) = auth { return hosts.keys.needsPassphrase(id) }
        guard case .keyFile(let path) = auth else { return false }
        if let key = inventory.localKey(at: path) {
            return key.encrypted && !inventory.agentHolds(fingerprint: key.info.fingerprint)
        }
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).map { privateKeyIsEncrypted(pem: $0) } ?? false
    }

    // MARK: Result

    /// The endpoint the form describes, or why it is incomplete.
    public func endpoint() throws -> SSHEndpoint {
        guard let host = typedHost, !host.isEmpty else { throw JustSSHError.missingHost }
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { throw JustSSHError.missingUser }
        let portText = port.trimmingCharacters(in: .whitespaces)
        guard let port = portText.isEmpty ? 22 : UInt16(portText), port > 0 else { throw JustSSHError.badPort(portText) }
        let config = alias.flatMap(inventory.configHost)
        let jump = proxyJump.trimmingCharacters(in: .whitespaces)
        let configJump = resolvedConfig(host)?.proxyJump.joined(separator: ",") ?? ""
        var endpoint = SSHEndpoint(
            user: user, host: config?.hostName ?? host, port: port, alias: config?.alias, identity: identity,
            proxyJump: jump == configJump ? nil : (jump.isEmpty ? "none" : jump))
        if case .agentKey(let fingerprint) = auth { endpoint.agentKey = fingerprint }
        return endpoint
    }

    private var identity: SSHIdentity {
        switch auth {
        case .password: .password
        case .key(let id): hosts.keys.key(id)?.kind == .secureEnclave ? .secureEnclave(id: id) : .key(id: id)
        case .keyFile(let path): .keyFile(path: path)
        case .agent, .agentKey: .agent
        }
    }

    private var typedPassword: String? { auth == .password ? password : nil }
    private var typedPassphrase: String? { needsPassphrase && !passphrase.isEmpty ? passphrase : nil }

    /// Dials once and signs in without saving: shows the host key on first contact.
    public func runTest() async {
        test = .running
        do {
            let elapsed = try await hosts.testSSH(try endpoint(), password: typedPassword, passphrase: typedPassphrase)
            test = .succeeded(elapsed)
        } catch {
            test = .failed(SshErrorText.describe(error))
        }
    }

    /// Adds the host and connects, or saves the edited host.
    public func connect() async {
        step = .connecting
        do {
            let endpoint = try endpoint()
            let name = name.trimmingCharacters(in: .whitespaces)
            if let editingHostId {
                try hosts.updateSSH(
                    editingHostId, endpoint: endpoint, name: name.isEmpty ? nil : name, password: typedPassword,
                    rememberPassword: rememberPassword, passphrase: typedPassphrase, rememberPassphrase: rememberPassphrase)
                step = .connected(editingHostId)
                return
            }
            let id = try hosts.connectSSH(
                endpoint, name: name.isEmpty ? nil : name, password: typedPassword, rememberPassword: rememberPassword,
                passphrase: typedPassphrase, rememberPassphrase: rememberPassphrase)
            if let ssh = hosts.connection(id) as? SshConnection {
                try await connected(ssh, hostId: id, endpoint: endpoint)
            }
            step = .connected(id)
        } catch {
            step = .failed(SshErrorText.describe(error))
        }
    }

    /// Waits until authenticated, or fails at the first dial that cannot reach the host
    /// (the session would otherwise redial forever while the sheet spins). The host stays
    /// saved; the redial stops until the user tries again.
    private func connected(_ ssh: SshConnection, hostId: String, endpoint: SSHEndpoint) async throws {
        let attempt = Task { try await ssh.connected() }
        while true {
            if case .reconnecting(_, let reason) = ssh.status {
                hosts.disconnect(hostId)
                _ = try? await attempt.value
                throw JustSSHError.unreachable(host: endpoint.host, reason: reason, tailscale: Tailscale.isTailnet(endpoint))
            }
            switch ssh.status {
            case .connected, .needsAttention, .idle:
                try await attempt.value
                return
            default:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Keys

    /// Generates an ed25519 key for this host and selects it. Show `newKey.publicKey` and
    /// `authorizeCommand` so the user can install it (or connect with a password first and
    /// use `authorizeOverSession`).
    public func generateKey() async throws {
        let key = try await hosts.keys.generate(label: keyLabel)
        select(key)
    }

    public func generateSecureEnclaveKey() throws {
        let key = try hosts.keys.generateSecureEnclaveKey(label: keyLabel)
        select(key)
    }

    /// Imports a private key (file contents or paste) and selects it.
    public func importKey(pem: Data, passphrase: String?, label: String) async throws {
        let key = try await hosts.keys.importKey(pem: pem, passphrase: passphrase, label: label)
        select(key)
    }

    /// Selects a key made elsewhere (the Keys manager) and shows its public half.
    public func select(_ key: SSHKey) {
        newKey = key
        auth = .key(id: key.id)
    }

    private var keyLabel: String {
        (try? endpoint().display) ?? "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "app") key"
    }

    /// Installs `key`'s public half into `~/.ssh/authorized_keys` over a host's live SSH
    /// session ("Use a key next time"), then switches the host to that key.
    public func authorizeOverSession(hostId: String, key: SSHKey) async throws {
        try await hosts.authorize(key.publicKey, onHost: hostId)
        hosts.update(hostId) { $0.ssh?.identity = key.kind == .secureEnclave ? .secureEnclave(id: key.id) : .key(id: key.id) }
    }

    public func reset() {
        step = .enterDestination
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return HostsModel.homeDirectory + path.dropFirst()
    }
}

/// `user@host:port` text, IPv6 in brackets when a port follows.
nonisolated public enum SSHAddress {
    public static func text(user: String?, host: String, port: UInt16) -> String {
        let userPart = user.map { "\($0)@" } ?? ""
        guard port != 22 else { return userPart + host }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return "\(userPart)\(hostPart):\(port)"
    }
}

public enum JustSSHError: Error, Equatable, LocalizedError {
    case missingHost
    case missingUser
    case badPort(String)
    case remote(String)
    /// The first dial did not reach the host (`tailscale`: it is on a tailnet).
    case unreachable(host: String, reason: String, tailscale: Bool)

    public var errorDescription: String? {
        switch self {
        case .missingHost: "Add the host's address"
        case .missingUser: "Add a user name"
        case .badPort(let port): "\(port) is not a port (1 to 65535)"
        case .remote(let stderr): "The host refused: \(stderr)"
        // The screen adds the Tailscale hint (with its Open button) for tailnet hosts.
        case .unreachable(let host, let reason, _): "Couldn't reach \(host): \(reason)"
        }
    }
}
