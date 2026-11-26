import GudoCore
import HostKit

/// A request and a standing yes for the cross-host snapshots.
enum CrossHostFixtures {
    static let card = CrossHostCard(
        from: "studio", requestId: 41, agent: "Claude", paneId: 3, fromName: "studio", to: "ops", toName: "ops",
        tool: "cmd_run", verb: .input, action: "run $ npm test -- --watch=false in p4", title: "", guestDriving: nil,
        expiresAtMs: 4_000_000_000_000)

    static let allow = StandingAllow(
        from: "studio", fromName: "studio", to: "ops", toName: "ops", paneId: 3, agent: "Claude", all: true)
}
