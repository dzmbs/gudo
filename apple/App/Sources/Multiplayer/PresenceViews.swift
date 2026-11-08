import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import GudoCore
#if canImport(UIKit)
import UIKit
#endif

struct PresenceToolbarButton: View {
    let session: MultiplayerSession
    /// The tab a pane is in, for "In cargo test".
    var place: (UInt64) -> String? = { _ in nil }
    let action: () -> Void
    @State private var showsPeople = false
    /// A command chosen in the popover, run once it has closed: a sheet presented while a
    /// popover is still dismissing is dropped.
    @State private var afterClose: (() -> Void)?

    var body: some View {
        let others = session.others
        Button {
            if others.isEmpty { action() } else { showsPeople.toggle() }
        } label: {
            if others.isEmpty {
                Image(systemName: "person.crop.circle.badge.plus")
            } else {
                PresenceStack(others.map(\.avatar))
                    .animation(DS.Motion.indicator, value: others.map(\.actor.device))
            }
        }
        .popover(isPresented: $showsPeople, arrowEdge: .top) {
            PeopleSwitcher(
                people: people,
                commands: [
                    HostSwitcherCommand(id: "share-session", title: "Share Session…", systemImage: "person.crop.circle.badge.plus") {
                        afterClose = action
                        showsPeople = false
                    },
                ],
                onFollow: { session.follow($0) },
                onDismiss: { showsPeople = false })
                .presentationCompactAdaptation(.popover)
                .chromePopover()
        }
        .onChange(of: showsPeople) { _, shown in
            guard !shown, let next = afterClose else { return }
            afterClose = nil
            Task { @MainActor in next() }
        }
        .contextMenu {
            FollowMenuItems(session: session)
            Button("Share Session…", systemImage: "person.crop.circle.badge.plus", action: action)
        }
        .help(others.isEmpty ? "Share Session" : "\(others.count) \(others.count == 1 ? "person" : "people") here")
        .accessibilityLabel(others.isEmpty ? "Share Session" : "Share Session, \(others.count) \(others.count == 1 ? "person" : "people") here")
        .accessibilityIdentifier("presence-button")
    }

    /// This device's person first, then the others as they arrived.
    private var people: [PeopleSwitcherPerson] {
        let followers = Set(session.followers.map(\.actor.principal))
        var seen = Set<String>()
        let everyone = session.participants.filter { $0.actor.principal == session.myPrincipal } + session.others
        return everyone.compactMap { person in
            guard seen.insert(person.actor.principal).inserted else { return nil }
            let isMe = person.actor.principal == session.myPrincipal
            return PeopleSwitcherPerson(
                id: person.actor.principal, avatar: person.avatar, name: person.name,
                detail: isMe ? nil : detail(person, followsMe: followers.contains(person.actor.principal)),
                isFollowed: session.following == person.actor.principal, isMe: isMe)
        }
    }

    /// What they are doing, in a few words: "Typing in cargo test", "Following you", "Away".
    private func detail(_ person: GudoCore.Participant, followsMe: Bool) -> String? {
        if person.state == .away { return "Away" }
        let place = person.focus.flatMap(place)
        if person.typing { return place.map { "Typing in \($0)" } ?? "Typing" }
        if followsMe { return "Following you" }
        if let place { return "In \(place)" }
        return person.state == .idle ? "Idle" : nil
    }
}

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
                            .font(.caption2.weight(.semibold))
                            .imageScale(.small)
                            .foregroundStyle(driverColor(session, driver))
                    }
                    HStack(spacing: -3) {
                        ForEach(people.prefix(3), id: \.actor.device) { person in
                            PresenceAvatar(person.avatar, size: 14)
                        }
                    }
                    if people.contains(where: \.typing) {
                        TypingDots(color: people.first(where: \.typing).map { AnyShapeStyle($0.avatar.color) } ?? AnyShapeStyle(DS.Palette.textSecondary))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(session, people, driver))
                .accessibilityIdentifier("pane-presence-\(pane.rawValue)")
            }
        }
    }

    private func driverColor(_ session: MultiplayerSession, _ principal: String) -> AnyShapeStyle {
        session.participants.first { $0.actor.principal == principal }.map { AnyShapeStyle($0.avatar.color) } ?? AnyShapeStyle(DS.Palette.textSecondary)
    }

    private func label(_ session: MultiplayerSession, _ people: [GudoCore.Participant], _ driver: String?) -> String {
        var parts = people.map { $0.typing ? "\($0.name), typing" : $0.name }
        if let driver, driver != session.myPrincipal { parts.append("\(session.name(ofPrincipal: driver)) is driving") }
        return parts.joined(separator: "; ")
    }
}

struct TypingDots: View {
    let color: AnyShapeStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(color)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * max(0, sin((seconds * 5) - Double(index) * 0.8)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct MultiplayerPaneOverlay: View {
    let workspace: Workspace
    let pane: PaneId
    let isFocused: Bool

    private var showsOverlayApproval: Bool {
        #if os(iOS)
        workspace.pane(pane)?.chat?.presentation != .chat
        #else
        true
        #endif
    }

    var body: some View {
        if let session = workspace.multiplayer, session.me != nil, !LaunchOptions.mock || MockMultiplayer.onPanes {
            ZStack {
                if let request = session.leaseRequests.first(where: { $0.paneId == pane.rawValue }) {
                    LeaseRequestCard(session: session, request: request)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, DS.Space.l)
                        .movingTransition(.top)
                } else if showsControlChip(session) {
                    ControlChip(session: session, pane: pane.rawValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(DS.Space.s)
                        .scalingTransition(0.96, anchor: .topTrailing)
                }
                if showsOverlayApproval {
                    SharedApproval(workspace: workspace, session: session, pane: pane.rawValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // Under the control chip, never over it.
                        .padding(.top, 52)
                        .padding(.horizontal, DS.Space.m)
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if isFocused {
                        FollowPill(session: session)
                            .movingTransition(.top)
                    }
                    ViewportMarkers(session: session, pane: pane.rawValue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DS.Space.s)
                .animation(DS.Motion.overlay, value: session.following)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    LivePaneActivity(session: session, pane: pane.rawValue)
                    // A prompter's composer sits on every agent pane (it is their only input);
                    // the role banner only on the focused pane.
                    if session.isGuest && !session.canDrive, isFocused || (session.canPrompt && workspace.isAgentPane(pane)) {
                        guestBar(session)
                            .frame(maxWidth: .infinity)
                            .movingTransition(.bottom)
                    }
                }
                // Banners ("Stopped following") rise above these cards, never over them.
                .toastObstacle()
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(DS.Space.s)
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

private struct ControlChip: View {
    let session: MultiplayerSession
    let pane: UInt64

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let pending = session.pendingTakes[pane] {
                Text("Asked \(session.name(ofPrincipal: pending.holder))")
                    .font(.callout.weight(.medium))
                TimelineView(.periodic(from: pending.since, by: 1)) { context in
                    let secondsLeft = max(0, Int((session.leaseIdle / .seconds(1)).rounded()) - Int(context.date.timeIntervalSince(pending.since)))
                    Text(secondsLeft > 0 ? "· yours if idle \(secondsLeft) s" : "· waiting for an answer")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
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
                    .buttonStyle(.primaryGlass)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("take-control")
            } else {
                Image(systemName: "keyboard.fill")
                    .foregroundStyle(DS.Palette.accent)
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

/// Asks the holder to keep or hand over; if they stay idle, the host hands over by itself.
private struct LeaseRequestCard: View {
    let session: MultiplayerSession
    let request: MultiplayerSession.LeaseRequest

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.gap10) {
            HStack(spacing: DS.Space.m) {
                if let person = session.participants.first(where: { $0.actor.device == request.by.device }) {
                    PresenceAvatar(person.avatar, size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.name) wants control")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: request.at, by: 1)) { context in
                        let secondsLeft = max(0, Int((session.leaseIdle / .seconds(1)).rounded()) - Int(context.date.timeIntervalSince(request.at)))
                        Text(secondsLeft > 0 ? "Hands over in \(secondsLeft) s if you stay idle" : "Hands over when you stop typing")
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.textSecondary)
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
                    .buttonStyle(.primaryGlass)
                    .fixedSize()
                    .accessibilityIdentifier("hand-over")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 380)
        .floatingPanel(cornerRadius: DS.Radius.card)
        .padding(.horizontal, DS.Space.m)
        .sensoryFeedback(DS.Haptic.attention, trigger: request.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lease-request")
    }
}

private struct GuestBanner: View {
    let session: MultiplayerSession
    let isAgentPane: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: session.canPrompt ? "text.bubble" : "eye")
                .foregroundStyle(DS.Palette.textSecondary)
            Text(message)
                .font(.callout)
                .lineLimit(1)
            if let expires = session.me?.expiresMs, let text = RelativeTime.string(ms: expires) {
                Text("· ends \(text)")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
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

/// The host sends the prompt as a sanitized bracketed paste, then Enter.
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
                .buttonStyle(.primaryGlass)
                .buttonBorderShape(.circle)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send Prompt")
                .accessibilityIdentifier("send-prompt")
            }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, DS.Space.xs)
            .padding(.vertical, DS.Space.xs)
            .floatingPanel(cornerRadius: DS.Radius.largeCard)
        }
        .frame(maxWidth: 640)
        .onChange(of: text.isEmpty) { _, empty in session.setTyping(empty ? nil : pane) }
        .onChange(of: text) { _, text in session.setDraft(pane, source: .prompt, text: text, caret: text.count) }
        .onDisappear {
            session.setTyping(nil)
            session.clearDraft()
        }
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

struct MultiplayerWindowHooks: ViewModifier {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { KnockOverlay(workspace: workspace) }
            .modifier(PresenceSyncModifier(workspace: workspace))
            .onChange(of: workspace.multiplayer?.notice) { _, notice in
                guard let notice, let session = workspace.multiplayer else { return }
                var toast = PresenceNotices.toast(notice, in: session)
                switch notice.kind {
                case .devicePaired, .hostAlert:
                    if let hostId = workspace.hostId {
                        toast.action = Toast.Action("Review") { SettingsLink.shared.open(.hostDevices(hostId)) }
                    }
                default: break
                }
                model.toasts.show(toast)
            }
            // Keyed by host: one window is reused across hosts.
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

enum PresenceNotices {
    @MainActor static func toast(_ notice: MultiplayerSession.Notice, in session: MultiplayerSession) -> Toast {
        var toast = notice.toast
        switch notice.kind {
        case .arrived(let names), .left(let names):
            if names.count == 1 { toast.person = person(names[0], in: session) }
        case .stoppedFollowing(let principal):
            toast.person = session.participants.first { $0.actor.principal == principal }?.avatar
            toast.action = Toast.Action("Follow Again") { session.follow(principal) }
        default: break
        }
        return toast
    }

    /// "Mira Holt joined", as the daemon would say it.
    @MainActor static func toast(arrived names: [String], in session: MultiplayerSession) -> Toast {
        var toast = Toast("\(names.joined(separator: ", ")) joined", systemImage: "person.crop.circle.badge.plus")
        if names.count == 1 { toast.person = person(names[0], in: session) }
        return toast
    }

    @MainActor private static func person(_ name: String, in session: MultiplayerSession) -> DesignSystem.Participant? {
        session.participants.first { $0.name == name }?.avatar
    }
}
