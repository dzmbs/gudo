import Foundation
import HostKit
#if os(iOS)
import UIKit

/// Sets the notification delegate before launch finishes (actions on a cold start), and in
/// builds with the push entitlement (`PUSH_ENTITLEMENT = YES` in Brand.xcconfig → `PUSH_YES`)
/// registers for remote notifications. A free account has no push entitlement, so the default
/// build never calls `registerForRemoteNotifications` and works with local notifications only.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppNotifications.shared.install()
        AgentLiveActivities.shared.install()
        #if PUSH_YES
        application.registerForRemoteNotifications()
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppNotifications.shared.didRegister(apnsToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppModel.log.error("remote notifications unavailable: \(error.localizedDescription, privacy: .public)")
    }
}
#else
import AppKit

/// macOS: the same notification wiring (no Live Activities).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppNotifications.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if PUSH_YES
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppNotifications.shared.didRegister(apnsToken: deviceToken)
    }
}
#endif

/// `<scheme>://join/<invite>` and `<scheme>://open/<host>/<pane>` (Live Activity, notification).
enum AppLinks {
    static func isInvite(_ url: URL) -> Bool {
        url.host()?.lowercased() == "join"
    }

    /// `(host id, pane)` for an open link.
    static func openTarget(_ url: URL) -> (String, UInt64)? {
        guard url.host()?.lowercased() == "open" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let pane = UInt64(parts[1]) else { return nil }
        return (parts[0], pane)
    }
}
