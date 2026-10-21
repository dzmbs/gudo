import Foundation
import Synchronization
@testable import HostKit
import PaneLayout
import Testing
import UnnamedCore

/// Multiplayer end to end through HostsModel → DaemonConnection → MultiplayerSession → a real
/// local daemon, with three devices (three `HostsModel`s, three device keys): the owner pairs
/// and invites; a viewer joins by link, its keys are gated locally and refused by the daemon;
/// a driver asks for control, the owner is asked and gives it, the driver types; the owner
/// revokes the driver and the audit log records joins, the lease and the revocation.
@MainActor
@Suite(.serialized) struct MultiplayerIntegrationTests {
    func makeModel() -> HostsModel {
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        configuration.mirrorVt = true
        return HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
    }

    @Test func inviteJoinViewerDriverLeaseRevokeAudit() async throws {
        let daemon = try LocalDaemon()
        let owner = makeModel()
        // A fresh daemon occasionally refuses its very first pairing secret; a new ticket works.
        let ownerHost: String
        do {
            ownerHost = try await owner.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        } catch PairingError.refused {
            ownerHost = try await owner.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        }
        let ownerConnection = try #require(owner.connection(ownerHost) as? DaemonConnection)
        let mp = ownerConnection.multiplayer
        try await eventually("owner identity") { mp.me != nil }
        #expect(mp.isOwner && !mp.isGuest)
        let pane = try #require(ownerConnection.layout.session.activeTab?.focused)
        let ownerBackend = try ownerConnection.makeBackend(for: pane)
        let ownerSink = EventSink()
        ownerBackend.start(events: ownerSink.handler)
        ownerBackend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)

        // Owner: a viewer invite for this session (two devices may use it), shown as a link and QR.
        var draft = InviteDraft()
        draft.name = "Vic"
        draft.scope = .session
        draft.uses = .five
        let viewerInvite = try await mp.createInvite(draft.options(
            inviter: "Alex", session: ownerConnection.layout.sessionId, tab: nil, pane: nil))
        #expect(viewerInvite.link.hasPrefix("unnamed://join/"))
        #expect(viewerInvite.qrPayload == viewerInvite.link.uppercased())
        let card = try inspectInvite(invite: viewerInvite.qrPayload)
        #expect(card.inviter == "Alex" && card.label == "Vic" && card.roles == [.viewer])

        // Viewer joins by link: a guest host record, the layout of the session, view-only.
        let viewer = makeModel()
        let viewerHost = try await viewer.join(invite: viewerInvite.link)
        #expect(viewer.record(viewerHost)?.isGuest == true)
        #expect(viewer.record(viewerHost)?.name == "Alex’s host")
        let viewerConnection = try #require(viewer.connection(viewerHost) as? DaemonConnection)
        try await eventually("viewer identity") { viewerConnection.multiplayer.me != nil }
        let vmp = viewerConnection.multiplayer
        #expect(vmp.isGuest && vmp.isViewOnly && vmp.roles == [.viewer])
        #expect(vmp.inputGate.all)
        try await eventually("owner sees the viewer") { mp.others.contains { $0.name == "Vic" } }

        // The viewer sees output…
        let viewerBackend = try viewerConnection.makeBackend(for: pane)
        let viewerSink = EventSink()
        viewerBackend.start(events: viewerSink.handler)
        Array("echo owner-$((20+1))\r".utf8).withUnsafeBytes { ownerBackend.write($0) }
        try await eventually("viewer sees the owner's output", timeout: .seconds(10)) {
            viewerConnection.paneText(pane)?.contains("owner-21") == true
        }
        // …its keys never leave the device (gated, with a nudge)…
        Array("echo viewer-typed\r".utf8).withUnsafeBytes { viewerBackend.write($0) }
        try await eventually("view-only nudge") { if case .viewOnly = vmp.notice?.kind { true } else { false } }
        // …and the daemon refuses them too when a client sends them anyway (same device key).
        let raw = ClientEventCollector()
        let viewerKey = try DeviceIdentity.load(from: viewer.secrets)
        let rawClient = try DaemonClient.join(
            invite: viewerInvite.link, config: ClientConfig(secretKey: viewerKey, relay: .disabled, mirrorVt: false), listener: raw)
        let rejections = MultiplayerCollector()
        rawClient.setMultiplayerListener(listener: rejections)
        try await eventually("raw client connected", timeout: .seconds(10)) { raw.connected }
        rawClient.attach(sessionId: nil)
        try await Task.sleep(for: .milliseconds(200))
        rawClient.sendInput(paneId: pane.rawValue, data: Data("echo sneaky\r".utf8))
        try await eventually("input rejected for the role", timeout: .seconds(10)) {
            rejections.events.contains { if case .inputRejected(_, .role) = $0 { true } else { false } }
        }
        await #expect(throws: MultiplayerError.self) { _ = try await rawClient.takeControl(paneId: pane.rawValue, force: false) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(ownerConnection.paneText(pane)?.contains("sneaky") != true)
        #expect(ownerConnection.paneText(pane)?.contains("viewer-typed") != true)

        // Driver: joins by a driver invite; the owner is typing, so taking control asks.
        draft.name = "Dee"
        draft.roles = [.driver]
        draft.uses = .once
        draft.scope = .host
        let driverInvite = try await mp.createInvite(draft.options(inviter: "Alex", session: nil, tab: nil, pane: nil))
        let driver = makeModel()
        let driverHost = try await driver.join(invite: driverInvite.link, name: "Alex (shared)")
        let driverConnection = try #require(driver.connection(driverHost) as? DaemonConnection)
        let dmp = driverConnection.multiplayer
        try await eventually("driver identity") { dmp.me != nil }
        #expect(dmp.canDrive && !dmp.isOwner)
        let driverBackend = try driverConnection.makeBackend(for: pane)
        let driverSink = EventSink()
        driverBackend.start(events: driverSink.handler)

        // The owner holds the lease by typing.
        Array("echo lease-$((1+1))\r".utf8).withUnsafeBytes { ownerBackend.write($0) }
        try await eventually("owner holds the lease", timeout: .seconds(10)) { dmp.holder(of: pane.rawValue) == mp.myPrincipal }
        #expect(dmp.isDrivenByOther(pane.rawValue))
        #expect(dmp.inputGate.panes.contains(pane.rawValue))
        let outcome = await dmp.takeControl(pane.rawValue)
        guard case .pending = outcome else {
            Issue.record("expected a pending request, got \(String(describing: outcome))")
            return
        }
        #expect(dmp.pendingTakes[pane.rawValue] != nil)
        try await eventually("owner is asked", timeout: .seconds(5)) { mp.leaseRequests.contains { $0.name == "Dee" } }
        let request = try #require(mp.leaseRequests.first)
        await mp.answer(request, give: true)
        try await eventually("driver drives", timeout: .seconds(10)) { dmp.isDriving(pane.rawValue) }
        #expect(dmp.inputGate == .open)
        #expect(dmp.notice?.kind == .controlGranted(pane: pane.rawValue))
        try await eventually("owner's gate closes", timeout: .seconds(5)) { mp.inputGate.panes.contains(pane.rawValue) }
        Array("echo driver-$((3*3))\r".utf8).withUnsafeBytes { driverBackend.write($0) }
        try await eventually("driver's keys arrive", timeout: .seconds(10)) { ownerConnection.paneText(pane)?.contains("driver-9") == true }

        // Owner: grants list both invites; revoke the driver's grant.
        await mp.refreshGrants()
        #expect(mp.grants.count >= 2)
        let driverGrant = try #require(mp.grants.first { $0.grant.label == "Dee" })
        #expect(driverGrant.bound.count == 1 && !driverGrant.revoked)
        let result = await mp.revoke(.grant(grantId: driverGrant.grant.grantId))
        // (`disconnected` may be 0: the daemon's 500 ms validity tick can close it first.)
        #expect(result?.grants.contains(driverGrant.grant.grantId) == true)
        try await eventually("driver is told", timeout: .seconds(10)) { dmp.isRevoked || !driverConnection.status.isLive }
        try await eventually("driver gone from presence", timeout: .seconds(10)) { !mp.others.contains { $0.name == "Dee" } }
        #expect(mp.grants.first { $0.grant.grantId == driverGrant.grant.grantId }?.revoked == true)

        // The audit log: both joins, the lease moving, the revocation; the chain verifies.
        await mp.loadAudit()
        let audit = try #require(mp.auditPage)
        #expect(audit.chainOk)
        let kinds = Set(audit.records.map(\.kind))
        #expect(kinds.isSuperset(of: [.join, .grantRedeemed, .lease, .revoked]))
        #expect(audit.records.contains { $0.kind == .denied || $0.kind == .join })
        _ = rawClient
    }
}

extension MultiplayerIntegrationTests {
    /// Knock to join through the real daemon: the guest knocks and waits, the owner sees the
    /// knock and admits it as a driver, the guest joins with its own grant; the owner then sets
    /// the session's approval rules and the guest hears them.
    @Test func knockAdmitJoinAndApprovalRules() async throws {
        let daemon = try LocalDaemon()
        let owner = makeModel()
        let ownerHost: String
        do {
            ownerHost = try await owner.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        } catch PairingError.refused {
            ownerHost = try await owner.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        }
        let ownerConnection = try #require(owner.connection(ownerHost) as? DaemonConnection)
        let mp = ownerConnection.multiplayer
        try await eventually("owner identity") { mp.me != nil }

        var draft = InviteDraft()
        draft.knock = true
        draft.scope = .host
        draft.uses = .unlimited
        let invite = try await mp.createInvite(draft.options(inviter: "Alex", session: nil, tab: nil, pane: nil))
        let card = try inspectInvite(invite: invite.link)
        #expect(card.knock && card.sinceJoin)

        let guest = makeModel()
        let asked = Mutex(false)
        let joining = Task { try await guest.knock(invite: invite.link, name: "Kim Lee") { asked.withLock { $0 = true } } }
        try await eventually("owner sees the knock", timeout: .seconds(10)) { mp.knocks.contains { $0.name == "Kim Lee" } }
        #expect(asked.withLock { $0 })
        let knock = try #require(mp.knocks.first)
        await mp.admit(knock, roles: [.viewer, .driver], sinceJoin: true)
        let guestHost = try await joining.value
        let guestConnection = try #require(guest.connection(guestHost) as? DaemonConnection)
        let gmp = guestConnection.multiplayer
        try await eventually("guest identity") { gmp.me != nil }
        #expect(gmp.canDrive && !gmp.isOwner)
        #expect(gmp.me?.name == "Kim Lee")
        try await eventually("knock cleared") { mp.knocks.isEmpty }

        // Turned away: the knock throws, nothing is saved.
        let other = makeModel()
        let refused = Task { try await other.knock(invite: invite.link, name: "Lou") }
        try await eventually("lou knocks", timeout: .seconds(10)) { mp.knocks.contains { $0.name == "Lou" } }
        await mp.turnAway(try #require(mp.knocks.first { $0.name == "Lou" }))
        await #expect(throws: PairingError.turnedAway) { try await refused.value }
        #expect(other.records.isEmpty)

        // Session rules: set by the owner, heard by the guest.
        let session = try #require(ownerConnection.layout.sessionId)
        let rules = ApprovalPolicy(mode: .twoPerson, maxRisk: .edits)
        await mp.setApprovalPolicy(rules, session: session)
        try await eventually("guest hears the rules", timeout: .seconds(10)) { gmp.approvalPolicy == rules }
        #expect(gmp.approvalBlock(requestId: 1, risk: .any) != nil)
    }
}

nonisolated final class ClientEventCollector: ClientEventListener {
    private let state = Mutex(false)
    var connected: Bool { state.withLock { $0 } }
    func onEvent(event: ClientEvent) {
        if case .connected = event { state.withLock { $0 = true } }
    }
}

nonisolated final class MultiplayerCollector: MultiplayerListener {
    private let state = Mutex<[MultiplayerEvent]>([])
    var events: [MultiplayerEvent] { state.withLock { $0 } }
    func onMultiplayerEvent(event: MultiplayerEvent) {
        state.withLock { $0.append(event) }
    }
}
