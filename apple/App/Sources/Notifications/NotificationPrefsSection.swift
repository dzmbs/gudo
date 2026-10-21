import DesignSystem
import NotifyKit
import SwiftUI
import UserNotifications

/// Settings ▸ Notifications: which kinds notify, whether only in the background, the system
/// permission, and whether this build can receive pushes at all.
struct NotificationPrefsSection: View {
    @State private var prefs = AppNotifications.shared.prefs
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Section {
            kind("Approval Requests", "Approve or deny from the notification, after Face ID.", "checkmark.seal", \.approvals)
                .settingAnchor("notify-approvals")
            kind("Agent Waiting", "An agent asks a question or waits in the terminal.", "exclamationmark.bubble", \.blocked)
                .settingAnchor("notify-blocked")
            kind("Agent Finished", "A turn ended with its last message.", "checkmark.circle", \.done)
                .settingAnchor("notify-done")
            kind("Agent Failed", "A turn ended with an error.", "xmark.octagon", \.failed)
                .settingAnchor("notify-failed")
            kind("Long Commands", "A command you weren't watching finished.", "terminal", \.commands)
                .settingAnchor("notify-commands")
            Toggle("Only When the App Is in the Background", isOn: $prefs.onlyInBackground)
                .settingAnchor("notify-background")
        } header: {
            Text("Notifications")
        } footer: {
            Text(footer)
        }
        .onChange(of: prefs) { _, new in AppNotifications.shared.prefs = new }
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    private func kind(_ title: String, _ detail: String, _ image: String, _ key: WritableKeyPath<NotificationPrefs, Bool>) -> some View {
        Toggle(isOn: Binding(get: { prefs[keyPath: key] }, set: { prefs[keyPath: key] = $0 })) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.textSecondary)
                }
            } icon: {
                Image(systemName: image)
            }
        }
    }

    private var footer: String {
        let permission = status == .denied ? "Notifications are off for this app in System Settings. " : ""
        let push = AppNotifications.pushEnabled
            ? "Hosts push these to this device even when the app is closed (end-to-end encrypted through the relay)."
            : "This build alerts while the app is running in the background. Lock-screen pushes need a build with the push entitlement."
        return permission + push
    }
}
