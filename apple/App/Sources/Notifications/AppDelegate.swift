import Foundation
import HostKit
#if os(iOS)
import UIKit

/// Sets the notification delegate before launch finishes (actions on a cold start), and in
/// builds with the push entitlement (`PUSH_ENTITLEMENT = YES` in Brand.xcconfig → `PUSH_YES`)
/// registers for remote notifications. A free account has no push entitlement, so the default
/// build never calls `registerForRemoteNotifications` and works with local notifications only.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppNotifications.shared.install()
        AppLockCovers.shared.install()
        AgentLiveActivities.shared.install()
        AgentsLiveActivity.shared.install()
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

    /// ⌘W is Close Pane; the system's Close Window moves to ⇧⌘W, as in Safari.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.replaceChildren(ofMenu: .close) { children in
            children.map { element in
                guard let command = element as? UIKeyCommand, let action = command.action,
                      command.input?.lowercased() == "w", command.modifierFlags == .command else { return element }
                let moved = UIKeyCommand(title: command.title, image: command.image, action: action,
                                         input: "w", modifierFlags: [.command, .shift], propertyList: command.propertyList)
                moved.discoverabilityTitle = command.discoverabilityTitle
                return moved
            }
        }
    }

    /// Windows (Windows/ExternalDisplay.swift): an external display without Stage Manager gets a
    /// window of its own; every other scene is SwiftUI's `WindowGroup`.
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        ExternalDisplay.configuration(for: connectingSceneSession)
            ?? UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
#else
import AppKit

/// macOS: the same notification wiring (no Live Activities).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: no Dock icon and never active, so a test run leaves the screen alone.
        if LaunchOptions.isTesting { NSApp.setActivationPolicy(.accessory) }
        #if DEBUG
        // `-dogfoodBackground YES` (scripts/dogfood.sh's default): a test run never takes the
        // screen from whoever is working. No Dock icon, never active, its window kept behind.
        if UserDefaults.standard.bool(forKey: "dogfoodBackground") {
            NSApp.setActivationPolicy(.accessory)
        }
        #endif
        AppNotifications.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLockCovers.shared.install()
        #if PUSH_YES
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppNotifications.shared.didRegister(apnsToken: deviceToken)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.localHelper?.appWillTerminate()
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
