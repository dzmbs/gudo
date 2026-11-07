import Foundation

@MainActor
final class ChatModelLease {
    let model: TimelineModel
    private let owner: UUID
    private weak var pool: ChatModelPool?

    fileprivate init(model: TimelineModel, owner: UUID, pool: ChatModelPool) {
        self.model = model
        self.owner = owner
        self.pool = pool
    }

    isolated deinit { close() }

    func close() {
        guard let pool else { return }
        self.pool = nil
        pool.release(owner)
    }
}

@MainActor
final class ChatModelPool {
    static let maximumCapacity = 4
    static let shared = ChatModelPool()

    private final class Entry {
        let model: TimelineModel
        var users = 0
        var recency = 0
        init(model: TimelineModel) { self.model = model }
    }

    private let capacity: Int
    private let modelValueByteLimit: Int
    private var entries: [UUID: Entry] = [:]
    private var recency = 0

    init(
        capacity: Int = ChatModelPool.maximumCapacity,
        valueByteLimit: Int = TimelineWindow.defaultByteLimit
    ) {
        self.capacity = max(1, min(Self.maximumCapacity, capacity))
        modelValueByteLimit = max(TimelineWindow.minimumByteLimit, valueByteLimit / self.capacity)
    }

    func acquire(_ owner: UUID, pane: UInt64) -> ChatModelLease? {
        if let existing = entries[owner], existing.model.pane != pane { return nil }
        if entries[owner] == nil {
            if entries.count >= capacity {
                // The candidate set is bounded; visible controllers must never lose their model.
                guard let oldest = entries.filter({ $0.value.users == 0 })
                    .min(by: { $0.value.recency < $1.value.recency })?.key else { return nil }
                entries.removeValue(forKey: oldest)
            }
            entries[owner] = Entry(model: TimelineModel(pane: pane, valueByteLimit: modelValueByteLimit))
        }
        guard let entry = entries[owner] else { return nil }
        touch(entry)
        entry.users += 1
        return ChatModelLease(model: entry.model, owner: owner, pool: self)
    }

    fileprivate func release(_ owner: UUID) {
        guard let entry = entries[owner], entry.users > 0 else { return }
        entry.users -= 1
        if entry.users == 0 {
            touch(entry)
            entry.model.stop()
        }
    }

    private func touch(_ entry: Entry) {
        recency += 1
        entry.recency = recency
    }
}
