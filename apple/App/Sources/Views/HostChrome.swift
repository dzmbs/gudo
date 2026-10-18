import HostKit
import PaneLayout
import SwiftUI

// Minimal, functional chrome for remote hosts. The design layer replaces these views; they
// only bind to HostKit's models (docs/APP-ARCHITECTURE.md).

/// Opens the hosts list (the window's root decides what that means).
struct ShowHostsAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var showHosts: ShowHostsAction?
}

struct HostsButton: View {
    @Environment(\.showHosts) private var showHosts

    var body: some View {
        if let showHosts {
            Button("Hosts", systemImage: "server.rack") { showHosts() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .accessibilityIdentifier("hosts-button")
        }
    }
}

/// A thin bar over a remote workspace whenever its connection is not live: what is wrong, in
/// words, with Retry (04-mobile-ux R8, R9, A22). Also the "Install helper" offer for plain-SSH
/// hosts and its progress.
struct ConnectionBanner: View {
    let host: any HostConnection
    let hostId: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 4) {
            if !host.status.isLive {
                HStack(spacing: 8) {
                    if case .needsAttention = host.status {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(host.status.summary).lineLimit(2)
                    Spacer()
                    Button("Retry") { host.retry() }
                        .accessibilityIdentifier("retry-connection")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connection-status")
                .bannerStyle()
            }
            if let hostId, host is SshConnection {
                InstallHelperRow(hostId: hostId)
            }
            if let hostId, let notes = app.hosts.installNotes[hostId] {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(notes.joined(separator: "\n")).textSelection(.enabled)
                    Spacer()
                    Button("OK") { app.hosts.dismissNotes(hostId) }
                }
                .bannerStyle()
            }
            if app.hosts.network.isOffline {
                Label("No network. Panes resume when it is back.", systemImage: "wifi.slash")
                    .bannerStyle()
                    .accessibilityIdentifier("offline-banner")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

/// "Install helper" on a plain-SSH host: installs or upgrades the daemon, pairs, and the window
/// switches to it (`HostsModel.installHelper`).
struct InstallHelperRow: View {
    let hostId: String
    @Environment(AppModel.self) private var app
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            if let progress = app.hosts.installs[hostId] {
                ProgressView().controlSize(.small)
                Text(progress.summary)
                    .accessibilityIdentifier("install-progress")
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).lineLimit(3)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                Text("Plain SSH. Keep sessions alive when the device sleeps?")
            }
            Spacer()
            if app.hosts.installs[hostId] == nil {
                Button("Install helper") {
                    error = nil
                    Task {
                        do {
                            try await app.hosts.installHelper(hostId)
                        } catch {
                            self.error = SshErrorText.describe(error)
                        }
                    }
                }
                .accessibilityIdentifier("install-helper")
            }
        }
        .bannerStyle()
    }
}

/// Dims a pane whose host is reconnecting; its last content stays visible (never blank).
struct StalePaneOverlay: View {
    let connection: PaneConnection
    let paneId: PaneId

    var body: some View {
        if case .stale(let reason) = connection {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.45)
                Label(reason, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .padding(6)
                    .background(.thinMaterial, in: .capsule)
                    .padding(8)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stale-\(paneId)")
        }
    }
}

extension View {
    func bannerStyle() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

/// Trust-on-first-use and changed-key decisions (04-mobile-ux C1.3).
struct HostKeyPromptModifier: ViewModifier {
    let prompts: HostKeyPrompts

    func body(content: Content) -> some View {
        content.alert(
            prompts.pending?.isChange == true ? "Host key changed" : "Trust this host?",
            isPresented: Binding(get: { prompts.pending != nil }, set: { if !$0, prompts.pending != nil { prompts.answer(false) } }),
            presenting: prompts.pending
        ) { prompt in
            if prompt.isChange {
                Button("Replace key", role: .destructive) { prompts.answer(true) }
            } else {
                Button("Trust") { prompts.answer(true) }
                    .accessibilityIdentifier("trust-host")
            }
            Button("Cancel", role: .cancel) { prompts.answer(false) }
        } message: { prompt in
            if let expected = prompt.expected {
                Text("\(prompt.host) now presents \(prompt.algorithm) \(prompt.fingerprint), but \(expected.joined(separator: " or ")) is on record. This can mean someone is intercepting the connection.")
            } else {
                Text("\(prompt.host)\n\(prompt.algorithm) \(prompt.fingerprint)")
            }
        }
    }
}
