nonisolated struct LRUCost: Equatable, Sendable {
    let bytes: Int
    let units: Int

    init(bytes: Int = 0, units: Int = 0) {
        self.bytes = max(0, bytes)
        self.units = max(0, units)
    }
}

/// Single-owner cache. Keep it inside one actor; reads that promote entries are mutations.
nonisolated final class BoundedLRU<Key: Hashable, Value> {
    private final class Entry {
        let key: Key
        let value: Value
        let cost: LRUCost
        weak var previous: Entry?
        var next: Entry?

        init(key: Key, value: Value, cost: LRUCost) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let capacity: Int
    private let byteLimit: Int
    private let unitLimit: Int
    private var entries: [Key: Entry] = [:]
    private var first: Entry?
    private var last: Entry?
    private(set) var cost = LRUCost()
    var count: Int { entries.count }

    init(capacity: Int, byteLimit: Int = .max, unitLimit: Int = .max) {
        self.capacity = max(0, capacity)
        self.byteLimit = max(0, byteLimit)
        self.unitLimit = max(0, unitLimit)
    }

    func peek(_ key: Key) -> Value? { entries[key]?.value }

    func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        if entry !== first { unlink(entry); prepend(entry) }
        return entry.value
    }

    @discardableResult
    func insert(_ value: Value, for key: Key, cost incoming: LRUCost = LRUCost()) -> Bool {
        remove(key)
        guard capacity > 0, incoming.bytes <= byteLimit, incoming.units <= unitLimit else { return false }
        // Reject a single uncacheable value before evicting unrelated completed work.
        // Subtract the incoming allowance first so adding near Int.max cannot overflow.
        while count >= capacity || cost.bytes > byteLimit - incoming.bytes || cost.units > unitLimit - incoming.units {
            guard let oldest = last else { break }
            remove(oldest.key)
        }
        let entry = Entry(key: key, value: value, cost: incoming)
        entries[key] = entry
        prepend(entry)
        cost = LRUCost(bytes: cost.bytes + incoming.bytes, units: cost.units + incoming.units)
        return true
    }

    @discardableResult
    func remove(_ key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        unlink(entry)
        cost = LRUCost(bytes: cost.bytes - entry.cost.bytes, units: cost.units - entry.cost.units)
        return entry.value
    }

    func removeAll() {
        first = nil
        last = nil
        entries.removeAll(keepingCapacity: false)
        cost = LRUCost()
    }

    private func unlink(_ entry: Entry) {
        if let previous = entry.previous { previous.next = entry.next } else { first = entry.next }
        if let next = entry.next { next.previous = entry.previous } else { last = entry.previous }
        entry.previous = nil
        entry.next = nil
    }

    private func prepend(_ entry: Entry) {
        entry.next = first
        first?.previous = entry
        first = entry
        if last == nil { last = entry }
    }
}
