import Foundation
@testable import HostKit
import Testing
import GudoCore

/// A Mac with an ssh_config, two key pairs in `~/.ssh` (one encrypted) and an agent holding
/// one key, all in a temporary directory.
@MainActor
private struct Desk {
    let model: HostsModel
    let sshDirectory: URL
    let plainKey: GeneratedSshKey
    let lockedKey: GeneratedSshKey

    init(config: String = Desk.config, agentHoldsLocked: Bool = false, agentKeys extra: [SshPublicKeyInfo] = []) throws {
        let home = temporaryDirectory()
        let ssh = home.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let plain = try generateSshKey(keyType: .ed25519, comment: "me@mac", passphrase: nil)
        let locked = try generateSshKey(keyType: .ed25519, comment: "work", passphrase: "pw")
        try plain.privateKey.write(to: ssh.appending(path: "id_ed25519"))
        try plain.publicKey.write(to: ssh.appending(path: "id_ed25519.pub"), atomically: true, encoding: .utf8)
        try locked.privateKey.write(to: ssh.appending(path: "work"))
        try locked.publicKey.write(to: ssh.appending(path: "work.pub"), atomically: true, encoding: .utf8)
        let configText = config.replacingOccurrences(of: "$SSH", with: ssh.path)
        try configText.write(to: ssh.appending(path: "config"), atomically: true, encoding: .utf8)
        let lockedInfo = try parseSshPublicKey(line: locked.publicKey)
        let agent = (agentHoldsLocked ? [lockedInfo] : []) + extra
        var configuration = HostsModel.Configuration()
        configuration.sshInventory = SSHInventory.Source(
            config: { try? SshConfigFile.load(path: ssh.appending(path: "config").path, home: home.path, localUser: "vani") },
            localKeys: { listLocalSshKeys(directory: ssh.path) },
            agentKeys: { agent },
            knownHosts: { knownSshHostNames(text: "build.example.com ssh-ed25519 AAAA\n[git.example.com]:2222 ssh-ed25519 AAAA\n|1|x|y ssh-rsa AAAA\n") },
            localUser: "vani",
            isDesktop: true)
        model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
        sshDirectory = ssh
        plainKey = plain
        lockedKey = locked
    }

    static let config = """
        Include conf.d/*
        Host prod
          HostName 62.238.108.86
          User root
          Port 2200
          IdentityFile $SSH/work
          ProxyJump admin@bastion
        Host bastion
          HostName bastion.example.com
          IdentityFile $SSH/id_ed25519
        Host *.internal
          User ops
        """
}

@MainActor
@Suite struct SSHHostFormTests {
    @Test func smartFieldFillsEditableFields() throws {
        let desk = try Desk()
        let flow = JustSSHFlow(hosts: desk.model)
        #expect(flow.user == "vani")
        flow.destination = "root@62.238.108.86"
        #expect(flow.user == "root")
        #expect(flow.port == "")
        flow.destination = "ssh -p 2222 -i ~/.ssh/key -J admin@jump deploy@box.example.com"
        #expect(flow.user == "deploy")
        #expect(flow.port == "2222")
        #expect(flow.proxyJump == "admin@jump")
        flow.tidyDestination()
        #expect(flow.destination == "box.example.com")
        let endpoint = try flow.endpoint()
        #expect(endpoint.host == "box.example.com")
        #expect(endpoint.port == 2222)
        #expect(endpoint.proxyJump == "admin@jump")

        // Every field stays editable; what the user typed wins over defaults.
        flow.user = "admin"
        flow.port = "2022"
        flow.destination = "other.example.com"
        #expect(flow.user == "admin")
        #expect(flow.port == "2022")
        flow.port = "70000"
        #expect(throws: JustSSHError.badPort("70000")) { try flow.endpoint() }
        flow.user = ""
        flow.port = ""
        #expect(throws: JustSSHError.missingUser) { try flow.endpoint() }
    }

    @Test func aliasFromSSHConfig() throws {
        let desk = try Desk()
        let flow = JustSSHFlow(hosts: desk.model)
        flow.destination = "pro"
        let suggestion = try #require(flow.suggestions().first)
        #expect(suggestion.source == .sshConfig)
        #expect(suggestion.value == "prod")
        #expect(suggestion.detail == "root@62.238.108.86:2200 via admin@bastion")
        flow.choose(suggestion)
        #expect(flow.alias == "prod")
        #expect(flow.aliasHostName == "62.238.108.86")
        #expect(flow.user == "root")
        #expect(flow.port == "2200")
        #expect(flow.proxyJump == "admin@bastion")
        #expect(flow.auth == .keyFile(path: desk.sshDirectory.appending(path: "work").path))
        // An encrypted key the agent does not hold needs its passphrase.
        #expect(flow.needsPassphrase)

        let endpoint = try flow.endpoint()
        #expect(endpoint.alias == "prod")
        #expect(endpoint.host == "62.238.108.86")
        #expect(endpoint.proxyJump == nil)
        let route = try desk.model.route(for: endpoint)
        #expect(route.target.host.host == "62.238.108.86")
        #expect(route.target.host.port == 2200)
        #expect(route.target.jumps.map(\.host) == ["bastion.example.com"])
        #expect(route.target.jumps.map(\.user) == ["admin"])
        #expect(route.jumpIdentityFiles == [[desk.sshDirectory.appending(path: "id_ed25519").path]])

        // Clearing Jump Host overrides the config's ProxyJump.
        flow.proxyJump = ""
        #expect(try flow.endpoint().proxyJump == "none")
        #expect(try desk.model.route(for: flow.endpoint()).target.jumps.isEmpty)
    }

    @Test func includedHostsAndPatterns() async throws {
        let desk = try Desk()
        try FileManager.default.createDirectory(at: desk.sshDirectory.appending(path: "conf.d"), withIntermediateDirectories: true)
        try "Host lab\n  HostName 10.1.2.3\n  User lab\n".write(
            to: desk.sshDirectory.appending(path: "conf.d/lab"), atomically: true, encoding: .utf8)
        await desk.model.sshInventory.refresh()
        let flow = JustSSHFlow(hosts: desk.model)
        flow.destination = "lab"
        #expect(flow.alias == "lab")
        #expect(flow.user == "lab")
        #expect(try flow.endpoint().host == "10.1.2.3")

        // Not an alias, but a `Host *.internal` pattern names the user.
        let patterned = JustSSHFlow(hosts: desk.model)
        patterned.destination = "db.internal"
        #expect(patterned.alias == nil)
        #expect(patterned.user == "ops")
        #expect(try desk.model.route(for: patterned.endpoint()).target.host.user == "ops")
    }

    @Test func knownHostsAndSavedHostsAreSuggested() throws {
        let desk = try Desk()
        desk.model.upsert(HostRecord(id: "s", name: "staging", kind: .ssh, ssh: SSHEndpoint(user: "deploy", host: "staging.example.com", identity: .password)))
        let flow = JustSSHFlow(hosts: desk.model)
        flow.destination = "example"
        let values = flow.suggestions().map(\.value)
        #expect(values.contains("staging.example.com"))
        #expect(values.contains("build.example.com"))
        #expect(values.contains("git.example.com:2222"))
        let saved = try #require(flow.suggestions().first { $0.source == .saved("s") })
        flow.choose(saved)
        #expect(flow.user == "deploy")
        #expect(flow.auth == .password)
    }

    @Test func defaultSignInPrefersConfigThenAgentThenFiles() async throws {
        let agentKey = try parseSshPublicKey(line: try generateSshKey(keyType: .ed25519, comment: "1password", passphrase: nil).publicKey)
        let withAgent = try Desk(agentKeys: [agentKey])
        let flow = JustSSHFlow(hosts: withAgent.model)
        await flow.refreshInventory()
        #expect(flow.auth == .agent)
        flow.destination = "prod"
        #expect(flow.auth == .keyFile(path: withAgent.sshDirectory.appending(path: "work").path))

        let noAgent = try Desk()
        let fileFlow = JustSSHFlow(hosts: noAgent.model)
        await fileFlow.refreshInventory()
        #expect(fileFlow.auth == .keyFile(path: noAgent.sshDirectory.appending(path: "id_ed25519").path))

        // A choice the user made is kept.
        fileFlow.auth = .password
        fileFlow.destination = "box"
        #expect(fileFlow.auth == .password)

        // One agent key only: the endpoint records it.
        flow.auth = .agentKey(fingerprint: agentKey.fingerprint)
        let endpoint = try flow.endpoint()
        #expect(endpoint.identity == .agent)
        #expect(endpoint.agentKey == agentKey.fingerprint)
    }

    @Test func encryptedKeyFileUsesAgentOrPassphrase() async throws {
        let held = try Desk(agentHoldsLocked: true)
        await held.model.sshInventory.refresh()
        let heldPath = held.sshDirectory.appending(path: "work").path
        let heldRecord = HostRecord(id: "p", name: "prod", kind: .ssh, ssh: SSHEndpoint(user: "root", host: "62.238.108.86", identity: .keyFile(path: heldPath)))
        // The agent has unlocked it: sign with the agent's copy, ask for nothing.
        guard case .agentKey(_, let fingerprint) = try held.model.auth(for: heldRecord, password: nil).first else {
            Issue.record("not the agent's key"); return
        }
        #expect(fingerprint == (try parseSshPublicKey(line: held.lockedKey.publicKey)).fingerprint)
        let flow = JustSSHFlow(hosts: held.model)
        flow.destination = "prod"
        #expect(!flow.needsPassphrase)

        let locked = try Desk()
        let lockedRecord = HostRecord(id: "p", name: "prod", kind: .ssh, ssh: SSHEndpoint(
            user: "root", host: "62.238.108.86", identity: .keyFile(path: locked.sshDirectory.appending(path: "work").path)))
        #expect(throws: HostError.missingSecret("passphrase for work")) { try locked.model.auth(for: lockedRecord, password: nil) }
        guard case .keyFile(_, let passphrase) = try locked.model.auth(for: lockedRecord, password: nil, passphrase: "pw").first else {
            Issue.record("not a key file"); return
        }
        #expect(passphrase == "pw")
    }

    @Test func editingKeepsTheHostAndSavesChanges() async throws {
        let desk = try Desk()
        let endpoint = SSHEndpoint(user: "me", host: "127.0.0.1", port: 1, identity: .password)
        desk.model.upsert(HostRecord(id: "e", name: "box", kind: .ssh, ssh: endpoint))
        let flow = JustSSHFlow(hosts: desk.model, editing: try #require(desk.model.record("e")))
        #expect(flow.destination == "127.0.0.1")
        #expect(flow.user == "me")
        #expect(flow.port == "1")
        #expect(flow.auth == .password)
        #expect(flow.suggestions().allSatisfy { $0.source != .saved("e") })
        flow.user = "root"
        flow.port = ""
        flow.name = "Web"
        await flow.connect()
        #expect(flow.step == .connected("e"))
        let saved = try #require(desk.model.record("e"))
        #expect(saved.name == "Web")
        #expect(saved.ssh?.user == "root")
        #expect(saved.ssh?.port == 22)
        #expect(desk.model.records.count == 1)
    }

    @Test func passphraseProtectedAppKeys() async throws {
        let desk = try Desk()
        let key = try await desk.model.keys.generate(label: "laptop", type: .ed25519, passphrase: "secret")
        #expect(key.encrypted == true)
        #expect(desk.model.keys.needsPassphrase(key.id))
        #expect(throws: HostError.missingSecret("passphrase for laptop")) { try desk.model.keys.auth(for: key.id) }
        _ = try desk.model.keys.auth(for: key.id, passphrase: "secret")
        try desk.model.keys.savePassphrase("secret", for: key.id)
        #expect(!desk.model.keys.needsPassphrase(key.id))
        let remembered = try await desk.model.keys.generate(label: "rsa", type: .ed25519, passphrase: "x", rememberPassphrase: true)
        #expect(!desk.model.keys.needsPassphrase(remembered.id))
        #expect(remembered.typeName == "Ed25519")
    }

    @Test func authorizeCommandIsSafe() throws {
        let key = try generateSshKey(keyType: .ed25519, comment: "it's me", passphrase: nil)
        let command = try sshAuthorizeKeyCommand(publicKey: key.publicKey)
        #expect(command.contains("authorized_keys"))
        #expect(throws: (any Error).self) { try sshAuthorizeKeyCommand(publicKey: "ssh-ed25519 AAAA'; rm -rf ~") }
    }
}
