import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI
import GudoCore

extension Workspace {
    /// nil for this device and plain SSH hosts; a sample session under `-mock`.
    var multiplayer: MultiplayerSession? {
        if LaunchOptions.mock { return MockMultiplayer.session }
        return (host as? DaemonConnection)?.multiplayer
    }

    var daemon: DaemonConnection? { host as? DaemonConnection }

    func isAgentPane(_ pane: PaneId) -> Bool {
        if LaunchOptions.mock { return MockMultiplayer.agentPanes.contains(pane.rawValue) }
        return daemon?.meta[pane]?.agent != nil
    }

    /// "Claude Code" for an agent pane.
    func agentName(_ pane: PaneId) -> String? {
        if LaunchOptions.mock { return MockMultiplayer.agentPanes.contains(pane.rawValue) ? "Claude Code" : nil }
        return daemon?.meta[pane]?.agent.map { AgentKind($0.kind).title }
    }
}

extension GudoCore.Participant {
    var avatar: DesignSystem.Participant {
        DesignSystem.Participant(
            id: actor.device, name: name.isEmpty ? "Guest" : name, role: Self.avatarRole(roles),
            isActive: typing, hue: Self.hue(for: actor.principal))
    }

    static func avatarRole(_ roles: [Role]) -> DesignSystem.Participant.Role {
        if roles.contains(.owner) { return .owner }
        if roles.contains(.driver) || roles.contains(.prompter) { return .editor }
        return .viewer
    }

    /// A stable hue per principal (FNV-1a), so a person keeps their color on every device.
    static func hue(for principal: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in principal.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % 5)
    }

    /// Where they are, in words: "In pane 3 · typing", "Idle", "Away".
    func whereabouts(paneTitle: (UInt64) -> String) -> String {
        var parts: [String] = []
        switch state {
        case .active: if let focus { parts.append("In \(paneTitle(focus))") } else { parts.append("Here") }
        case .idle: parts.append(focus.map { "Idle in \(paneTitle($0))" } ?? "Idle")
        case .away: parts.append("Away")
        }
        if typing { parts.append("typing…") }
        return parts.joined(separator: " · ")
    }
}

extension GudoCore.Peer {
    /// The same avatar and color as the person's participant entry.
    var avatar: DesignSystem.Participant {
        DesignSystem.Participant(
            id: "\(peer)", name: name.isEmpty ? "Guest" : name, role: GudoCore.Participant.avatarRole(roles),
            isActive: typing != nil, hue: GudoCore.Participant.hue(for: actor.principal))
    }

    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? (name.isEmpty ? "Guest" : name)
    }

    /// "iPad", "Mac", … or nil when the device did not say.
    var deviceName: String? { device.title }
}

extension MultiplayerSession.Notice {
    var toast: Toast {
        let image: String = switch kind {
        case .controlGranted: "keyboard"
        case .controlKept, .controlLost: "keyboard.badge.ellipsis"
        case .viewOnly, .inputRejected: "eye"
        case .revoked: "person.crop.circle.badge.xmark"
        case .devicePaired: "lock.shield"
        case .hostAlert: "exclamationmark.shield"
        case .alreadyDecided, .guestAnswered: "checkmark.seal"
        case .forbidden, .failed: "exclamationmark.triangle.fill"
        case .arrived: "person.crop.circle.badge.plus"
        case .left: "person.crop.circle.badge.minus"
        case .stoppedFollowing: "eye.slash"
        }
        let granted: Bool = if case .controlGranted = kind { true } else { false }
        return Toast(message, systemImage: image, style: isFailure ? .failure : granted ? .success : .neutral)
    }
}

/// Short, human times: "in 23 h", "2 min ago".
enum RelativeTime {
    static func string(ms: UInt64?, now: Date = .now) -> String? {
        guard let ms else { return nil }
        return string(Date(timeIntervalSince1970: Double(ms) / 1000), now: now)
    }

    static func string(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Short hex for keys and ids: "a1b2 c3d4 e5f6 0718".
func groupedHex(_ hex: String, groups: Int = 4) -> String {
    let chars = Array(hex.prefix(groups * 4))
    return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: " ")
}

// MARK: - Mock (`-mock` screenshots and previews)

nonisolated enum MockMultiplayer {
    static let owner = Actor(principal: "a1".padding(toLength: 32, withPad: "0", startingAt: 0), device: "a1".padding(toLength: 64, withPad: "1", startingAt: 0))
    static let mira = Actor(principal: "b2".padding(toLength: 32, withPad: "0", startingAt: 0), device: "b2".padding(toLength: 64, withPad: "2", startingAt: 0))
    static let jon = Actor(principal: "c3".padding(toLength: 32, withPad: "0", startingAt: 0), device: "c3".padding(toLength: 64, withPad: "3", startingAt: 0))
    static let sam = Actor(principal: "d4".padding(toLength: 32, withPad: "0", startingAt: 0), device: "d4".padding(toLength: 64, withPad: "4", startingAt: 0))
    /// The design fixture's split: pane 1 a shell, 3 Claude Code, 4 Codex.
    static let agentPanes: Set<UInt64> = [3, 4]

    /// `-mockPresence YES` also puts presence on the panes; off by default so other fixtures stay unchanged.
    static var onPanes: Bool { UserDefaults.standard.bool(forKey: "mockPresence") }

    /// Who the mock session is: `-mockRole viewer|prompter|driver` shows a guest's view.
    static var role: String { UserDefaults.standard.string(forKey: "mockRole") ?? "owner" }

    static let now = UInt64(Date.now.timeIntervalSince1970 * 1000)

    @MainActor static let session: MultiplayerSession = {
        let me: JoinInfo = switch role {
        case "viewer": JoinInfo(actor: jon, name: "Jon Oyelaran", roles: [.viewer], scope: .session(sessionId: 1), grantId: "g3", expiresMs: now + 23 * 3_600_000)
        case "prompter": JoinInfo(actor: sam, name: "Sam Ruiz", roles: [.viewer, .prompter], scope: .session(sessionId: 1), grantId: "g4", expiresMs: now + 3_600_000)
        case "driver": JoinInfo(actor: mira, name: "Mira Holt", roles: [.viewer, .driver, .approver], scope: .daemon, grantId: "g2", expiresMs: now + 6 * 86_400_000)
        default: JoinInfo(actor: owner, name: "Alex Kim", roles: [.owner], scope: .daemon, grantId: nil, expiresMs: nil)
        }
        let people = [
            GudoCore.Participant(actor: owner, name: "Alex Kim", roles: [.owner], scope: .daemon, grantId: nil, sinceMs: now - 3_600_000, state: .active, focus: 1, typing: false, cursor: nil),
            GudoCore.Participant(actor: mira, name: "Mira Holt", roles: [.viewer, .driver, .approver], scope: .daemon, grantId: "g2", sinceMs: now - 1_800_000, state: .active, focus: 3, typing: true, cursor: nil),
            GudoCore.Participant(actor: jon, name: "Jon Oyelaran", roles: [.viewer], scope: .session(sessionId: 1), grantId: "g3", sinceMs: now - 900_000, state: .idle, focus: 1, typing: false, cursor: nil),
            GudoCore.Participant(actor: sam, name: "Sam Ruiz", roles: [.viewer, .prompter], scope: .session(sessionId: 1), grantId: "g4", sinceMs: now - 300_000, state: .active, focus: 3, typing: false, cursor: nil),
        ]
        let holder = role == "driver" || UserDefaults.standard.bool(forKey: "mockLeaseRequest") ? owner.principal : mira.principal
        let session = MultiplayerSession.preview(
            me: me, participants: people,
            leases: [Lease(paneId: 3, holder: holder, sinceMs: now - 120_000, mode: .leased)],
            peers: people.enumerated().map { index, person in peer(person, id: UInt64(index + 1)) },
            client: MockMultiplayerClient())
        session.seed(grants: grants, devices: devices, audit: audit,
                     leaseRequests: UserDefaults.standard.bool(forKey: "mockLeaseRequest")
                        ? [.init(paneId: 3, by: mira, name: "Mira Holt")] : [],
                     knocks: UserDefaults.standard.bool(forKey: "mockKnock") ? [knock] : [],
                     approvalPolicy: ApprovalPolicy(mode: .twoPerson, maxRisk: .edits),
                     hostAlerts: UserDefaults.standard.bool(forKey: "mockHostAlert") ? [hostAlert] : [],
                     freshPairings: showsPairing ? [pairedNow.device: pairedNow.pairedAt] : [:])
        // `-mockFollow YES`: this device follows Mira (the follow pill).
        if UserDefaults.standard.bool(forKey: "mockFollow") { session.follow(mira.principal) }
        return session
    }()

    /// A participant's live presence; Mira is writing a prompt for Claude Code.
    static func peer(_ person: GudoCore.Participant, id: UInt64) -> Peer {
        let drafting = person.actor == mira
        return Peer(
            peer: id, rev: id, actor: person.actor, name: person.name, roles: person.roles,
            device: drafting ? .tablet : .desktop, sinceMs: person.sinceMs, state: person.state, focus: person.focus,
            viewport: person.focus.map { PeerViewport(paneId: $0, fromBottom: person.actor == jon ? 120 : 0, rows: 40) },
            typing: drafting ? 3 : nil,
            draft: drafting ? Draft(paneId: 3, source: .composer, text: "Split the parser into a lexer and a recursive-descent pass, keep the error spans", caret: 82) : nil,
            following: person.actor == sam ? mira.principal : nil)
    }

    /// `-mockKnock YES`: someone at the door.
    static let knock = Knock(knockId: 1, actor: Actor(principal: "e5".padding(toLength: 32, withPad: "0", startingAt: 0), device: "e5".padding(toLength: 64, withPad: "5", startingAt: 0)),
                             name: "Priya Nair", grantId: "g6".padding(toLength: 32, withPad: "0", startingAt: 0), roles: [.viewer],
                             scope: .session(sessionId: 1), atMs: now - 40_000)

    static func grant(_ id: String, _ label: String, _ roles: [Role], _ scope: Scope, expires: UInt64?, uses: UInt32?, bound: Int, revoked: Bool = false, issuedAgo: UInt64) -> GrantInfo {
        GrantInfo(
            grant: Grant(grantId: id.padding(toLength: 32, withPad: "0", startingAt: 0), issuer: owner.device, roles: roles, scope: scope,
                         issuedAtMs: now - issuedAgo, expiresMs: expires, maxUses: uses, bind: nil, delegate: false, label: label),
            parent: nil, bound: Array(repeating: mira.device, count: bound), revoked: revoked)
    }

    static let grants: [GrantInfo] = [
        grant("g2", "Mira Holt", [.viewer, .driver, .approver], .daemon, expires: now + 6 * 86_400_000, uses: 1, bound: 1, issuedAgo: 86_400_000),
        grant("g3", "Jon Oyelaran", [.viewer], .session(sessionId: 1), expires: now + 23 * 3_600_000, uses: 5, bound: 1, issuedAgo: 3_600_000),
        grant("g4", "Sam Ruiz", [.viewer, .prompter], .session(sessionId: 1), expires: now + 3_600_000, uses: 1, bound: 1, issuedAgo: 600_000),
        grant("g5", "Design review", [.viewer], .tab(tabId: 3), expires: now + 86_400_000, uses: nil, bound: 0, issuedAgo: 120_000),
        grant("g1", "Old laptop", [.viewer, .driver], .daemon, expires: now - 86_400_000, uses: 1, bound: 1, revoked: true, issuedAgo: 9 * 86_400_000),
    ]

    /// `-mockDevicePaired YES`: an iPhone paired a minute ago (the highlighted row, the notice).
    static let pairedNow = DeviceInfo(
        device: "c7".padding(toLength: 64, withPad: "4", startingAt: 0), principal: owner.principal, kind: .owner,
        name: "Alex’s iPhone", firstSeenMs: now - 60_000, grantId: nil, revoked: false, connected: 1)
    static var showsPairing: Bool { UserDefaults.standard.bool(forKey: "mockDevicePaired") }

    /// `-mockHostAlert YES`: the host lost its grant store.
    static let hostAlert = HostAlert(
        kind: .grantStoreReset, atMs: now - 7_200_000, title: "Earlier invites stopped working",
        body: "The host couldn't read its invite records and set them aside. Links shared before now are refused; send new invites.")

    static var devices: [DeviceInfo] {
        (showsPairing ? [pairedNow] : []) + baseDevices
    }

    static let baseDevices: [DeviceInfo] = [
        DeviceInfo(device: owner.device, principal: owner.principal, kind: .owner, name: "Alex’s iPad", firstSeenMs: now - 40 * 86_400_000, grantId: nil, revoked: false, connected: 1),
        DeviceInfo(device: "b3".padding(toLength: 64, withPad: "9", startingAt: 0), principal: owner.principal, kind: .owner, name: "Alex’s MacBook Pro", firstSeenMs: now - 12 * 86_400_000, grantId: nil, revoked: false, connected: 0),
        DeviceInfo(device: "d1".padding(toLength: 64, withPad: "2", startingAt: 0), principal: owner.principal, kind: .owner, name: "owner", firstSeenMs: now - 63 * 86_400_000, grantId: nil, revoked: false, connected: 0),
        DeviceInfo(device: mira.device, principal: mira.principal, kind: .guest, name: "Mira Holt", firstSeenMs: now - 1_800_000, grantId: "g2", revoked: false, connected: 1),
        DeviceInfo(device: jon.device, principal: jon.principal, kind: .guest, name: "Jon Oyelaran", firstSeenMs: now - 900_000, grantId: "g3", revoked: false, connected: 1),
    ]

    static let audit: AuditPage = {
        func record(_ seq: UInt64, _ ago: UInt64, _ kind: AuditKind, _ actor: Actor?, _ detail: String, approval: ApprovalAudit? = nil) -> AuditRecord {
            AuditRecord(seq: seq, atMs: now - ago, kind: kind, actor: actor, grantId: nil, paneId: 2, detail: detail, approval: approval,
                        prevHash: Data(repeating: UInt8(seq), count: 32), hash: Data(repeating: UInt8(seq + 1), count: 32))
        }
        let signed = Data("approval-v1".utf8) + Data(repeating: 7, count: 40)
        let approval = ApprovalAudit(requestId: 41, agentRequest: "toolu_01HcV9", optionId: 1, option: "Yes", tool: "Bash",
                                     summary: "git push --force-with-lease origin feat/mp", signed: signed, sig: Data((0..<64).map { UInt8($0 &* 37 & 0xff) }))
        let denied = ApprovalAudit(requestId: 44, agentRequest: "toolu_01KqZ2", optionId: 3, option: "No", tool: "Bash",
                                   summary: "rm -rf ~/projects/gudo/target", signed: signed, sig: Data((0..<64).map { UInt8($0 &* 11 & 0xff) }))
        return AuditPage(records: [
            record(1, 86_400_000, .grantRegistered, owner, "grant for Mira Holt: driver+approver on daemon"),
            record(2, 1_800_000, .grantRedeemed, mira, "Mira Holt redeemed an invite"),
            record(3, 1_800_000, .join, mira, "joined"),
            record(4, 900_000, .join, jon, "joined"),
            record(5, 600_000, .lease, mira, "took control of pane 2 (given by Alex Kim)"),
            record(6, 420_000, .prompt, sam, "prompt to pane 2: 214 chars, sha256 9f1c…"),
            record(7, 300_000, .approval, mira, "approved Bash", approval: approval),
            record(8, 240_000, .denied, nil, "refused join: grant expired (Old laptop)"),
            record(9, 120_000, .approval, owner, "denied Bash", approval: denied),
            record(10, 60_000, .revoked, owner, "revoked grant 1a2b3c4d (Old laptop)"),
        ], total: 10, chainOk: true)
    }()
}

nonisolated final class MockMultiplayerClient: MultiplayerClientAPI {
    func setMultiplayerListener(listener: any MultiplayerListener) {}
    func me() -> JoinInfo? { nil }
    func participantList() -> [GudoCore.Participant] { [] }
    func lease(paneId: UInt64) -> Lease? { nil }
    func setTyping(paneId: UInt64, typing: Bool) {}
    func participants() async throws -> [GudoCore.Participant] { [] }
    func setName(name: String) async throws {}
    func createInvite(options: InviteOptions) async throws -> CreatedInvite {
        try await Task.sleep(for: .milliseconds(250))
        let link = "gudo://join/" + "ab3kq7m2d4x9p5r8t6v1w3y5z7c2e4g6j8l0n3q5s7u9w2y4a6c8e0g2i4k6m8o0q2s4u6w8y0a3c5e7g9i1k3m5o7q9s2u4w6y8a0c2e4g6i8k0m2o4q6s8u0w2y4b6d8f0h2j4l6n8p0r2t4v6x8z1b3d5f7h9j2l4n6p8r1t3v5x7z9"
        return CreatedInvite(link: link, qrPayload: link.uppercased(), grantId: "5e7a".padding(toLength: 32, withPad: "0", startingAt: 0),
                             expiresMs: options.ttlSecs.map { UInt64(Date.now.timeIntervalSince1970 * 1000) + $0 * 1000 })
    }
    func listGrants() async throws -> [GrantInfo] { MockMultiplayer.grants }
    func listDevices() async throws -> [DeviceInfo] { MockMultiplayer.devices }
    func canManageDevices() -> Bool { true }
    func pairingCode() async throws -> PairingCode {
        let link = "gudo://pair/" + "ahyuuihplhmobkzj6ntbzl7tjjpizmjbt4iuzfij4i7nbikwr743aaiap4aaaaoz54bqa7ngnmxxqbhpjewwquhnd24yruwkwmrux63wwshwtbmtrb73nksj5dskb6ezgttqcaq"
        return PairingCode(link: link, qrPayload: link.uppercased(), expiresMs: UInt64((Date.now.timeIntervalSince1970 + 600) * 1000))
    }
    func renameDevice(device: String, name: String) async throws {}
    func revoke(target: RevokeTarget) async throws -> RevokeResult { RevokeResult(grants: [], devices: [], disconnected: 1) }
    func takeControl(paneId: UInt64, force: Bool) async throws -> LeaseOutcome { .pending(holder: MockMultiplayer.mira.principal) }
    func releaseControl(paneId: UInt64) async throws {}
    func answerControl(paneId: UInt64, give: Bool) async throws -> LeaseOutcome { .granted(lease: Lease(paneId: paneId, holder: nil, sinceMs: 0, mode: .free)) }
    func giveControl(paneId: UInt64, to: String) async throws -> LeaseOutcome { .granted(lease: Lease(paneId: paneId, holder: to, sinceMs: 0, mode: .leased)) }
    func leases() async throws -> [Lease] { [] }
    func prompt(paneId: UInt64, text: String, submit: Bool) async throws -> UInt32 { UInt32(text.count) }
    func audit(after: UInt64?, limit: UInt32) async throws -> AuditPage { MockMultiplayer.audit }
    func pendingKnocks() -> [Knock] { [] }
    func admitKnock(knockId: UInt64, roles: [Role], sinceJoin: Bool, ttlSecs: UInt64?) async throws -> GrantInfo {
        MockMultiplayer.grant("g6", "Priya Nair", roles, .session(sessionId: 1), expires: MockMultiplayer.now + 7 * 86_400_000, uses: 1, bound: 1, issuedAgo: 0)
    }
    func denyKnock(knockId: UInt64) async throws {}
    func approvalPolicyCached() -> ApprovalPolicy? { nil }
    func approvalStatuses() -> [ApprovalStatus] { [] }
    func setApprovalPolicy(sessionId: UInt64, policy: ApprovalPolicy) async throws -> ApprovalPolicy { policy }
    func claimApproval(requestId: UInt64, claim: Bool) async throws -> ApprovalStatus {
        ApprovalStatus(paneId: 3, requestId: requestId, risk: .any, mode: .claim, approvals: [], needed: 1,
                       claimedBy: claim ? ApprovalVote(actor: MockMultiplayer.owner, name: "Alex Kim", atMs: MockMultiplayer.now) : nil)
    }
}
