import SwiftUI

//
// and only a failure, or a link gone for 40 s, a card with actions (VS Code). Motion is the system
// spinner while connecting, never a pulsing dot.

nonisolated public enum ConnectionState: Hashable, Sendable {
    /// Live.
    case connected
    /// Live but slow: keystrokes take `rtt` to echo.
    case slow(rtt: Duration)
    /// On the way to live; `phase` says what it waits for ("Opening session…").
    case connecting(phase: String?)
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
        case .connected, .paused, .disconnected, .connecting: nil
        case .slow: "wifi.exclamationmark"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .needsAttention, .unreachable: "exclamationmark.triangle.fill"
        }
    }

    /// The glyph's colour: amber for "your turn", red for failure, otherwise the chrome's own.
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

    /// A host icon that the state glyph replaces while the link is not healthy (Zed).
    public init(_ state: ConnectionState, healthy: some View) {
        self.state = state
        self.healthy = AnyView(healthy)
    }

    public var body: some View {
        Group {
            if case .connecting = state {
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

/// The deprecated name of `ConnectionGlyph` (it was a coloured dot).
@available(*, deprecated, renamed: "ConnectionGlyph")
public typealias ConnectionDot = ConnectionGlyph

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
/// with actions appears only for a failure or a link gone for 40 s (VS Code
/// `DISCONNECT_PROMPT_TIME`). Live, slow and paused links show nothing here.
private struct ConnectionOverlayModifier: ViewModifier {
    let state: ConnectionState
    let hostName: String
    /// The panes show the screens this device saved (instant start), already marked quietly
    /// on each pane and in the header: while connecting, no dim and no notice for the grace.
    let showsSavedState: Bool
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    /// How long a link may be down before the pane dims and before the card replaces the notice.
    static let dimAfter: TimeInterval = 2
    static let cardAfter: TimeInterval = 40

    @State private var downSince: Date?

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = presentation(now: context.date)
            content
                .saturation(presentation.dimmed ? 0.25 : 1)
                .opacity(presentation.dimmed ? 0.55 : 1)
                .allowsHitTesting(state.isLive || state == .paused || state == .disconnected || savedAndConnecting)
                .overlay(alignment: .topTrailing) {
                    if let notice = presentation.notice {
                        ConnectionNotice(state: state, text: notice)
                            .padding(DS.Space.s)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if let card = presentation.card {
                        ConnectionCard(state: state, card: card, onRetry: onRetry, onDisconnect: onDisconnect)
                            .scalingTransition(0.96)
                    }
                }
                .animation(DS.Motion.overlay, value: presentation)
        }
        .onChange(of: state.isQuiet || state.isLive, initial: true) { _, healthy in
            downSince = healthy ? nil : (downSince ?? .now)
        }
    }

    /// Saved screens on the way to live take clicks and scrolls; typed input waits (held).
    private var savedAndConnecting: Bool {
        if case .connecting = state { showsSavedState } else { false }
    }

    private struct Presentation: Equatable {
        var dimmed = false
        var notice: String?
        var card: CardCopy?
    }

    private func presentation(now: Date) -> Presentation {
        let down = downSince.map { now.timeIntervalSince($0) } ?? 0
        var result = Presentation(dimmed: !state.isLive && !state.isQuiet && down >= Self.dimAfter)
        switch state {
        case .connected, .slow, .paused, .disconnected:
            result.dimmed = false
        case .connecting where showsSavedState:
            result.dimmed = false
            if down >= Self.dimAfter { result.notice = "Connecting to \(hostName)…" }
        case .connecting(let phase):
            result.notice = phase.map { "\($0.trimmingCharacters(in: ["…"])) on \(hostName)…" } ?? "Connecting to \(hostName)…"
        case .reconnecting(_, let since):
            let gone = now.timeIntervalSince(since)
            if gone >= Self.cardAfter {
                result.card = CardCopy(
                    title: "Lost connection to \(hostName)",
                    detail: "Sessions keep running on the host. Reconnecting automatically.",
                    action: "Reconnect Now")
            } else {
                result.notice = "Reconnecting to \(hostName)… · last contact \(Self.ago(gone))"
            }
        case .offline:
            result.notice = "Offline · waiting for network"
        case .needsAttention(let reason, let action):
            result.card = CardCopy(title: "Can't connect to \(hostName)", detail: reason, action: action ?? "Retry")
        case .unreachable(let reason, let hint):
            result.card = CardCopy(
                title: "Can't reach \(hostName)",
                detail: [reason, hint].compactMap(\.self).joined(separator: " "),
                action: "Retry")
        }
        return result
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

private struct ConnectionNotice: View {
    let state: ConnectionState
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.row) {
            ConnectionGlyph(state)
                .font(.caption)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(DS.Font.overlay)
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.row)
        .floatingCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-notice")
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
        .floatingPanel(cornerRadius: DS.Radius.largeCard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-overlay")
    }
}

public extension View {
    func connectionOverlay(
        _ state: ConnectionState, hostName: String, showsSavedState: Bool = false,
        onRetry: @escaping () -> Void, onDisconnect: @escaping () -> Void
    ) -> some View {
        modifier(ConnectionOverlayModifier(
            state: state, hostName: hostName, showsSavedState: showsSavedState, onRetry: onRetry, onDisconnect: onDisconnect))
    }
}
