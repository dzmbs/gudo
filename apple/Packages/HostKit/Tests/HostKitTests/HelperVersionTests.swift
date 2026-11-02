import Foundation
@testable import HostKit
import Testing
import GudoCore

nonisolated func daemonInfo(
    build: String = "aaa", builtUnix: UInt64 = 100, protocol level: UInt32 = 1, minClient: UInt32 = 0,
    selfUpgrade: Bool = true, hostname: String = "build-server-01.example.com", os: String = "linux",
    arch: String = "x86_64", agentUsage: Bool = false
) -> DaemonInfo {
    DaemonInfo(
        version: "0.0.0", build: build, builtUnix: builtUnix, protocol: level, minClientProtocol: minClient,
        selfUpgrade: selfUpgrade, hostname: hostname, os: os, osName: "Ubuntu 24.04.1 LTS", arch: arch,
        agentUsage: agentUsage)
}

nonisolated let bundled = BundledDaemons(
    builds: [
        BundledDaemon(file: "gudo-hostd-x86_64-linux.gz", os: "linux", arch: "x86_64", build: "bbb", builtUnix: 200, protocol: 1),
        BundledDaemon(file: "gudo-hostd-aarch64-linux.gz", os: "linux", arch: "aarch64", build: "bbb", builtUnix: 200, protocol: 1),
    ],
    directory: URL(fileURLWithPath: "/app/Resources"))

@Suite struct HelperCheckTests {
    func assess(
        _ info: DaemonInfo?, reported: Bool = true, incompatible: String? = nil, bundled: BundledDaemons? = bundled,
        canSSH: Bool = false, isGuest: Bool = false
    ) -> HelperAdvice? {
        HelperCheck.assess(
            info: info, reported: reported, incompatible: incompatible, bundled: bundled, canSSH: canSSH,
            isGuest: isGuest, appProtocol: 1, minDaemonProtocol: 0)
    }

    @Test func anOlderBuildIsOfferedQuietlyOverTheConnection() throws {
        let advice = try #require(assess(daemonInfo()))
        #expect(advice.kind == .update)
        #expect(advice.method == .connection)
        #expect(advice.bundled?.build == "bbb")
        #expect(advice.canUpdate)
        #expect(advice.message == "A newer helper is available.")
        // The CPU picks the build.
        #expect(assess(daemonInfo(arch: "aarch64"))?.bundled?.file == "gudo-hostd-aarch64-linux.gz")
        // An older protocol level is older whatever the dates.
        #expect(assess(daemonInfo(builtUnix: 999, protocol: 0))?.kind == .update)
    }

    @Test func sshWinsWhenTheHostWasSetUpFromSSH() {
        #expect(assess(daemonInfo(), canSSH: true)?.method == .ssh)
        // A helper that cannot replace itself is updated over SSH, or not offered at all.
        #expect(assess(daemonInfo(selfUpgrade: false), canSSH: true)?.method == .ssh)
        #expect(assess(daemonInfo(selfUpgrade: false)) == nil)
    }

    @Test func currentNewerAndUnbundledBuildsAreLeftAlone() {
        #expect(assess(daemonInfo(build: "bbb", builtUnix: 200)) == nil)
        #expect(assess(daemonInfo(build: "ccc", builtUnix: 300)) == nil)
        #expect(assess(daemonInfo(protocol: 2)) == nil)
        // Same source date, different build: not provably older.
        #expect(assess(daemonInfo(build: "ccc", builtUnix: 200)) == nil)
        // No build for that platform (a Mac host), or none bundled at all.
        #expect(assess(daemonInfo(os: "macos", arch: "aarch64")) == nil)
        #expect(assess(daemonInfo(), bundled: nil) == nil)
        // Developer builds report 0 and are older than any release build.
        #expect(assess(daemonInfo(build: "dev", builtUnix: 0))?.kind == .update)
    }

    @Test func guestsAndUnconnectedHostsGetNothing() {
        #expect(assess(daemonInfo(), isGuest: true) == nil)
        #expect(assess(nil, reported: false) == nil)
        #expect(assess(nil, reported: false, canSSH: true) == nil)
    }

    @Test func helpersFromBeforeVersionReportingNeedSSH() {
        let advice = assess(nil, canSSH: true)
        #expect(advice?.kind == .update)
        #expect(advice?.method == .ssh)
        #expect(assess(nil) == nil)
    }

    @Test func incompatibleHelpersAreSaidPlainly() throws {
        let reason = "the host's helper draws terminals in a format this app does not read"
        let overConnection = try #require(assess(daemonInfo(), incompatible: reason))
        #expect(overConnection.kind == .required)
        #expect(overConnection.method == .connection)
        #expect(overConnection.message.contains("too old for this app"))
        // An old helper that refuses outright (no info) is updated over SSH, or explained.
        #expect(assess(nil, incompatible: reason, canSSH: true)?.method == .ssh)
        let stuck = try #require(assess(nil, incompatible: reason))
        #expect(stuck.kind == .required)
        #expect(!stuck.canUpdate)
        #expect(stuck.message.contains("over SSH"))
    }

    @Test func aHelperNewerThanTheAppAsksForAnAppUpdate() throws {
        let advice = try #require(assess(daemonInfo(protocol: 3, minClient: 2)))
        #expect(advice.kind == .appTooOld)
        #expect(!advice.canUpdate)
        #expect(assess(daemonInfo(protocol: 3), incompatible: "format")?.kind == .appTooOld)
    }

    @Test func manifestLoadsFromTheBundle() throws {
        let directory = temporaryDirectory()
        let json = """
            {
              "builds": [
                {"file": "gudo-hostd-x86_64-linux.gz", "os": "linux", "arch": "x86_64", "build": "3f2a9c1d7e4b", "built_unix": 1792000000, "protocol": 1, "size": 19000000}
              ]
            }
            """
        try json.write(to: directory.appending(path: "hostd-manifest.json"), atomically: true, encoding: .utf8)
        let loaded = try #require(BundledDaemons.load(manifest: directory.appending(path: "hostd-manifest.json")))
        let build = try #require(loaded.build(os: "linux", arch: "x86_64"))
        #expect(build.build == "3f2a9c1d7e4b")
        #expect(build.builtUnix == 1_792_000_000)
        #expect(loaded.path(of: build).hasSuffix("/gudo-hostd-x86_64-linux.gz"))
        #expect(BundledDaemons.load(manifest: directory.appending(path: "missing.json")) == nil)
    }
}

@Suite struct MachineNameTests {
    @Test func theDomainIsDropped() {
        #expect(MachineName.display("build-server-01") == "build-server-01")
        #expect(MachineName.display("build-server-01.example.com") == "build-server-01")
        #expect(MachineName.display("studio-MacBook-Pro.local\n") == "studio-MacBook-Pro")
        #expect(MachineName.display("") == nil)
        #expect(MachineName.display("localhost") == nil)
        #expect(MachineName.display("localhost.localdomain") == nil)
        #expect(MachineName.display("10.0.0.7") == "10.0.0.7")
    }

    @Test func placeholdersAreRecognized() {
        #expect(MachineName.looksDefault(HostRecord(name: "Host 1a2b3c4d", kind: .daemon, daemonId: "1a2b3c4d5e6f")))
        #expect(MachineName.looksDefault(HostRecord(name: "test daemon", kind: .daemon, daemonId: "ff")))
        #expect(MachineName.looksDefault(HostRecord(name: "test daemon 2", kind: .daemon, daemonId: "ff")))
        let typed = SSHEndpoint(user: "root", host: "203.0.113.4", identity: .password)
        #expect(MachineName.looksDefault(HostRecord(name: "203.0.113.4", kind: .daemon, ssh: typed, daemonId: "ff")))
        #expect(!MachineName.looksDefault(HostRecord(name: "prod", kind: .daemon, ssh: typed, daemonId: "ff")))
        #expect(!MachineName.looksDefault(HostRecord(name: "Host 99999999", kind: .daemon, daemonId: "1a2b3c4d")))
        var alias = typed
        alias.alias = "203.0.113.4"
        #expect(!MachineName.looksDefault(HostRecord(name: "203.0.113.4", kind: .ssh, ssh: alias)))
    }
}

@MainActor
@Suite struct HostNamingTests {
    func model(_ records: [HostRecord] = []) -> (HostsModel, URL) {
        let directory = temporaryDirectory()
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: directory))
        for record in records { model.upsert(record) }
        return (model, directory)
    }

    func connect(_ model: HostsModel, _ id: String) throws -> (DaemonConnection, FakeClient) {
        nonisolated(unsafe) var fake: FakeClient?
        let connection = DaemonConnection(hostId: id, ticket: "t") { _, listener in
            let client = FakeClient(listener: listener)
            fake = client
            return client
        }
        connection.onDaemonInfo = { [weak model] info in model?.daemonReported(id, info) }
        try connection.connect()
        model.connections[id] = connection
        return (connection, try #require(fake))
    }

    @Test func newHostsAreNamedAfterTheMachineOnce() async throws {
        var record = HostRecord(id: "h", name: "Host 1a2b3c4d", kind: .daemon, daemonId: "1a2b3c4d5e6f")
        record.nameSource = .placeholder
        let (model, directory) = model([record])
        let (connection, _) = try connect(model, "h")
        connection.handle(.daemonInfo(info: daemonInfo()))
        #expect(model.record("h")?.name == "build-server-01")
        #expect(model.record("h")?.nameSource == .machine)
        #expect(model.record("h")?.machine?.osName == "Ubuntu 24.04.1 LTS")
        #expect(model.entries.first?.machine == "Ubuntu 24.04.1 LTS · x86_64")
        // Once: a later host name change does not rename it again.
        connection.handle(.daemonInfo(info: daemonInfo(hostname: "renamed-box")))
        #expect(model.record("h")?.name == "build-server-01")
        #expect(model.record("h")?.machine?.hostname == "renamed-box")
        // The user's name always wins, and stays.
        model.rename("h", to: "prod")
        connection.handle(.daemonInfo(info: daemonInfo(hostname: "other")))
        #expect(model.record("h")?.name == "prod")
        let reloaded = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: directory))
        #expect(reloaded.record("h")?.nameSource == .user)
    }

    @Test func existingHostsNamedByDefaultAreRenamedOnceAndCustomNamesStay() throws {
        // Records from before names were tracked (no nameSource).
        let (model, _) = model([
            HostRecord(id: "t", name: "test daemon", kind: .daemon, daemonId: "aa"),
            HostRecord(id: "c", name: "my box", kind: .daemon, daemonId: "bb"),
        ])
        let (t, _) = try connect(model, "t")
        let (c, _) = try connect(model, "c")
        t.handle(.daemonInfo(info: daemonInfo()))
        c.handle(.daemonInfo(info: daemonInfo()))
        #expect(model.record("t")?.name == "build-server-01")
        #expect(model.record("c")?.name == "my box")
        #expect(model.record("c")?.nameSource == .user)
    }

    @Test func nothingUsefulKeepsThePlaceholder() throws {
        var record = HostRecord(id: "h", name: "Host 1a2b3c4d", kind: .daemon, daemonId: "1a2b3c4d")
        record.nameSource = .placeholder
        let (model, _) = model([record])
        let (connection, _) = try connect(model, "h")
        connection.handle(.daemonInfo(info: nil))
        connection.handle(.daemonInfo(info: daemonInfo(hostname: "")))
        connection.handle(.daemonInfo(info: daemonInfo(hostname: "localhost")))
        #expect(model.record("h")?.name == "Host 1a2b3c4d")
        #expect(model.record("h")?.nameSource == .placeholder)
    }

    @Test func helperAdviceFollowsTheConnection() throws {
        var configuration = HostsModel.Configuration()
        configuration.bundledDaemons = { bundled }
        let model = HostsModel(
            secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()),
            configuration: configuration)
        model.upsert(HostRecord(id: "h", name: "h", kind: .daemon, daemonId: "aa"))
        #expect(model.helperAdvice("h") == nil)
        let (connection, _) = try connect(model, "h")
        #expect(model.helperAdvice("h") == nil)
        connection.handle(.daemonInfo(info: daemonInfo()))
        #expect(model.entries.first?.helper?.kind == .update)
        #expect(model.entries.first?.helper?.method == .connection)

        // An incompatible daemon: plain words in the status, the update required.
        connection.handle(.incompatible(reason: "format"))
        #expect(connection.status == .needsAttention(reason: "This host's helper needs an update"))
        #expect(model.entries.first?.helper?.kind == .required)
        connection.handle(.refused(reason: "SnapshotFormat { daemon: 9 }"))
        #expect(connection.status == .needsAttention(reason: "This host's helper needs an update"))
        connection.handle(.connected(epoch: 2, resumed: false))
        #expect(connection.incompatibility == nil)
        #expect(connection.epoch == 2)
    }

    @Test func pairingAndSSHHostsRecordWhereTheirNameCameFrom() throws {
        let (model, _) = model()
        let endpoint = SSHEndpoint(user: "me", host: "127.0.0.1", port: 1, identity: .password)
        _ = try? model.connectSSH(endpoint, password: "pw", rememberPassword: true)
        #expect(model.records.first?.nameSource == .placeholder)
        let named = SSHEndpoint(user: "me", host: "127.0.0.2", port: 1, identity: .password)
        _ = try? model.connectSSH(named, name: "staging", password: "pw", rememberPassword: true)
        #expect(model.records.first { $0.name == "staging" }?.nameSource == .user)
    }
}
