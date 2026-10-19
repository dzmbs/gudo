import DesignSystem
import HostKit
import SwiftUI
import UnnamedCore

/// Joining someone's host: paste (or open) an invite link, read who invites and with which
/// rights before anything is dialled, then join. Deep links (`<scheme>://join/…`) open this
/// sheet pre-filled; joining is always the user's tap.
struct JoinSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var name = ""
    @State private var phase = Phase.idle

    enum Phase: Equatable {
        case idle
        case joining
        case failed(String)
    }

    init(invite: String = "") {
        _text = State(initialValue: invite)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The invite read without dialling (nil while empty or unreadable).
    private var card: Result<InviteInfo, Error>? {
        guard !trimmed.isEmpty else { return nil }
        return Result { try inspectInvite(invite: trimmed) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("unnamed://join/…", text: $text, axis: .vertical)
                        .font(DS.Font.literalSmall)
                        .lineLimit(2...3)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("join-field")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                } header: {
                    SectionTitle("Invite Link")
                } footer: {
                    Text("Paste the link someone shared, or open it from Messages or Mail. Scanning their QR code opens it too.")
                }
                .raisedRows()

                switch card {
                case .success(let info):
                    JoinCard(info: info)
                        .raisedRows()
                    Section {
                        TextField(info.label.isEmpty ? "Your name" : info.label, text: $name)
                            .textContentType(.name)
                    } header: {
                        SectionTitle("Show Me As")
                    } footer: {
                        Text("Everyone in the session sees this name next to your avatar.")
                    }
                    .raisedRows()
                    Section {
                        Button(action: { join(info) }) {
                            HStack {
                                Spacer()
                                Text(phase == .joining ? "Joining \(info.inviter.isEmpty ? "host" : info.inviter + "’s host")…" : "Join as \(roleWords(info.roles))")
                                    .font(.body.weight(.semibold))
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(phase == .joining || isExpired(info))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("join-button")
                        if case .failed(let reason) = phase {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(DS.Font.rowSubtitle)
                                .foregroundStyle(DS.Palette.error)
                        }
                    }
                case .failure:
                    Section {
                        Label("That isn't an invite link. Pairing tickets go in Add Host.", systemImage: "questionmark.circle")
                            .foregroundStyle(DS.Palette.error)
                    }
                    .raisedRows()
                case nil:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .terminalGrouped()
            .navigationTitle("Join a Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .animation(DS.Motion.snappy, value: trimmed)
        }
        .followsTerminalChrome()
        #if os(iOS)
        .phoneDetents([.large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520)
        #endif
    }

    private func isExpired(_ info: InviteInfo) -> Bool {
        info.expiresMs.map { Double($0) / 1000 < Date.now.timeIntervalSince1970 } ?? false
    }

    private func join(_ info: InviteInfo) {
        phase = .joining
        let link = trimmed
        let display = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let id = try await model.app.hosts.join(invite: link)
                if !display.isEmpty, let daemon = model.app.hosts.connection(id) as? DaemonConnection {
                    await daemon.multiplayer.setName(display)
                }
                model.show(.host(id))
                dismiss()
                model.toasts.show(Toast("Joined \(info.inviter.isEmpty ? "the host" : info.inviter + "’s host") as \(roleWords(info.roles))",
                                        systemImage: "person.2.fill", style: .success))
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        if case PairingError.refused(let reason) = error {
            if reason.contains("Revoked") { return "This invite was revoked by its owner." }
            if reason.contains("InvalidGrant") { return "The host refused this invite: it expired, was used up, or isn't valid for this host." }
            return reason
        }
        if case PairingError.timedOut = error { return "The host didn't answer. It may be offline; try again when it is up." }
        return SshErrorText.describe(error)
    }
}

/// What the invite grants, as a card: who invites, the roles with what they allow, scope,
/// expiry and uses.
private struct JoinCard: View {
    let info: InviteInfo

    var body: some View {
        Section {
            HStack(spacing: DS.Space.m) {
                PresenceAvatar(DesignSystem.Participant(
                    id: info.daemonId, name: info.inviter.isEmpty ? "Host" : info.inviter, role: .owner,
                    hue: UnnamedCore.Participant.hue(for: info.daemonId)), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.inviter.isEmpty ? "You're invited" : "\(info.inviter) invites you")
                        .font(DS.Font.title)
                        .accessibilityIdentifier("join-inviter")
                    Text(info.label.isEmpty ? "to their terminal" : "as \(info.label)")
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            ForEach(Role.invitable.filter(info.roles.contains) + (info.roles.contains(.owner) ? [.owner] : []), id: \.self) { role in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.title).font(DS.Font.rowTitleEmphasis)
                        Text(role.summary).font(DS.Font.rowSubtitle).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: role.systemImage).foregroundStyle(Color.accentColor)
                }
            }
            LabeledContent("Covers", value: info.scope.title)
            LabeledContent("Expires", value: info.expiresMs.map { RelativeTime.string(ms: $0) ?? "" } ?? "Never")
            if let uses = info.maxUses {
                LabeledContent("Devices", value: uses == 1 ? "This device only" : "Up to \(uses)")
            }
            LabeledContent("Host") {
                Text(groupedHex(info.daemonId))
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionTitle("Invitation")
        } footer: {
            Text("End-to-end encrypted, straight to their machine. They can see who is connected and revoke access at any time.")
        }
    }
}
