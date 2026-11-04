import DesignSystem
import SwiftUI

/// Settings › Browser: recording agents' browser sessions for Session Replay.
struct ReplaySettingsSection: View {
    @AppStorage(ReplayStore.enabledKey) private var record = true
    @State private var store = ReplayStore.shared
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle("Record Agent Sessions", isOn: $record)
                .accessibilityIdentifier("settings-record-agent-sessions")
                .settingAnchor("record-agent-sessions")
            LabeledContent("Saved Replays") {
                Text(store.sessions.isEmpty ? "None" : "\(store.sessions.count) · \(ByteCountFormatter.string(fromByteCount: Int64(store.totalSize), countStyle: .file))")
            }
            Button("Delete All Replays", role: .destructive) { confirmDelete = true }
                .buttonStyle(.formAction)
                .disabled(store.sessions.isEmpty)
                .settingAnchor("delete-replays")
                .confirmationDialog("Delete all session replays?", isPresented: $confirmDelete) {
                    Button("Delete All Replays", role: .destructive) { store.deleteAll() }
                }
        } header: {
            Text("Session Replay")
        } footer: {
            Text("""
            Keeps what agents do in browser pages on this device: each step, a picture after it, and \
            the page as it changed, to play back from the page's Replays. Password and card fields \
            are masked. Replays older than 30 days, or beyond 512 MB, are deleted oldest first.
            """)
        }
    }
}
