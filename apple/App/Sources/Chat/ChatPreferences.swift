import Foundation

/// Chat's own settings, stored on the device.
nonisolated enum ChatPreferences {
    enum Key {
        static let collapsesTurns = "chat-collapse-finished-turns"
        static let sendWhileWorking = "chat-send-while-working"
    }

    /// What Send does while the agent is still working on a turn.
    enum SendWhileWorking: String, CaseIterable, Sendable {
        /// Hold the message and send it when the turn ends.
        case queue
        /// Send it now, for the agent to read mid-turn.
        case steer

        var title: String {
            switch self {
            case .queue: "Queue until the turn ends"
            case .steer: "Send right away"
            }
        }
    }

    static var collapsesTurns: Bool {
        UserDefaults.standard.object(forKey: Key.collapsesTurns) as? Bool ?? true
    }

    static var sendWhileWorking: SendWhileWorking {
        UserDefaults.standard.string(forKey: Key.sendWhileWorking).flatMap(SendWhileWorking.init(rawValue:)) ?? .queue
    }
}
