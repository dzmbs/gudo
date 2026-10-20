import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

// Chrome for remote hosts over the terminal: the plain-SSH upgrade offer, install progress and
// notes, the offline notice, stale panes, and host-key decisions. The reconnect card itself is
// the design system's `connectionOverlay` (ActiveTabView). Everything binds to HostKit's models
// (docs/APP-ARCHITECTURE.md).

/// Floating notices for a host window, top-trailing over the terminal like Ghostty's search
/// bar: small glass panels that never cover more than they must.
struct HostNotices: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var offerDismissed = false
    @State private var updateDismissed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            if app.hosts.network.isOffline {
                notice(systemImage: "wifi.slash", tint: DS.Palette.error) {
                    Text("No network. Panes resume when it's back.")
                }
                .accessibilityIdentifier("offline-banner")
            }
            if let hostId = workspace.hostId {
                if let progress = app.hosts.installs[hostId] {
                    notice(systemImage: nil, tint: nil) {
                        HStack(spacing: DS.Space.s) {
                            Spinner(color: DS.Palette.working)
                                .frame(width: 12, height: 12)
                            Text(progress.summary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("install-progress")
                        }
                    }
                } else if workspace.host is SshConnection, !offerDismissed {
                    InstallHelperOffer(hostId: hostId) { offerDismissed = true }
                }
                if let progress = app.hosts.helperUpdates[hostId] {
                    notice(systemImage: nil, tint: nil) {
                        HStack(spacing: DS.Space.s) {
                            Spinner(color: DS.Palette.working)
                                .frame(width: 12, height: 12)
                            Text(progress.summary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("helper-update-progress")
                        }
                    }
                } else if let advice = app.hosts.helperAdvice(hostId), advice.kind != .update || !updateDismissed {
                    HelperUpdateNotice(hostId: hostId, advice: advice) { updateDismissed = true }
                }
                if let notes = app.hosts.installNotes[hostId] {
                    notice(systemImage: "info.circle", tint: DS.Palette.info) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                            Text(notes.joined(separator: "\n"))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Dismiss", systemImage: "xmark") { app.hosts.dismissNotes(hostId) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.bar)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: 420, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(DS.Space.m)
        .animation(DS.Motion.panel, value: app.hosts.installs[workspace.hostId ?? ""]?.summary)
    }

    private func notice(systemImage: String?, tint: ChromeStyle?, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: DS.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint ?? DS.Palette.textSecondary)
            }
            content()
        }
        .padding(.horizontal, DS.Space.m + 2)
        .padding(.vertical, DS.Space.s + 1)
        .floatingPanel(cornerRadius: DS.Radius.panel)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// "Install Helper" on a plain-SSH host (04-mobile-ux C1): installs or upgrades the daemon,
/// pairs, and the window switches to it (`HostsModel.installHelper`).
private struct InstallHelperOffer: View {
    let hostId: String
    let onDismiss: () -> Void
    @Environment(WindowModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plain SSH")
                        .font(.callout.weight(.semibold))
                    Text(error ?? "Install the helper to keep sessions running while this device sleeps.")
                        .font(.footnote)
                        .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Palette.error))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button("Not Now", action: onDismiss)
                    .buttonStyle(.glass)
                Button("Install Helper") {
                    error = nil
                    Task {
                        do {
                            try await model.hosts.installHelper(hostId)
                        } catch {
                            self.error = SshErrorText.describe(error)
                        }
                    }
                }
                .buttonStyle(.primaryGlass)
                .accessibilityIdentifier("install-helper")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .frame(width: 320)
        .floatingPanel(cornerRadius: DS.Radius.panel)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// The host's helper version (`HostsModel.helperAdvice`): one quiet line with "Update" when the
/// app has a newer build; a plain statement when the app cannot work with it, with "Update
/// Helper" when that can be done from here (docs/APP-ARCHITECTURE.md §14).
private struct HelperUpdateNotice: View {
    let hostId: String
    let advice: HelperAdvice
    let onDismiss: () -> Void
    @Environment(WindowModel.self) private var model
    @State private var error: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: advice.kind == .update ? "arrow.down.circle" : "exclamationmark.triangle")
                .foregroundStyle(advice.kind == .update ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Palette.error))
            Text(error ?? advice.message)
                .foregroundStyle(error == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Palette.error))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("helper-update-message")
            if advice.canUpdate {
                if advice.kind == .update {
                    Button("Update", action: update)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityIdentifier("update-helper")
                } else {
                    Button("Update Helper", action: update)
                        .buttonStyle(.primaryGlass)
                        .controlSize(.small)
                        .accessibilityIdentifier("update-helper")
                }
            }
            if advice.kind == .update {
                Button("Not Now", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
            }
        }
        .padding(.horizontal, DS.Space.m + 2)
        .padding(.vertical, DS.Space.s + 1)
        .floatingPanel(cornerRadius: DS.Radius.panel)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func update() {
        error = nil
        Task {
            do {
                try await model.hosts.updateHelper(hostId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A pane whose host link dropped keeps its last content (never blank, R12). The window-wide
/// reconnect card dims the tab; this marks the pane for VoiceOver and tests, and when only this
/// pane is stale (the host is otherwise live) dims it the same way with its reason.
struct StalePaneOverlay: View {
    let connection: PaneConnection
    let paneId: PaneId
    /// Whether the pane's own host is live, when it is not the window's (a mixed tab's leaf).
    var hostIsLive: Bool?
    @Environment(WindowModel.self) private var model

    var body: some View {
        if case .stale(let reason) = connection {
            ZStack(alignment: .bottomTrailing) {
                // A host that is down shows its card over the pane instead.
                if hostIsLive ?? model.connection.isLive {
                    Color.black.opacity(0.35)
                    Label(reason, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .padding(.horizontal, DS.Space.s + 2)
                        .padding(.vertical, DS.Space.xs + 1)
                        .floatingCapsule()
                        .padding(DS.Space.s)
                } else {
                    Color.clear
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stale: \(reason)")
            .accessibilityIdentifier("stale-\(paneId)")
        }
    }
}

/// Trust-on-first-use and changed-key decisions (04-mobile-ux C1.3).
struct HostKeyPromptModifier: ViewModifier {
    let prompts: HostKeyPrompts

    func body(content: Content) -> some View {
        content.alert(
            prompts.pending?.isChange == true ? "Host Key Changed" : "Trust This Host?",
            isPresented: Binding(get: { prompts.pending != nil }, set: { if !$0, prompts.pending != nil { prompts.answer(false) } }),
            presenting: prompts.pending
        ) { prompt in
            if prompt.isChange {
                Button("Replace Key", role: .destructive) { prompts.answer(true) }
            } else {
                Button("Trust") { prompts.answer(true) }
                    .accessibilityIdentifier("trust-host")
            }
            Button("Cancel", role: .cancel) { prompts.answer(false) }
        } message: { prompt in
            if let expected = prompt.expected {
                Text("\(prompt.host) now presents \(prompt.algorithm) \(prompt.fingerprint), but \(expected.joined(separator: " or ")) is on record. This can mean someone is intercepting the connection.")
            } else {
                Text("First connection to \(prompt.host). Check that its key matches:\n\(prompt.algorithm) \(prompt.fingerprint)")
            }
        }
    }
}

/// Copies text to the general pasteboard.
func copy(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
