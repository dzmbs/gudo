import DesignSystem
import HostKit
import SwiftUI
import UnnamedCore

/// Manage Sharing: every host this device owns that has guests or live links, with who is
/// connected and each link, removable and revocable on the spot.
struct SharingSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sharing")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("sharing-done")
                    }
                }
        }
        .macMinimumSize(width: 560, height: 560)
    }

    /// Connected hosts this device owns, by name.
    private var hosts: [(id: String, name: String, session: MultiplayerSession)] {
        guard !LaunchOptions.mock else { return [] }
        return model.app.hosts.entries.compactMap { entry in
            guard let daemon = model.app.hosts.connection(entry.id) as? DaemonConnection, daemon.multiplayer.isOwner else { return nil }
            return (entry.id, entry.name, daemon.multiplayer)
        }
    }

    @ViewBuilder private var content: some View {
        let hosts = hosts
        let shared = hosts.filter { $0.session.sharingSummary != nil }
        if shared.isEmpty {
            EmptyState(
                "Nothing Shared", systemImage: "person.2.slash",
                message: hosts.isEmpty
                    ? "Connect to a host you own to share its sessions."
                    : "Invite someone from Share Session. Their links and the people who joined show up here.") {
                Button("Share Session…") { model.sheet = .invite }
                    .buttonStyle(.primaryGlass)
                    .disabled(hosts.isEmpty)
            }
            .task { for host in hosts { await host.session.refreshGrants() } }
        } else {
            Form {
                ForEach(shared, id: \.id) { host in
                    HostSharing(name: host.name, session: host.session)
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .accessibilityIdentifier("sharing-list")
        }
    }
}

/// One host's guests and links.
private struct HostSharing: View {
    let name: String
    let session: MultiplayerSession
    @State private var removing: UnnamedCore.Participant?

    var body: some View {
        Section {
            ForEach(session.guests, id: \.actor.device) { person in
                GuestRow(person: person, session: session) { removing = person }
            }
            if session.guests.isEmpty {
                Text("Nobody is connected now.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } header: {
            HStack {
                SectionTitle(name)
                Spacer()
                Text(session.sharingSummary ?? "")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .chromeRows()
        .modifier(RemovePersonDialog(session: session, person: $removing))
        ActiveLinksSection(session: session).chromeRows()
    }
}

/// A connected guest: who, with what role, on what device; Remove.
private struct GuestRow: View {
    let person: UnnamedCore.Participant
    let session: MultiplayerSession
    let onRemove: () -> Void

    private var device: String? {
        session.peers.values.first { $0.actor.device == person.actor.device }?.deviceName
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            PresenceAvatar(person.avatar, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(DS.Font.rowTitle).lineLimit(1)
                Text([roleWords(person.roles), person.scope == .daemon ? nil : person.scope.title, device].compactMap(\.self).joined(separator: " · "))
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            Button("Remove", role: .destructive, action: onRemove)
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("remove-\(person.name)")
        }
        .padding(.vertical, 2)
    }
}
