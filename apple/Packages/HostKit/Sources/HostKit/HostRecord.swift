import Foundation

/// A saved host: metadata only (`hosts.json` in the app container). Secrets (ticket, password,
/// private keys) live in the `SecretStore` under keys derived from `id`.
nonisolated public struct HostRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Paired with `gudo-hostd`: dialled over iroh by its ticket.
        case daemon
        /// Plain SSH, no daemon (yet).
        case ssh
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// How to reach it over SSH: set for SSH hosts, and kept for daemon hosts that were
    /// upgraded from SSH (to reinstall or upgrade the helper).
    public var ssh: SSHEndpoint?
    /// The daemon's endpoint id (hex), for daemon hosts.
    public var daemonId: String?
    /// The daemon session last attached.
    public var sessionId: UInt64?
    public var lastConnected: Date?
    public var pinned = false
    public var created = Date()
    /// Joined with an invite (multiplayer guest) rather than paired: dialled with the invite
    /// (`DaemonClient.join`), never as the owner. Optional so older `hosts.json` files decode.
    public var guest: Bool?
    /// Who invited, for guest hosts ("Alex").
    public var inviter: String?
    /// Where `name` came from. nil for records from before it was tracked (decided once, by
    /// `MachineName.looksDefault`).
    public var nameSource: NameSource?
    /// What the daemon last said about its machine.
    public var machine: Machine?
    /// The helper the app itself runs on this device (the Mac's "This Mac"). Optional so older
    /// `hosts.json` files decode.
    public var thisDevice: Bool?

    public var isGuest: Bool { guest == true }
    public var isThisDevice: Bool { thisDevice == true }

    /// Where a host's name came from: the app's placeholder, the machine's host name, or the
    /// user. Only placeholders are replaced by the machine's name, and only once.
    public enum NameSource: String, Codable, Sendable {
        /// The app made it up ("Host 1a2b3c4d", the address typed).
        case placeholder
        /// The machine's host name (`DaemonInfo.hostname`, domain stripped).
        case machine
        /// Typed or chosen by the user (rename, a name given when pairing, an ssh_config
        /// alias): never changed by the app.
        case user
    }

    /// The machine behind a daemon host.
    public struct Machine: Codable, Hashable, Sendable {
        /// Host name as the system reports it.
        public var hostname: String
        /// "Ubuntu 24.04.1 LTS".
        public var osName: String
        /// `linux`, `macos`.
        public var os: String
        /// `x86_64`, `aarch64`.
        public var arch: String

        public init(hostname: String, osName: String, os: String, arch: String) {
            self.hostname = hostname
            self.osName = osName
            self.os = os
            self.arch = arch
        }
    }

    public init(id: String = UUID().uuidString, name: String, kind: Kind, ssh: SSHEndpoint? = nil, daemonId: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ssh = ssh
        self.daemonId = daemonId
    }

    /// Secret-store keys for this host.
    public var ticketKey: String { "host.\(id).ticket" }
    public var passwordKey: String { "host.\(id).password" }
    public var inviteKey: String { "host.\(id).invite" }
}

/// Where and how to SSH to a host.
nonisolated public struct SSHEndpoint: Codable, Hashable, Sendable {
    public var user: String
    public var host: String
    public var port: UInt16
    /// The `~/.ssh/config` alias it came from (resolved again at connect time: ProxyJump,
    /// HostKeyAlias).
    public var alias: String?
    /// How to authenticate.
    public var identity: SSHIdentity

    public init(user: String, host: String, port: UInt16 = 22, alias: String? = nil, identity: SSHIdentity) {
        self.user = user
        self.host = host
        self.port = port
        self.alias = alias
        self.identity = identity
    }

    /// `user@host[:port]`.
    public var display: String {
        port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }
}

/// An SSH credential, by reference (the secret itself is in the `SecretStore`).
nonisolated public enum SSHIdentity: Codable, Hashable, Sendable {
    /// A password saved for this host (or asked for every time if not saved).
    case password
    /// A private key in the app's key store (`KeyStore`): generated here or imported.
    case key(id: String)
    /// A Secure Enclave P-256 key (`KeyStore`), never exportable.
    case secureEnclave(id: String)
    /// A key file on disk (macOS: `~/.ssh/id_ed25519`, IdentityFile from `~/.ssh/config`).
    case keyFile(path: String)
    /// The ssh-agent at `$SSH_AUTH_SOCK` (macOS).
    case agent
}

/// Loads and saves `HostRecord`s as JSON in a directory (the app's Application Support).
nonisolated public final class HostRepository: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/<bundle id>/`, created on demand.
    public static func appDefault() -> HostRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HostRepository(directory: base.appending(path: Bundle.main.bundleIdentifier ?? "dev.gudo.app"))
    }

    private var hostsURL: URL { directory.appending(path: "hosts.json") }
    private var sshConfigURL: URL { directory.appending(path: "ssh_config") }

    public func load() -> [HostRecord] {
        guard let data = try? Data(contentsOf: hostsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HostRecord].self, from: data)) ?? []
    }

    public func save(_ hosts: [HostRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hosts).write(to: hostsURL, options: .atomic)
    }

    /// The imported `~/.ssh/config` text (not secret: it holds names and paths).
    public func loadSSHConfig() -> String? {
        try? String(contentsOf: sshConfigURL, encoding: .utf8)
    }

    public func saveSSHConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: sshConfigURL, atomically: true, encoding: .utf8)
    }
}
