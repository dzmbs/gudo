import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UnnamedCore

extension Workspace {
    /// The window's native password prompts (daemon hosts only).
    var askpass: AskpassSession? { (host as? DaemonConnection)?.askpass }
}

/// A pane's password prompts: the secure card for an askpass request or an opened detected
/// prompt, else the "Enter Password Securely" chip while the terminal asks with echo off.
struct AskpassPaneOverlay: View {
    let workspace: Workspace
    let pane: PaneId

    /// The detected prompt the user opened the card for.
    @State private var opened: DetectedPrompt?

    var body: some View {
        if let session = workspace.askpass, let hostId = workspace.hostId {
            ZStack {
                if let prompt = session.prompt(for: pane.rawValue) {
                    SecretPromptCard(
                        target: .askpass(prompt), hostId: hostId, session: session,
                        isStale: session.stale.contains(prompt.id)
                    ) { refocus() }
                    .id("askpass-\(prompt.id)")
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, DS.Space.l)
                    .movingTransition(.top)
                } else if let detected = session.detected[pane.rawValue] {
                    if opened == detected {
                        SecretPromptCard(target: .detected(detected), hostId: hostId, session: session, isStale: false) {
                            opened = nil
                            refocus()
                        }
                        .id("detected-\(pane.rawValue)-\(detected.atSeq)")
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, DS.Space.l)
                        .movingTransition(.top)
                    } else {
                        SecretPromptChip { opened = detected }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, DS.Space.m)
                            .movingTransition(.bottom)
                    }
                }
            }
            .animation(DS.Motion.panel, value: session.prompt(for: pane.rawValue)?.id)
            .animation(DS.Motion.overlay, value: session.detected[pane.rawValue])
            .onChange(of: session.detected[pane.rawValue]) { _, now in
                if now == nil { opened = nil }
            }
        }
    }

    /// Gives the terminal the keyboard back once the card is gone.
    private func refocus() {
        guard let view = workspace.panes[pane]?.view else { return }
        #if os(macOS)
        view.window?.makeFirstResponder(view)
        #else
        _ = view.becomeFirstResponder()
        #endif
    }
}

/// "Enter Password Securely": the terminal is asking for a password with echo off.
struct SecretPromptChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Enter Password Securely", systemImage: "key.horizontal.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
        }
        .buttonStyle(.plain)
        .floatingCapsule(interactive: true)
        .accessibilityLabel("Enter password securely")
        .accessibilityHint("Opens a secure field. The password is typed into the terminal without being shown.")
        .accessibilityIdentifier("askpass-chip")
    }
}

/// The secure prompt, anchored to its pane: who asks and where, the program's own prompt, a
/// secure field (plain for yes/no questions), Remember in Keychain, Cancel and OK.
struct SecretPromptCard: View {
    let isStale: Bool
    let onClose: () -> Void

    @State private var entry: SecretEntry
    @FocusState private var fieldFocused: Bool
    @Environment(WindowModel.self) private var model

    init(target: SecretEntry.Target, hostId: String, session: AskpassSession, isStale: Bool, onClose: @escaping () -> Void) {
        self.isStale = isStale
        self.onClose = onClose
        _entry = State(initialValue: SecretEntry(
            target: target, hostId: hostId, session: session,
            vault: AskpassVaultStore.shared, vaultAvailable: AskpassVaultStore.isAvailable))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            field
            if let message = statusMessage {
                Label(message.text, systemImage: message.symbol)
                    .font(.footnote)
                    .foregroundStyle(message.color)
                    .accessibilityIdentifier("askpass-status")
            }
            HStack(spacing: DS.Space.s) {
                if entry.canRemember {
                    Toggle("Remember in Keychain", isOn: $entry.remember)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #else
                        .toggleStyle(.switch)
                        #endif
                        .font(.footnote)
                        .fixedSize()
                        .accessibilityHint("Saves it on this device for \(model.hostName). Using it later asks for Face ID or Touch ID.")
                        .accessibilityIdentifier("askpass-remember")
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { close(cancel: true) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    .accessibilityIdentifier("askpass-cancel")
                Button("OK") { submit() }
                    .buttonStyle(.primaryGlass)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!entry.canSend || isStale)
                    .fixedSize()
                    .accessibilityIdentifier("askpass-ok")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 420)
        .floatingPanel(cornerRadius: DS.Radius.card)
        .padding(.horizontal, DS.Space.m)
        .sensoryFeedback(DS.Haptic.attention, trigger: entry.copy.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.copy.title)
        .accessibilityIdentifier("askpass-card")
        .task {
            // After the move-in, so the keyboard comes up with the card in place.
            try? await Task.sleep(for: .milliseconds(150))
            fieldFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.gap10) {
            Image(systemName: entry.copy.symbol)
                .font(.title3)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.copy.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(subtitleForVoiceOver)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var field: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(entry.copy.fieldLabel)
                .font(.footnote)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(3)
                .accessibilityHidden(true)
            HStack(spacing: DS.Space.s) {
                Group {
                    if entry.copy.echo {
                        TextField("Answer", text: $entry.secret)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    } else {
                        SecureField("Password", text: $entry.secret)
                            .textContentType(.password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.literal)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
                .accessibilityLabel(entry.copy.fieldLabel)
                .accessibilityIdentifier("askpass-secret")
                if entry.hasSaved {
                    Button {
                        Task {
                            if await entry.sendSaved() { close(cancel: false) }
                        }
                    } label: {
                        Image(systemName: "faceid")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Use Saved Password")
                    .accessibilityLabel("Use saved password")
                    .accessibilityHint("Asks for Face ID or Touch ID")
                    .accessibilityIdentifier("askpass-use-saved")
                }
            }
        }
    }

    /// The program and the host: "sudo apt upgrade · hetzner".
    private var subtitle: String {
        var parts: [String] = []
        if case .askpass(let prompt) = entry.target, !prompt.program.isEmpty { parts.append(prompt.program) }
        parts.append(model.hostName)
        return parts.joined(separator: " · ")
    }

    private var subtitleForVoiceOver: String {
        if case .askpass(let prompt) = entry.target, !prompt.program.isEmpty {
            return "\(prompt.program), on \(model.hostName)"
        }
        return "On \(model.hostName)"
    }

    private struct Message {
        let text: String
        let symbol: String
        let color: ChromeStyle
    }

    private var statusMessage: Message? {
        if isStale {
            return Message(text: "Reconnecting…", symbol: "arrow.triangle.2.circlepath", color: DS.Palette.attention)
        }
        if let failure = entry.failure {
            return Message(text: failure, symbol: "exclamationmark.triangle.fill", color: DS.Palette.error)
        }
        if entry.forgotSaved {
            return Message(text: "The saved password didn't work and was forgotten.", symbol: "exclamationmark.triangle.fill", color: DS.Palette.error)
        }
        if entry.isRetry {
            return Message(text: "That didn't work. Try again.", symbol: "exclamationmark.triangle.fill", color: DS.Palette.error)
        }
        return nil
    }

    private func submit() {
        guard entry.canSend, !isStale else { return }
        Task {
            if await entry.send() { close(cancel: false) }
        }
    }

    private func close(cancel: Bool) {
        Task {
            if cancel { await entry.cancel() }
            onClose()
        }
    }
}
