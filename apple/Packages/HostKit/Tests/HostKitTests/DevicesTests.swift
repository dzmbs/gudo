import Foundation
@testable import HostKit
import Testing
import GudoCore

private let me = Actor(principal: "aa", device: String(repeating: "a", count: 64))
private let now = UInt64(Date.now.timeIntervalSince1970 * 1000)
private let day: UInt64 = 86_400_000

private func device(_ key: Character, _ name: String, kind: DeviceKind = .owner, ago: UInt64, connected: UInt32 = 0, revoked: Bool = false) -> DeviceInfo {
    DeviceInfo(device: String(repeating: key, count: 64), principal: kind == .owner ? "aa" : String(key), kind: kind, name: name,
               firstSeenMs: now - ago, grantId: kind == .guest ? "g" : nil, revoked: revoked, connected: connected)
}

private let thisIPad = DeviceInfo(device: me.device, principal: "aa", kind: .owner, name: "Mira’s iPad", firstSeenMs: now - 40 * day,
                                  grantId: nil, revoked: false, connected: 1)

@MainActor
private func ownerSession(_ devices: [DeviceInfo], client: FakeMultiplayerClient = FakeMultiplayerClient()) -> MultiplayerSession {
    client.state.withLock { $0.devices = devices }
    let session = MultiplayerSession()
    session.attach(client)
    session.apply(.joined(info: JoinInfo(actor: me, name: "Mira’s iPad", roles: [.owner], scope: .daemon, grantId: nil, expiresMs: nil)))
    session.seed(devices: devices)
    return session
}

@MainActor
private func settle(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestError("condition not met") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite struct DevicesTests {
    @Test func aNewPairingIsNamedAnnouncedAndListedFirst() async throws {
        let mac = device("b", "Studio Mac", ago: 10 * day)
        let iphone = device("c", "Mira’s iPhone", ago: 0)
        let client = FakeMultiplayerClient()
        let session = ownerSession([thisIPad, mac], client: client)
        var announced: [DeviceInfo] = []
        session.onDevicePaired = { announced.append($0) }
        // The host's list includes the new device by the time the app asks again.
        client.state.withLock { $0.devices = [thisIPad, mac, iphone] }

        session.apply(.devicePaired(device: iphone))

        #expect(announced.map(\.device) == [iphone.device])
        #expect(session.notice?.message.hasPrefix("Mira’s iPhone paired with this host") == true)
        #expect(session.ownerDevices.map(\.device) == [iphone.device, thisIPad.device, mac.device])
        try await settle { session.devices.count == 3 }
        #expect(session.freshPairings[iphone.device] != nil, "a refresh keeps the highlight")
        #expect(session.ownerDevices.first?.device == iphone.device)
    }

    @Test func thisDevicesOwnPairingIsNotAnnounced() {
        let session = ownerSession([thisIPad])
        var announced = 0
        session.onDevicePaired = { _ in announced += 1 }
        session.apply(.devicePaired(device: thisIPad))
        #expect(announced == 0)
        #expect(session.notice == nil)
        #expect(session.freshPairings.isEmpty)
    }

    @Test func unnamedDevicesFallBackToWhatTheyAre() {
        let session = ownerSession([])
        #expect(session.displayName(of: device("b", "owner", ago: 0)) == "Unnamed device")
        #expect(session.displayName(of: device("b", "  ", ago: 0)) == "Unnamed device")
        #expect(session.displayName(of: device("e", "", kind: .guest, ago: 0)) == "Guest")
        #expect(session.displayName(of: device("b", "Studio Mac", ago: 0)) == "Studio Mac")
        // A connected device that said what it is.
        let phone = Actor(principal: "aa", device: String(repeating: "b", count: 64))
        session.apply(.peers(you: 1, peers: [
            Peer(peer: 2, rev: 1, actor: phone, name: "owner", roles: [.owner], device: .phone, sinceMs: 1, state: .active,
                 focus: nil, viewport: nil, typing: nil, draft: nil, following: nil),
        ]))
        #expect(session.displayName(of: device("b", "owner", ago: 0)) == "iPhone")
    }

    @Test func listsPutThisDeviceFirstAndRemovedOnesLast() {
        let old = device("b", "Old Mac", ago: 90 * day, revoked: true)
        let laptop = device("c", "Laptop", ago: 5 * day)
        let ipad = device("d", "Spare iPad", ago: 50 * day)
        let idleGuest = device("e", "Kim", kind: .guest, ago: 1 * day)
        let liveGuest = device("f", "Mira", kind: .guest, ago: 3 * day, connected: 1)
        let goneGuest = device("1", "Jon", kind: .guest, ago: 0, revoked: true)
        let session = ownerSession([old, ipad, idleGuest, thisIPad, goneGuest, laptop, liveGuest])
        #expect(session.ownerDevices.map(\.name) == ["Mira’s iPad", "Laptop", "Spare iPad", "Old Mac"])
        #expect(session.guestDevices.map(\.name) == ["Mira", "Kim", "Jon"])
    }

    @Test func removingUnpairsThatDeviceAndNeverThisOne() async {
        let laptop = device("c", "Laptop", ago: 5 * day)
        let gone = device("b", "Old Mac", ago: 90 * day, revoked: true)
        let client = FakeMultiplayerClient()
        let session = ownerSession([thisIPad, laptop, gone], client: client)
        session.apply(.devicePaired(device: laptop))

        #expect(!session.canRemove(thisIPad))
        #expect(await session.removeDevice(thisIPad) == nil)
        #expect(await session.removeDevice(gone) == nil)
        #expect(client.state.withLock { $0.revoked }.isEmpty, "the daemon is not asked to unpair this device or a removed one")

        #expect(await session.removeDevice(laptop) != nil)
        #expect(client.state.withLock { $0.revoked } == [.device(device: laptop.device)])
        #expect(session.freshPairings[laptop.device] == nil)
    }

    @Test func ownerDevicesPairAnotherDeviceAndExpectIt() async throws {
        let client = FakeMultiplayerClient()
        let session = ownerSession([thisIPad], client: client)
        #expect(!session.canManageDevices, "an older host can't make codes")
        client.state.withLock { $0.managesDevices = true }
        #expect(session.canManageDevices)

        let code = try #require(await session.makePairingCode())
        #expect(code.link == "gudo://pair/code1" && code.qrPayload == "GUDO://PAIR/CODE1")
        #expect(session.pairingCodeExpiry.map { $0 > .now } == true)

        let phone = device("c", "iPhone", ago: 0)
        session.apply(.devicePaired(device: phone))
        #expect(session.notice?.message == "iPhone paired with this host.", "a pairing made from here is expected")
    }

    @Test func guestsNeverPairOrRename() async {
        let client = FakeMultiplayerClient()
        client.state.withLock { $0.managesDevices = true }
        let session = MultiplayerSession()
        session.attach(client)
        session.apply(.joined(info: JoinInfo(actor: me, name: "Kim", roles: [.owner, .driver], scope: .daemon, grantId: "g1", expiresMs: nil)))
        #expect(!session.canManageDevices)
        #expect(!session.canRename(device("b", "Studio Mac", ago: 0)))
    }

    @Test func renamingAsksTheHostAndRefreshes() async throws {
        let mac = device("b", "Studio Mac", ago: 10 * day)
        let guest = device("e", "Kim", kind: .guest, ago: 1 * day)
        let client = FakeMultiplayerClient()
        client.state.withLock { $0.managesDevices = true }
        let session = ownerSession([thisIPad, mac, guest], client: client)

        #expect(session.canRename(mac) && !session.canRename(guest))
        #expect(await session.renameDevice(mac, to: "  Desk Mac "))
        #expect(client.state.withLock { $0.renamed.map(\.1) } == ["Desk Mac"])
        try await settle { session.devices.contains { $0.name == "Desk Mac" } }
        #expect(await session.renameDevice(guest, to: "x") == false)
    }

    @Test func aStandingHostAlertIsAnnouncedOncePerRun() {
        let session = ownerSession([thisIPad])
        var pushes = 0
        session.onHostAlert = { _ in pushes += 1 }
        let alert = HostAlert(kind: .grantStoreReset, atMs: 1_000, title: "Earlier invites stopped working", body: "Send new invites.")

        session.apply(.hostAlert(alert: alert))
        let first = session.notice
        session.apply(.joined(info: JoinInfo(actor: me, name: "Mira’s iPad", roles: [.owner], scope: .daemon, grantId: nil, expiresMs: nil)))
        session.apply(.hostAlert(alert: alert))

        #expect(first?.message == "Earlier invites stopped working")
        #expect(session.notice == first, "a reconnect does not toast again")
        #expect(session.hostAlerts.count == 1)
        #expect(pushes == 2, "the app's ledger decides about notifications")

        session.apply(.hostAlert(alert: HostAlert(kind: .grantStoreReset, atMs: 2_000, title: "Again", body: "")))
        #expect(session.hostAlerts.map(\.atMs) == [2_000, 1_000])
        #expect(session.notice?.message == "Again")
    }
}
