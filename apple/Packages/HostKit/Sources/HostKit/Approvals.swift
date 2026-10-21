import Foundation
import Observation
import os
import UnnamedCore

// Approval extras (docs/DAEMON.md §6.10): approve an agent's request with an edited command, and
// "approve all like this for this task" rules the daemon applies until they lapse (time, turns,
// the agent session) or are revoked. Views bind to `ApprovalSession` (one per
// `DaemonConnection`); plain approve / deny stays `DaemonConnection.decide`.

/// The approvals half of `UnnamedCore.DaemonClient`, so the session can be tested with a fake.
nonisolated public protocol ApprovalClientAPI: AnyObject, Sendable {
    func setApprovalListener(listener: any ApprovalListener)
    func approvalInfo(paneId: UInt64) -> ApprovalInfo?
    func autoApproveRules(paneId: UInt64) -> [AutoApproveRule]
    func approveEdited(requestId: UInt64, optionId: UInt32, input: String) async throws
    func addAutoApprove(paneId: UInt64, requestId: UInt64?, matcher: ApprovalRuleMatch, minutes: UInt32, maxTurns: UInt32) async throws -> String
    func revokeAutoApprove(id: String) async throws
}

extension DaemonClient: ApprovalClientAPI {}

nonisolated final class ApprovalRelay: ApprovalListener {
    private let handler: @Sendable (ApprovalEvent) -> Void

    init(_ handler: @escaping @Sendable (ApprovalEvent) -> Void) {
        self.handler = handler
    }

    func onApprovalEvent(event: ApprovalEvent) {
        handler(event)
    }
}

/// What "approve all like this" covers: a tool, and for shell commands how the command starts.
nonisolated public struct ApprovalMatch: Hashable, Sendable {
    public var tool: String
    /// The command it starts with (`cargo test`); empty: any use of the tool.
    public var prefix: String

    public init(tool: String, prefix: String) {
        self.tool = tool
        self.prefix = prefix
    }

    /// "cargo test …", or "any Edit".
    public var label: String {
        prefix.isEmpty ? "any \(tool)" : "\(prefix) …"
    }

    init(_ m: ApprovalRuleMatch) {
        self.init(tool: m.tool, prefix: m.prefix)
    }

    var core: ApprovalRuleMatch { ApprovalRuleMatch(tool: tool, prefix: prefix) }
}

/// What may be done with the request a pane's agent is blocked on, beyond approve and deny.
nonisolated public struct ApprovalRequestInfo: Hashable, Sendable {
    public var paneId: UInt64
    /// Matches the pane's `AgentState.blocked` request id while it is current.
    public var requestId: UInt64
    public var tool: String
    /// The command a person may edit before approving (Claude Code's Bash); nil: not editable.
    public var editableInput: String?
    /// What "approve all like this" would cover; nil: not offered for this request.
    public var like: ApprovalMatch?

    public init(paneId: UInt64, requestId: UInt64, tool: String, editableInput: String? = nil, like: ApprovalMatch? = nil) {
        self.paneId = paneId
        self.requestId = requestId
        self.tool = tool
        self.editableInput = editableInput
        self.like = like
    }

    init(_ i: ApprovalInfo) {
        self.init(paneId: i.paneId, requestId: i.requestId, tool: i.tool, editableInput: i.editableInput,
                  like: i.like.map(ApprovalMatch.init))
    }
}

/// An auto-approve rule in force on a pane.
nonisolated public struct AutoApproveRuleInfo: Identifiable, Hashable, Sendable {
    /// For `ApprovalSession.revoke`.
    public var id: String
    public var paneId: UInt64
    public var match: ApprovalMatch
    public var expiresAt: Date
    /// Turns it still covers, the current one included (1: this turn only).
    public var turnsLeft: Int
    /// Requests it has approved.
    public var uses: Int
    /// Who added it (their display name; may be empty).
    public var grantedBy: String

    public init(id: String, paneId: UInt64, match: ApprovalMatch, expiresAt: Date, turnsLeft: Int, uses: Int, grantedBy: String) {
        self.id = id
        self.paneId = paneId
        self.match = match
        self.expiresAt = expiresAt
        self.turnsLeft = turnsLeft
        self.uses = uses
        self.grantedBy = grantedBy
    }

    init(_ r: AutoApproveRule) {
        self.init(
            id: r.id, paneId: r.paneId, match: ApprovalMatch(r.matcher),
            expiresAt: Date(timeIntervalSince1970: Double(r.expiresAtMs) / 1000),
            turnsLeft: max(0, Int(r.maxTurns) - Int(r.turnsUsed) + 1), uses: Int(r.uses), grantedBy: r.grantedBy)
    }
}

/// Approval extras and auto-approve rules on one daemon connection.
@MainActor
@Observable
public final class ApprovalSession {
    /// What may be done with each pane's open request (by pane id). May be stale: use
    /// `request(pane:blockedOn:)`, which checks it against the request the pane is blocked on.
    public private(set) var requests: [UInt64: ApprovalRequestInfo] = [:]
    /// The rules in force, by pane id, oldest first.
    public private(set) var rules: [UInt64: [AutoApproveRuleInfo]] = [:]

    @ObservationIgnored private var client: (any ApprovalClientAPI)?
    @ObservationIgnored private var pump: Task<Void, Never>?

    private static let log = Logger(subsystem: Log.subsystem, category: "approvals")

    public init() {}

    /// Whether the connection can approve with edits and add rules.
    public var isAvailable: Bool { client != nil }

    /// Starts following a client's approval pushes (called once per dial; public for tests).
    public func attach(_ client: any ApprovalClientAPI) {
        self.client = client
        pump?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: ApprovalEvent.self)
        client.setApprovalListener(listener: ApprovalRelay { continuation.yield($0) })
        pump = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    func detach() {
        pump?.cancel()
        pump = nil
        client = nil
        requests = [:]
        rules = [:]
    }

    /// The extras for `pane`'s request `requestId`, if the daemon sent them for that request.
    public func request(pane: UInt64, blockedOn requestId: UInt64) -> ApprovalRequestInfo? {
        guard let info = requests[pane], info.requestId == requestId else { return nil }
        return info
    }

    /// Applies one push (public so previews and tests can drive the session without a daemon).
    public func apply(_ event: ApprovalEvent) {
        switch event {
        case .request(let info):
            requests[info.paneId] = ApprovalRequestInfo(info)
        case .rules(let pane, let list):
            rules[pane] = list.isEmpty ? nil : list.map(AutoApproveRuleInfo.init)
            Self.log.info("pane \(pane): \(list.count) auto-approve rule(s)")
        case .reset:
            requests = [:]
            rules = [:]
        }
    }

    /// Approves `requestId` on `paneId` with its allow option `optionId`, running `input`
    /// instead of what the agent asked for.
    ///
    /// - Throws: `ApprovalError` (`.NotEditable` when the agent cannot take it).
    public func approveEdited(paneId: UInt64, requestId: UInt64, optionId: UInt32, input: String) async throws {
        guard let client else { throw ApprovalError.Disconnected }
        try await client.approveEdited(requestId: requestId, optionId: optionId, input: input)
        if requests[paneId]?.requestId == requestId { requests[paneId] = nil }
    }

    /// Approves `requestId` and adds a rule approving what `match` covers on `paneId` for
    /// `minutes` and `turns` agent turns (the current one included). Returns the rule's id.
    ///
    /// - Throws: `ApprovalError` (`.Invalid` past 8 h or 50 turns, `.Forbidden` without Approver).
    @discardableResult
    public func approveAllLikeThis(paneId: UInt64, requestId: UInt64, match: ApprovalMatch, minutes: Int, turns: Int) async throws -> String {
        guard let client else { throw ApprovalError.Disconnected }
        let id = try await client.addAutoApprove(
            paneId: paneId, requestId: requestId, matcher: match.core,
            minutes: UInt32(clamping: minutes), maxTurns: UInt32(clamping: turns))
        if requests[paneId]?.requestId == requestId { requests[paneId] = nil }
        return id
    }

    /// Revokes rule `ruleId` on `paneId`; it approves nothing from now on.
    public func revoke(paneId: UInt64, ruleId: String) async throws {
        guard let client else { throw ApprovalError.Disconnected }
        do {
            try await client.revokeAutoApprove(id: ruleId)
        } catch ApprovalError.NotFound {
            // Already over (expired, turns used up): same outcome.
        }
        rules[paneId]?.removeAll { $0.id == ruleId }
        if rules[paneId]?.isEmpty == true { rules[paneId] = nil }
    }
}
