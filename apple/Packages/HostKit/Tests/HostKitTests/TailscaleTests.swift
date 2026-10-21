import Foundation
@testable import HostKit
import Testing

@Suite struct TailscaleTests {
    @Test(arguments: [
        ("100.64.0.0", true), ("100.64.0.1", true), ("100.101.102.103", true), ("100.127.255.255", true),
        ("100.63.255.255", false), ("100.128.0.0", false), ("10.0.0.1", false), ("192.168.1.40", false),
        ("100.64.0", false), ("100.64.0.256", false), ("1000.64.0.1", false),
    ])
    func cgnatRange(host: String, expected: Bool) {
        #expect(Tailscale.isTailnet(host: host) == expected)
    }

    @Test(arguments: [
        ("devbox.tail3f2c.ts.net", true), ("DevBox.Tail3F2C.TS.NET", true), ("devbox.tail3f2c.ts.net.", true),
        ("ts.net", false), (".ts.net", false), ("foo.ts.net.evil.com", false), ("notts.net", false),
        ("example.com", false), ("localhost", false), ("", false),
    ])
    func magicDNS(host: String, expected: Bool) {
        #expect(Tailscale.isTailnet(host: host) == expected)
    }

    @Test(arguments: [
        ("fd7a:115c:a1e0::1", true), ("[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]", true),
        ("fd7a:115c:a1e1::1", false), ("::1", false), ("fe80::1%en0", false),
    ])
    func ipv6(host: String, expected: Bool) {
        #expect(Tailscale.isTailnet(host: host) == expected)
    }

    @Test(arguments: [
        ("me@100.64.0.1", true), ("me@100.64.0.1:2222", true), ("100.100.1.1:22", true), ("ssh me@nas.tail1.ts.net", true),
        ("me@devbox.tail3f2c.ts.net:2200", true), ("me@[fd7a:115c:a1e0::5]:22", true), ("fd7a:115c:a1e0::5", true),
        ("me@100.128.0.1", false), ("me@box.internal:22", false), ("me@ts.net.example.com", false),
    ])
    func destinations(destination: String, expected: Bool) {
        #expect(Tailscale.isTailnet(destination: destination) == expected)
    }

    @Test func endpointsUseTheHostNameElseTheAlias() {
        #expect(Tailscale.isTailnet(SSHEndpoint(user: "me", host: "100.64.1.2", identity: .password)))
        #expect(Tailscale.isTailnet(SSHEndpoint(user: "me", host: "nas", alias: "nas.tail1.ts.net", identity: .password)))
        #expect(!Tailscale.isTailnet(SSHEndpoint(user: "me", host: "10.0.0.2", alias: "box", identity: .password)))
    }

    @MainActor
    @Test func importedAndSavedHostsAreTagged() throws {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        try model.loadSSHConfig("""
            Host nas
              HostName nas.tail3f2c.ts.net
              User admin
            Host pi
              HostName 100.88.1.2
            Host box
              HostName 192.168.1.40
            """)
        model.importSSHHosts(["nas", "pi", "box"])
        let tagged = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.name, $0.isTailscale) })
        #expect(tagged == ["nas": true, "pi": true, "box": false])
        // Not dialled yet: nothing failed, so no hint.
        #expect(model.entries.allSatisfy { !$0.needsTailscale })
        // A daemon host is dialled over its own link, never through the tailnet address.
        model.upsert(HostRecord(id: "d", name: "daemon", kind: .daemon, ssh: SSHEndpoint(user: "me", host: "100.64.0.9", identity: .password), daemonId: "ab"))
        #expect(model.entries.first { $0.id == "d" }?.isTailscale == false)
    }

    @MainActor
    @Test func aFailedDialToATailnetHostAsksForTailscale() {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "t", name: "tailbox", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "100.64.3.4", identity: .password)))
        model.upsert(HostRecord(id: "l", name: "lan", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "10.0.0.4", identity: .password)))
        for id in ["t", "l"] {
            let connection = SshConnection(hostId: id)
            model.connections[id] = connection
            connection.apply(.connecting(attempt: 1))
            #expect(model.entries.first { $0.id == id }?.needsTailscale == false, "dialling is not a failure yet")
            connection.apply(.reconnecting(attempt: 1, retryIn: 1, reason: "connect: no route to host"))
        }
        #expect(model.entries.first { $0.id == "t" }?.needsTailscale == true)
        #expect(model.entries.first { $0.id == "l" }?.needsTailscale == false, "only tailnet hosts get the hint")
        (model.connections["t"] as? SshConnection)?.apply(.connected(generation: 1))
        #expect(model.entries.first { $0.id == "t" }?.needsTailscale == false, "gone once it connects")
    }
}
