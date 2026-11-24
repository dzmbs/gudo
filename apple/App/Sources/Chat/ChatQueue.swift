import Foundation
import Observation

nonisolated struct ChatQueuedMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Messages written while the agent works, held on the device and sent one per finished turn,
/// oldest first, through the composer's usual once-only send.
@MainActor
@Observable
final class ChatQueue {
    static let limit = 8

    private(set) var messages: [ChatQueuedMessage] = []

    var isFull: Bool { messages.count >= Self.limit }

    @discardableResult
    func enqueue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isFull, text.utf8.count <= ChatComposer.maximumDraftBytes else { return false }
        messages.append(ChatQueuedMessage(text: text))
        return true
    }

    /// Takes a message out of the queue, to send or edit it.
    func take(_ id: UUID) -> ChatQueuedMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages.remove(at: index)
    }

    /// Puts back a message whose send did not go through, at the front where it was.
    func restore(_ message: ChatQueuedMessage) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.insert(message, at: 0)
    }

    func clear() { messages.removeAll() }
}
