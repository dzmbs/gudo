import Foundation
import Observation
import os
import Synchronization
import UnnamedCore

// Multiplayer on a daemon connection (docs/DAEMON.md §6, docs/APPLE-FFI.md "Multiplayer"):
// who this connection is, who else is here and where, control leases, the composer path for
// prompters, invites, grants, revocation and the audit log. Views bind to `MultiplayerSession`
// (one per `DaemonConnection`); they never hold the client.

/// The multiplayer half of `UnnamedCore.DaemonClient`, so the session can be tested against a
/// fake. Requests are `async throws` (`MultiplayerError`); the rest answer from the last push.
nonisolated public protocol MultiplayerClientAPI: AnyObject, Sendable {
    func setMultiplayerListener(listener: any MultiplayerListener)
    func me() -> JoinInfo?
    func participantList() -> [UnnamedCore.Participant]
    func lease(paneId: UInt64) -> Lease?
    func setTyping(paneId: UInt64, typing: Bool)
    func participants() async throws -> [UnnamedCore.Participant]
    func setName(name: String) async throws
    func createInvite(options: InviteOptions) async throws -> CreatedInvite
    func listGrants() async throws -> [GrantInfo]
    func listDevices() async throws -> [DeviceInfo]
    func revoke(target: RevokeTarget) async throws -> RevokeResult
    func takeControl(paneId: UInt64, force: Bool) async throws -> LeaseOutcome
    func releaseControl(paneId: UInt64) async throws
    func answerControl(paneId: UInt64, give: Bool) async throws -> LeaseOutcome
    func giveControl(paneId: UInt64, to: String) async throws -> LeaseOutcome
    func leases() async throws -> [Lease]
    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32
    func audit(after: UInt64?, limit: UInt32) async throws -> AuditPage
}

extension DaemonClient: MultiplayerClientAPI {}

/// The roles the app distinguishes, ordered from least to most.
nonisolated public extension Role {
    /// "Viewer", "Prompter", …
    var title: String {
        switch self {
        case .viewer: "Viewer"
        case .prompter: "Prompter"
        case .driver: "Driver"
        case .approver: "Approver"
        case .owner: "Owner"
        }
    }

    /// What the role lets someone do, in one line.
    var summary: String {
        switch self {
        case .viewer: "Watches output and agent state. Cannot type."
        case .prompter: "Sends prompts to agents through the composer."
        case .driver: "Types into panes after taking control."
        case .approver: "Approves or denies agent requests, signed."
        case .owner: "Everything, including invites and revocation."
        }
    }

    var systemImage: String {
        switch self {
        case .viewer: "eye"
        case .prompter: "text.bubble"
        case .driver: "keyboard"
        case .approver: "checkmark.seal"
        case .owner: "crown"
        }
    }

    static let invitable: [Role] = [.viewer, .prompter, .driver, .approver]
}

/// A set of roles as people read it: the strongest first ("Driver + Approver").
nonisolated public func roleWords(_ roles: [Role]) -> String {
    if roles.contains(.owner) { return "Owner" }
    let shown = Role.invitable.reversed().filter(roles.contains)
    // Viewing is implied by every other role.
    let trimmed = shown.count > 1 ? shown.filter { $0 != .viewer } : shown
    return trimmed.isEmpty ? "No access" : trimmed.map(\.title).joined(separator: " + ")
}

nonisolated public extension Scope {
    /// "Whole host", "Session 3", "Tab 7", "Pane 12".
    var title: String {
        switch self {
        case .daemon: "Whole host"
        case .session(let id): "Session \(id)"
        case .tab(let id): "Tab \(id)"
        case .pane(let id): "Pane \(id)"
        }
    }
}

/// Everything multiplayer for one daemon connection, on the main actor. Pushes arrive through
/// `MultiplayerListener` on a runtime thread and are applied here in order.
@MainActor
@Observable
public final class MultiplayerSession {
    /// Who this connection is (roles, scope, grant), after every handshake.
    public private(set) var me: JoinInfo?
    /// Everyone connected, one entry per device, this device included.
    public private(set) var participants: [UnnamedCore.Participant] = []
    /// Control leases by pane.
    public private(set) var leases: [UInt64: Lease] = [:]
    /// Someone asked for a lease this principal holds (the holder's accept/keep prompt).
    public private(set) var leaseRequests: [LeaseRequest] = []
    /// Panes where this device asked for control and waits for the holder.
    public private(set) var pendingTakes: [UInt64: PendingTake] = [:]
    /// The owner's view of grants, devices and the audit log (loaded on demand).
    public private(set) var grants: [GrantInfo] = []
    public private(set) var devices: [DeviceInfo] = []
    public private(set) var auditPage: AuditPage?
    /// Invites made on this device in this run (link, QR text), newest first.
    public private(set) var invites: [CreatedInvite] = []
    /// The last thing to tell the user (a refusal, a hand-over, a revocation); views show it
    /// once per `id`.
    public private(set) var notice: Notice?
    /// This connection's grant was revoked; the daemon is closing it.
    public private(set) var isRevoked = false
    /// Decisions on agent requests, newest last (who approved what).
    public private(set) var decisions: [Decided] = []

    /// How long the holder may stay idle before the daemon hands the lease over
    /// (`[multiplayer] lease_idle_secs`, default 5 s).
    public var leaseIdle: Duration = .seconds(5)

    /// Called with the panes whose raw input must not be sent (`PaneRouter` gate).
    @ObservationIgnored var onInputGate: ((InputGate) -> Void)?

    @ObservationIgnored private var client: (any MultiplayerClientAPI)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var lastBlockedNotice = ContinuousClock.now - .seconds(10)
    @ObservationIgnored private var typingPane: UInt64?
    private static let log = Logger(subsystem: Log.subsystem, category: "multiplayer")

    nonisolated public struct LeaseRequest: Identifiable, Equatable, Sendable {
        public var id: String { "\(paneId)/\(by.device)" }
        public var paneId: UInt64
        public var by: Actor
        public var name: String
        public var at: Date

        public init(paneId: UInt64, by: Actor, name: String, at: Date = .now) {
            self.paneId = paneId
            self.by = by
            self.name = name
            self.at = at
        }
    }

    nonisolated public struct PendingTake: Equatable, Sendable {
        /// The holder's principal.
        public var holder: String
        public var since: Date
    }

    nonisolated public struct Notice: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The daemon refused keys or a paste.
            case inputRejected(pane: UInt64, reason: InputRejectReason)
            /// Typed while view-only; nothing was sent.
            case viewOnly(pane: UInt64)
            /// A request was refused by policy.
            case forbidden(what: String, reason: String)
            /// A lease came to this device.
            case controlGranted(pane: UInt64)
            /// The holder kept it.
            case controlKept(pane: UInt64, holder: String)
            /// This device lost the lease to someone.
            case controlLost(pane: UInt64, to: String)
            /// Another device decided first.
            case alreadyDecided(by: String)
            /// Revoked: the connection closes.
            case revoked
            /// A request failed.
            case failed(String)
        }
        public let id = UUID()
        public var kind: Kind

        /// The sentence to show.
        public var message: String
        public var isFailure: Bool

        public static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
    }

    /// The panes input is gated on (`PaneRouter`), recomputed on every role or lease change.
    nonisolated public struct InputGate: Equatable, Sendable {
        /// No raw input anywhere (viewer, prompter, approver without the driver role).
        public var all: Bool
        /// Panes whose lease another connected principal holds.
        public var panes: Set<UInt64>

        public static let open = InputGate(all: false, panes: [])
    }

    public init() {}

    // MARK: Wiring

    /// Starts following a client's multiplayer pushes (called once per dial).
    func attach(_ client: any MultiplayerClientAPI) {
        self.client = client
        pump?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerEvent.self)
        client.setMultiplayerListener(listener: MultiplayerRelay { continuation.yield($0) })
        pump = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
        if let me = client.me() { self.me = me }
        let list = client.participantList()
        if !list.isEmpty { participants = list }
        refreshGate()
    }

    func detach() {
        pump?.cancel()
        pump = nil
        client = nil
    }

    // MARK: Events

    /// Applies one push (public so previews and tests can drive the session without a daemon).
    public func apply(_ event: MultiplayerEvent) {
        switch event {
        case .joined(let info):
            me = info
            isRevoked = false
            Self.log.info("joined as \(info.name, privacy: .public) roles=\(roleWords(info.roles), privacy: .public)")
        case .participants(let list):
            participants = list
            // A request from someone who left is moot.
            let present = Set(list.map(\.actor.device))
            leaseRequests.removeAll { !present.contains($0.by.device) }
        case .presence(let presence):
            for index in participants.indices where participants[index].actor == presence.actor {
                participants[index].state = presence.state
                participants[index].focus = presence.focus
                participants[index].typing = presence.typing
                participants[index].cursor = presence.cursor
            }
        case .lease(let lease):
            let previous = leases[lease.paneId]
            leases[lease.paneId] = lease
            leaseRequests.removeAll { $0.paneId == lease.paneId && lease.holder != myPrincipal }
            if lease.holder == myPrincipal, previous?.holder != myPrincipal {
                if pendingTakes.removeValue(forKey: lease.paneId) != nil {
                    post(.controlGranted(pane: lease.paneId), "You're driving now", failure: false)
                }
            } else if previous?.holder == myPrincipal, let holder = lease.holder, holder != myPrincipal {
                post(.controlLost(pane: lease.paneId, to: holder), "\(name(ofPrincipal: holder)) took control", failure: false)
            }
            if lease.holder == nil || lease.holder == myPrincipal { pendingTakes[lease.paneId] = nil }
        case .leaseRequested(let pane, let by, let name):
            leaseRequests.removeAll { $0.paneId == pane && $0.by.device == by.device }
            leaseRequests.append(LeaseRequest(paneId: pane, by: by, name: name))
        case .inputRejected(let pane, let reason):
            let message = switch reason {
            case .role: "Your role can't type here. \(canPrompt ? "Use the composer to prompt the agent." : "You're viewing.")"
            case .noLease: "\(holderName(pane) ?? "Someone") is driving. Take control to type."
            case .blocked: "The host refused that input."
            case .unknownPane: "That pane is outside what you were invited to."
            }
            postThrottled(.inputRejected(pane: pane, reason: reason), message)
        case .forbidden(let what, let reason):
            post(.forbidden(what: what, reason: reason), Self.forbiddenText(what: what, reason: reason), failure: true)
        case .decided(let decided):
            decisions.append(decided)
            if decisions.count > 50 { decisions.removeFirst(decisions.count - 50) }
        case .alreadyDecided(_, let by):
            post(.alreadyDecided(by: by.principal), "\(name(ofPrincipal: by.principal)) answered first", failure: false)
        case .revoked:
            isRevoked = true
            post(.revoked, "Your access to this host was revoked", failure: true)
        }
        refreshGate()
    }

    // MARK: Derived state

    public var roles: [Role] { me?.roles ?? [] }
    public var myPrincipal: String? { me?.actor.principal }
    /// Joined with an invite (a paired owner device has no grant).
    public var isGuest: Bool { me?.grantId != nil }
    public var isOwner: Bool { roles.contains(.owner) }
    public var canDrive: Bool { isOwner || roles.contains(.driver) }
    public var canPrompt: Bool { isOwner || roles.contains(.prompter) || roles.contains(.driver) || roles.contains(.approver) }
    public var canApprove: Bool { isOwner || roles.contains(.approver) }
    /// Sees output only.
    public var isViewOnly: Bool { me != nil && !canDrive && !canPrompt }

    /// Other people connected (one entry per principal, the most active device).
    public var others: [UnnamedCore.Participant] {
        var byPrincipal: [String: UnnamedCore.Participant] = [:]
        for person in participants where person.actor.principal != myPrincipal {
            if let existing = byPrincipal[person.actor.principal], existing.state.rank <= person.state.rank { continue }
            byPrincipal[person.actor.principal] = person
        }
        return byPrincipal.values.sorted { ($0.sinceMs, $0.name) < ($1.sinceMs, $1.name) }
    }

    /// People focused on a pane (other than this device's principal).
    public func people(in pane: UInt64) -> [UnnamedCore.Participant] {
        others.filter { $0.focus == pane }
    }

    /// The principal driving a pane, if someone holds its lease.
    public func holder(of pane: UInt64) -> String? {
        guard let lease = leases[pane], lease.mode == .leased else { return nil }
        return lease.holder
    }

    public func holderName(_ pane: UInt64) -> String? {
        holder(of: pane).map(name(ofPrincipal:))
    }

    public func isDriving(_ pane: UInt64) -> Bool {
        holder(of: pane) != nil && holder(of: pane) == myPrincipal
    }

    /// Someone else holds the pane's lease and is connected.
    public func isDrivenByOther(_ pane: UInt64) -> Bool {
        guard let holder = holder(of: pane), holder != myPrincipal else { return false }
        return participants.contains { $0.actor.principal == holder }
    }

    public func name(ofPrincipal principal: String) -> String {
        if principal == myPrincipal { return "You" }
        if let person = participants.first(where: { $0.actor.principal == principal }) { return person.name }
        if let device = devices.first(where: { $0.principal == principal }) { return device.name }
        return "Someone"
    }

    public func name(of actor: Actor?) -> String {
        guard let actor else { return "The host" }
        if actor.principal == myPrincipal { return me?.name ?? "You" }
        if let person = participants.first(where: { $0.actor.device == actor.device }) { return person.name }
        if let device = devices.first(where: { $0.device == actor.device }) { return device.name }
        return "Device \(actor.device.prefix(8))"
    }

    /// The input gate for `PaneRouter`: no raw input without the driver role, none into a pane
    /// another connected principal drives.
    public var inputGate: InputGate {
        guard me != nil else { return .open }
        if !canDrive || isRevoked { return InputGate(all: true, panes: []) }
        return InputGate(all: false, panes: Set(leases.keys.filter(isDrivenByOther)))
    }

    private func refreshGate() {
        onInputGate?(inputGate)
    }

    // MARK: Control lease

    /// Asks for a pane's lease. Free, idle or ours: granted now. Otherwise the holder is asked
    /// and it moves when they accept or stay idle for `leaseIdle`. `force` (owner) takes it.
    @discardableResult
    public func takeControl(_ pane: UInt64, force: Bool = false) async -> LeaseOutcome? {
        guard let client else { return nil }
        do {
            let outcome = try await client.takeControl(paneId: pane, force: force)
            switch outcome {
            case .granted(let lease):
                leases[pane] = lease
                pendingTakes[pane] = nil
            case .pending(let holder):
                pendingTakes[pane] = PendingTake(holder: holder, since: .now)
            case .kept(let lease):
                leases[pane] = lease
                pendingTakes[pane] = nil
                post(.controlKept(pane: pane, holder: lease.holder ?? ""), "\(holderName(pane) ?? "The driver") kept control", failure: false)
            }
            refreshGate()
            return outcome
        } catch {
            fail(error)
            return nil
        }
    }

    /// The holder's answer to a request.
    public func answer(_ request: LeaseRequest, give: Bool) async {
        leaseRequests.removeAll { $0 == request }
        guard let client else { return }
        do {
            _ = try await client.answerControl(paneId: request.paneId, give: give)
        } catch {
            fail(error)
        }
    }

    public func releaseControl(_ pane: UInt64) async {
        guard let client else { return }
        do {
            try await client.releaseControl(paneId: pane)
        } catch {
            fail(error)
        }
    }

    public func giveControl(_ pane: UInt64, to principal: String) async {
        guard let client else { return }
        do {
            _ = try await client.giveControl(paneId: pane, to: principal)
        } catch {
            fail(error)
        }
    }

    /// Withdraws a pending request locally (the daemon still moves the lease if the holder
    /// accepts later).
    public func cancelTake(_ pane: UInt64) {
        pendingTakes[pane] = nil
    }

    // MARK: Composer (prompters)

    /// Sends a prompt to an agent pane (sanitized on the host). Throws the refusal in words.
    public func prompt(_ pane: UInt64, _ text: String, submit: Bool = true) async throws {
        guard let client else { throw MultiplayerError.Disconnected }
        setTyping(nil)
        _ = try await client.prompt(paneId: pane, text: text, submit: submit)
    }

    /// The composer's typing indicator: the pane being typed in, or nil.
    public func setTyping(_ pane: UInt64?) {
        guard pane != typingPane else { return }
        if let old = typingPane { client?.setTyping(paneId: old, typing: false) }
        typingPane = pane
        if let pane { client?.setTyping(paneId: pane, typing: true) }
    }

    // MARK: Owner: invites, grants, devices, audit

    /// Signs and registers an invite. The link is `<scheme>://join/…`; `qrPayload` is the same
    /// text upper-cased for a compact QR code.
    public func createInvite(_ options: InviteOptions) async throws -> CreatedInvite {
        guard let client else { throw MultiplayerError.Disconnected }
        let invite = try await client.createInvite(options: options)
        invites.insert(invite, at: 0)
        Self.log.info("invite created grant=\(invite.grantId.prefix(8), privacy: .public) roles=\(roleWords(options.roles), privacy: .public)")
        return invite
    }

    /// Grants and devices, fresh from the host (owner only).
    public func refreshGrants() async {
        guard let client else { return }
        do {
            async let grants = client.listGrants()
            async let devices = client.listDevices()
            (self.grants, self.devices) = try await (grants, devices)
        } catch {
            fail(error)
        }
    }

    /// Revokes and refreshes. Returns what it hit.
    @discardableResult
    public func revoke(_ target: RevokeTarget) async -> RevokeResult? {
        guard let client else { return nil }
        do {
            let result = try await client.revoke(target: target)
            await refreshGrants()
            return result
        } catch {
            fail(error)
            return nil
        }
    }

    /// The newest `limit` audit records (owner only).
    public func loadAudit(limit: UInt32 = 200) async {
        guard let client else { return }
        do {
            auditPage = try await client.audit(after: nil, limit: limit)
        } catch {
            fail(error)
        }
    }

    public func setName(_ name: String) async {
        do {
            try await client?.setName(name: name)
        } catch {
            fail(error)
        }
    }

    // MARK: Notices

    /// Typed into a pane the gate closed: say why, at most every few seconds.
    func noteBlockedInput(_ pane: UInt64) {
        let message = if !canDrive {
            canPrompt ? "You can prompt agents, not type. Use the composer." : "You're viewing. Typing is off."
        } else {
            "\(holderName(pane) ?? "Someone") is driving. Take control to type."
        }
        postThrottled(.viewOnly(pane: pane), message)
    }

    private func postThrottled(_ kind: Notice.Kind, _ message: String) {
        let now = ContinuousClock.now
        guard now - lastBlockedNotice > .seconds(3) else { return }
        lastBlockedNotice = now
        post(kind, message, failure: false)
    }

    private func post(_ kind: Notice.Kind, _ message: String, failure: Bool) {
        notice = Notice(kind: kind, message: message, isFailure: failure)
    }

    private func fail(_ error: any Error) {
        Self.log.error("multiplayer request failed: \(String(describing: error), privacy: .public)")
        post(.failed(Self.describe(error)), Self.describe(error), failure: true)
    }

    /// A refusal in words: the daemon names the missing role.
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? MultiplayerError else { return error.localizedDescription }
        switch error {
        case .Forbidden(let message): return forbiddenText(what: nil, reason: message)
        case .NotFound(let message): return "Not found: \(message)"
        case .Invalid(let message): return message.prefix(1).uppercased() + message.dropFirst()
        case .Conflict(let message): return message.prefix(1).uppercased() + message.dropFirst()
        case .Failed(let message): return message
        case .Disconnected: return "The host went away before it answered."
        }
    }

    static func forbiddenText(what: String?, reason: String) -> String {
        let lower = reason.lowercased()
        let role = ["owner", "driver", "approver", "prompter"].first { lower.contains($0) }
        if let role {
            let article = role == "owner" || role == "approver" ? "an" : "a"
            return "Needs \(article) \(role): \(what.map { "\($0) " } ?? "")is not allowed with your invite."
                .replacingOccurrences(of: ":  ", with: ": ")
        }
        return what.map { "\($0): \(reason)" } ?? reason
    }

    // MARK: Previews

    /// A session filled with sample data (previews, `-mock` screenshots).
    public static func preview(me: JoinInfo, participants: [UnnamedCore.Participant], leases: [Lease] = [], client: (any MultiplayerClientAPI)? = nil) -> MultiplayerSession {
        let session = MultiplayerSession()
        session.me = me
        session.participants = participants
        for lease in leases { session.leases[lease.paneId] = lease }
        session.client = client
        return session
    }

    /// Seeds owner data for previews.
    public func seed(grants: [GrantInfo] = [], devices: [DeviceInfo] = [], audit: AuditPage? = nil, invites: [CreatedInvite] = [], leaseRequests: [LeaseRequest] = []) {
        self.grants = grants
        self.devices = devices
        self.auditPage = audit
        self.invites = invites
        self.leaseRequests = leaseRequests
    }
}

nonisolated private extension PresenceState {
    var rank: Int {
        switch self {
        case .active: 0
        case .idle: 1
        case .away: 2
        }
    }
}

/// Forwards multiplayer pushes from the runtime thread.
nonisolated final class MultiplayerRelay: MultiplayerListener {
    private let handler: @Sendable (MultiplayerEvent) -> Void

    init(_ handler: @escaping @Sendable (MultiplayerEvent) -> Void) {
        self.handler = handler
    }

    func onMultiplayerEvent(event: MultiplayerEvent) {
        handler(event)
    }
}

// MARK: - Workspace pushes

/// The workspace half of the client this layer subscribes to (`setWorkspaceListener` takes one
/// listener; `WorkspaceEventHub` fans it out).
nonisolated public protocol WorkspaceEventSource: AnyObject, Sendable {
    func setWorkspaceListener(listener: any WorkspaceListener)
}

extension DaemonClient: WorkspaceEventSource {}

/// One `WorkspaceListener` per connection, fanned out to any number of observers (the inbox,
/// local notifications, ports). Observers are called on the main actor, in order.
@MainActor
public final class WorkspaceEventHub {
    private var observers: [UUID: (WorkspaceEvent) -> Void] = [:]
    private var pump: Task<Void, Never>?

    public init() {}

    /// Adds an observer; keep the token to remove it.
    @discardableResult
    public func observe(_ handler: @escaping (WorkspaceEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func remove(_ token: UUID) {
        observers[token] = nil
    }

    func attach(_ source: any WorkspaceEventSource) {
        pump?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceEvent.self)
        source.setWorkspaceListener(listener: WorkspaceRelay { continuation.yield($0) })
        pump = Task { [weak self] in
            for await event in stream {
                self?.deliver(event)
            }
        }
    }

    /// Delivers an event to every observer (public for tests and previews).
    public func deliver(_ event: WorkspaceEvent) {
        for observer in observers.values { observer(event) }
    }
}

nonisolated final class WorkspaceRelay: WorkspaceListener {
    private let handler: @Sendable (WorkspaceEvent) -> Void

    init(_ handler: @escaping @Sendable (WorkspaceEvent) -> Void) {
        self.handler = handler
    }

    func onWorkspaceEvent(event: WorkspaceEvent) {
        handler(event)
    }
}
