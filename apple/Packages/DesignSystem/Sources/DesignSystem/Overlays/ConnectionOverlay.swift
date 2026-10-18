import SwiftUI

nonisolated public enum ConnectionState: Hashable, Sendable {
    case connected
    /// First connection in progress.
    case connecting
    /// Lost and redialling; `attempt` counts from 1, `since` is when output last arrived.
    case reconnecting(attempt: Int, since: Date)
    /// Gave up the fast retries (12 failures or 60 s); still retrying slowly in the background.
    case unreachable(reason: String, hint: String?)

    public var isLive: Bool { self == .connected }

    public var title: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .unreachable: "Unreachable"
        }
    }

    public var color: Color {
        switch self {
        case .connected: DS.Palette.done
        case .connecting, .reconnecting: DS.Palette.working
        case .unreachable: DS.Palette.error
        }
    }
}

/// A connection dot for host rows and the sidebar footer: solid when connected, a spinner while
/// dialling, a hollow red ring when unreachable.
public struct ConnectionDot: View {
    let state: ConnectionState

    public init(_ state: ConnectionState) {
        self.state = state
    }

    public var body: some View {
        Group {
            switch state {
            case .connected:
                Circle().fill(state.color).padding(2)
            case .connecting, .reconnecting:
                Spinner(color: state.color, lineWidth: 1.5)
            case .unreachable:
                Circle().strokeBorder(state.color, lineWidth: 1.5).padding(1)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(state.title)
    }
}

/// Keeps the last frame visible but dimmed and desaturated while the link is down, with a floating
/// card that says what is happening and offers Retry and Disconnect. Never a blank screen.
private struct ConnectionOverlayModifier: ViewModifier {
    let state: ConnectionState
    let hostName: String
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    func body(content: Content) -> some View {
        content
            .saturation(state.isLive ? 1 : 0.25)
            .opacity(state.isLive ? 1 : 0.55)
            .allowsHitTesting(state.isLive)
            .overlay {
                if !state.isLive {
                    card
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(DS.Motion.overlay, value: state)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                ConnectionDot(state)
                Text(headline).font(.headline)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(detail(now: context.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s) {
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(.glass)
                Button("Retry Now", action: onRetry)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .controlSize(.regular)
        }
        .padding(DS.Space.l)
        .frame(width: 340)
        .floatingPanel(cornerRadius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-overlay")
    }

    private var headline: String {
        switch state {
        case .connected: ""
        case .connecting: "Connecting to \(hostName)"
        case .reconnecting: "Reconnecting to \(hostName)"
        case .unreachable: "\(hostName) is unreachable"
        }
    }

    private func detail(now: Date) -> String {
        switch state {
        case .connected: return ""
        case .connecting: return "Your sessions keep running on the host."
        case .reconnecting(let attempt, let since):
            let seconds = max(0, Int(now.timeIntervalSince(since)))
            return "Attempt \(attempt) · last output \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) ago. Sessions keep running on the host; you'll resume where you left off."
        case .unreachable(let reason, let hint):
            return [reason, hint].compactMap(\.self).joined(separator: " ")
        }
    }
}

public extension View {
    func connectionOverlay(
        _ state: ConnectionState, hostName: String, onRetry: @escaping () -> Void, onDisconnect: @escaping () -> Void
    ) -> some View {
        modifier(ConnectionOverlayModifier(state: state, hostName: hostName, onRetry: onRetry, onDisconnect: onDisconnect))
    }
}
