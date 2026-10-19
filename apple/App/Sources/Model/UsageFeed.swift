import Foundation
import HostKit
import Observation
import UnnamedCore

/// and the Inbox show it. Views call `watch` / `unwatch` as they appear and disappear, so a
/// daemon only refreshes while something is on screen.
@MainActor
protocol UsageFeed: AnyObject, Observable {
    /// Hosts that can report usage now (connected daemons that offer it), in the hosts' order.
    var reportingHosts: [UsageHost] { get }
    /// The host's report while watched; nil when there is nothing to show.
    func usage(forHost id: String) -> AgentUsageReport?
    func watch(host id: String)
    func unwatch(host id: String)
}

struct UsageHost: Identifiable, Hashable {
    var id: String
    var name: String
}

/// The daemons' reports (`DaemonWorkspace.usage`).
@MainActor
@Observable
final class LiveUsageFeed: UsageFeed {
    @ObservationIgnored let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    private func daemon(_ id: String) -> DaemonConnection? {
        app.hosts.connection(id) as? DaemonConnection
    }

    var reportingHosts: [UsageHost] {
        app.hosts.entries.compactMap { entry in
            guard let daemon = daemon(entry.id), daemon.status.isLive, daemon.daemonInfo?.agentUsage == true else { return nil }
            return UsageHost(id: entry.id, name: entry.name)
        }
    }

    func usage(forHost id: String) -> AgentUsageReport? {
        daemon(id)?.existingWorkspace?.usage
    }

    func watch(host id: String) {
        daemon(id)?.workspace.beginWatchingUsage()
    }

    func unwatch(host id: String) {
        daemon(id)?.existingWorkspace?.endWatchingUsage()
    }
}

/// A fixed report for every host (`-fakeUsage YES`, `-mock`): screenshots and the UI test.
@MainActor
@Observable
final class FakeUsageFeed: UsageFeed {
    @ObservationIgnored private let hosts: () -> [UsageHost]
    private(set) var watched: [String: Int] = [:]

    init(hosts: @escaping () -> [UsageHost]) {
        self.hosts = hosts
    }

    var reportingHosts: [UsageHost] { hosts() }

    func usage(forHost id: String) -> AgentUsageReport? {
        Self.report()
    }

    func watch(host id: String) { watched[id, default: 0] += 1 }
    func unwatch(host id: String) { watched[id, default: 0] -= 1 }

    /// Claude at 62 % of its 5-hour window (quiet), Codex at 92 % of its week (amber).
    static func report(now: Date = .now) -> AgentUsageReport {
        let ms = { (d: TimeInterval) in UInt64((now.timeIntervalSince1970 + d) * 1000) }
        return AgentUsageReport(agents: [
            AgentUsage(
                agent: .claude, plan: "max",
                windows: [
                    UsageWindow(name: "5h", minutes: 300, usedPermille: 620, resetsAtMs: ms(2 * 3600 + 20 * 60), limited: false),
                    UsageWindow(name: "weekly", minutes: 10_080, usedPermille: 410, resetsAtMs: ms(3 * 86_400), limited: false),
                ],
                source: .statusLine, asOfMs: ms(-120), note: nil),
            AgentUsage(
                agent: .codex, plan: "plus",
                windows: [
                    UsageWindow(name: "5h", minutes: 300, usedPermille: 300, resetsAtMs: ms(3600), limited: false),
                    UsageWindow(name: "weekly", minutes: 10_080, usedPermille: 920, resetsAtMs: ms(2 * 86_400), limited: false),
                ],
                source: .localLog, asOfMs: ms(-600), note: nil),
        ])
    }
}
