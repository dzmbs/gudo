/// Delivers notes one at a time, keeping only the newest per key while one is in flight. Each
/// pane has one notification, so a burst of a thousand attention items over twenty panes is at
/// most twenty system requests, not a thousand concurrent ones.
@MainActor
public final class NoteQueue<Note> {
    private var pending: [(key: String, note: Note)] = []
    private var draining = false
    private let deliver: @MainActor (Note) async -> Void

    public init(deliver: @escaping @MainActor (Note) async -> Void) {
        self.deliver = deliver
    }

    public var count: Int { pending.count }

    public func enqueue(_ note: Note, key: String) {
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].note = note
        } else {
            pending.append((key, note))
        }
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            while !pending.isEmpty {
                await deliver(pending.removeFirst().note)
            }
            draining = false
        }
    }
}
