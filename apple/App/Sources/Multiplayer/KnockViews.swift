import DesignSystem
import HostKit
import SwiftUI
import UnnamedCore

// Knock to join and approval rules (docs/DAEMON.md §6.9). Someone with a knock link waits
// until the owner lets them in: the owner sees them here (a banner over the terminal, the
// Inbox, Share Session) and admits them with a role, or turns them away. The approval rules
// say who answers a session's agent requests.

/// Someone knocking on one of this device's hosts.
struct KnockItem: Identifiable {
    var id: String { "\(hostId)/\(knock.knockId)" }
    var hostId: String
    var hostName: String
    var knock: Knock
    var session: MultiplayerSession
}

/// An approval request under its session's rules, as this device sees it.
nonisolated struct ApprovalContext: Equatable, Sendable {
    /// Why this device may not approve (it may still deny), or nil.
    var block: String?
    /// "Alex approved · needs a second person", "Claimed by Bob".
    var progress: String?
    /// The session asks approvers to claim requests.
    var claimMode: Bool
    /// This principal holds the claim.
    var claimedByMe: Bool
    /// This principal's approval is already counted (two-person rule).
    var approvedAlready: Bool
}

/// The roles an owner admits someone as, weakest first, as the "Admit as" menu lists them.
enum AdmitChoice: String, CaseIterable, Identifiable {
    case viewer, prompter, driver, pair

    var id: String { rawValue }

    var roles: [Role] {
        switch self {
        case .viewer: [.viewer]
        case .prompter: [.viewer, .prompter]
        case .driver: [.viewer, .driver]
        case .pair: [.viewer, .driver, .approver]
        }
    }

    var title: String { roleWords(roles) }

    var systemImage: String {
        switch self {
        case .viewer: "eye"
        case .prompter: "text.bubble"
        case .driver: "keyboard"
        case .pair: "person.2"
        }
    }
}

extension Knock {
    /// The knocker as the design system draws people.
    var avatar: DesignSystem.Participant {
        DesignSystem.Participant(id: actor.device, name: name.isEmpty ? "Guest" : name, role: .viewer,
                                 hue: UnnamedCore.Participant.hue(for: actor.principal))
    }
}

/// "Admit as ▾" and "Deny" for one knock. Scrollback from before they join stays hidden unless
/// the owner turns "Show Earlier Output" on.
struct KnockActions: View {
    let knock: Knock
    let session: MultiplayerSession
    var compact = false
    @State private var showEarlier = false
    @State private var busy = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button("Deny") { answer { await session.turnAway(knock) } }
                .buttonStyle(.glass)
                .accessibilityIdentifier("knock-deny")
            Menu {
                Section("Admit \(knock.name) as") {
                    ForEach(AdmitChoice.allCases) { choice in
                        Button(choice.title, systemImage: choice.systemImage) {
                            answer { await session.admit(knock, roles: choice.roles, sinceJoin: !showEarlier) }
                        }
                        .accessibilityIdentifier("admit-\(choice.rawValue)")
                    }
                }
                Toggle("Show Earlier Output", systemImage: "clock.arrow.circlepath", isOn: $showEarlier)
            } label: {
                Text(compact ? "Admit" : "Admit as…")
                    .fontWeight(.semibold)
            }
            .menuStyle(.button)
            .buttonStyle(.primaryGlass)
            .fixedSize()
            .accessibilityIdentifier("knock-admit")
        }
        .controlSize(.small)
        .disabled(busy)
    }

    private func answer(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

/// One knock as a row (Inbox, Share Session): who, what the invite offers, how long they have
/// waited, and the answer.
struct KnockRow: View {
    let knock: Knock
    let session: MultiplayerSession
    /// The host's name when rows of several hosts are listed together.
    var hostName: String?

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            PresenceAvatar(knock.avatar, size: 30)
            VStack(alignment: .leading, spacing: DS.Space.row) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text("\(knock.name) wants to join")
                        .font(DS.Font.rowTitleEmphasis)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(waited(at: context.date))
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                Text(detail)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
                HStack {
                    Spacer()
                    KnockActions(knock: knock, session: session)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("knock-\(knock.name)")
    }

    private var detail: String {
        var parts: [String] = []
        if let hostName { parts.append(hostName) }
        parts.append(knock.scope.title)
        parts.append("link offers \(roleWords(knock.roles))")
        return parts.joined(separator: " · ")
    }

    private func waited(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - Double(knock.atMs) / 1000))
        return seconds < 60 ? "now" : "\(seconds / 60)m"
    }
}

/// The newest knock on the window's host, floating at the foot of the terminal (clear of the
/// toolbar and the panes' control chips) so the owner sees it
/// without opening anything. Other knocks wait in Agents.
struct KnockBanner: View {
    let session: MultiplayerSession

    var body: some View {
        if let knock = session.knocks.last {
            HStack(spacing: DS.Space.m) {
                PresenceAvatar(knock.avatar, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(knock.name) is asking to join")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(session.knocks.count > 1 ? "\(session.knocks.count - 1) more in Agents" : "Their link offers \(roleWords(knock.roles))")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s)
                KnockActions(knock: knock, session: session, compact: true)
            }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, DS.Space.s)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: 460)
            .floatingPanel(cornerRadius: DS.Radius.card)
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.l)
            .sensoryFeedback(DS.Haptic.attention, trigger: knock.knockId)
            .movingTransition(.bottom)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("knock-banner")
        }
    }
}

/// The knock banner for the window's host, owner devices only.
struct KnockOverlay: View {
    let workspace: Workspace

    var body: some View {
        let shown = !LaunchOptions.mock || MockMultiplayer.onPanes
        let session = workspace.multiplayer.flatMap { $0.isOwner && shown ? $0 : nil }
        ZStack(alignment: .bottom) {
            if let session, !session.knocks.isEmpty {
                KnockBanner(session: session)
            }
        }
        .animation(DS.Motion.panel, value: session?.knocks.map(\.knockId) ?? [])
    }
}

/// Share Session, owner: who answers this session's agent requests.
struct ApprovalRulesSection: View {
    let session: MultiplayerSession
    let sessionId: UInt64?
    let supported: Bool

    var body: some View {
        Section {
            if supported {
                Picker("Who Answers", selection: binding(\.mode)) {
                    ForEach(ApprovalMode.ordered, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("approval-mode")
                Picker("Approvers May Allow", selection: binding(\.maxRisk)) {
                    ForEach(Risk.ordered, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(session.approvalPolicy.mode == .ownerOnly)
                .accessibilityIdentifier("approval-max-risk")
            } else {
                Label("Update the helper on this host to set approval rules.", systemImage: "arrow.up.circle")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } header: {
            SectionTitle("Agent Approvals")
        } footer: {
            if supported {
                Text(footer)
                    .contentTransition(.opacity)
                    .animation(DS.Motion.snappy, value: session.approvalPolicy)
            }
        }
    }

    private var footer: String {
        let policy = session.approvalPolicy
        var text = policy.mode.summary
        if policy.mode != .ownerOnly, policy.maxRisk != .any {
            text += " Allowing anything riskier than \(policy.maxRisk == .readOnly ? "a read" : "an edit") needs you; anyone may still say no."
        }
        return text + " You are never held back, and every answer is signed and logged."
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ApprovalPolicy, Value>) -> Binding<Value> {
        Binding {
            session.approvalPolicy[keyPath: keyPath]
        } set: { value in
            guard let sessionId else { return }
            var policy = session.approvalPolicy
            policy[keyPath: keyPath] = value
            Task { await session.setApprovalPolicy(policy, session: sessionId) }
        }
    }
}

extension ApprovalPolicy {
    /// "Two people for commands · approvers allow edits", for a guest's access summary.
    var words: String {
        var parts = [mode.title]
        if mode != .ownerOnly, maxRisk != .any { parts.append("approvers allow \(maxRisk.title.lowercased())") }
        return parts.joined(separator: " · ")
    }
}
