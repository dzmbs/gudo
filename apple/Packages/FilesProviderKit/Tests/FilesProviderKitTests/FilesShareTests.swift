import FileProvider
import Foundation
@testable import FilesProviderKit
import HostKit
import Testing
import GudoCore

@Suite struct FilesShareTests {
    @Test func sharesOwnerDaemonHostsTheirTicketsTheKeyAndRelaySettings() throws {
        let app = MemorySecretStore()
        let share = FilesShare(directory: temporaryDirectory(), secrets: MemorySecretStore())
        let daemon = HostRecord(id: "d1", name: "studio", kind: .daemon, daemonId: "aa")
        var guest = HostRecord(id: "g1", name: "alex's", kind: .daemon, daemonId: "bb")
        guest.guest = true
        let ssh = HostRecord(id: "s1", name: "box", kind: .ssh)
        let unpaired = HostRecord(id: "d2", name: "no ticket", kind: .daemon)
        try app.set("ticket-1", for: daemon.ticketKey)
        try app.set("invite", for: guest.inviteKey)
        var relay = RelaySettings()
        relay.mode = .directOnly

        let shared = try share.publish(hosts: [daemon, guest, ssh, unpaired], appSecrets: app, relay: relay)
        #expect(shared.map(\.id) == ["d1"])
        #expect(share.hosts().map(\.id) == ["d1"])
        #expect(try share.secrets.string(for: daemon.ticketKey) == "ticket-1")
        #expect(try share.secrets.data(for: "device-key") == DeviceIdentity.load(from: app))
        #expect(RelaySettings.load(directory: share.directory, secrets: share.secrets).mode == .directOnly)

        // A host removed in the app leaves Files and takes its ticket and identifiers along.
        _ = share.identifiers(for: "d1").identifier(for: "/x")
        try share.publish(hosts: [], appSecrets: app, relay: relay)
        #expect(share.hosts().isEmpty)
        #expect(try share.secrets.string(for: daemon.ticketKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: share.hostDirectory("d1").path))
        #expect(throws: FilesShareError.notShared("d1")) {
            try share.connect(hostId: "d1", listener: NoEvents())
        }
    }

    @Test func domainsFollowTheSharedHosts() {
        let hosts = [HostRecord(id: "a", name: "studio", kind: .daemon), HostRecord(id: "b", name: "build box", kind: .daemon)]
        let plan = DomainPlan.plan(
            existing: [.init(id: "a", name: "studio"), .init(id: "b", name: "old name"), .init(id: "c", name: "gone")], hosts: hosts)
        #expect(plan.add == [.init(id: "b", name: "build box")])
        #expect(plan.remove == ["c"])
        #expect(DomainPlan.plan(existing: [], hosts: hosts).add.map(\.id) == ["a", "b"])
    }

    @Test func noShareWithoutTheGroups() {
        #expect(FilesShare.shared(bundle: .main, service: "test") == nil)
    }
}

nonisolated final class NoEvents: ClientEventListener {
    func onEvent(event: ClientEvent) {}
}
