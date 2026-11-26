import Foundation
import GudoCore
import HostKit
import Testing
@testable import App

@MainActor
@Suite struct CrossHostViewsTests {
    private func session() -> CrossHostSession {
        let name = "cross-host-views-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return CrossHostSession(defaults: defaults)
    }

    @Test func aHostsRowSaysWhichHostsAgentsMayReachIt() {
        let hosts = [
            CrossHostHosts.Host(id: "studio", name: "studio"), CrossHostHosts.Host(id: "ops", name: "ops"),
            CrossHostHosts.Host(id: "mini", name: "mini"),
        ]
        let session = session()
        #expect(CrossHostHosts.summary(hosts[1], hosts: hosts, session: session) == "Off")
        session.setEnabled(true, from: "studio", to: "ops")
        #expect(CrossHostHosts.summary(hosts[1], hosts: hosts, session: session) == "From studio")
        #expect(CrossHostHosts.summary(hosts[0], hosts: hosts, session: session) == "Off", "each direction is its own switch")
        session.setEnabled(true, from: "mini", to: "ops")
        #expect(CrossHostHosts.summary(hosts[1], hosts: hosts, session: session) == "From studio and mini")
    }

    @Test func theCardNamesTheAgentBothHostsAndTheExactAction() {
        let request = CrossHostRequestInfo(
            from: "studio", requestId: 4, agent: "Claude", fromName: "studio", to: "ops", toName: "ops",
            action: "run $ npm test", guestDriving: "bob")
        #expect(request.headline == "Claude on studio wants to reach ops")
        #expect(request.detail == "It wants to run $ npm test on ops. Asked while bob is driving the agent.")
        #expect(!request.detail.contains("—") && !request.detail.contains("–"))
    }
}
