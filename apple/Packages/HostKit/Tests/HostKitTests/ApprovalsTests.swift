import Foundation
import Synchronization
import Testing
import UnnamedCore
@testable import HostKit

/// A daemon client's approvals half: records requests, replays pushes.
nonisolated final class FakeApprovalClient: ApprovalClientAPI, @unchecked Sendable {
    struct State {
        var listener: (any ApprovalListener)?
        var edited: [(UInt64, UInt32, String)] = []
        var added: [(UInt64, UInt64?, ApprovalRuleMatch, UInt32, UInt32)] = []
        var revoked: [String] = []
        var revokeError: ApprovalError?
    }

    let state = Mutex(State())

    func push(_ event: ApprovalEvent) {
        state.withLock { $0.listener }?.onApprovalEvent(event: event)
    }

    func setApprovalListener(listener: any ApprovalListener) { state.withLock { $0.listener = listener } }
    func approvalInfo(paneId: UInt64) -> ApprovalInfo? { nil }
    func autoApproveRules(paneId: UInt64) -> [AutoApproveRule] { [] }
    func approveEdited(requestId: UInt64, optionId: UInt32, input: String) async throws {
        state.withLock { $0.edited.append((requestId, optionId, input)) }
    }
    func addAutoApprove(paneId: UInt64, requestId: UInt64?, matcher: ApprovalRuleMatch, minutes: UInt32, maxTurns: UInt32) async throws -> String {
        state.withLock { $0.added.append((paneId, requestId, matcher, minutes, maxTurns)) }
        return String(repeating: "ab", count: 16)
    }
    func revokeAutoApprove(id: String) async throws {
        if let error = state.withLock({ $0.revokeError }) { throw error }
        state.withLock { $0.revoked.append(id) }
    }
}

@MainActor
@Suite struct ApprovalSessionTests {
    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func info(request: UInt64 = 7) -> ApprovalInfo {
        ApprovalInfo(paneId: 3, requestId: request, tool: "Bash", editableInput: "cargo test -p x",
                     like: ApprovalRuleMatch(tool: "Bash", prefix: "cargo test"))
    }

    @Test func requestExtrasAreKeptPerPaneAndCheckedAgainstTheRequest() async throws {
        let client = FakeApprovalClient()
        let session = ApprovalSession()
        session.attach(client)
        #expect(session.isAvailable)

        client.push(.request(info: info()))
        await settle { session.requests[3] != nil }
        let request = try #require(session.request(pane: 3, blockedOn: 7))
        #expect(request.editableInput == "cargo test -p x")
        #expect(request.like == ApprovalMatch(tool: "Bash", prefix: "cargo test"))
        #expect(request.like?.label == "cargo test …")
        // A newer request on the pane: the old extras do not apply to it.
        #expect(session.request(pane: 3, blockedOn: 8) == nil)

        try await session.approveEdited(paneId: 3, requestId: 7, optionId: 0, input: "cargo test -p y")
        #expect(client.state.withLock { $0.edited.map(\.2) } == ["cargo test -p y"])
        #expect(session.requests[3] == nil)
    }

    @Test func approveAllLikeThisAddsAScopedRuleAndRevokeEndsIt() async throws {
        let client = FakeApprovalClient()
        let session = ApprovalSession()
        session.attach(client)
        client.push(.request(info: info()))
        await settle { session.requests[3] != nil }

        let id = try await session.approveAllLikeThis(
            paneId: 3, requestId: 7, match: ApprovalMatch(tool: "Bash", prefix: "cargo test"), minutes: 60, turns: 10)
        let added = try #require(client.state.withLock { $0.added.first })
        #expect(added.0 == 3 && added.1 == 7 && added.2.prefix == "cargo test" && added.3 == 60 && added.4 == 10)
        #expect(session.requests[3] == nil)

        let expires = UInt64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        client.push(.rules(paneId: 3, rules: [AutoApproveRule(
            id: id, paneId: 3, matcher: ApprovalRuleMatch(tool: "Bash", prefix: "cargo test"),
            expiresAtMs: expires, maxTurns: 10, turnsUsed: 3, uses: 2, grantedBy: "Ana")]))
        await settle { session.rules[3] != nil }
        let rule = try #require(session.rules[3]?.first)
        #expect(rule.turnsLeft == 8)
        #expect(rule.uses == 2)
        #expect(rule.grantedBy == "Ana")
        #expect(abs(rule.expiresAt.timeIntervalSinceNow - 3600) < 5)

        // A rule that already lapsed on the daemon still disappears.
        client.state.withLock { $0.revokeError = .NotFound }
        try await session.revoke(paneId: 3, ruleId: id)
        #expect(session.rules[3] == nil)

        // The daemon's empty list clears, and a dropped connection forgets everything.
        client.push(.request(info: info(request: 9)))
        await settle { session.requests[3] != nil }
        client.push(.reset)
        await settle { session.requests.isEmpty }
        #expect(session.rules.isEmpty)
    }

    @Test func labelsSayWhatARuleCovers() {
        #expect(ApprovalMatch(tool: "Edit", prefix: "").label == "any Edit")
        #expect(ApprovalMatch(tool: "Bash", prefix: "rm").label == "rm …")
    }
}
