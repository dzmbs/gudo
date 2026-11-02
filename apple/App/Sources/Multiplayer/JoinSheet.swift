import DesignSystem
import HostKit
import SwiftUI
import GudoCore

/// Shows what an invite link grants before anything is dialled. Deep links only pre-fill it:
/// joining is always the user's tap.
struct JoinSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var name = ""
    @State private var phase = Phase.idle
    @State private var knocking: Task<Void, Never>?
    @State private var progress = KnockProgress()

    enum Phase: Hashable {
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

    /// 0 no link, 1 an invite, 2 something else.
    private var cardKind: Int {
        switch card {
        case nil: 0
        case .success: 1
        case .failure: 2
        }
    }

    var body: some View {
        SheetScaffold(
            "Join a Session",
            cancel: SheetAction("Cancel") {
                stopKnocking()
                dismiss()
            },
            primary: primary,
            // On the Mac, Paste sits on the buttons' line, as in the system's own sheets.
            accessory: {
                #if os(macOS)
                pasteButton
                #endif
            }
        ) {
            Form {
                Section {
                    // Prompt only: a titled field in a Mac form puts its title on the left and
                    // the link on the right.
                    TextField("Invite Link", text: $text, prompt: Text(verbatim: "\(WindowContent.urlScheme)://join/…"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(DS.Font.literal)
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("join-field")
                    #if os(iOS)
                    pasteButton
                    #endif
                } header: {
                    SectionTitle("Invite Link")
                } footer: {
                    Text("Paste the link someone shared, or open it from Messages or Mail. Scanning their QR code opens it too.")
                    .foregroundStyle(DS.Palette.textSecondary)
                }
                .chromeRows()

                switch card {
                case .success(let info):
                    JoinCard(info: info)
                        .chromeRows()
                    Section {
                        TextField("Name", text: $name, prompt: Text(info.label.isEmpty ? "Your name" : info.label))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .textContentType(.name)
                    } header: {
                        SectionTitle("Show Me As")
                    } footer: {
                        Text("Everyone in the session sees this name next to your avatar.")
                        .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .chromeRows()
                    if phase == .knocking || isFailed {
                        Section { status(info) }
                            .chromeRows()
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
            // Resizes for the user's steps (a link pasted, a knock sent), never in between.
            .macFittedForm(maxHeight: 560, step: [AnyHashable(cardKind), AnyHashable(phase)])
            .onDisappear { knocking?.cancel() }
            .animation(DS.Motion.snappy, value: trimmed)
        }
        #if os(iOS)
        .phoneDetents([.large])
        #else
        // As tall as the form: the invite card and knock status grow it, then it scrolls.
        .frame(width: 500)
        #endif
    }

    private var primary: SheetAction? {
        guard case .success(let info) = card, phase != .knocking else { return nil }
        return SheetAction(
            buttonTitle(info), isEnabled: !isExpired(info), isBusy: phase == .joining,
            busyTitle: buttonTitle(info), identifier: "join-button"
        ) { info.knock ? knock(info) : join(info) }
    }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            if let first = strings.first { text = first }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
    }

    private var isFailed: Bool {
        if case .failed = phase { true } else { false }
    }

    @ViewBuilder private func status(_ info: InviteInfo) -> some View {
        if phase == .knocking {
            KnockWaiting(owner: info.inviter, asked: progress.asked, cancel: stopKnocking)
        } else if case .failed(let reason) = phase {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.error)
        }
    }

    private func buttonTitle(_ info: InviteInfo) -> String {
        let host = info.inviter.isEmpty ? "host" : info.inviter + "’s host"
        if phase == .joining { return "Joining \(host)…" }
        return info.knock ? "Ask to Join" : "Join as \(roleWords(info.roles))"
    }

    private func knock(_ info: InviteInfo) {
        phase = .knocking
        progress.asked = false
        let progress = progress
        let link = trimmed
        let displayName = name.trimmingCharacters(in: .whitespaces)
        let hosts = model.app.hosts
        knocking = Task {
            do {
                let hostId = try await hosts.knock(invite: link, name: displayName.isEmpty ? WindowModel.deviceName : displayName) {
                    Task { @MainActor in progress.asked = true }
                }
                model.show(.host(hostId))
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
        let displayName = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let hostId = try await model.app.hosts.join(invite: link)
                if !displayName.isEmpty, let daemon = model.app.hosts.connection(hostId) as? DaemonConnection {
                    await daemon.multiplayer.setName(displayName)
                }
                model.show(.host(hostId))
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

private struct JoinCard: View {
    let info: InviteInfo

    var body: some View {
        Section {
            HStack(spacing: DS.Space.m) {
                PresenceAvatar(DesignSystem.Participant(
                    id: info.daemonId, name: info.inviter.isEmpty ? "Host" : info.inviter, role: .owner,
                    hue: GudoCore.Participant.hue(for: info.daemonId)), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.inviter.isEmpty ? "You're invited" : "\(info.inviter) invites you")
                        .font(DS.Font.title)
                        .accessibilityIdentifier("join-inviter")
                    Text(info.label.isEmpty ? "to their terminal" : "as \(info.label)")
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .padding(.vertical, 4)
            // A knock link's roles are a suggestion: the owner picks them when letting you in.
            ForEach(info.knock ? [] : Role.invitable.filter(info.roles.contains) + (info.roles.contains(.owner) ? [.owner] : []), id: \.self) { role in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.title).font(DS.Font.rowTitleEmphasis)
                        Text(role.summary).font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.textSecondary)
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
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } header: {
            SectionTitle("Invitation")
        } footer: {
            Text("End-to-end encrypted, straight to their machine. They can see who is connected and revoke access at any time.")
            .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

private struct KnockWaiting: View {
    let owner: String
    let asked: Bool
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || !asked)) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(DS.Palette.working)
                    .frame(width: 9, height: 9)
                    .opacity(reduceMotion || !asked ? 1 : 0.45 + 0.55 * (0.5 + 0.5 * sin(seconds * 3)))
                    .padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(asked ? "Waiting for \(who) to let you in" : "Knocking…")
                    .font(DS.Font.rowTitleEmphasis)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("knock-status")
                Text(asked ? "You join the moment they do. Keep this open." : "Reaching \(who)’s host.")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
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
