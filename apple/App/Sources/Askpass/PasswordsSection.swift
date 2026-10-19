import DesignSystem
import HostKit
import SwiftUI

/// Settings › Passwords: what the secure prompts do, and "Forget Saved Passwords".
struct PasswordsSection: View {
    @State private var saved = 0
    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        Section {
            LabeledContent("Saved Passwords") {
                Text(saved == 0 ? "None" : "\(saved)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityIdentifier("saved-passwords-count")
            Button("Forget Saved Passwords", role: .destructive) { confirming = true }
                .disabled(saved == 0)
                .accessibilityIdentifier("forget-saved-passwords")
                .confirmationDialog("Forget \(saved == 1 ? "the saved password" : "all \(saved) saved passwords")?",
                                    isPresented: $confirming, titleVisibility: .visible) {
                    Button("Forget", role: .destructive) { forget() }
                } message: {
                    Text("Prompts on your hosts will ask you to type them again.")
                }
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.error)
            }
        } header: {
            Text("Passwords")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: refresh)
    }

    private var footer: String {
        let base = "When sudo, ssh or git asks for a password on a host, a secure prompt opens on its pane; what you type goes only to that program, and is never shown, logged or kept."
        guard AskpassVaultStore.isAvailable else { return base }
        return base + " Passwords you choose to remember stay in this device's Keychain, per host and prompt, and are only used after Face ID or Touch ID."
    }

    private func refresh() {
        saved = AskpassVaultStore.isAvailable ? AskpassVaultStore.shared.count() : 0
    }

    private func forget() {
        do {
            try AskpassVaultStore.shared.removeAll()
            AskpassVaultStore.recentlyUsed = [:]
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        withAnimation(DS.Motion.snappy) { refresh() }
    }
}
