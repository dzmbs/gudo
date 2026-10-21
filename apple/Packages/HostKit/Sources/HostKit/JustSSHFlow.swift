import Foundation
import Observation
import UnnamedCore

/// The "just ssh" flow (04-mobile-ux C1): type `user@host[:port]`, pick how to authenticate,
/// answer the host-key prompt (`HostsModel.hostKeyPrompts`), get a plain-SSH terminal at once,
/// then optionally "Install helper" (`HostsModel.installHelper`).
@MainActor
@Observable
public final class JustSSHFlow {
    public enum Step: Equatable, Sendable {
        case enterDestination
        case connecting
        /// Connected: the host id to open.
        case connected(String)
        case failed(String)
    }

    /// How to authenticate.
    public enum AuthChoice: Hashable, Sendable {
        case password
        /// A key the app already has (generated, imported or Secure Enclave).
        case key(id: String)
        /// A key file on disk (macOS).
        case keyFile(path: String)
        /// ssh-agent (macOS).
        case agent
    }

    public var destination = ""
    public var auth = AuthChoice.password
    public var password = ""
    public var rememberPassword = true
    public private(set) var step = Step.enterDestination
    /// The key just generated or imported in this flow, to show its public key.
    public private(set) var newKey: SSHKey?

    private let hosts: HostsModel

    public init(hosts: HostsModel) {
        self.hosts = hosts
    }

    /// The parsed destination, or why it does not parse.
    public func endpoint() throws -> SSHEndpoint {
        let parsed = try parseSshDestination(text: destination.trimmingCharacters(in: .whitespaces))
        guard let user = parsed.user ?? Self.defaultUser else { throw JustSSHError.missingUser }
        return SSHEndpoint(user: user, host: parsed.host, port: parsed.port ?? 22, identity: identity)
    }

    private var identity: SSHIdentity {
        switch auth {
        case .password: .password
        case .key(let id): hosts.keys.key(id)?.kind == .secureEnclave ? .secureEnclave(id: id) : .key(id: id)
        case .keyFile(let path): .keyFile(path: path)
        case .agent: .agent
        }
    }

    private static var defaultUser: String? {
        #if os(macOS)
        NSUserName()
        #else
        nil
        #endif
    }

    /// Generates an ed25519 key for this host and selects it. Show `newKey.publicKey` and
    /// `authorizeCommand` so the user can install it (or connect with a password first and
    /// use `authorizeOverSession`).
    public func generateKey() throws {
        let label = (try? endpoint().display) ?? "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "app") key"
        let key = try hosts.keys.generate(label: label)
        newKey = key
        auth = .key(id: key.id)
    }

    /// A Secure Enclave P-256 key, selected.
    public func generateSecureEnclaveKey() throws {
        let key = try hosts.keys.generateSecureEnclaveKey(label: (try? endpoint().display) ?? "secure enclave")
        newKey = key
        auth = .key(id: key.id)
    }

    /// Imports a private key (file contents or paste) and selects it.
    public func importKey(pem: Data, passphrase: String?, label: String) throws {
        let key = try hosts.keys.importKey(pem: pem, passphrase: passphrase, label: label)
        newKey = key
        auth = .key(id: key.id)
    }

    /// Connects and waits until authenticated (the host-key prompt may come up meanwhile).
    public func connect() async {
        step = .connecting
        do {
            let endpoint = try endpoint()
            let id = try hosts.connectSSH(
                endpoint, password: auth == .password ? password : nil, rememberPassword: rememberPassword)
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

    /// Installs `key`'s public half into `~/.ssh/authorized_keys` over a host's live SSH
    /// session ("Use a key next time", C1.2), then switches the host to that key.
    public func authorizeOverSession(hostId: String, key: SSHKey) async throws {
        guard let ssh = hosts.connection(hostId) as? SshConnection, let session = ssh.session else {
            throw HostError.notConnected
        }
        let output = try await session.exec(command: key.authorizeCommand)
        guard output.exitStatus == 0 else {
            throw JustSSHError.remote(String(decoding: output.stderr, as: UTF8.self))
        }
        hosts.update(hostId) { $0.ssh?.identity = key.kind == .secureEnclave ? .secureEnclave(id: key.id) : .key(id: key.id) }
    }

    public func reset() {
        step = .enterDestination
    }
}

public enum JustSSHError: Error, Equatable, LocalizedError {
    case missingUser
    case remote(String)
    /// The first dial did not reach the host (`tailscale`: it is on a tailnet).
    case unreachable(host: String, reason: String, tailscale: Bool)

    public var errorDescription: String? {
        switch self {
        case .missingUser: "Add a user name: user@host"
        case .remote(let stderr): "The host refused: \(stderr)"
        // The screen adds the Tailscale hint (with its Open button) for tailnet hosts.
        case .unreachable(let host, let reason, _): "Couldn't reach \(host): \(reason)"
        }
    }
}
