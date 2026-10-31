import DesignSystem
import SwiftUI

/// Settings › Privacy & Security: App Lock ("Require Face ID") and when it locks again.
struct AppLockSection: View {
    @State private var lock = AppLock.shared

    var body: some View {
        Section {
            Toggle(lock.settingTitle, isOn: Binding(
                get: { lock.isEnabled },
                set: { wanted in Task { await lock.setEnabled(wanted) } }))
                .disabled(lock.isAuthenticating)
                .accessibilityIdentifier("app-lock-toggle")
                .settingAnchor("app-lock")
            if lock.isEnabled {
                Picker("Lock", selection: $lock.grace) {
                    ForEach(AppLock.Grace.allCases) { Text($0.title).tag($0) }
                }
                .settingAnchor("app-lock-grace")
            }
            if let failure = lock.failure, !lock.isLocked {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.error)
            }
        } header: {
            Text("App Lock")
        } footer: {
            Text("\(Brand.name) asks for \((lock.method ?? .passcode).name) when it opens and when you come back to it. Agents keep working and notifications still arrive while it is locked.")
        }
        .onAppear { lock.refreshMethod() }
        .animation(DS.Motion.snappy, value: lock.isEnabled)
    }
}
