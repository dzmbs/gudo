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

    /// Removed from its own helper's devices (`gudo devices`), this device is handed back to
    /// the app to pair again, quietly: no refusal shows, and a fresh ticket brings it back.
    @Test func removedFromItsOwnHelperItPairsAgain() async throws {
        let mine = try LocalDaemon()
        let model = makeModel()
        let id = try await model.pairThisDevice(try PairingTicket(try await mine.ticket()), name: "This Mac")
        let fresh = try PairingTicket(try await mine.ticket())
        var removals = 0
        model.onThisDeviceRemoved = { removed in
            #expect(removed == id)
            removals += 1
            Task { _ = try await model.pairThisDevice(fresh, name: "This Mac") }
            return true
        }
        let removed = try #require(model.connection(id) as? DaemonConnection)
        try mine.unpairEveryDevice()

        try await eventually("paired again", timeout: .seconds(15)) {
            (model.connection(id) as? DaemonConnection).map { $0 !== removed && $0.status.isLive } == true
        }
        #expect(removals == 1)
        if case .needsAttention = removed.status { Issue.record("the refusal showed: \(removed.status)") }
        #expect(model.thisDeviceId == id)
    }

    /// Any other host keeps refusing a removed device, in words, and never pairs it again.
    @Test func aRemovedDeviceElsewhereIsToldInWords() async throws {
        let remote = try LocalDaemon()
        let model = makeModel()
        let id = try await model.pair(try PairingTicket(try await remote.ticket()), name: "box")
        model.onThisDeviceRemoved = { _ in
            Issue.record("a remote host must not pair again on its own")
            return true
        }
        let connection = try #require(model.connection(id) as? DaemonConnection)
        try remote.unpairEveryDevice()

        try await eventually("refused", timeout: .seconds(15)) {
            if case .needsAttention = connection.status { true } else { false }
        }
        guard case .needsAttention(let reason) = connection.status else { return }
        #expect(reason == "This device isn't paired with this host anymore. Pair it again with a new ticket.")
        #expect(connection.refusal.map(DaemonConnection.meansDeviceRemoved) == true)
    }

    /// This Mac as the app reaches it at launch: its own helper with relays on, a `pair --local`
    /// ticket, the app's relay settings. Opening it again must be live over loopback in a
    /// blink, with no relay or address lookup in the way. Prints the times.
    @Test func thisMacIsLiveInABlink() async throws {
        let mine = try LocalDaemon(isThisMacHelper: true)
        let model = HostsModel(
            secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()),
            configuration: HostsModel.Configuration())
        let id = try await model.pairThisDevice(try PairingTicket(try await mine.ticket()), name: "This Mac")
        var samples: [(connected: Duration, layout: Duration)] = []
        for _ in 0..<5 {
            model.disconnect(id)
            let connection = try #require(try model.open(id) as? DaemonConnection)
            try await eventually("live", timeout: .seconds(15)) { connection.status.isLive }
            samples.append((connection.timings.connected ?? .zero, connection.timings.firstLayout ?? .zero))
        }
        func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
        let connected = median(samples.map(\.connected)), layout = median(samples.map(\.layout))
        print("this Mac: connected \(connected), layout \(layout) (median of 5; all: \(samples.map(\.layout)))")
        #expect(layout < .milliseconds(250))
    }

    /// The app dials This Mac at launch, maybe before its helper is up (a login item still
    /// starting): once the helper is up and the app retries, it is live at once, not after the
    /// dial it started too early gives up.
    @Test func thisMacIsLiveAsSoonAsItsHelperIsUp() async throws {
        let mine = try LocalDaemon(isThisMacHelper: true)
        let model = HostsModel(
            secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()),
            configuration: HostsModel.Configuration())
        let id = try await model.pairThisDevice(try PairingTicket(try await mine.ticket()), name: "This Mac")
        model.disconnect(id)
        mine.kill()
        let connection = try #require(try model.open(id) as? DaemonConnection)
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        try mine.start()
        let endpoint = mine.stateDir.appending(path: "endpoint.json")
        let before = (try? Data(contentsOf: endpoint)) ?? Data()
        try await eventually("helper up", timeout: .seconds(15)) { (try? Data(contentsOf: endpoint)).map { $0 != before } == true }
        let up = ContinuousClock.now
        connection.retry()
        try await eventually("live", timeout: .seconds(30)) { connection.status.isLive }
        let live = ContinuousClock.now - up
        print("this Mac: helper up \(up - started) after its start, live \(live) after that")
        #expect(live < .seconds(1))
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
