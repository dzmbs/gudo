import Foundation
@testable import HostKit
import PaneLayout
import Testing
import GudoCore

nonisolated func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hostkit-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Suite struct HostsModelTests {
    @Test func hostsPersistAndSortNeedsYouFirst() async throws {
        let directory = temporaryDirectory()
        let secrets = MemorySecretStore()
        let model = HostsModel(secrets: secrets, repository: HostRepository(directory: directory))
        model.upsert(HostRecord(id: "a", name: "alpha", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "alpha", identity: .password)))
        model.upsert(HostRecord(id: "b", name: "beta", kind: .daemon, daemonId: "ab"))
        model.upsert(HostRecord(id: "c", name: "gamma", kind: .daemon, daemonId: "cd"))
        model.setPinned("c", true)
        #expect(model.entries.map(\.id) == ["c", "a", "b"])

        // A connection that needs the user moves its host to the top.
        let connection = DaemonConnection(hostId: "b", ticket: "t") { _, listener in FakeClient(listener: listener) }
        try connection.connect()
        model.connections["b"] = connection
        connection.handle(.refused(reason: "InvalidGrant"))
        #expect(model.entries.first?.id == "b")
        #expect(model.entries.first?.needsYou?.contains("isn't paired with this host anymore") == true)
        #expect(model.entries.first?.needsYou?.contains("InvalidGrant") == false)
        #expect(model.entries.first { $0.id == "a" }?.canInstallHelper == true)

        // Everything but secrets is saved as JSON and comes back.
        model.rename("a", to: "prod")
        let reloaded = HostsModel(secrets: secrets, repository: HostRepository(directory: directory))
        #expect(Set(reloaded.records.map(\.name)) == ["prod", "beta", "gamma"])
        #expect(reloaded.record("c")?.pinned == true)
        let json = try String(contentsOf: directory.appending(path: "hosts.json"), encoding: .utf8)
        #expect(!json.contains("password\":\""))

        reloaded.remove("a")
        #expect(HostsModel(secrets: secrets, repository: HostRepository(directory: directory)).record("a") == nil)
    }

    @Test func lowDataModeTurnedOffAfterOpeningReachesTheClient() throws {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.dialer = { _, listener in FakeClient(listener: listener) }
        model.upsert(HostRecord(id: "h", name: "studio", kind: .daemon, daemonId: "d1"))
        try model.secrets.set("ticket", for: "host.h.ticket")
        model.network.update(offline: false, interfaces: ["wifi"], lowDataMode: true, signature: "wifi-constrained")
        let connection = try #require(try model.open("h") as? DaemonConnection)
        model.network.update(offline: false, interfaces: ["wifi"], lowDataMode: false, signature: "wifi")
        let client = try #require(connection.client as? FakeClient)
        #expect(client.calls.last { if case .lowDataMode = $0 { true } else { false } } == .lowDataMode(false))
    }

    @Test func sshHostsNeedACredential() throws {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        let endpoint = SSHEndpoint(user: "me", host: "127.0.0.1", port: 1, identity: .password)
        model.upsert(HostRecord(id: "s", name: "s", kind: .ssh, ssh: endpoint))
        #expect(throws: HostError.missingSecret("password for me@127.0.0.1:1")) { try model.open("s") }
    }

    @Test func sshConfigImport() throws {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        try model.loadSSHConfig("""
            Host bastion
              HostName 10.0.0.1
              User ops
            Host box
              HostName box.internal
              User dev
              Port 2222
              ProxyJump bastion
            Host *
              ServerAliveInterval 30
            """)
        #expect(model.sshConfigAliases.map(\.alias) == ["bastion", "box"])
        model.importSSHHosts(["box"])
        let record = try #require(model.records.first)
        #expect(record.name == "box")
        #expect(record.ssh?.host == "box.internal")
        #expect(record.ssh?.port == 2222)
        #expect(record.ssh?.alias == "box")
        // The target goes through the jump host.
        let target = try model.target(for: try #require(record.ssh))
        #expect(target.jumps.map(\.host) == ["10.0.0.1"])
        #expect(target.host.host == "box.internal")
        // Importing again does not duplicate.
        model.importSSHHosts(["box"])
        #expect(model.records.count == 1)
    }
}

@MainActor
@Suite struct PairingAndKeysTests {
    @Test func badTicketsAreRejected() {
        #expect(throws: HostError.self) { try PairingTicket("hello") }
        #expect(throws: HostError.badTicket("not a pairing ticket")) { try PairingTicket("hello world!") }
        #expect(PairingTicket(url: URL(string: "https://example.com/pair/x")!) == nil)
    }

    @Test func deviceKeyIsGeneratedOnce() throws {
        let secrets = MemorySecretStore()
        let first = try DeviceIdentity.load(from: secrets)
        #expect(first.count == 32)
        #expect(try DeviceIdentity.load(from: secrets) == first)
    }

    @Test func fileSecretsRoundTrip() throws {
        let store = FileSecretStore(directory: temporaryDirectory())
        try store.set("s3cret", for: "host.x/../ticket")
        #expect(try store.string(for: "host.x/../ticket") == "s3cret")
        try store.remove("host.x/../ticket")
        #expect(try store.data(for: "host.x/../ticket") == nil)
    }

    @Test func daemonIdFingerprintIsGroupedAndShort() {
        #expect(PairingTicket.keyFingerprint(String(repeating: "AB12", count: 16)) == "ab12 ab12 ab12 ab12 …")
        #expect(PairingTicket.keyFingerprint("abcdef") == "abcd ef")
    }

    @Test func fileSecretsAreOwnerOnly() throws {
        let directory = temporaryDirectory().appending(path: "secrets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = FileSecretStore(directory: directory)
        try store.set("s3cret", for: "device-key")
        func permissions(_ url: URL) throws -> Int {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
        }
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(directory.appending(path: "device-key")) == 0o600)
    }

    /// A permissive umask (0: everything world-writable) still leaves the folder and every
    /// secret owner-only, including a folder another process made first.
    @Test func fileSecretsAreOwnerOnlyUnderAnOpenUmask() throws {
        let parent = temporaryDirectory()
        let directory = parent.appending(path: "a/b/secrets")
        let previous = umask(0)
        defer { umask(previous) }
        let store = FileSecretStore(directory: directory)
        try store.set("s3cret", for: "device-key")
        try FileManager.default.createDirectory(at: parent.appending(path: "planted"), withIntermediateDirectories: true)
        let planted = FileSecretStore(directory: parent.appending(path: "planted"))
        try planted.set("s3cret", for: "device-key")
        func permissions(_ url: URL) throws -> Int {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
        }
        for folder in [directory, parent.appending(path: "planted")] {
            #expect(try permissions(folder) == 0o700, "\(folder.path)")
            #expect(try permissions(folder.appending(path: "device-key")) == 0o600)
            // No stray copies (an atomic write's temporary file) left readable beside it.
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["device-key"])
        }
    }

    @Test func fileSecretsMoveIntoTheKeychainAndLeaveNoFiles() throws {
        let files = FileSecretStore(directory: temporaryDirectory())
        try files.set("ticket-a", for: "host.A.ticket")
        try files.set("old-key", for: "device-key")
        let keychain = MemorySecretStore()
        try keychain.set("current-key", for: "device-key")

        try SecretStores.migrate(from: files, to: keychain)

        #expect(try keychain.string(for: "host.A.ticket") == "ticket-a")
        // What the Keychain already holds wins.
        #expect(try keychain.string(for: "device-key") == "current-key")
        #expect(files.keys().isEmpty)
    }

    @Test func keysGenerateImportAndAuthenticate() throws {
        let secrets = MemorySecretStore()
        let directory = temporaryDirectory()
        let keys = KeyStore(secrets: secrets, directory: directory)
        let generated = try keys.generate(label: "me@box")
        #expect(generated.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(generated.fingerprint.hasPrefix("SHA256:"))
        #expect(generated.authorizeCommand.contains(generated.publicKey))
        guard case .keyData(let pem, nil) = try keys.auth(for: generated.id) else { Issue.record("not key data"); return }

        // Importing the same key again returns the existing entry.
        let other = KeyStore(secrets: secrets, directory: temporaryDirectory())
        let imported = try other.importKey(pem: pem, passphrase: nil, label: "copy")
        #expect(imported.fingerprint == generated.fingerprint)
        #expect(throws: (any Error).self) { try other.importKey(pem: Data("junk".utf8), passphrase: nil, label: "x") }

        // The list survives a reload; removal deletes the secret.
        #expect(KeyStore(secrets: secrets, directory: directory).keys.map(\.id) == [generated.id])
        try keys.remove(generated.id)
        #expect(throws: KeyStoreError.unknownKey(generated.id)) { try keys.auth(for: generated.id) }
    }

    @Test func justSSHParsesDestinations() throws {
        var configuration = HostsModel.Configuration()
        configuration.sshInventory = SSHInventory.Source()
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
        let flow = JustSSHFlow(hosts: model)
        flow.destination = " mira@example.com:2222 "
        let endpoint = try flow.endpoint()
        #expect(endpoint == SSHEndpoint(user: "mira", host: "example.com", port: 2222, identity: .password))
        flow.destination = "ssh://root@[::1]:22"
        #expect(try flow.endpoint().host == "::1")
        try flow.generateKey()
        guard case .key(let id) = flow.auth else { Issue.record("key not selected"); return }
        #expect(flow.newKey?.id == id)
        #expect(try flow.endpoint().identity == .key(id: id))
    }
}
