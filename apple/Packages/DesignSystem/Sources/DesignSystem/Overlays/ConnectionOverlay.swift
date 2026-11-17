import SwiftUI

// Connection state in the chrome. Quiet when fine, loud when broken: a healthy link shows nothing,
// a slow or reconnecting one a static amber glyph and a one-line notice, and only a failure, or a
// link gone for 40 s, a card with actions. Motion is the system spinner while connecting, never a
// pulsing dot.

nonisolated public enum ConnectionState: Hashable, Sendable {
    case connected
    /// Live but slow: keystrokes take `rtt` to echo.
    case slow(rtt: Duration)
    /// On the way to live; `phase` says what it waits for ("Opening session…").
    case connecting(phase: String?)
    /// This device's own helper is starting (the app's launch, or after it stopped): nothing
    /// was lost on the way, so there is no last contact to count from.
    case starting
    /// Lost and redialling; `attempt` counts from 1, `since` is when the link went down.
    case reconnecting(attempt: Int, since: Date)
    /// The device has no network; resumes when it is back.
    case offline(since: Date)
    /// Paused by the app (iOS background); resumes silently on foreground.
    case paused
    /// The host refused us (pairing, sign-in, host key): the user has to act. `action` names
    /// the fix ("Re-pair…"); nil offers Retry.
    case needsAttention(reason: String, action: String?)
    /// The network failed to reach the host; still retrying slowly in the background.
    case unreachable(reason: String, hint: String?)
    /// Saved but not dialled (a host nobody opened since launch).
    case disconnected

    /// Takes input: live, even if slow.
    public var isLive: Bool {
        switch self {
        case .connected, .slow: true
        default: false
        }
    }

    /// Shows nothing in the chrome: healthy, paused, or never dialled.
    public var isQuiet: Bool {
        switch self {
        case .connected, .paused, .disconnected: true
        default: false
        }
    }

    /// Whether the user has to act (a card with actions, the Inbox).
    public var isFailure: Bool {
        switch self {
        case .needsAttention, .unreachable: true
        default: false
        }
    }

    /// The state in a few words (accessibility labels, the Hosts list, tooltips).
    public var title: String {
        switch self {
        case .connected: "Connected"
        case .slow(let rtt): "Slow connection · \(rtt.milliseconds) ms"
        case .connecting(let phase): phase ?? "Connecting…"
        case .starting: "Starting…"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline · waiting for network"
        case .paused: "Paused"
        case .needsAttention: "Can't connect"
        case .unreachable: "Can't reach host"
        case .disconnected: "Not connected"
        }
    }

    /// The SF Symbol shown in place of the host icon, or nil when the state shows no glyph
    /// (healthy, paused, never dialled) or a spinner (connecting).
    public var symbol: String? {
        switch self {
        case .connected, .paused, .disconnected, .connecting, .starting: nil
        case .slow: "wifi.exclamationmark"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .needsAttention, .unreachable: "exclamationmark.triangle.fill"
        }
    }

    var isConnecting: Bool { if case .connecting = self { true } else { false } }

    /// How long a link may be on its way or down before the window offers to retry or
    /// disconnect.
    public static let longWait: TimeInterval = 40

    public var color: ChromeStyle {
        switch self {
        case .slow, .reconnecting: DS.Palette.attention
        case .needsAttention, .unreachable: DS.Palette.error
        default: DS.Palette.textSecondary
        }
    }
}

nonisolated private extension Duration {
    var milliseconds: Int { Int((self / .milliseconds(1)).rounded()) }
}

/// The state glyph that replaces a host's icon when its link is not healthy: nothing when
/// connected, the system mini spinner while connecting (after a 1 s grace, so a quick connect
/// shows nothing), a static symbol otherwise.
public struct ConnectionGlyph: View {
    let state: ConnectionState
    /// What to show while healthy (the host's own icon, or nothing).
    let healthy: AnyView?

    public init(_ state: ConnectionState) {
        self.state = state
        healthy = nil
    }

    /// A host icon that the state glyph replaces while the link is not healthy.
    public init(_ state: ConnectionState, healthy: some View) {
        self.state = state
        self.healthy = AnyView(healthy)
    }

    public var body: some View {
        Group {
            if state == .starting || state.isConnecting {
                GraceSpinner()
            } else if let symbol = state.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(state.color)
                    .symbolRenderingMode(.monochrome)
            } else if let healthy {
                healthy
            }
        }
        .accessibilityLabel(state.title)
    }
}

@available(*, deprecated, renamed: "ConnectionGlyph")
public typealias ConnectionDot = ConnectionGlyph

/// The system mini spinner, shown only once a wait has lasted `grace`.
struct GraceSpinner: View {
    var grace: Duration = .seconds(1)
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if shown {
                if reduceMotion {
                    Image(systemName: "circle.dotted").foregroundStyle(DS.Palette.textSecondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
        .task {
            try? await Task.sleep(for: grace)
            shown = true
        }
    }
}

/// Over a host's panes while the link is not live. The last frame stays: undimmed for a 2 s
/// grace, then dimmed. Trouble past a 1 s grace is a one-line notice at the top right; a card with actions
/// appears only for a failure or a link gone for 40 s. Live, slow and paused links show nothing
/// here.
private struct ConnectionOverlayModifier: ViewModifier {
    let state: ConnectionState
    let hostName: String
    /// The panes show the screens this device saved (instant start), already marked quietly
    /// on each pane and in the header: while connecting, no dim and no notice for the grace.
    let showsSavedState: Bool
    /// The host is this device's own helper.
    let isThisDevice: Bool
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    @State private var downSince: Date?

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = ConnectionPresentation(
                state: state, hostName: hostName, showsSavedState: showsSavedState, isThisDevice: isThisDevice,
                downFor: downSince.map { context.date.timeIntervalSince($0) } ?? 0, now: context.date)
            content
                .fadedTowardTerminalBackground(presentation.fade)
                // A link that drops for a moment leaves the panes as they were: the terminal keeps
                // the keyboard and its place (a view that stops taking touches gives the keyboard
                // up, and the grid moves under it). Only the card takes the panes away.
                .allowsHitTesting(presentation.card == nil)
                .overlay(alignment: .topTrailing) {
                    if let notice = presentation.notice {
                        // The notice is also the way to act on it: Retry Now or Disconnect.
                        Menu {
                            Button("Retry Now", systemImage: "arrow.clockwise", action: onRetry)
                            Button("Disconnect", systemImage: "xmark.circle", action: onDisconnect)
                        } label: {
                            ConnectionNotice(state: state, copy: notice)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .padding(DS.Space.l)
                        .motionTransition(.fade)
                    }
                }
                .overlay {
                    if let card = presentation.card {
                        ConnectionCard(state: state, card: card, onRetry: onRetry, onDisconnect: onDisconnect)
                            .motionTransition(.card())
                    }
                }
                .animation(DS.Motion.standard, value: presentation)
        }
        .onChange(of: state.isQuiet || state.isLive, initial: true) { _, healthy in
            downSince = healthy ? nil : (downSince ?? .now)
        }
    }
}

/// What the overlay shows for a state that has lasted `downFor` seconds.
struct ConnectionPresentation: Equatable {
    /// How far the panes fade toward the terminal's background.
    var fade = 0.0
    var notice: NoticeCopy?
    var card: CardCopy?

    /// How long a link may be on its way or down before a notice says so, before the pane dims,
    /// and before the card replaces the notice. A quick connect shows nothing. The notice grace
    /// sits just under the timeline's 1 s tick so it shows on the first tick past it.
    static let noticeAfter: TimeInterval = 0.9
    static let dimAfter: TimeInterval = 2
    static let cardAfter = ConnectionState.longWait
    static let dimLevel = 0.45

    init() {}

    init(state: ConnectionState, hostName: String, showsSavedState: Bool, isThisDevice: Bool, downFor: TimeInterval, now: Date) {
        // Saved screens carry their own light wash: nothing dims them further while they wait.
        if !state.isLive, !state.isQuiet, !showsSavedState, downFor >= Self.dimAfter { fade = Self.dimLevel }
        switch state {
        case .connected, .slow, .paused, .disconnected:
            fade = 0
        case .starting:
            fade = !showsSavedState && downFor >= Self.noticeAfter ? ChromePalette.waitingLevel : 0
            if downFor >= Self.cardAfter {
                card = CardCopy(
                    title: "The helper on \(hostName) hasn't answered",
                    detail: "It is still starting. Retrying automatically.",
                    action: "Retry Now")
            } else if downFor >= Self.dimAfter {
                notice = NoticeCopy(before: "Starting…")
            }
        case .connecting where showsSavedState:
            if downFor >= Self.dimAfter { notice = NoticeCopy(before: "Connecting to ", host: hostName, after: "…") }
        case .connecting(let phase):
            guard downFor >= Self.noticeAfter else { break }
            notice = phase.map { NoticeCopy(before: "\($0.trimmingCharacters(in: ["…"])) on ", host: hostName, after: "…") }
                ?? NoticeCopy(before: "Connecting to ", host: hostName, after: "…")
        case .reconnecting(_, let since):
            let goneFor = now.timeIntervalSince(since)
            if downFor < Self.noticeAfter {
                break
            } else if goneFor >= Self.cardAfter {
                card = CardCopy(
                    title: "Lost connection to \(hostName)",
                    // This device's own helper may be what stopped, and its sessions with it.
                    detail: isThisDevice
                        ? "The helper on this Mac isn't answering. Reconnecting automatically."
                        : "Sessions keep running on the host. Reconnecting automatically.",
                    action: "Reconnect Now")
            } else {
                notice = NoticeCopy.reconnecting(to: hostName, ago: Self.ago(goneFor))
            }
        case .offline:
            notice = NoticeCopy(before: "Offline · waiting for network")
        case .needsAttention(let reason, let action):
            card = CardCopy(title: "Can't connect to \(hostName)", detail: reason, action: action ?? "Retry")
        case .unreachable(let reason, let hint):
            card = CardCopy(
                title: "Can't reach \(hostName)",
                detail: [reason, hint].compactMap(\.self).joined(separator: " "),
                action: "Retry")
        }
    }

    static func ago(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, Int(seconds))).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)) + " ago"
    }
}

struct CardCopy: Equatable {
    var title: String
    var detail: String
    var action: String
}

/// A notice's words, in parts that give way in order when the line is short: first "last
/// contact" goes, then the host's name shortens (its domain, then its middle). The time stays.
struct NoticeCopy: Equatable {
    var before: String
    var host: String?
    var after = ""
    /// `after` for a short line ("… · 12s ago").
    var compactAfter: String?

    static func reconnecting(to host: String, ago: String) -> NoticeCopy {
        NoticeCopy(before: "Reconnecting to ", host: host, after: "… · last contact \(ago)", compactAfter: "… · \(ago)")
    }

    var text: String { before + (host ?? "") + after }

    /// `after` beside a host name already cut short by an ellipsis: without a second one.
    static func squeezed(_ after: String) -> String {
        after.hasPrefix("…") ? String(after.dropFirst()) : after
    }

    /// A host name for a short line: without its domain ("studio.local", "box.tail1234.ts.net").
    static func shortHost(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), dot > name.startIndex,
              name.rangeOfCharacter(from: .letters) != nil, !name.allSatisfy({ $0.isNumber || $0 == "." })
        else { return name }
        return String(name[..<dot])
    }
}

/// One line at the top right of the pane: glyph and words, on material. On a narrow pane the
/// words shorten by priority (`NoticeCopy`), never cutting the time.
struct ConnectionNotice: View {
    let state: ConnectionState
    let copy: NoticeCopy

    var body: some View {
        HStack(spacing: DS.Space.row) {
            ConnectionGlyph(state)
                .font(.caption)
            ViewThatFits(in: .horizontal) {
                line(host: copy.host, after: copy.after)
                if let compact = copy.compactAfter {
                    line(host: copy.host, after: compact)
                }
                line(host: copy.host.map(NoticeCopy.shortHost), after: NoticeCopy.squeezed(copy.compactAfter ?? copy.after), squeezes: true)
            }
            .monospacedDigit()
            .accessibilityLabel(copy.text)
        }
        .font(DS.Font.overlay)
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.row)
        .floatingCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-notice")
    }

    /// The words on one line; `squeezes`: the host's name gives way (middle first) so the rest
    /// fits whole.
    private func line(host: String?, after: String, squeezes: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(copy.before).fixedSize()
            if let host {
                Text(host)
                    .truncationMode(.middle)
                    .layoutPriority(squeezes ? -1 : 0)
                    .fixedSize(horizontal: !squeezes, vertical: false)
            }
            Text(after).fixedSize()
        }
        .lineLimit(1)
    }
}

/// The card for a failure or a long outage: what happened, why, and the way forward.
private struct ConnectionCard: View {
    let state: ConnectionState
    let card: CardCopy
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                ConnectionGlyph(state)
                Text(card.title).font(.headline)
            }
            Text(card.detail)
                .font(.subheadline)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(.glass)
                Button(card.action, action: onRetry)
                    .buttonStyle(.primaryGlass)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .controlSize(.regular)
        }
        .chromeContent()
        .padding(DS.Space.l)
        .frame(width: 340)
        .floatingPanel(cornerRadius: DS.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-overlay")
    }
}

public extension View {
    func connectionOverlay(
        _ state: ConnectionState, hostName: String, showsSavedState: Bool = false, isThisDevice: Bool = false,
        onRetry: @escaping () -> Void, onDisconnect: @escaping () -> Void
    ) -> some View {
        modifier(ConnectionOverlayModifier(
            state: state, hostName: hostName, showsSavedState: showsSavedState, isThisDevice: isThisDevice,
            onRetry: onRetry, onDisconnect: onDisconnect))
    }
}
