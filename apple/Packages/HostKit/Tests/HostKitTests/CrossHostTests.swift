import Foundation
import Synchronization
import Testing
import GudoCore
@testable import HostKit

/// The relay's half: records what the session asks of it.
nonisolated final class FakeCrossHostRelay: CrossHostRelayAPI, @unchecked Sendable {
    enum Call: Equatable {
        case add(String, String, String), remove(String), pair(String, String, Bool), endAllows(String, String)
        case answer(String, UInt64, CrossHostChoice)
    }

    let calls = Mutex<[Call]>([])
    let listener: Mutex<(any CrossHostListener)?> = Mutex(nil)

    func addOwnerHost(id: String, name: String, client: DaemonClient) { record(.add(id, name, "owner")) }
    func addGuestHost(id: String, name: String) { record(.add(id, name, "guest")) }
    func addSshHost(id: String, name: String) { record(.add(id, name, "ssh")) }
    func addUnreachedHost(id: String, name: String) { record(.add(id, name, "unreached")) }
    func removeHost(id: String) { record(.remove(id)) }
    func setPair(from: String, to: String, enabled: Bool) { record(.pair(from, to, enabled)) }
    func endAllows(from: String, to: String) { record(.endAllows(from, to)) }
    func answer(from: String, requestId: UInt64, choice: CrossHostChoice) { record(.answer(from, requestId, choice)) }

    private func record(_ call: Call) { calls.withLock { $0.append(call) } }
    var recorded: [Call] { calls.withLock { $0 } }
}

@MainActor
@Suite struct CrossHostSessionTests {
    private func defaults() -> UserDefaults {
        let name = "cross-host-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func card(_ id: UInt64, verb: CrossHostVerb = .input) -> CrossHostCard {
        CrossHostCard(
            from: "mac", requestId: id, agent: "Claude", paneId: 3, fromName: "mac", to: "ops", toName: "ops",
            tool: "cmd_run", verb: verb, action: "run $ npm test", title: "Claude on mac wants to run $ npm test on ops",
            guestDriving: nil, expiresAtMs: 2_000_000_000_000)
    }

    @Test func pairsAreOffUntilTurnedOnEachDirectionOnItsOwnAndKept() {
        let store = defaults()
        let relay = FakeCrossHostRelay()
        let session = CrossHostSession(defaults: store)
        session.start { _ in relay }
        #expect(session.pairs.isEmpty)
        #expect(!session.isEnabled(from: "mac", to: "ops"))

        session.setEnabled(true, from: "mac", to: "ops")
        #expect(session.isEnabled(from: "mac", to: "ops"))
        #expect(!session.isEnabled(from: "ops", to: "mac"), "the other direction is its own switch")
        #expect(relay.recorded == [.pair("mac", "ops", true)])

        // A new launch reads the switches back and hands them to the relay.
        let again = FakeCrossHostRelay()
        let relaunched = CrossHostSession(defaults: store)
        relaunched.start { _ in again }
        #expect(relaunched.isEnabled(from: "mac", to: "ops"))
        #expect(again.recorded == [.pair("mac", "ops", true)])

        // Off is the revoke: the relay ends every standing yes for the pair.
        relaunched.setEnabled(false, from: "mac", to: "ops")
        #expect(again.recorded.last == .pair("mac", "ops", false))
        #expect(CrossHostSession(defaults: store).pairs.isEmpty)
    }

    @Test func requestsComeAndGoAndAnAnswerReachesTheRelay() async {
        let relay = FakeCrossHostRelay()
        let session = CrossHostSession(defaults: defaults())
        session.start { listener in
            relay.listener.withLock { $0 = listener }
            return relay
        }
        let listener = relay.listener.withLock { $0 }
        listener?.onCard(card: card(5))
        listener?.onCard(card: card(6, verb: .read))
        await settle { session.requests.count == 2 }
        #expect(session.requests.map(\.requestId) == [5, 6])
        let first = session.requests[0]
        #expect(first.headline == "Claude on mac wants to reach ops")
        #expect(first.detail == "It wants to run $ npm test on ops.")
        #expect(session.requests[1].detail.contains("goes to the agent and its model provider"))

        session.answer(first, .allowAgent)
        #expect(session.requests.map(\.requestId) == [6])
        #expect(relay.recorded.last == .answer("mac", 5, .allowAgent))

        // Answered on another device, or expired: it goes.
        listener?.onCardClosed(from: "mac", requestId: 6)
        await settle { session.requests.isEmpty }
        #expect(session.requests.isEmpty)

        listener?.onStanding(allows: [StandingAllow(from: "mac", fromName: "mac", to: "ops", toName: "ops", paneId: 3, agent: "Claude", all: true)])
        await settle { !session.allows.isEmpty }
        #expect(session.allows(from: "mac", to: "ops").first?.summary == "Claude on mac may do anything on ops until its pane closes")
        session.endAllows(from: "mac", to: "ops")
        #expect(relay.recorded.last == .endAllows("mac", "ops"))
    }

    @Test func hostsAreAddedOnceReplacedWhenTheyChangeAndForgotten() {
        let relay = FakeCrossHostRelay()
        let session = CrossHostSession(defaults: defaults())
        session.start { _ in relay }
        let hosts = [
            CrossHostMember(id: "mac", name: "mac", link: .unreached),
            CrossHostMember(id: "theirs", name: "theirs", link: .guest),
            CrossHostMember(id: "pi", name: "pi", link: .ssh),
        ]
        session.sync(hosts)
        session.sync(hosts)
        #expect(relay.recorded == [
            .add("mac", "mac", "unreached"), .add("theirs", "theirs", "guest"), .add("pi", "pi", "ssh"),
        ])
        session.setEnabled(true, from: "mac", to: "pi")
        session.sync([CrossHostMember(id: "mac", name: "studio", link: .unreached)])
        let latest = Array(relay.recorded.suffix(3))
        #expect(Set(latest.prefix(2).map { "\($0)" }) == Set([FakeCrossHostRelay.Call.remove("theirs"), .remove("pi")].map { "\($0)" }))
        #expect(latest.last == .add("mac", "studio", "unreached"))
        #expect(session.pairs.isEmpty, "a forgotten host's pairs go with it")
    }

    @Test func guestHostsNeverRelayAndAreNeverTargets() {
        var record = HostRecord(name: "theirs", kind: .daemon)
        record.guest = true
        #expect(CrossHostSession.link(record, nil) == .guest)
        #expect(CrossHostSession.link(HostRecord(name: "pi", kind: .ssh), nil) == .ssh)
        #expect(CrossHostSession.link(HostRecord(name: "ops", kind: .daemon), nil) == .unreached)
    }
}
