import HostKit

/// What an empty Chat says. A Claude Code started by hand in a shell has no session at first:
/// Chat finds it from the transcript Claude Code saves, and says so instead of "No messages yet".
nonisolated enum ChatEmptyState: Equatable {
    case opening
    case findingSession
    case empty

    init(isLoading: Bool, session: TimelineSession?) {
        if isLoading { self = .opening }
        else if let session, session.nativeSession.isEmpty { self = .findingSession }
        else { self = .empty }
    }

    var title: String {
        switch self {
        case .opening: "Opening Chat…"
        case .findingSession: "Looking for this conversation"
        case .empty: "No messages yet"
        }
    }

    var detail: String? {
        switch self {
        case .findingSession:
            "Claude Code was started in the shell, so Chat finds it from the transcript Claude Code saves. It shows here after the next message. Until then it is in Terminal."
        case .opening, .empty: nil
        }
    }

    var offersTerminal: Bool { self == .findingSession }
}
