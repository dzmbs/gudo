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
    func inviteLink(grantId: String, inviter: String) async throws -> String
    func inviterDevice() -> String?
    func listDevices() async throws -> [DeviceInfo]
    func revoke(target: RevokeTarget) async throws -> RevokeResult
    func takeControl(paneId: UInt64, force: Bool) async throws -> LeaseOutcome
    func releaseControl(paneId: UInt64) async throws
    func answerControl(paneId: UInt64, give: Bool) async throws -> LeaseOutcome
    func giveControl(paneId: UInt64, to: String) async throws -> LeaseOutcome
    func leases() async throws -> [Lease]
    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32
    func audit(after: UInt64?, limit: UInt32) async throws -> AuditPage
    func pendingKnocks() -> [Knock]
    func admitKnock(knockId: UInt64, roles: [Role], sinceJoin: Bool, ttlSecs: UInt64?) async throws -> GrantInfo
    func denyKnock(knockId: UInt64) async throws
    func approvalPolicyCached() -> ApprovalPolicy?
    func approvalStatuses() -> [ApprovalStatus]
    func setApprovalPolicy(sessionId: UInt64, policy: ApprovalPolicy) async throws -> ApprovalPolicy
    func claimApproval(requestId: UInt64, claim: Bool) async throws -> ApprovalStatus
    func hasLivePresence() -> Bool
    func setDraft(paneId: UInt64, source: DraftSource, text: String, caret: UInt32)
    func clearDraft()
    func setViewport(viewport: PeerViewport?)
    func follow(principal: String?) throws
    func setDeviceClass(device: DeviceClass)
    func setPresenceState(state: PresenceState)
    func peerList() -> PeerList
}

/// Fakes and older stand-ins have no live presence.
nonisolated public extension MultiplayerClientAPI {
    func inviteLink(grantId: String, inviter: String) async throws -> String {
        throw MultiplayerError.Failed(message: "This host can't share a link again.")
    }
    func inviterDevice() -> String? { nil }
    func hasLivePresence() -> Bool { false }
    func setDraft(paneId: UInt64, source: DraftSource, text: String, caret: UInt32) {}
    func clearDraft() {}
    func setViewport(viewport: PeerViewport?) {}
    func follow(principal: String?) throws {}
    func setDeviceClass(device: DeviceClass) {}
    func setPresenceState(state: PresenceState) {}
    func peerList() -> PeerList { PeerList(you: nil, peers: []) }
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

nonisolated public extension ApprovalMode {
    /// "Any approver", "Owner only", …
    var title: String {
        switch self {
        case .anyApprover: "Any Approver"
        case .ownerOnly: "Owner Only"
        case .twoPerson: "Two People"
        case .claim: "Claim First"
        }
    }

    /// What it means, in one sentence.
    var summary: String {
        switch self {
        case .anyApprover: "Anyone with the approver role answers. The first answer counts."
        case .ownerOnly: "Only you answer. Approvers see requests but cannot decide them."
        case .twoPerson: "Running a command needs two different people to approve. One no is enough to stop it."
        case .claim: "An approver claims a request, then only they or you can answer it. The others stop being notified."
        }
    }

    static let ordered: [ApprovalMode] = [.anyApprover, .ownerOnly, .twoPerson, .claim]
}

nonisolated public extension Risk {
    /// "Reads", "Edits", "Commands".
    var title: String {
        switch self {
        case .readOnly: "Reads Only"
        case .edits: "Reads and Edits"
        case .any: "Anything"
        }
    }

    /// A short noun for a request of this risk: "a read", "an edit", "a command".
    var noun: String {
        switch self {
        case .readOnly: "a read"
        case .edits: "an edit"
        case .any: "a command"
        }
    }

    static let ordered: [Risk] = [.readOnly, .edits, .any]

    /// Ordered from least to most risky.
    var rank: Int {
        switch self {
        case .readOnly: 0
        case .edits: 1
        case .any: 2
        }
    }
}

nonisolated public extension ApprovalPolicy {
    /// The daemon's default: any approver, any risk.
    static let standard = ApprovalPolicy(mode: .anyApprover, maxRisk: .any)
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
    /// People waiting to be let in (owner devices), oldest first.
    public private(set) var knocks: [Knock] = []
    /// The attached session's approval rules (the default until the host says otherwise).
    public private(set) var approvalPolicy: ApprovalPolicy = .standard
    /// Open approval requests with votes or a claim, by request id.
    public private(set) var approvalStatuses: [UInt64: ApprovalStatus] = [:]
    /// Everyone's live presence by connection: focus, viewport, typing, drafts (daemons with
    /// live presence; empty otherwise).
    public private(set) var peers: [UInt64: Peer] = [:]
    /// This connection among `peers`.
    public private(set) var myPeer: UInt64?
    /// The person this device follows (principal), or nil.
    public private(set) var following: String?
    /// A guest follows whoever invited them (else the owner, else the driver) until they stop
    /// or move on their own; then only "Follow" starts it again.
    public private(set) var followDeclined = false

    /// How long the holder may stay idle before the daemon hands the lease over
    /// (`[multiplayer] lease_idle_secs`, default 5 s).
    public var leaseIdle: Duration = .seconds(5)

    /// Called with the panes whose raw input must not be sent (`PaneRouter` gate).
    @ObservationIgnored var onInputGate: ((InputGate) -> Void)?
    /// Called once per new knock (not for renames), for a notification.
    @ObservationIgnored public var onKnockArrived: ((Knock) -> Void)?
    /// Called when another owner device pairs with the host, for a notification.
    @ObservationIgnored public var onDevicePaired: ((DeviceInfo) -> Void)?
    /// Owner devices that paired while this session ran, by key, with when.
    public private(set) var freshPairings: [String: Date] = [:]
    /// What the host says the owner must know while it stands (re-sent on every connection).
    public private(set) var hostAlerts: [HostAlert] = []
    /// Called for every host alert push, repeats included (the app notifies once per alert).
    @ObservationIgnored public var onHostAlert: ((HostAlert) -> Void)?
    /// Alerts already announced in this run, so a reconnect does not toast again.
    @ObservationIgnored private var announcedAlerts: Set<String> = []

    @ObservationIgnored private var client: (any MultiplayerClientAPI)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var lastBlockedNotice = ContinuousClock.now - .seconds(10)
    @ObservationIgnored private var typingPane: UInt64?
    @ObservationIgnored private var draftPane: UInt64?
    /// The device that signed this guest's invite.
    @ObservationIgnored private var inviterDevice: String?
    /// Links of invites known on this device, by grant id.
    @ObservationIgnored private var links: [String: String] = [:]
    /// A participant list arrived on this connection already (later ones announce changes).
    @ObservationIgnored private var hasRoster = false
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
            /// Another device paired with this host (the new device's key).
            case devicePaired(String)
            /// The host reported something the owner must act on.
            case hostAlert(title: String)
            /// People came or went (by person, not device).
            case arrived([String])
            case left([String])
            /// A request failed.
            case failed(String)
            /// This device's own navigation ended following someone (principal).
            case stoppedFollowing(String)
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
        knocks = client.pendingKnocks()
        if let policy = client.approvalPolicyCached() { approvalPolicy = policy }
        approvalStatuses = Dictionary(client.approvalStatuses().map { ($0.requestId, $0) }, uniquingKeysWith: { $1 })
        let live = client.peerList()
        myPeer = live.you
        peers = Dictionary(live.peers.map { ($0.peer, $0) }, uniquingKeysWith: { $1 })
        client.setDeviceClass(device: Self.deviceClass)
        inviterDevice = client.inviterDevice()
        if let following { try? client.follow(principal: following) }
        refreshGate()
        followByDefault()
    }

    /// This device's kind, for "Ivan · iPad" (the app sets it at launch).
    public static var deviceClass: DeviceClass = .unknown

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
            hasRoster = false
            Self.log.info("joined as \(info.name, privacy: .private) roles=\(roleWords(info.roles), privacy: .public)")
        case .participants(let list):
            announceArrivals(from: participants, to: list)
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
        case .devicePaired(let device):
            // The daemon tells every other owner device; this one never needs telling.
            guard device.device != me?.actor.device else { break }
            Self.log.info("device paired \(device.device.prefix(12), privacy: .public)")
            freshPairings[device.device] = device.pairedAt
            if let index = devices.firstIndex(where: { $0.device == device.device }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
            post(.devicePaired(device.device), "\(displayName(of: device)) paired with this host. Not you? Remove it in Devices.", failure: false)
            onDevicePaired?(device)
        case .hostAlert(let alert):
            hostAlerts.removeAll { $0.key == alert.key }
            hostAlerts.insert(alert, at: 0)
            if announcedAlerts.insert(alert.key).inserted {
                Self.log.info("host alert \(String(describing: alert.kind), privacy: .public)")
                post(.hostAlert(title: alert.title), alert.title, failure: true)
            }
            onHostAlert?(alert)
        case .knockAdded(let knock):
            if let index = knocks.firstIndex(where: { $0.knockId == knock.knockId }) {
                knocks[index] = knock
            } else {
                knocks.append(knock)
                Self.log.info("knock \(knock.knockId) from \(knock.name, privacy: .private)")
                onKnockArrived?(knock)
            }
        case .knockGone(let knockId, _, _):
            knocks.removeAll { $0.knockId == knockId }
        case .approvalPolicy(_, let policy):
            approvalPolicy = policy
        case .approvalStatus(let status):
            approvalStatuses[status.requestId] = status
        case .peers(let you, let list):
            myPeer = you
            peers = Dictionary(list.map { ($0.peer, $0) }, uniquingKeysWith: { $1 })
        case .peerChanged(let peer):
            guard (peers[peer.peer]?.rev ?? 0) < peer.rev else { break }
            peers[peer.peer] = peer
            // The participant list's typing and activity follow live presence.
            for index in participants.indices where participants[index].actor == peer.actor {
                participants[index].state = peer.state
                participants[index].focus = peer.focus
                participants[index].typing = peer.typing != nil
            }
        }
        if case .decided(let decided) = event { approvalStatuses[decided.requestId] = nil }
        if case .joined = event { knocks = []; approvalStatuses = [:] }
        refreshGate()
        followByDefault()
        switch event {
        case .joined, .participants, .devicePaired: if isOwner { refreshSharing() }
        default: break
        }
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

    // MARK: Live presence

    /// Whether the host shares drafts, viewports and following.
    public var hasLivePresence: Bool { client?.hasLivePresence() ?? false || !peers.isEmpty }

    /// Other connections (this one excluded; this person's other devices included).
    public var otherPeers: [Peer] {
        peers.values.filter { $0.peer != myPeer }.sorted { ($0.sinceMs, $0.peer) < ($1.sinceMs, $1.peer) }
    }

    /// Drafts others are writing for a pane, oldest connection first.
    public func drafts(in pane: UInt64) -> [Peer] {
        otherPeers.filter { $0.draft?.paneId == pane && !($0.draft?.text.isEmpty ?? true) }
    }

    /// Others typing into a pane right now (raw keys or a draft).
    public func typists(in pane: UInt64) -> [Peer] {
        otherPeers.filter { $0.typing == pane }
    }

    /// Others looking at a pane.
    public func viewers(of pane: UInt64) -> [Peer] {
        otherPeers.filter { $0.focus == pane && $0.state != .away }
    }

    /// The device of `principal` to follow: the most recently changed one that is not away.
    public func leader(_ principal: String) -> Peer? {
        let theirs = otherPeers.filter { $0.actor.principal == principal }
        return theirs.filter { $0.state != .away }.max { $0.rev < $1.rev } ?? theirs.max { $0.rev < $1.rev }
    }

    /// The device this one follows now.
    public var leaderPeer: Peer? { following.flatMap(leader) }

    /// People following this person.
    public var followers: [Peer] {
        guard let me = myPrincipal else { return [] }
        return otherPeers.filter { $0.following == me }
    }

    /// Follows a person (their focus and scroll), or stops with nil.
    public func follow(_ principal: String?) {
        followDeclined = principal == nil
        setFollowing(principal)
    }

    private func setFollowing(_ principal: String?) {
        guard principal != following else { return }
        following = principal
        try? client?.follow(principal: principal)
        Self.log.info("follow \(principal == nil ? "stopped" : "started", privacy: .public)")
    }

    /// Whom a guest follows by default: whoever signed their invite, else an owner device,
    /// else whoever drives a pane.
    public var defaultLeader: String? {
        let others = otherPeers.filter { $0.actor.principal != myPrincipal }
        if let inviterDevice, let inviter = others.first(where: { $0.actor.device == inviterDevice }) {
            return inviter.actor.principal
        }
        if let owner = others.filter({ $0.roles.contains(.owner) }).max(by: { $0.rev < $1.rev }) {
            return owner.actor.principal
        }
        let present = Set(others.map(\.actor.principal))
        return leases.values.filter { $0.mode == .leased }.compactMap(\.holder).sorted().first(where: present.contains)
    }

    /// A guest mirrors the session from the moment they join: same tab, pane and scroll.
    private func followByDefault() {
        guard following == nil, !followDeclined, isGuest, !isRevoked, hasLivePresence, let leader = defaultLeader else { return }
        setFollowing(leader)
    }

    /// Own navigation (a scroll, a tab or pane change, typing) ends following, as in Zed and
    /// Figma; the notice offers to follow again.
    public func breakFollow() {
        guard let leader = following else { return }
        follow(nil)
        let name = name(ofPrincipal: leader).split(separator: " ").first.map(String.init) ?? "them"
        post(.stoppedFollowing(leader), "Stopped following \(name)", failure: false)
    }

    /// The draft being typed for a pane; others see it live. Empty text clears it.
    public func setDraft(_ pane: UInt64, source: DraftSource, text: String, caret: Int) {
        guard let client, canPrompt else { return }
        if text.isEmpty {
            clearDraft()
            return
        }
        draftPane = pane
        client.setDraft(paneId: pane, source: source, text: text, caret: UInt32(max(0, caret)))
    }

    /// The draft was sent, discarded or left.
    public func clearDraft() {
        guard draftPane != nil else { return }
        draftPane = nil
        client?.clearDraft()
    }

    /// The rows of the focused pane on screen.
    public func setViewport(_ viewport: PeerViewport?) {
        client?.setViewport(viewport: viewport)
    }

    /// Says what kind of device this is (`deviceClass`).
    public func announceDevice() {
        client?.setDeviceClass(device: Self.deviceClass)
    }

    /// Away while the app is in the background.
    public func setAway(_ away: Bool) {
        client?.setPresenceState(state: away ? .away : .active)
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
        if let pane {
            client?.setTyping(paneId: pane, typing: true)
            breakFollow()
        }
    }

    // MARK: Owner: invites, grants, devices, audit

    /// Signs and registers an invite. The link is `<scheme>://join/…`; `qrPayload` is the same
    /// text upper-cased for a compact QR code.
    public func createInvite(_ options: InviteOptions) async throws -> CreatedInvite {
        guard let client else { throw MultiplayerError.Disconnected }
        let invite = try await client.createInvite(options: options)
        invites.insert(invite, at: 0)
        links[invite.grantId] = invite.link
        refreshSharing()
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

    /// Grants and devices without telling the user when it fails (counts, badges).
    private func refreshSharing() {
        guard let client else { return }
        Task {
            async let grants = client.listGrants()
            async let devices = client.listDevices()
            if let (grants, devices) = try? await (grants, devices) {
                (self.grants, self.devices) = (grants, devices)
            }
        }
    }

    /// Links that still let people in: neither revoked nor expired.
    public var activeGrants: [GrantInfo] {
        let now = UInt64(Date.now.timeIntervalSince1970 * 1000)
        return grants
            .filter { !$0.revoked && ($0.grant.expiresMs ?? .max) > now }
            .sorted { $0.grant.issuedAtMs > $1.grant.issuedAtMs }
    }

    /// Guests connected now, one per person.
    public var guests: [UnnamedCore.Participant] {
        others.filter { $0.grantId != nil }
    }

    /// "Shared · 2 people · 1 link", or nil when nothing is shared.
    public var sharingSummary: String? {
        let people = guests.count, links = activeGrants.count
        guard people + links > 0 else { return nil }
        var parts = ["Shared"]
        if people > 0 { parts.append(people == 1 ? "1 person" : "\(people) people") }
        if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        return parts.joined(separator: " · ")
    }

    /// A link's text to share again: as made on this device, else signed again from the host's
    /// record. Nil (with a notice) when the host can't.
    public func link(for grant: GrantInfo) async -> String? {
        if let link = links[grant.grant.grantId] { return link }
        guard let client else { return nil }
        do {
            let link = try await client.inviteLink(grantId: grant.grant.grantId, inviter: me?.name ?? "")
            links[grant.grant.grantId] = link
            return link
        } catch {
            fail(error)
            return nil
        }
    }

    /// Disconnects a person now and keeps their device out; links stay for everyone else.
    @discardableResult
    public func remove(_ person: UnnamedCore.Participant) async -> RevokeResult? {
        await revoke(.device(device: person.actor.device))
    }

    // MARK: Devices

    /// Whether `device` is the one this session runs on.
    public func isThisDevice(_ device: DeviceInfo) -> Bool {
        device.device == me?.actor.device
    }

    /// The daemon refuses to unpair the device asking, and a revoked one is gone already.
    public func canRemove(_ device: DeviceInfo) -> Bool {
        !isThisDevice(device) && !device.revoked
    }

    /// What to call a device: the name it gave, else what kind it is.
    public func displayName(of device: DeviceInfo) -> String {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Paired devices are "owner" on the host until they say their name.
        if !name.isEmpty, name != "owner" { return name }
        if let kind = peers.values.first(where: { $0.actor.device == device.device })?.device.title { return kind }
        return device.kind == .owner ? "Unnamed device" : "Guest"
    }

    /// Owner devices: ones paired while this session ran first (newest first), then this
    /// device, then the rest by pairing time, newest first; removed ones last.
    public var ownerDevices: [DeviceInfo] {
        let fresh = freshPairings, mine = me?.actor.device
        return devices.filter { $0.kind == .owner }.sorted { a, b in
            func rank(_ d: DeviceInfo) -> Int { d.revoked ? 3 : fresh[d.device] != nil ? 0 : d.device == mine ? 1 : 2 }
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.firstSeenMs > b.firstSeenMs
        }
    }

    /// Guest devices: connected first, then newest first; removed ones last.
    public var guestDevices: [DeviceInfo] {
        devices.filter { $0.kind == .guest }.sorted { a, b in
            func rank(_ d: DeviceInfo) -> Int { d.revoked ? 2 : d.connected > 0 ? 0 : 1 }
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.firstSeenMs > b.firstSeenMs
        }
    }

    /// Unpairs a device (an owner device is signed out and its invites stop working; a guest
    /// is disconnected and kept out). Never this device.
    @discardableResult
    public func removeDevice(_ device: DeviceInfo) async -> RevokeResult? {
        guard canRemove(device) else { return nil }
        let result = await revoke(.device(device: device.device))
        if result != nil { freshPairings[device.device] = nil }
        return result
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

    // MARK: Knocks (owner)

    /// Lets someone in with `roles`. `sinceJoin` hides the scrollback from before now.
    public func admit(_ knock: Knock, roles: [Role], sinceJoin: Bool) async {
        guard let client else { return }
        do {
            _ = try await client.admitKnock(knockId: knock.knockId, roles: roles, sinceJoin: sinceJoin, ttlSecs: nil)
            knocks.removeAll { $0.knockId == knock.knockId }
            Self.log.info("admitted knock \(knock.knockId) as \(roleWords(roles), privacy: .public)")
        } catch {
            fail(error)
        }
    }

    /// Turns someone away.
    public func turnAway(_ knock: Knock) async {
        guard let client else { return }
        do {
            try await client.denyKnock(knockId: knock.knockId)
            knocks.removeAll { $0.knockId == knock.knockId }
        } catch {
            fail(error)
        }
    }

    // MARK: Approval rules

    /// Sets the session's approval rules (owner).
    public func setApprovalPolicy(_ policy: ApprovalPolicy, session: UInt64) async {
        guard let client else { return }
        let previous = approvalPolicy
        approvalPolicy = policy
        do {
            approvalPolicy = try await client.setApprovalPolicy(sessionId: session, policy: policy)
        } catch {
            approvalPolicy = previous
            fail(error)
        }
    }

    /// Claims a request ("I'll take this one"), or gives the claim up.
    public func claim(_ requestId: UInt64, _ claim: Bool = true) async {
        guard let client else { return }
        do {
            let status = try await client.claimApproval(requestId: requestId, claim: claim)
            approvalStatuses[requestId] = status
        } catch {
            fail(error)
        }
    }

    /// Why this device cannot approve a request of `risk` here (nil: it can). Denying is never
    /// held back.
    public func approvalBlock(requestId: UInt64, risk: Risk) -> String? {
        guard me != nil else { return nil }
        if !canApprove { return "Your invite can't answer approvals." }
        if isOwner { return nil }
        let policy = approvalPolicy
        if policy.mode == .ownerOnly { return "Only the owner answers approvals here." }
        if risk.rank > policy.maxRisk.rank { return "Allowing \(risk.noun) needs the owner here." }
        if policy.mode == .claim, let claim = approvalStatuses[requestId]?.claimedBy, claim.actor.principal != myPrincipal {
            return "\(claim.name) claimed this request."
        }
        return nil
    }

    /// "Mira approved · needs one more", or nil when there is nothing to say.
    public func approvalProgress(requestId: UInt64) -> String? {
        guard let status = approvalStatuses[requestId] else { return nil }
        if let claim = status.claimedBy {
            return claim.actor.principal == myPrincipal ? "You claimed this" : "Claimed by \(claim.name)"
        }
        guard status.needed > 1, let first = status.approvals.first else { return nil }
        let who = first.actor.principal == myPrincipal ? "You" : first.name
        return "\(who) approved · needs a second person"
    }

    /// Whether this device already cast the approval a two-person request is holding.
    public func approvedAlready(requestId: UInt64) -> Bool {
        approvalStatuses[requestId]?.approvals.contains { $0.actor.principal == myPrincipal } ?? false
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

    /// "Kim joined", "Kim and Rex left": once per person, not per device, and not for the
    /// list that arrives on (re)connecting.
    private func announceArrivals(from old: [UnnamedCore.Participant], to new: [UnnamedCore.Participant]) {
        defer { hasRoster = true }
        guard hasRoster, let me = myPrincipal else { return }
        func people(_ list: [UnnamedCore.Participant]) -> [String: String] {
            Dictionary(list.filter { $0.actor.principal != me }.map { ($0.actor.principal, $0.name) }, uniquingKeysWith: { a, _ in a })
        }
        let before = people(old), after = people(new)
        let came = after.filter { before[$0.key] == nil }.map(\.value).sorted()
        let went = before.filter { after[$0.key] == nil }.map(\.value).sorted()
        if !came.isEmpty {
            post(.arrived(came), "\(Self.names(came)) joined", failure: false)
        } else if !went.isEmpty {
            post(.left(went), "\(Self.names(went)) left", failure: false)
        }
    }

    static func names(_ list: [String]) -> String {
        switch list.count {
        case 1: list[0]
        case 2: "\(list[0]) and \(list[1])"
        default: "\(list[0]) and \(list.count - 1) others"
        }
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
        // Approval rules and claims answer in sentences ("only the owner answers approvals in
        // this session"); missing roles name the role ("needs the driver role; …").
        if !lower.contains(" role") {
            let prefix = ["forbidden: ", "conflict: ", "not found: ", "invalid: "].first { reason.hasPrefix($0) }
            let plain = prefix.map { String(reason.dropFirst($0.count)) } ?? reason
            if what == "Decide" || what == nil, !plain.isEmpty {
                return plain.prefix(1).uppercased() + plain.dropFirst() + (plain.hasSuffix(".") ? "" : ".")
            }
        }
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
    public static func preview(me: JoinInfo, participants: [UnnamedCore.Participant], leases: [Lease] = [], peers: [Peer] = [],
                               client: (any MultiplayerClientAPI)? = nil) -> MultiplayerSession {
        let session = MultiplayerSession()
        session.me = me
        session.participants = participants
        session.peers = Dictionary(peers.map { ($0.peer, $0) }, uniquingKeysWith: { $1 })
        for lease in leases { session.leases[lease.paneId] = lease }
        session.client = client
        return session
    }

    /// Seeds owner data for previews.
    public func seed(grants: [GrantInfo] = [], devices: [DeviceInfo] = [], audit: AuditPage? = nil, invites: [CreatedInvite] = [], leaseRequests: [LeaseRequest] = [],
                     knocks: [Knock] = [], approvalPolicy: ApprovalPolicy = .standard, approvalStatuses: [ApprovalStatus] = [],
                     hostAlerts: [HostAlert] = [], freshPairings: [String: Date] = [:]) {
        self.hostAlerts = hostAlerts
        self.freshPairings = freshPairings
        self.grants = grants
        self.devices = devices
        self.auditPage = audit
        self.invites = invites
        self.leaseRequests = leaseRequests
        self.knocks = knocks
        self.approvalPolicy = approvalPolicy
        self.approvalStatuses = Dictionary(approvalStatuses.map { ($0.requestId, $0) }, uniquingKeysWith: { $1 })
    }
}

nonisolated public extension DeviceInfo {
    /// When it paired (owner) or first joined (guest).
    var pairedAt: Date {
        firstSeenMs > 0 ? Date(timeIntervalSince1970: Double(firstSeenMs) / 1000) : .now
    }
}

nonisolated public extension HostAlert {
    /// Identifies one alert across connections and launches.
    var key: String { "\(kind)/\(atMs)" }
}

nonisolated public extension DeviceClass {
    /// "iPhone", "iPad", "Mac", "Terminal", or nil when the device did not say.
    var title: String? {
        switch self {
        case .phone: "iPhone"
        case .tablet: "iPad"
        case .desktop: "Mac"
        case .terminal: "Terminal"
        case .unknown: nil
        }
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
