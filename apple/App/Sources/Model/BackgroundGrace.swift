#if os(iOS)
import HostKit
import UIKit

/// Keeps host connections up for the background time iOS grants, so a quick visit to another app
/// comes back to live terminals and editors. Connections resume before the app is active again,
/// so pages' timers find the link up.
@MainActor
final class BackgroundGrace {
    static let shared = BackgroundGrace()

    private var task: UIBackgroundTaskIdentifier = .invalid
    private var suspended = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackgroundGrace.shared.returned() }
        }
    }

    func enter() {
        guard task == .invalid, !suspended else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Keep host connections") {
            MainActor.assumeIsolated { BackgroundGrace.shared.expire() }
        }
        if task == .invalid { expire() }
    }

    func returned() {
        end()
        guard suspended else { return }
        suspended = false
        AppModel.shared.hosts.foreground()
    }

    private func expire() {
        AppModel.log.info("background time ran out: suspending host connections")
        suspended = true
        AppModel.shared.hosts.background()
        end()
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif
