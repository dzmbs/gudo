import Foundation
import HostKit

nonisolated enum TimelineWindowError: Error {
    case missingSnapshot
    case cursorGap
    case unsupportedAppend
    case staleHistory
}

nonisolated struct TimelineChanges: Sendable {
    var changed: Set<String> = []
    var removed: Set<String> = []
    var didReset = false
    var needsHistoryCursor = false
}

nonisolated struct TimelineWindow: Sendable {
    private(set) var cursor: TimelineCursor?
    private(set) var session: TimelineSession?
    private(set) var order: [String] = []
    private(set) var items: [String: TimelineItem] = [:]
    private(set) var before: UInt64?
    private(set) var hasNewerGap = false
    private(set) var needsHistoryCursor = false
    private(set) var note: String?
    private var boundaries: [String: UInt64] = [:]
    let limit: Int

    init(limit: Int = 3_000) { self.limit = max(60, limit) }

    mutating func apply(_ update: TimelineUpdate, resetSnapshot: Bool = false, protectsHistory: Bool = false) throws -> TimelineChanges {
        var next = self
        var changes = TimelineChanges()
        for operation in update.operations {
            switch operation {
            case .snapshot(let snapshot):
                next.snapshot(snapshot, reset: resetSnapshot, changes: &changes)
            case .unavailable(let message):
                next.note = message
            case .upsert(let cursor, let item):
                guard try next.accept(cursor) else { continue }
                if next.items[item.id] == nil {
                    if next.hasNewerGap || (protectsHistory && next.order.count >= next.limit) {
                        next.hasNewerGap = true
                        continue
                    }
                    next.order.append(item.id)
                }
                if let current = next.items[item.id], current.revision >= item.revision { continue }
                next.items[item.id] = item
                changes.changed.insert(item.id)
            case .append(let cursor, let id, let field, let text):
                guard try next.accept(cursor) else { continue }
                guard var item = next.items[id] else {
                    if next.hasNewerGap { continue }
                    throw TimelineWindowError.missingSnapshot
                }
                switch (item.body, field) {
                case (.assistant(var value), "Text"):
                    guard value.text.utf8.count + text.utf8.count <= 256 * 1_024 else { throw TimelineWindowError.unsupportedAppend }
                    value.text += text
                    item.body = .assistant(value)
                case (.thinking(var value), "Thinking"):
                    guard (value.text?.utf8.count ?? 0) + text.utf8.count <= 256 * 1_024 else { throw TimelineWindowError.unsupportedAppend }
                    value.text = (value.text ?? "") + text
                    item.body = .thinking(value)
                case (.tool(var value), "Output"):
                    guard var output = value.output else { throw TimelineWindowError.unsupportedAppend }
                    let bytes = Array((output.preview + text).utf8.suffix(4_096))
                    let start = bytes.firstIndex { $0 & 0xC0 != 0x80 } ?? bytes.endIndex
                    output.preview = String(decoding: bytes[start...], as: UTF8.self)
                    let count = output.bytes.addingReportingOverflow(UInt64(text.utf8.count))
                    output.bytes = count.overflow ? UInt64.max : count.partialValue
                    value.output = output
                    item.body = .tool(value)
                default: throw TimelineWindowError.unsupportedAppend
                }
                guard item.revision < UInt32.max else { throw TimelineWindowError.cursorGap }
                item.revision += 1
                next.items[id] = item
                changes.changed.insert(id)
            case .remove(let cursor, let id):
                guard try next.accept(cursor) else { continue }
                next.items[id] = nil
                next.order.removeAll { $0 == id }
                next.boundaries[id] = nil
                changes.removed.insert(id)
            case .session(let cursor, let session):
                guard try next.accept(cursor) else { continue }
                next.session = session
            case .checkpoint(let cursor):
                _ = try next.accept(cursor)
            }
        }
        next.trimOldest(changes: &changes)
        changes.removed.subtract(next.items.keys)
        changes.changed.subtract(changes.removed)
        self = next
        return changes
    }

    mutating func replace(_ snapshot: TimelineSnapshot) -> TimelineChanges {
        reconcile(snapshot, reset: true)
    }

    mutating func reconcile(_ snapshot: TimelineSnapshot, reset: Bool = false) -> TimelineChanges {
        var changes = TimelineChanges()
        self.snapshot(snapshot, reset: reset, changes: &changes)
        trimOldest(changes: &changes)
        changes.removed.subtract(items.keys)
        changes.changed.subtract(changes.removed)
        return changes
    }

    mutating func prepend(_ page: TimelineSnapshot) throws -> TimelineChanges {
        guard page.cursor.epoch == cursor?.epoch else { throw TimelineWindowError.staleHistory }
        var changes = TimelineChanges()
        var prefix: [String] = []
        var seen: Set<String> = []
        for item in page.items {
            guard seen.insert(item.id).inserted else { continue }
            if items[item.id] == nil { prefix.append(item.id) }
            if let current = items[item.id], current.revision >= item.revision { continue }
            items[item.id] = item
            changes.changed.insert(item.id)
        }
        order = prefix + order
        before = page.before
        needsHistoryCursor = false
        if let first = page.items.first { boundaries[first.id] = page.before ?? 0 }
        if prefix.isEmpty, page.before == nil, let first = order.first { boundaries[first] = 0 }
        if order.count > limit {
            let removed = order.suffix(order.count - limit)
            for identifier in removed {
                items[identifier] = nil
                boundaries[identifier] = nil
                changes.removed.insert(identifier)
            }
            order.removeLast(order.count - limit)
            hasNewerGap = true
        }
        changes.changed.subtract(changes.removed)
        return changes
    }

    private mutating func accept(_ incoming: TimelineCursor) throws -> Bool {
        guard let current = cursor else { throw TimelineWindowError.missingSnapshot }
        guard incoming.epoch == current.epoch else { throw TimelineWindowError.cursorGap }
        guard incoming.sequence > current.sequence else { return false }
        guard current.sequence != UInt64.max, incoming.sequence == current.sequence + 1 else { throw TimelineWindowError.cursorGap }
        cursor = incoming
        return true
    }

    private mutating func snapshot(_ snapshot: TimelineSnapshot, reset: Bool, changes: inout TimelineChanges) {
        if !reset, let cursor, cursor.epoch == snapshot.cursor.epoch, snapshot.cursor.sequence < cursor.sequence { return }
        let shouldReset = reset || cursor?.epoch != snapshot.cursor.epoch || session?.nativeSession != snapshot.session.nativeSession
        if shouldReset {
            changes.removed.formUnion(order)
            order.removeAll(keepingCapacity: true)
            items.removeAll(keepingCapacity: true)
            boundaries.removeAll(keepingCapacity: true)
            hasNewerGap = false
            needsHistoryCursor = false
            before = snapshot.before
            changes.didReset = true
        }
        cursor = snapshot.cursor
        session = snapshot.session
        note = nil
        if snapshot.items.isEmpty {
            changes.removed.formUnion(order)
            order.removeAll(keepingCapacity: true)
            items.removeAll(keepingCapacity: true)
            boundaries.removeAll(keepingCapacity: true)
            before = snapshot.before
            hasNewerGap = false
            needsHistoryCursor = false
            changes.didReset = true
            return
        }
        if !shouldReset, hasNewerGap {
            for item in snapshot.items where items[item.id] != nil { upsertSnapshot(item, changes: &changes) }
            return
        }
        if !shouldReset, !order.isEmpty, !snapshot.items.isEmpty,
           !snapshot.items.contains(where: { items[$0.id] != nil }) {
            hasNewerGap = true
            return
        }
        if !shouldReset, let overlap = snapshot.items.first(where: { items[$0.id] != nil }),
           let index = order.firstIndex(of: overlap.id) {
            let incoming = Set(snapshot.items.map(\.id))
            for identifier in order.suffix(from: index) where !incoming.contains(identifier) {
                items[identifier] = nil
                boundaries[identifier] = nil
                changes.removed.insert(identifier)
            }
            order.removeSubrange(index...)
        }
        if order.isEmpty { before = snapshot.before }
        var arranged = Set(order)
        for item in snapshot.items {
            if arranged.insert(item.id).inserted { order.append(item.id) }
            upsertSnapshot(item, changes: &changes)
        }
        if let first = snapshot.items.first { boundaries[first.id] = snapshot.before ?? 0 }
        changes.removed.subtract(items.keys)
    }

    private mutating func upsertSnapshot(_ item: TimelineItem, changes: inout TimelineChanges) {
        if let current = items[item.id], current.revision >= item.revision { return }
        items[item.id] = item
        changes.changed.insert(item.id)
    }

    private mutating func trimOldest(changes: inout TimelineChanges) {
        guard order.count > limit || needsHistoryCursor else { return }
        let minimum = max(0, order.count - limit)
        let boundary = (minimum..<order.count).first { boundaries[order[$0]] != nil }
        let count = boundary ?? minimum
        for identifier in order.prefix(count) {
            items[identifier] = nil
            boundaries[identifier] = nil
            changes.removed.insert(identifier)
        }
        order.removeFirst(count)
        let position = order.first.flatMap { boundaries[$0] }
        before = position.flatMap { $0 == 0 ? nil : $0 }
        needsHistoryCursor = position == nil
        changes.needsHistoryCursor = needsHistoryCursor
    }
}
