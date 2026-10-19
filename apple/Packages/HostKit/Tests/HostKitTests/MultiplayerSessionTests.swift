import Foundation
@testable import HostKit
import Synchronization
import Testing
import UnnamedCore

/// A daemon's multiplayer side, scripted.
nonisolated final class FakeMultiplayerClient: MultiplayerClientAPI {
    struct State {
        var listener: (any MultiplayerListener)?
        var typing: [(UInt64, Bool)] = []
        var invites: [InviteOptions] = []
        var takes: [(UInt64, Bool)] = []
        var answers: [(UInt64, Bool)] = []
        var prompts: [(UInt64, String)] = []
        var revoked: [RevokeTarget] = []
        var takeOutcome: LeaseOutcome = .granted(lease: Lease(paneId: 1, holder: "aa", sinceMs: 0, mode: .leased))
        var promptError: MultiplayerError?
    }
    let state = Mutex(State())

    func push(_ event: MultiplayerEvent) {
        state.withLock { $0.listener }?.onMultiplayerEvent(event: event)
    }

    func setMultiplayerListener(listener: any MultiplayerListener) { state.withLock { $0.listener = listener } }
    func me() -> JoinInfo? { nil }
    func participantList() -> [UnnamedCore.Participant] { [] }
    func lease(paneId: UInt64) -> Lease? { nil }
    func setTyping(paneId: UInt64, typing: Bool) { state.withLock { $0.typing.append((paneId, typing)) } }
    func participants() async throws -> [UnnamedCore.Participant] { [] }
    func setName(name: String) async throws {}
    func createInvite(options: InviteOptions) async throws -> CreatedInvite {
        state.withLock { $0.invites.append(options) }
        let link = "unnamed://join/abc\(options.label.lowercased())"
        return CreatedInvite(link: link, qrPayload: link.uppercased(), grantId: String(repeating: "ab", count: 16), expiresMs: options.ttlSecs.map { $0 * 1000 })
    }
    func listGrants() async throws -> [GrantInfo] { [] }
    func listDevices() async throws -> [DeviceInfo] { [] }
    func revoke(target: RevokeTarget) async throws -> RevokeResult {
        state.withLock { $0.revoked.append(target) }
        return RevokeResult(grants: [], devices: [], disconnected: 1)
    }
    func takeControl(paneId: UInt64, force: Bool) async throws -> LeaseOutcome {
        state.withLock { $0.takes.append((paneId, force)); return $0.takeOutcome }
    }
    func releaseControl(paneId: UInt64) async throws {}
    func answerControl(paneId: UInt64, give: Bool) async throws -> LeaseOutcome {
        state.withLock { $0.answers.append((paneId, give)) }
        return .granted(lease: Lease(paneId: paneId, holder: nil, sinceMs: 0, mode: .free))
    }
    func giveControl(paneId: UInt64, to: String) async throws -> LeaseOutcome { .granted(lease: Lease(paneId: paneId, holder: to, sinceMs: 0, mode: .leased)) }
    func leases() async throws -> [Lease] { [] }
    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32 {
        if let error = state.withLock({ $0.promptError }) { throw error }
        state.withLock { $0.prompts.append((paneId, text)) }
        return UInt32(text.count)
    }
    func audit(after: UInt64?, limit: UInt32) async throws -> AuditPage { AuditPage(records: [], total: 0, chainOk: true) }
}

private let ownerActor = Actor(principal: "aa", device: String(repeating: "a", count: 64))
private let guestActor = Actor(principal: "bb", device: String(repeating: "b", count: 64))

private func info(_ actor: Actor, _ name: String, _ roles: [Role], grant: String? = nil) -> JoinInfo {
    JoinInfo(actor: actor, name: name, roles: roles, scope: .daemon, grantId: grant, expiresMs: nil)
}

private func person(_ actor: Actor, _ name: String, _ roles: [Role], focus: UInt64? = nil, typing: Bool = false) -> UnnamedCore.Participant {
    UnnamedCore.Participant(actor: actor, name: name, roles: roles, scope: .daemon, grantId: nil, sinceMs: 1, state: .active, focus: focus, typing: typing, cursor: nil)
}

/// Waits for the session's event pump (events hop to the main actor in order).
@MainActor
private func settle(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestError("condition not met") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite struct MultiplayerSessionTests {
    @Test func rolesDecideTheGateAndTheComposer() {
        let session = MultiplayerSession()
        #expect(session.inputGate == .open)

        session.apply(.joined(info: info(guestActor, "Mira", [.viewer], grant: "g1")))
        #expect(session.isGuest && session.isViewOnly && !session.canPrompt)
        #expect(session.inputGate == .init(all: true, panes: []))

        session.apply(.joined(info: info(guestActor, "Mira", [.prompter], grant: "g1")))
        #expect(session.canPrompt && !session.canDrive && !session.isViewOnly)
        #expect(session.inputGate.all)

        session.apply(.joined(info: info(guestActor, "Mira", [.driver, .approver], grant: "g1")))
        #expect(session.canDrive && session.canApprove)
        #expect(session.inputGate == .open)
        #expect(roleWords([.viewer, .driver, .approver]) == "Approver + Driver")
        #expect(roleWords([.viewer]) == "Viewer")
        #expect(roleWords([.owner, .viewer]) == "Owner")
    }

    @Test func leaseHeldByAnotherConnectedPersonClosesThatPane() {
        let session = MultiplayerSession()
        var gates: [MultiplayerSession.InputGate] = []
        session.onInputGate = { gates.append($0) }
        session.apply(.joined(info: info(ownerActor, "Alex", [.owner])))
        session.apply(.participants(participants: [person(ownerActor, "Alex", [.owner]), person(guestActor, "Mira", [.driver], focus: 4)]))
        session.apply(.lease(lease: Lease(paneId: 4, holder: "bb", sinceMs: 0, mode: .leased)))
        #expect(session.isDrivenByOther(4))
        #expect(session.holderName(4) == "Mira")
        #expect(session.inputGate == .init(all: false, panes: [4]))
        #expect(gates.last == .init(all: false, panes: [4]))
        #expect(session.people(in: 4).map(\.name) == ["Mira"])

        // Mira leaves: her lease no longer blocks.
        session.apply(.participants(participants: [person(ownerActor, "Alex", [.owner])]))
        #expect(!session.isDrivenByOther(4))
        #expect(session.inputGate == .open)
    }

    @Test func presenceUpdatesTypingAndFocus() {
        let session = MultiplayerSession()
        session.apply(.joined(info: info(ownerActor, "Alex", [.owner])))
        session.apply(.participants(participants: [person(ownerActor, "Alex", [.owner]), person(guestActor, "Mira", [.prompter], focus: 1)]))
        session.apply(.presence(presence: Presence(actor: guestActor, state: .active, focus: 2, typing: true, cursor: nil)))
        #expect(session.others.first?.typing == true)
        #expect(session.people(in: 2).count == 1)
        #expect(session.people(in: 1).isEmpty)
    }

    @Test func takeControlPendingThenGrantedPostsANotice() async throws {
        let fake = FakeMultiplayerClient()
        fake.state.withLock { $0.takeOutcome = .pending(holder: "aa") }
        let session = MultiplayerSession()
        session.attach(fake)
        fake.push(.joined(info: info(guestActor, "Mira", [.driver], grant: "g1")))
        fake.push(.participants(participants: [person(ownerActor, "Alex", [.owner]), person(guestActor, "Mira", [.driver])]))
        fake.push(.lease(lease: Lease(paneId: 1, holder: "aa", sinceMs: 0, mode: .leased)))
        try await settle { session.leases[1] != nil }
        #expect(session.inputGate.panes == [1])

        let outcome = await session.takeControl(1)
        #expect(outcome == .pending(holder: "aa"))
        #expect(session.pendingTakes[1]?.holder == "aa")

        // Alex gives it.
        fake.push(.lease(lease: Lease(paneId: 1, holder: "bb", sinceMs: 1, mode: .leased)))
        try await settle { session.pendingTakes[1] == nil }
        #expect(session.isDriving(1))
        #expect(session.notice?.kind == .controlGranted(pane: 1))
        #expect(session.inputGate == .open)
    }

    @Test func holderAnswersARequest() async throws {
        let fake = FakeMultiplayerClient()
        let session = MultiplayerSession()
        session.attach(fake)
        fake.push(.joined(info: info(ownerActor, "Alex", [.owner])))
        fake.push(.participants(participants: [person(ownerActor, "Alex", [.owner]), person(guestActor, "Mira", [.driver])]))
        fake.push(.leaseRequested(paneId: 3, by: guestActor, name: "Mira"))
        try await settle { !session.leaseRequests.isEmpty }
        let request = try #require(session.leaseRequests.first)
        #expect(request.name == "Mira")
        await session.answer(request, give: false)
        #expect(session.leaseRequests.isEmpty)
        #expect(fake.state.withLock { $0.answers.map(\.1) } == [false])

        // A request from someone who left disappears.
        fake.push(.leaseRequested(paneId: 3, by: guestActor, name: "Mira"))
        fake.push(.participants(participants: [person(ownerActor, "Alex", [.owner])]))
        try await settle { session.participants.count == 1 }
        #expect(session.leaseRequests.isEmpty)
    }

    @Test func inviteModelBuildsOptionsAndKeepsTheLink() async throws {
        let fake = FakeMultiplayerClient()
        let session = MultiplayerSession()
        session.attach(fake)
        var draft = InviteDraft()
        draft.name = "  Mira "
        draft.roles = [.driver]
        draft.scope = .tab
        draft.expiry = .day
        draft.uses = .once
        let options = draft.options(inviter: "Alex", session: 1, tab: 2, pane: 3)
        #expect(options.roles == [.viewer, .driver])
        #expect(options.scope == .tab(tabId: 2))
        #expect(options.ttlSecs == 86_400)
        #expect(options.maxUses == 1)
        #expect(options.label == "Mira")
        #expect(options.inviter == "Alex")
        #expect(draft.summary == "Driver · Tab · 24 hours · 1 person")

        let invite = try await session.createInvite(options)
        #expect(invite.qrPayload == invite.link.uppercased())
        #expect(session.invites.first == invite)

        // Unlimited, never expires, whole host, approver implies viewing too.
        draft.roles = [.approver]
        draft.scope = .host
        draft.expiry = .never
        draft.uses = .unlimited
        draft.name = ""
        let open = draft.options(inviter: "Alex", session: nil, tab: nil, pane: nil)
        #expect(open.scope == .daemon && open.ttlSecs == nil && open.maxUses == nil)
        #expect(open.label == "Guest")
        // A scope that is not available falls back to the host.
        draft.scope = .pane
        #expect(draft.options(inviter: "A", session: nil, tab: nil, pane: nil).scope == .daemon)
    }

    @Test func promptRefusalsAndRevocationReadWell() async throws {
        let fake = FakeMultiplayerClient()
        let session = MultiplayerSession()
        session.attach(fake)
        fake.push(.joined(info: info(guestActor, "Mira", [.prompter], grant: "g1")))
        try await settle { session.me != nil }

        session.setTyping(5)
        session.setTyping(5)
        try await session.prompt(5, "fix the failing test")
        #expect(fake.state.withLock { $0.typing.map { "\($0.0):\($0.1)" } } == ["5:true", "5:false"])
        #expect(fake.state.withLock { $0.prompts.map(\.1) } == ["fix the failing test"])

        fake.state.withLock { $0.promptError = .Invalid(message: "prompts may not start with !") }
        await #expect(throws: MultiplayerError.self) { try await session.prompt(5, "!rm -rf /") }
        #expect(MultiplayerSession.describe(MultiplayerError.Invalid(message: "prompts may not start with !")) == "Prompts may not start with !")
        #expect(MultiplayerSession.describe(MultiplayerError.Forbidden(message: "needs the owner role")).hasPrefix("Needs an owner"))

        fake.push(.inputRejected(paneId: 5, reason: .role))
        try await settle { session.notice != nil }
        #expect(session.notice?.message.contains("composer") == true)

        fake.push(.revoked)
        try await settle { session.isRevoked }
        #expect(session.notice?.kind == .revoked)
        #expect(session.inputGate.all)
    }
}
