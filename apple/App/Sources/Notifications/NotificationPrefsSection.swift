import DesignSystem
import NotifyKit
import SwiftUI
import UserNotifications

/// Settings ▸ Notifications: which kinds notify, what each agent notifies about, whether only in
/// the background, the system permission, and whether this build can receive pushes at all.
struct NotificationPrefsSection: View {
    @State private var prefs = AppNotifications.shared.prefs
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Section {
            kind("Approval Requests", "Approve or deny from the notification, after Face ID.", "checkmark.seal", \.approvals)
                .settingAnchor("notify-approvals")
            kind("Agent Needs You", "An agent asks a question or waits for your permission.", "exclamationmark.bubble", \.blocked)
                .settingAnchor("notify-blocked")
            kind("Agent Finished", "A turn ended and the agent is waiting for you.", "checkmark.circle", \.done)
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
        Section {
            ForEach(AgentKind.allCases, id: \.self) { agent in
                Picker(selection: choice(for: agent)) {
                    ForEach(AgentNotificationChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label(agent == .other ? "Other Agents" : agent.title, systemImage: agent.systemImage)
                }
            }
            .settingAnchor("notify-agents")
        } header: {
            Text("By Agent")
        } footer: {
            Text("Needs You: a question or a permission. Finished: a turn ended and the agent is waiting for you. The pane you are looking at never notifies.")
        }
        .onChange(of: prefs) { _, updated in AppNotifications.shared.prefs = updated }
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

    private func choice(for agent: AgentKind) -> Binding<AgentNotificationChoice> {
        let key = agent.notificationKey
        return Binding(
            get: { AgentNotificationChoice(prefs.agent(key)) },
            set: { prefs.agents[key] = $0.prefs })
    }

    private var footer: String {
        let permission = status == .denied ? "Notifications are off for this app in System Settings. " : ""
        let push = AppNotifications.pushEnabled
            ? "Hosts push these to this device even when the app is closed (end-to-end encrypted through the relay)."
            : "Alerts arrive while the app is open or running in the background."
        return permission + push
    }
}

/// One agent's notifications as a single choice.
enum AgentNotificationChoice: CaseIterable, Hashable {
    case all, needsYou, finished, off

    init(_ prefs: AgentNotificationPrefs) {
        self = switch (prefs.needsYou, prefs.finished) {
        case (true, true): .all
        case (true, false): .needsYou
        case (false, true): .finished
        case (false, false): .off
        }
    }

    var prefs: AgentNotificationPrefs {
        switch self {
        case .all: AgentNotificationPrefs(needsYou: true, finished: true)
        case .needsYou: AgentNotificationPrefs(needsYou: true, finished: false)
        case .finished: AgentNotificationPrefs(needsYou: false, finished: true)
        case .off: AgentNotificationPrefs(needsYou: false, finished: false)
        }
    }

    var title: String {
        switch self {
        case .all: "Needs You and Finished"
        case .needsYou: "Needs You"
        case .finished: "Finished"
        case .off: "Off"
        }
    }
}

extension AgentKind {
    /// The daemon's name for the agent in attention items and push rules.
    var notificationKey: String {
        self == .other ? NotificationPrefs.otherAgents : rawValue
    }
}
