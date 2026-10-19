#if os(iOS)
import ActivityKit
import Foundation
import HostKit
import NotifyKit
import os
import PaneLayout
import UnnamedCore

/// A Live Activity per agent run, updated locally while the app is alive: started when an
/// agent starts working, "Needs you" when it blocks, ended a few minutes after it finishes.
/// (Push updates need the daemon to send them; docs/PUSH.md §6.)
@MainActor
final class AgentLiveActivities {
    static let shared = AgentLiveActivities()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "activity")

    private var activities: [String: Activity<AgentRunAttributes>] = [:]
    private var started: [String: Date] = [:]
    private var installed = false

    /// `-liveActivities NO` turns it off (UI tests).
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "liveActivities") as? Bool ?? true
    }

    func install() {
        guard !installed, enabled else { return }
        installed = true
        follow()
    }

    private func follow() {
        let hosts = AppModel.shared.hosts
        var seen: Set<String> = []
        for (hostId, connection) in hosts.connections {
            guard let daemon = connection as? DaemonConnection else { continue }
            let hostName = hosts.record(hostId)?.name ?? "Host"
            for (pane, meta) in daemon.meta {
                guard let agent = meta.agent else { continue }
                let key = "\(hostId)/\(pane.rawValue)"
                seen.insert(key)
                update(key: key, hostId: hostId, hostName: hostName, pane: pane, agent: agent, title: meta.title)
            }
        }
        for key in activities.keys where !seen.contains(key) { end(key, phase: .done, headline: "Pane closed") }
        withObservationTracking {
            for connection in hosts.connections.values {
                _ = (connection as? DaemonConnection)?.meta
            }
        } onChange: {
            Task { @MainActor in AgentLiveActivities.shared.follow() }
        }
    }

    private func update(key: String, hostId: String, hostName: String, pane: PaneId, agent: AgentStatus, title: String) {
        let phase: AgentRunState.Phase?
        var headline = title
        switch agent.state {
        case .running: phase = .working
        case .blocked(_, let summary, _):
            phase = .blocked
            headline = summary
        case .done: phase = .done
        case .idle: phase = nil
        }
        guard let phase else { return }
        if let activity = activities[key] {
            let state = AgentRunState(phase: phase, headline: headline, startedAt: started[key] ?? .now)
            guard activity.content.state.phase != phase || activity.content.state.headline != headline else { return }
            let id = activity.id
            let title = "\(AgentKind(agent.kind).title) needs you"
            let body = headline
            Task.detached {
                guard let live = Activity<AgentRunAttributes>.activities.first(where: { $0.id == id }) else { return }
                await live.update(ActivityContent(state: state, staleDate: .now + 15 * 60, relevanceScore: phase == .blocked ? 100 : 50),
                                  alertConfiguration: phase == .blocked ? AlertConfiguration(title: "\(title)", body: "\(body)", sound: .default) : nil)
            }
            if phase.isFinal { end(key, phase: phase, headline: headline) }
        } else if phase == .working || phase == .blocked {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let now = Date.now
            started[key] = now
            let attributes = AgentRunAttributes(agent: AgentKind(agent.kind).title, hostName: hostName, hostId: hostId, paneId: pane.rawValue, task: title)
            do {
                activities[key] = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: AgentRunState(phase: phase, headline: headline, startedAt: now), staleDate: now + 15 * 60),
                    pushType: nil)
            } catch {
                Self.log.error("live activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func end(_ key: String, phase: AgentRunState.Phase, headline: String) {
        guard let activity = activities.removeValue(forKey: key) else { return }
        let state = AgentRunState(phase: phase, headline: headline, startedAt: started.removeValue(forKey: key) ?? .now)
        let id = activity.id
        Task.detached {
            guard let live = Activity<AgentRunAttributes>.activities.first(where: { $0.id == id }) else { return }
            await live.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 10 * 60))
        }
    }
}
#endif
