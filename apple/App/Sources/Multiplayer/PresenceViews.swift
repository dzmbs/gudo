import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UnnamedCore
#if canImport(UIKit)
import UIKit
#endif

// Presence on the terminal: avatars in the toolbar and pane headers, who is driving a pane and
// "Take Control", the holder's hand-over prompt, the guest's role banner and the prompter's
// composer. All of it floats on the grid as quiet glass (DESIGN.md: chrome recedes, color only
// for state), and none of it shows while the owner is alone.

/// The toolbar's people button: others' avatars (≤ 3 + N, typing ring), or a share glyph when
/// nobody else is here. Opens Share Session.
struct PresenceToolbarButton: View {
    let session: MultiplayerSession
    let action: () -> Void

    var body: some View {
        let others = session.others
        Button(action: action) {
            if others.isEmpty {
                Image(systemName: "person.crop.circle.badge.plus")
            } else {
                PresenceStack(others.map(\.avatar))
                    .animation(DS.Motion.indicator, value: others.map(\.actor.device))
            }
        }
        .help(others.isEmpty ? "Share Session" : "\(others.count) \(others.count == 1 ? "person" : "people") here")
        .accessibilityLabel(others.isEmpty ? "Share Session" : "Share Session, \(others.count) \(others.count == 1 ? "person" : "people") here")
        .accessibilityIdentifier("presence-button")
    }
}

/// People in one pane, for its header: small avatars with typing rings and a keyboard when one
/// of them is driving.
struct PanePresence: View {
    let workspace: Workspace
    let pane: PaneId

    var body: some View {
        if let session = workspace.multiplayer, !LaunchOptions.mock || MockMultiplayer.onPanes {
            let people = session.people(in: pane.rawValue)
            let driver = session.holder(of: pane.rawValue)
            if !people.isEmpty || (driver != nil && driver != session.myPrincipal) {
                HStack(spacing: 4) {
                    if let driver, driver != session.myPrincipal {
                        Image(systemName: "keyboard.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(driverColor(session, driver))
                    }
                    HStack(spacing: -3) {
                        ForEach(people.prefix(3), id: \.actor.device) { person in
                            PresenceAvatar(person.avatar, size: 14)
                        }
                    }
                    if people.contains(where: \.typing) {
                        TypingDots(color: people.first(where: \.typing)?.avatar.color ?? .secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(session, people, driver))
                .accessibilityIdentifier("pane-presence-\(pane.rawValue)")
            }
        }
    }

    private func driverColor(_ session: MultiplayerSession, _ principal: String) -> Color {
        session.participants.first { $0.actor.principal == principal }?.avatar.color ?? .secondary
    }

    private func label(_ session: MultiplayerSession, _ people: [UnnamedCore.Participant], _ driver: String?) -> String {
        var parts = people.map { $0.typing ? "\($0.name), typing" : $0.name }
        if let driver, driver != session.myPrincipal { parts.append("\(session.name(ofPrincipal: driver)) is driving") }
        return parts.joined(separator: "; ")
    }
}

/// Three dots that breathe while someone types (stills under Reduce Motion).
struct TypingDots: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(color)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * max(0, sin((t * 5) - Double(index) * 0.8)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Everything multiplayer drawn over one pane.
struct MultiplayerPaneOverlay: View {
    let workspace: Workspace
    let pane: PaneId
    let isFocused: Bool

    var body: some View {
        if let session = workspace.multiplayer, session.me != nil, !LaunchOptions.mock || MockMultiplayer.onPanes {
            ZStack {
                if let request = session.leaseRequests.first(where: { $0.paneId == pane.rawValue }) {
                    LeaseRequestCard(session: session, request: request)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, DS.Space.l)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if showsControlChip(session) {
                    ControlChip(session: session, pane: pane.rawValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(DS.Space.s)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
                // A prompter's composer sits on every agent pane (it is their only input); the
                // role banner only on the focused pane.
                if session.isGuest && !session.canDrive, isFocused || (session.canPrompt && workspace.isAgentPane(pane)) {
                    guestBar(session)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(DS.Space.s)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(DS.Motion.panel, value: session.leaseRequests)
            .animation(DS.Motion.overlay, value: session.leases[pane.rawValue])
            .animation(DS.Motion.overlay, value: session.pendingTakes[pane.rawValue])
        }
    }

    private func showsControlChip(_ session: MultiplayerSession) -> Bool {
        guard session.canDrive else { return false }
        if session.pendingTakes[pane.rawValue] != nil || session.isDrivenByOther(pane.rawValue) { return true }
        // Driving with someone watching this pane: say so (and offer to hand back).
        return isFocused && session.isDriving(pane.rawValue) && !session.people(in: pane.rawValue).isEmpty
    }

    @ViewBuilder private func guestBar(_ session: MultiplayerSession) -> some View {
        if session.canPrompt, workspace.isAgentPane(pane) {
            PromptComposer(session: session, pane: pane.rawValue, agent: workspace.agentName(pane) ?? "the agent")
        } else {
            GuestBanner(session: session, isAgentPane: workspace.isAgentPane(pane))
        }
    }
}

/// Who drives the pane, and the way to take over. Owners can force.
private struct ControlChip: View {
    let session: MultiplayerSession
    let pane: UInt64

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let pending = session.pendingTakes[pane] {
                Text("Asked \(session.name(ofPrincipal: pending.holder))")
                    .font(.callout.weight(.medium))
                TimelineView(.periodic(from: pending.since, by: 1)) { context in
                    let left = max(0, Int((session.leaseIdle / .seconds(1)).rounded()) - Int(context.date.timeIntervalSince(pending.since)))
                    Text(left > 0 ? "· yours if idle \(left) s" : "· waiting for an answer")
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: true))
                }
                Button("Cancel") { session.cancelTake(pane) }
                    .buttonStyle(.bar)
                if session.isOwner {
                    Button("Take Now") { Task { await session.takeControl(pane, force: true) } }
                        .buttonStyle(.bar)
                        .accessibilityIdentifier("force-control")
                }
            } else if let holder = session.holder(of: pane), holder != session.myPrincipal {
                if let person = session.participants.first(where: { $0.actor.principal == holder }) {
                    PresenceAvatar(person.avatar, size: 18)
                }
                Text("\(session.name(ofPrincipal: holder)) is driving")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Button("Take Control") { Task { await session.takeControl(pane) } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("take-control")
            } else {
                Image(systemName: "keyboard.fill")
                    .foregroundStyle(Color.accentColor)
                Text("You're driving")
                    .font(.callout.weight(.medium))
                Button("Release") { Task { await session.releaseControl(pane) } }
                    .buttonStyle(.bar)
            }
        }
        .padding(.leading, DS.Space.m)
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .floatingCapsule(interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-chip")
    }
}

/// The holder is asked: keep or hand over. If they stay idle, the host hands over by itself.
private struct LeaseRequestCard: View {
    let session: MultiplayerSession
    let request: MultiplayerSession.LeaseRequest

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s + 2) {
            HStack(spacing: DS.Space.m) {
                if let person = session.participants.first(where: { $0.actor.device == request.by.device }) {
                    PresenceAvatar(person.avatar, size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.name) wants control")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: request.at, by: 1)) { context in
                        let left = max(0, Int((session.leaseIdle / .seconds(1)).rounded()) - Int(context.date.timeIntervalSince(request.at)))
                        Text(left > 0 ? "Hands over in \(left) s if you stay idle" : "Hands over when you stop typing")
                            .font(DS.Font.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button("Keep") { Task { await session.answer(request, give: false) } }
                    .buttonStyle(.glass)
                    .fixedSize()
                    .accessibilityIdentifier("keep-control")
                Button("Hand Over") { Task { await session.answer(request, give: true) } }
                    .buttonStyle(.glassProminent)
                    .fixedSize()
                    .accessibilityIdentifier("hand-over")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 380)
        .floatingPanel(cornerRadius: 20)
        .padding(.horizontal, DS.Space.m)
        .sensoryFeedback(DS.Haptic.attention, trigger: request.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lease-request")
    }
}

/// A guest who cannot type: what they can do here, always visible but out of the way.
private struct GuestBanner: View {
    let session: MultiplayerSession
    let isAgentPane: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: session.canPrompt ? "text.bubble" : "eye")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .lineLimit(1)
            if let expires = session.me?.expiresMs, let text = RelativeTime.string(ms: expires) {
                Text("· ends \(text)")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .floatingCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-banner")
    }

    private var message: String {
        if session.canPrompt {
            return isAgentPane ? "Prompt the agent below" : "Prompts go to agent panes"
        }
        let inviter = session.participants.first { $0.roles.contains(.owner) }?.name
        return "View only\(inviter.map { " · invited by \($0)" } ?? "")"
    }
}

/// The prompter's composer on an agent pane: text goes through the host's sanitizer as a
/// bracketed paste, then Enter. Others see a typing indicator while it has text.
private struct PromptComposer: View {
    let session: MultiplayerSession
    let pane: UInt64
    let agent: String
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.error)
                    .padding(.horizontal, DS.Space.m)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                TextField("Prompt \(agent)…", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("prompt-field")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send Prompt")
                .accessibilityIdentifier("send-prompt")
            }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, DS.Space.xs)
            .padding(.vertical, DS.Space.xs)
            .floatingPanel(cornerRadius: 22)
        }
        .frame(maxWidth: 640)
        .onChange(of: text.isEmpty) { _, empty in session.setTyping(empty ? nil : pane) }
        .onDisappear { session.setTyping(nil) }
        .animation(DS.Motion.overlay, value: error)
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        sending = true
        error = nil
        Task {
            do {
                try await session.prompt(pane, prompt)
                text = ""
            } catch {
                self.error = MultiplayerSession.describe(error)
            }
            sending = false
        }
    }
}

/// Window-level multiplayer: notices (refusals, hand-overs, revocation) become toasts.
struct MultiplayerWindowHooks: ViewModifier {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        content
            // Someone with a knock link waits for the owner (the Inbox has the full list).
            .overlay(alignment: .top) { KnockOverlay(workspace: workspace) }
            .onChange(of: workspace.multiplayer?.notice) { _, notice in
                if let notice { model.toasts.show(notice.toast) }
            }
            // Per host: the window no longer rebuilds per workspace (multi-host sidebar).
            .task(id: "\(workspace.hostId ?? "")/\(workspace.multiplayer?.me?.name ?? "")") {
                // A paired device is "owner" on the host until it says who it is; others see
                // this device's name instead.
                guard !LaunchOptions.mock, let session = workspace.multiplayer, let me = session.me,
                      session.isOwner, me.name == "owner" || me.name.isEmpty else { return }
                await session.setName(Self.deviceName)
            }
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
