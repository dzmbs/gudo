import Foundation
@testable import HostKit
import PaneLayout
import Testing
import GudoCore

/// The app's own helper on this device: paired like any daemon, marked as this device, listed
/// first, never offered a helper update, and replaced (not duplicated) when its folder is reset.
@MainActor
@Suite(.serialized) struct ThisDeviceTests {
    private func makeModel(_ directory: URL = temporaryDirectory()) -> HostsModel {
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        return HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: directory), configuration: configuration)
    }

    @Test func pairsAsThisDeviceAndLeadsTheGroups() async throws {
        let remote = try LocalDaemon()
        let mine = try LocalDaemon()
        let directory = temporaryDirectory()
        let model = makeModel(directory)
        let other = try await model.pair(try PairingTicket(try await remote.ticket()), name: "box")
        let id = try await model.pairThisDevice(try PairingTicket(try await mine.ticket()), name: "This Mac")

        #expect(model.thisDeviceId == id)
        #expect(model.record(id)?.name == "This Mac")
        #expect(model.record(id)?.nameSource == .user)
        #expect(model.record(other)?.isThisDevice == false)
        #expect(model.entries.first { $0.id == id }?.isThisDevice == true)
        #expect(model.helperAdvice(id) == nil)
        // Kept across launches.
        #expect(HostRepository(directory: directory).load().first { $0.id == id }?.isThisDevice == true)

        let groups = HostGroups(hosts: model)
        try groups.open(other)
        try groups.open(id)
        #expect(groups.groups.map(\.id) == [id, other])
    }

    @Test func aNewHelperReplacesTheOldOne() async throws {
        let first = try LocalDaemon()
        let model = makeModel()
        let old = try await model.pairThisDevice(try PairingTicket(try await first.ticket()), name: "This Mac")
        let reset = try LocalDaemon()
        let new = try await model.pairThisDevice(try PairingTicket(try await reset.ticket()), name: "This Mac")
        #expect(new != old)
        #expect(model.record(old) == nil)
        #expect(model.records.filter(\.isThisDevice).map(\.id) == [new])
    }

    @Test func anEmptyLocalGroupGivesWayToTheHelper() {
        let model = makeModel()
        let layout = LocalLayoutStore(session: Session(tabs: [], activeTabId: nil))
        let groups = HostGroups(hosts: model, local: .init(name: "This Mac", layout: layout))
        #expect(groups.groups.map(\.id) == [HostGroups.localId])
        groups.helperServesLocal = { true }
        #expect(groups.groups.isEmpty)
        // Plain shells still open stay listed until closed.
        layout.apply(.newTab)
        #expect(groups.groups.map(\.id) == [HostGroups.localId])
    }
}
