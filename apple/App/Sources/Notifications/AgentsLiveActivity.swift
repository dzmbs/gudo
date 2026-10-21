#if os(iOS)
import ActivityKit
import Foundation
import HostKit
import NotifyKit
import os
import UnnamedCore

/// The agents Live Activity the daemons push (docs/PUSH.md §6). The app only hands out tokens:
/// the push-to-start token goes into every daemon's push registration (`activityCap`), and
/// once an activity runs (started by a daemon's push, possibly while the app was not running:
/// iOS wakes it to deliver the new token) its update token goes to every connected daemon that
/// offers Live Activities. When the activity ends or is dismissed the daemons are told, so they
/// stop updating it and start a new one only for the next busy spell. Push builds only (the
/// tokens need the APNs entitlement); without one the per-run local activities stay.
@MainActor
final class AgentsLiveActivity {
    static let shared = AgentsLiveActivity()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "activity")

    /// The push-to-start token (registered with every daemon).
    private(set) var startToken: Data?
    /// The running activity's update token.
    private(set) var updateToken: Data?
    private var installed = false
    private var followed: Set<String> = []

    /// The daemons drive the activity (a push-to-start token exists): the app does not start
    /// its own per-run activities beside it.
    var isPushDriven: Bool { startToken != nil }

    func install() {
        guard !installed, AppNotifications.pushEnabled else { return }
        installed = true
        Task {
            for await token in Activity<AgentsActivityAttributes>.pushToStartTokenUpdates {
                startToken = token
                Self.log.info("live activity push-to-start token")
                await AppNotifications.shared.registerPush()
            }
        }
        Task {
            for await activity in Activity<AgentsActivityAttributes>.activityUpdates {
                follow(activity)
            }
        }
        for activity in Activity<AgentsActivityAttributes>.activities { follow(activity) }
    }

    /// One activity for all hosts: two hosts may each start one at once; the newer is ended.
    private func follow(_ activity: Activity<AgentsActivityAttributes>) {
        let id = activity.id
        guard !followed.contains(id) else { return }
        let running = Activity<AgentsActivityAttributes>.activities.filter { $0.activityState == .active }
        if running.count > 1, running.first?.id != id {
            Self.log.info("ending a second agents activity")
            Task.detached { await Self.live(id)?.end(nil, dismissalPolicy: .immediate) }
            return
        }
        followed.insert(id)
        Task.detached {
            guard let live = await Self.live(id) else { return }
            for await token in live.pushTokenUpdates {
                await AgentsLiveActivity.shared.updateTokenChanged(token)
            }
        }
        Task.detached {
            guard let live = await Self.live(id) else { return }
            for await state in live.activityStateUpdates where state == .ended || state == .dismissed {
                await AgentsLiveActivity.shared.ended(id)
                break
            }
        }
    }

    nonisolated private static func live(_ id: String) async -> Activity<AgentsActivityAttributes>? {
        Activity<AgentsActivityAttributes>.activities.first { $0.id == id }
    }

    private func updateTokenChanged(_ token: Data) async {
        updateToken = token
        await sendUpdateToken()
    }

    private func ended(_ id: String) async {
        followed.remove(id)
        updateToken = nil
        await sendUpdateToken()
    }

    /// The current update token (or that none runs) to every connected owner daemon; also
    /// after the app registers for pushes (a daemon that connected later).
    func sendUpdateToken() async {
        let hosts = AppModel.shared.hosts
        for (id, connection) in hosts.connections where connection is DaemonConnection && hosts.record(id)?.isGuest == false {
            do {
                try await hosts.registerActivityToken(hostId: id, token: updateToken, environment: AppNotifications.apnsEnvironment)
            } catch {
                Self.log.error("live activity token host=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
