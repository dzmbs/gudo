import DesignSystem
import HostKit
import SwiftUI
import UnnamedCore

/// Joining someone's host: paste (or open) an invite link, read who invites and with which
/// rights before anything is dialled, then join. Deep links (`<scheme>://join/…`) open this
/// sheet pre-filled; joining is always the user's tap. A knock link asks the owner first: the
/// sheet waits, in words, until they let this device in (or not).
struct JoinSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var name = ""
    @State private var phase = Phase.idle
    @State private var knocking: Task<Void, Never>?
    @State private var progress = KnockProgress()

    enum Phase: Equatable {
        case idle
        case joining
        /// Knocked; waiting for the owner (`KnockProgress.asked` once they have the request).
        case knocking
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
                .chromeRows()

                switch card {
                case .success(let info):
                    JoinCard(info: info)
                        .chromeRows()
                    Section {
                        TextField(info.label.isEmpty ? "Your name" : info.label, text: $name)
                            .textContentType(.name)
                    } header: {
                        SectionTitle("Show Me As")
                    } footer: {
                        Text("Everyone in the session sees this name next to your avatar.")
                    }
                    .chromeRows()
                    Section {
                        if phase == .knocking {
                            KnockWaiting(owner: info.inviter, asked: progress.asked, cancel: stopKnocking)
                        } else {
                            Button(action: { info.knock ? knock(info) : join(info) }) {
                                HStack {
                                    Spacer()
                                    Text(buttonTitle(info))
                                        .font(.body.weight(.semibold))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.primaryGlass)
                            .disabled(phase == .joining || isExpired(info))
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .accessibilityIdentifier("join-button")
                        }
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
                    .chromeRows()
                case nil:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle("Join a Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopKnocking()
                        dismiss()
                    }
                }
            }
            .onDisappear { knocking?.cancel() }
            .animation(DS.Motion.snappy, value: trimmed)
        }
        #if os(iOS)
        .phoneDetents([.large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520)
        #endif
    }

    private func buttonTitle(_ info: InviteInfo) -> String {
        let host = info.inviter.isEmpty ? "host" : info.inviter + "’s host"
        if phase == .joining { return "Joining \(host)…" }
        return info.knock ? "Ask to Join" : "Join as \(roleWords(info.roles))"
    }

    /// Knocks and waits for the owner; joins the moment they let this device in.
    private func knock(_ info: InviteInfo) {
        phase = .knocking
        progress.asked = false
        let progress = progress
        let link = trimmed
        let display = name.trimmingCharacters(in: .whitespaces)
        let hosts = model.app.hosts
        knocking = Task {
            do {
                let id = try await hosts.knock(invite: link, name: display.isEmpty ? WindowModel.deviceName : display) {
                    Task { @MainActor in progress.asked = true }
                }
                model.show(.host(id))
                dismiss()
                model.toasts.show(Toast("\(info.inviter.isEmpty ? "The owner" : info.inviter) let you in",
                                        systemImage: "person.2.fill", style: .success))
            } catch is CancellationError {
                phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.describe(error, owner: info.inviter))
            }
        }
    }

    private func stopKnocking() {
        knocking?.cancel()
        knocking = nil
        if phase == .knocking { phase = .idle }
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

    static func describe(_ error: any Error, owner: String = "") -> String {
        if case PairingError.turnedAway = error {
            return "\(owner.isEmpty ? "The owner" : owner) didn't let you in."
        }
        if let error = error as? KnockError {
            switch error {
            case .Refused(let reason) where reason.contains("Revoked"): return "This link was revoked by its owner."
            case .Refused: return "The host refused this link: it expired, or too many people are already waiting."
            case .Unreachable: return "The host stopped answering. It may be offline; try again when it is up."
            case .Invalid(let message): return message
            }
        }
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
            // A knock link's roles are a suggestion: the owner picks them when letting you in.
            ForEach(info.knock ? [] : Role.invitable.filter(info.roles.contains) + (info.roles.contains(.owner) ? [.owner] : []), id: \.self) { role in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.title).font(DS.Font.rowTitleEmphasis)
                        Text(role.summary).font(DS.Font.rowSubtitle).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: role.systemImage).foregroundStyle(DS.Palette.accent)
                }
            }
            LabeledContent("Covers", value: info.scope.title)
            LabeledContent("Expires", value: info.expiresMs.map { RelativeTime.string(ms: $0) ?? "" } ?? "Never")
            if let uses = info.maxUses, !info.knock {
                LabeledContent("Devices", value: uses == 1 ? "This device only" : "Up to \(uses)")
            }
            if info.knock {
                LabeledContent("Joining", value: "\(info.inviter.isEmpty ? "The owner" : info.inviter) lets you in")
            }
            if info.sinceJoin {
                LabeledContent("Earlier Output", value: "Hidden")
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

/// Waiting at the door: the owner has been asked (or is being asked), in words, with a way out.
private struct KnockWaiting: View {
    let owner: String
    let asked: Bool
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || !asked)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(DS.Palette.working)
                    .frame(width: 9, height: 9)
                    .opacity(reduceMotion || !asked ? 1 : 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 3)))
                    .padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(asked ? "Waiting for \(who) to let you in" : "Knocking…")
                    .font(DS.Font.rowTitleEmphasis)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("knock-status")
                Text(asked ? "You join the moment they do. Keep this open." : "Reaching \(who)’s host.")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Button("Stop", action: cancel)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityIdentifier("knock-stop")
        }
        .padding(.vertical, DS.Space.xs)
        .animation(DS.Motion.snappy, value: asked)
    }

    private var who: String { owner.isEmpty ? "the owner" : owner }
}

/// Whether the owner has the knock yet (set from the core's callback).
@MainActor @Observable
private final class KnockProgress {
    var asked = false
}
