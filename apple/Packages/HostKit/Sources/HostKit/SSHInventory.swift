import Foundation
import Observation
import GudoCore

/// What this device already knows about SSH, for the host form: `~/.ssh/config` hosts (with
/// `Include`s), key pairs in `~/.ssh`, the SSH agent's keys and known_hosts names on the Mac;
/// on iOS the ssh_config imported into the app. Private keys are never read here except to see
/// whether one is encrypted.
@MainActor
@Observable
public final class SSHInventory {
    /// Where the inventory comes from (the device, or fixed values in tests).
    public struct Source: Sendable {
        public var config: @Sendable () -> SshConfigFile?
        public var localKeys: @Sendable () -> [SshLocalKey]
        public var agentKeys: @Sendable () async -> [SshPublicKeyInfo]
        public var knownHosts: @Sendable () -> [SshKnownHostName]
        /// The user `ssh` would log in as by default (the Mac's user); nil on iOS.
        public var localUser: String?
        /// Keys in `~/.ssh` and an SSH agent exist here (the Mac).
        public var isDesktop: Bool

        public init(
            config: @escaping @Sendable () -> SshConfigFile? = { nil },
            localKeys: @escaping @Sendable () -> [SshLocalKey] = { [] },
            agentKeys: @escaping @Sendable () async -> [SshPublicKeyInfo] = { [] },
            knownHosts: @escaping @Sendable () -> [SshKnownHostName] = { [] },
            localUser: String? = nil,
            isDesktop: Bool = false
        ) {
            self.config = config
            self.localKeys = localKeys
            self.agentKeys = agentKeys
            self.knownHosts = knownHosts
            self.localUser = localUser
            self.isDesktop = isDesktop
        }
    }

    public private(set) var config: SshConfigFile?
    /// Concrete `Host` aliases, resolved.
    public private(set) var configHosts: [SshHostConfig] = []
    public private(set) var localKeys: [SshLocalKey] = []
    public private(set) var agentKeys: [SshPublicKeyInfo] = []
    public private(set) var knownHosts: [SshKnownHostName] = []
    public let localUser: String?
    /// Whether this device can have keys in `~/.ssh` and an agent (the Mac).
    public let isDesktop: Bool

    @ObservationIgnored private let source: Source

    public init(source: Source) {
        self.source = source
        isDesktop = source.isDesktop
        localUser = source.localUser
        reloadFiles()
    }

    /// Reads the files again and asks the agent.
    public func refresh() async {
        reloadFiles()
        agentKeys = await source.agentKeys()
    }

    private func reloadFiles() {
        config = source.config()
        configHosts = config.map { config in config.hostAliases().map { config.resolve(alias: $0) } } ?? []
        localKeys = source.localKeys()
        knownHosts = source.knownHosts()
    }

    public func configHost(_ alias: String) -> SshHostConfig? {
        configHosts.first { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }
    }

    /// The key pair on disk whose private key is at `path`.
    public func localKey(at path: String) -> SshLocalKey? {
        localKeys.first { $0.path == path }
    }

    /// Whether the agent holds this key (an encrypted key file it has unlocked needs no
    /// passphrase).
    public func agentHolds(fingerprint: String) -> Bool {
        agentKeys.contains { $0.fingerprint == fingerprint }
    }

    /// The device's own: `~/.ssh` on the Mac, the imported ssh_config on iOS.
    public static func live(importedConfig: @escaping @Sendable () -> String?) -> SSHInventory {
        #if os(macOS)
        let home = HostsModel.homeDirectory
        let user = NSUserName()
        let ssh = URL(fileURLWithPath: home).appending(path: ".ssh")
        let source = Source(
            config: {
                (try? SshConfigFile.load(path: ssh.appending(path: "config").path, home: home, localUser: user))
                    ?? importedConfig().flatMap { try? SshConfigFile.parse(text: $0, home: home, localUser: user) }
            },
            localKeys: { listLocalSshKeys(directory: ssh.path) },
            agentKeys: { (try? await listAgentSshKeys(socketPath: nil)) ?? [] },
            knownHosts: {
                let text = (try? String(contentsOf: ssh.appending(path: "known_hosts"), encoding: .utf8)) ?? ""
                return knownSshHostNames(text: text)
            },
            localUser: user,
            isDesktop: true)
        return SSHInventory(source: source)
        #else
        let source = Source(config: {
            importedConfig().flatMap { try? SshConfigFile.parse(text: $0, home: nil, localUser: nil) }
        })
        return SSHInventory(source: source)
        #endif
    }
}
