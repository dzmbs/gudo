import Foundation

/// A host connection's health as the UI shows it, derived from the object that sends input
/// (04-mobile-ux R8): "connected" means the transport answered recently, never a socket flag
/// (R2). Every non-live state offers retry (R9).
nonisolated public enum ConnectionStatus: Sendable, Equatable {
    /// Not started (a saved host nobody opened yet).
    case idle
    /// First dial.
    case connecting
    /// Live. `rtt` is the latest keystroke round trip, if measured.
    case connected(rtt: Duration?)
    /// Lost; redialling with backoff. Content stays on screen, dimmed.
    case reconnecting(attempt: UInt32, reason: String)
    /// Background with the retry budget spent, or the device has no network; resumes on
    /// foreground or network change (R10).
    case offline(reason: String)
    /// Paused by the app (iOS background); resumes on foreground.
    case suspended
    /// Needs the user: refused pairing, failed auth, changed host key. Not retried until the
    /// user acts.
    case needsAttention(reason: String)

    public var isLive: Bool {
        if case .connected = self { true } else { false }
    }

    /// Whether the host belongs in "Needs you" for connection reasons.
    public var needsUser: Bool {
        switch self {
        case .needsAttention, .offline: true
        default: false
        }
    }

    /// One line for a status row (A22: health in words, not a spinner).
    public var summary: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let rtt):
            if let rtt { "Connected · \(Int((rtt / .milliseconds(1)).rounded())) ms" } else { "Connected" }
        case .reconnecting(let attempt, let reason):
            attempt > 0 ? "Reconnecting (attempt \(attempt)) · \(reason)" : "Reconnecting · \(reason)"
        case .offline(let reason): "Offline · \(reason)"
        case .suspended: "Paused"
        case .needsAttention(let reason): reason
        }
    }
}
