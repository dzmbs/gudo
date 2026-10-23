import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UnnamedCore

// "Kim is typing" for raw keys, where people are scrolled, who is in each tab, and following a
// person. Everything is read-only and quiet: color only where it names a person.

/// Drafts others are writing for this pane, and who is typing in it.
struct LivePaneActivity: View {
    let session: MultiplayerSession
    let pane: UInt64

    var body: some View {
        let drafts = session.drafts(in: pane)
        let typists = session.typists(in: pane).filter { peer in !drafts.contains { $0.peer == peer.peer } }
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(drafts, id: \.peer) { peer in
                DraftMirror(peer: peer)
                    .movingTransition(.bottom)
            }
            if !typists.isEmpty {
                TypingPill(people: typists)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scalingTransition(0.96, anchor: .bottomLeading)
            }
        }
        .animation(DS.Motion.overlay, value: drafts.map(\.peer))
        .animation(DS.Motion.overlay, value: typists.map(\.peer))
    }
}

/// Someone's draft, as they type it: their name, the text and a caret in their color.
struct DraftMirror: View {
    let peer: Peer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let draft = peer.draft
        let text = draft?.text ?? ""
        let caret = min(Int(draft?.caret ?? 0), text.count)
        let color = peer.avatar.color
        let command = draft?.source == .lineEditor
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                PresenceAvatar(peer.avatar, size: 18)
                Text(peer.firstName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(subtitle(command: command))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if peer.typing != nil {
                    TypingDots(color: AnyShapeStyle(color))
                }
            }
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                let on = reduceMotion || peer.typing != nil
                    || Int(context.date.timeIntervalSinceReferenceDate / 0.55).isMultiple(of: 2)
                let caretMark = Text("▍").foregroundStyle(on ? AnyShapeStyle(color) : AnyShapeStyle(.clear))
                Text("\(String(text.prefix(caret)))\(caretMark)\(String(text.dropFirst(caret)))")
                    .font(command ? .callout.monospaced() : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1...4)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: 640, alignment: .leading)
        .floatingPanel(cornerRadius: DS.Radius.card)
        .overlay(alignment: .leading) {
            Capsule().fill(color).frame(width: 3).padding(.vertical, DS.Space.s).padding(.leading, 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(peer.name) is writing: \(text)")
        .accessibilityIdentifier("draft-mirror-\(peer.draft?.paneId ?? 0)")
    }

    private func subtitle(command: Bool) -> String {
        let what = command ? "writing a command" : "writing a prompt"
        return [peer.deviceName, what].compactMap(\.self).joined(separator: " · ")
    }
}

/// "Kim is typing", for raw keys in the terminal (the keys themselves show in the grid).
struct TypingPill: View {
    let people: [Peer]

    var body: some View {
        let first = people[0]
        HStack(spacing: DS.Space.s) {
            HStack(spacing: -4) {
                ForEach(people.prefix(3), id: \.peer) { PresenceAvatar($0.avatar, size: 16) }
            }
            Text(label)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            TypingDots(color: AnyShapeStyle(first.avatar.color))
        }
        .padding(.leading, DS.Space.xs)
        .padding(.trailing, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .floatingCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("typing-indicator")
    }

    private var label: String {
        switch people.count {
        case 1: "\(people[0].firstName) is typing"
        case 2: "\(people[0].firstName) and \(people[1].firstName) are typing"
        default: "\(people.count) people are typing"
        }
    }
}

/// People in this pane who are scrolled back, and how far: a quiet chip per person.
struct ViewportMarkers: View {
    let session: MultiplayerSession
    let pane: UInt64

    var body: some View {
        let back = session.viewers(of: pane).filter { ($0.viewport?.paneId == pane) && ($0.viewport?.fromBottom ?? 0) > 0 }
        if !back.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(back.prefix(3), id: \.peer) { peer in
                    let rows = Int(peer.viewport?.fromBottom ?? 0)
                    HStack(spacing: DS.Space.xs) {
                        Circle().fill(peer.avatar.color).frame(width: 6, height: 6)
                        Text("\(peer.firstName) ↑ \(rows)")
                            .font(DS.Font.meta.monospacedDigit())
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 3)
                    .floatingCapsule()
                    .help("\(peer.name) is \(rows) lines up in the scrollback")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(peer.name) is reading \(rows) lines up")
                }
            }
            .accessibilityIdentifier("viewport-markers-\(pane)")
        }
    }
}

/// Small avatars of the people whose focus is in a tab.
struct TabPresence: View {
    let workspace: Workspace?
    let panes: [PaneId]

    /// "Kim Lee, Rex Diaz here", for the tab's accessibility value; empty when nobody is.
    @MainActor static func value(_ workspace: Workspace?, _ panes: [PaneId]) -> String {
        guard let session = workspace?.multiplayer else { return "" }
        let ids = Set(panes.map(\.rawValue))
        let names = session.others.filter { $0.focus.map(ids.contains) ?? false }.map(\.name)
        return names.isEmpty ? "" : names.joined(separator: ", ") + " here"
    }

    var body: some View {
        if let session = workspace?.multiplayer {
            let ids = Set(panes.map(\.rawValue))
            let people = session.others.filter { $0.focus.map(ids.contains) ?? false }
            if !people.isEmpty {
                HStack(spacing: -4) {
                    ForEach(people.prefix(3), id: \.actor.device) { person in
                        PresenceAvatar(person.avatar, size: 14)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(people.map(\.name).joined(separator: ", ") + " here")
                .accessibilityIdentifier("tab-presence")
            }
        }
    }
}

/// "Following Kim · Stop": the window shows what Kim shows until stopped or until you move.
struct FollowPill: View {
    let session: MultiplayerSession

    var body: some View {
        if let principal = session.following {
            let leader = session.leader(principal)
            let name = leader?.firstName ?? session.name(ofPrincipal: principal)
            HStack(spacing: DS.Space.s) {
                if let leader { PresenceAvatar(leader.avatar, size: 18) }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Following \(name)")
                        .font(.callout.weight(.semibold))
                    if leader == nil || leader?.state == .away || leader?.focus == nil {
                        Text(leader == nil ? "Not here right now" : leader?.state == .away ? "Away" : "Somewhere you can't see")
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                Button("Stop") { session.follow(nil) }
                    .buttonStyle(.quiet)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("stop-following")
            }
            .padding(.leading, DS.Space.xs)
            .padding(.trailing, DS.Space.xs)
            .padding(.vertical, DS.Space.xs)
            .floatingCapsule(interactive: true)
            .overlay(Capsule().strokeBorder(leader.map { AnyShapeStyle($0.avatar.color) } ?? AnyShapeStyle(DS.Palette.hairline), lineWidth: 1.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("follow-pill")
        }
    }
}

/// An agent's permission request in a shared session, on its pane for everyone: what it wants,
/// who may answer under the session's rules, the answer buttons for those who may, and who
/// answered once someone did. The host takes the first valid answer; a late one is told.
struct SharedApproval: View {
    let workspace: Workspace
    let session: MultiplayerSession
    let pane: UInt64
    @State private var options: [UInt64: [DecisionOption]] = [:]

    var body: some View {
        if !session.others.isEmpty {
            let agent = workspace.daemon?.meta[PaneId(pane)]?.agent
            // Still "blocked" until the agent's next event: an answered request is done.
            if case .blocked(let request, let summary, let choices)? = agent?.state,
               !session.decisions.contains(where: { $0.requestId == request }) {
                card(request: request, summary: summary, choices: choices, agent: workspace.agentName(PaneId(pane)) ?? "The agent")
                    .task(id: request) { options[request] = choices }
            } else {
                // A short-lived "Allowed · Kim" after someone answered.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let decided = recent { answered(decided) }
                }
            }
        }
    }

    /// The last answer on this pane, for a few seconds after it came.
    private var recent: Decided? {
        guard let last = session.decisions.last(where: { $0.paneId == pane }) else { return nil }
        let age = Date.now.timeIntervalSince1970 * 1000 - Double(last.atMs)
        return age < 6000 ? last : nil
    }

    private func card(request: UInt64, summary: String, choices: [DecisionOption], agent: String) -> some View {
        let risk = session.approvalStatuses[request]?.risk ?? .any
        let block = session.approvalBlock(requestId: request, risk: risk)
        let note = session.approvalProgress(requestId: request) ?? answerers(risk: risk)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(DS.Palette.attention)
                Text("\(agent) asks")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Text(note)
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("shared-approval-who")
            }
            Text(summary)
                .font(.callout.monospaced())
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if block == nil, !session.approvedAlready(requestId: request) {
                HStack(spacing: DS.Space.s) {
                    Spacer(minLength: 0)
                    if let deny = LiveAgentFeed.option(choices, allow: false) {
                        Button(deny.label) { workspace.daemon?.decide(requestId: request, optionId: deny.id) }
                            .buttonStyle(.quiet)
                            .accessibilityIdentifier("shared-approval-deny")
                    }
                    if let allow = LiveAgentFeed.option(choices, allow: true) {
                        Button(allow.label) { workspace.daemon?.decide(requestId: request, optionId: allow.id) }
                            .buttonStyle(.primaryGlass)
                            .accessibilityIdentifier("shared-approval-allow")
                    }
                }
                .controlSize(.small)
            } else if let block {
                Label(block, systemImage: "lock")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 520)
        .floatingPanel(cornerRadius: DS.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shared-approval")
    }

    /// "Kim or you can answer", per the session's rules.
    private func answerers(risk: Risk) -> String {
        let policy = session.approvalPolicy
        let ownersOnly = policy.mode == .ownerOnly || risk.rank > policy.maxRisk.rank
        var names: [String] = []
        var seen = Set<String>()
        for person in session.participants where seen.insert(person.actor.principal).inserted {
            let owner = person.roles.contains(.owner)
            guard owner || (!ownersOnly && person.roles.contains(.approver)) else { continue }
            names.append(person.actor.principal == session.myPrincipal ? "you" : person.name.split(separator: " ").first.map(String.init) ?? person.name)
        }
        guard !names.isEmpty else { return "Nobody here can answer" }
        if names.count == 1 { return names[0] == "you" ? "You answer" : "\(names[0]) answers" }
        let list = names.dropLast().joined(separator: ", ") + " or " + names.last!
        return (list.prefix(1).uppercased() + list.dropFirst()) + " can answer"
    }

    private func answered(_ decided: Decided) -> some View {
        let label = options[decided.requestId]?.first { $0.id == decided.optionId }?.label ?? "Answered"
        let who = session.name(of: decided.decidedBy)
        let color = session.participants.first { $0.actor.principal == decided.decidedBy.principal }?.avatar.color
        return HStack(spacing: DS.Space.s) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(DS.Palette.done))
            Text("\(label) · \(who)")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .floatingCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shared-approval-answered")
    }
}

/// Follow and stop-following entries for a menu: one per other person here.
struct FollowMenuItems: View {
    let session: MultiplayerSession

    var body: some View {
        if session.hasLivePresence {
            let people = session.others
            ForEach(people, id: \.actor.principal) { person in
                if session.following == person.actor.principal {
                    Button("Stop Following \(person.name)", systemImage: "eye.slash") { session.follow(nil) }
                } else {
                    Button("Follow \(person.name)", systemImage: "eye") { session.follow(person.actor.principal) }
                        .accessibilityIdentifier("follow-\(person.name)")
                }
            }
        }
    }
}
