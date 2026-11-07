import Foundation
import HostKit

nonisolated enum TimelineWindowError: Error {
    case missingSnapshot
    case cursorGap
    case unsupportedAppend
    case staleHistory
    case valueTooLarge
    case historyBudget
}

nonisolated struct TimelineChanges: Sendable {
    var changed: Set<String> = []
    var removed: Set<String> = []
    var didReset = false
    var needsHistoryCursor = false
}

nonisolated struct TimelineWindow: Sendable {
    static let defaultByteLimit = 16 * 1_024 * 1_024
    static let minimumByteLimit = 1_024

    private(set) var cursor: TimelineCursor?
    private(set) var session: TimelineSession?
    private(set) var order: [String] = []
    private(set) var items: [String: TimelineItem] = [:]
    private(set) var before: UInt64?
    private(set) var hasNewerGap = false
    private(set) var needsHistoryCursor = false
    private(set) var note: String?
    private(set) var retainedBytes = 0
    private var boundaries: [String: UInt64] = [:]
    private var weights: [String: Int] = [:]
    let limit: Int
    let byteLimit: Int

    init(limit: Int = 3_000, byteLimit: Int = TimelineWindow.defaultByteLimit) {
        self.limit = max(60, limit)
        self.byteLimit = max(Self.minimumByteLimit, byteLimit)
    }

    mutating func apply(_ update: TimelineUpdate, resetSnapshot: Bool = false, protectsHistory: Bool = false) throws -> TimelineChanges {
        var next = self
        var changes = TimelineChanges()
        for operation in update.operations {
            switch operation {
            case .snapshot(let snapshot):
                next.snapshot(snapshot, reset: resetSnapshot, protectsHistory: protectsHistory, changes: &changes)
            case .unavailable(let message):
                next.note = message
            case .upsert(let cursor, let item):
                guard try next.accept(cursor) else { continue }
                if let current = next.items[item.id], current.revision >= item.revision { continue }
                let isNew = next.items[item.id] == nil
                if isNew && (next.hasNewerGap || (protectsHistory && next.items.count >= next.limit)) {
                    next.hasNewerGap = true
                    continue
                }
                let weight = TimelineValueWeight.of(item)
                guard weight <= next.byteLimit else { throw TimelineWindowError.valueTooLarge }
                guard next.store(item, weight: weight, protectsHistory: protectsHistory || next.hasNewerGap) else { continue }
                if isNew { next.order.append(item.id) }
                changes.changed.insert(item.id)
            case .append(let cursor, let id, let field, let text):
                guard try next.accept(cursor) else { continue }
                // A skipped append cannot be followed by another append onto its stale prefix.
                // Full upserts/snapshots can still reconcile existing values while reading history.
                if next.hasNewerGap { continue }
                guard var item = next.items[id] else { throw TimelineWindowError.missingSnapshot }
                switch (item.body, field) {
                case (.assistant(var value), .known(.text)):
                    guard value.text.utf8.count + text.utf8.count <= 256 * 1_024 else { throw TimelineWindowError.unsupportedAppend }
                    value.text += text
                    item.body = .assistant(value)
                case (.thinking(var value), .known(.thinking)):
                    guard (value.text?.utf8.count ?? 0) + text.utf8.count <= 256 * 1_024 else { throw TimelineWindowError.unsupportedAppend }
                    value.text = (value.text ?? "") + text
                    item.body = .thinking(value)
                case (.tool(var value), .known(.output)):
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
                let weight = TimelineValueWeight.of(item)
                guard weight <= next.byteLimit else { throw TimelineWindowError.valueTooLarge }
                guard next.store(item, weight: weight, protectsHistory: protectsHistory) else { continue }
                changes.changed.insert(id)
            case .remove(let cursor, let id):
                guard try next.accept(cursor) else { continue }
                next.discard(id)
                next.order.removeAll { $0 == id }
                changes.removed.insert(id)
            case .session(let cursor, let session):
                guard try next.accept(cursor) else { continue }
                next.session = session
            case .checkpoint(let cursor):
                _ = try next.accept(cursor)
            }
        }
        next.trimOldest(protectsHistory: protectsHistory || next.hasNewerGap, changes: &changes)
        changes.removed.subtract(next.items.keys)
        changes.changed.subtract(changes.removed)
        self = next
        return changes
    }

    mutating func replace(_ snapshot: TimelineSnapshot) -> TimelineChanges {
        reconcile(snapshot, reset: true)
    }

    mutating func reconcile(_ snapshot: TimelineSnapshot, reset: Bool = false, protectsHistory: Bool = false) -> TimelineChanges {
        var changes = TimelineChanges()
        self.snapshot(snapshot, reset: reset, protectsHistory: protectsHistory, changes: &changes)
        trimOldest(protectsHistory: protectsHistory || hasNewerGap, changes: &changes)
        changes.removed.subtract(items.keys)
        changes.changed.subtract(changes.removed)
        return changes
    }

    mutating func prepend(_ page: TimelineSnapshot, protecting readingItem: String? = nil) throws -> TimelineChanges {
        guard page.cursor.epoch == cursor?.epoch else { throw TimelineWindowError.staleHistory }
        guard page.items.allSatisfy({ TimelineValueWeight.of($0) <= byteLimit }) else { throw TimelineWindowError.valueTooLarge }
        var next = self
        let protected = readingItem.flatMap { items[$0] == nil ? nil : $0 } ?? order.first
        var changes = TimelineChanges()
        var prefix: [String] = []
        var seen: Set<String> = []
        for item in page.items {
            guard seen.insert(item.id).inserted else { continue }
            if next.items[item.id] == nil { prefix.append(item.id) }
            if let current = next.items[item.id], current.revision >= item.revision { continue }
            _ = next.store(item, weight: TimelineValueWeight.of(item), protectsHistory: false)
            changes.changed.insert(item.id)
        }
        next.order = prefix + next.order
        next.before = page.before
        next.needsHistoryCursor = false
        if let first = page.items.first { next.boundaries[first.id] = page.before ?? 0 }
        if prefix.isEmpty, page.before == nil, let first = next.order.first { next.boundaries[first] = 0 }
        while next.order.count > limit || next.retainedBytes > byteLimit {
            guard let id = next.order.last, id != protected else { throw TimelineWindowError.historyBudget }
            next.discard(id)
            next.order.removeLast()
            changes.removed.insert(id)
            next.hasNewerGap = true
        }
        changes.changed.subtract(changes.removed)
        self = next
        return changes
    }

    mutating func rejectRenderedPage(from candidate: TimelineWindow, preservingHistory: Bool, markNewerGap: Bool) {
        cursor = candidate.cursor
        session = candidate.session
        if !preservingHistory {
            clearValues()
            before = nil
        }
        hasNewerGap = hasNewerGap || markNewerGap
        needsHistoryCursor = false
        note = ChatRenderLimits.pageNotice
    }

    private mutating func store(_ item: TimelineItem, weight: Int, protectsHistory: Bool) -> Bool {
        let total = retainedBytes - (weights[item.id] ?? 0) + weight
        guard !protectsHistory || total <= byteLimit else {
            hasNewerGap = true
            return false
        }
        retainedBytes = total
        weights[item.id] = weight
        items[item.id] = item
        return true
    }

    private mutating func discard(_ id: String) {
        retainedBytes -= weights.removeValue(forKey: id) ?? 0
        items[id] = nil
        boundaries[id] = nil
    }

    private mutating func clearValues() {
        order.removeAll(keepingCapacity: false)
        items.removeAll(keepingCapacity: false)
        weights.removeAll(keepingCapacity: false)
        boundaries.removeAll(keepingCapacity: false)
        retainedBytes = 0
    }

    private mutating func accept(_ incoming: TimelineCursor) throws -> Bool {
        guard let current = cursor else { throw TimelineWindowError.missingSnapshot }
        guard incoming.epoch == current.epoch else { throw TimelineWindowError.cursorGap }
        guard incoming.sequence > current.sequence else { return false }
        guard current.sequence != UInt64.max, incoming.sequence == current.sequence + 1 else { throw TimelineWindowError.cursorGap }
        cursor = incoming
        return true
    }

    private mutating func snapshot(_ snapshot: TimelineSnapshot, reset: Bool, protectsHistory: Bool, changes: inout TimelineChanges) {
        if !reset, let cursor, cursor.epoch == snapshot.cursor.epoch, snapshot.cursor.sequence < cursor.sequence { return }
        let shouldReset = reset || cursor?.epoch != snapshot.cursor.epoch || session?.nativeSession != snapshot.session.nativeSession || (order.isEmpty && note != nil)
        // A snapshot must fit as a page: endlessly refreshing the same over-budget page
        // cannot repair a missing boundary. Keep a bounded Terminal fallback instead.
        if snapshot.items.reduce(0, { $0 + TimelineValueWeight.of($1) }) > byteLimit {
            if !shouldReset, protectsHistory || hasNewerGap, !order.isEmpty {
                cursor = snapshot.cursor
                session = snapshot.session
                hasNewerGap = true
                needsHistoryCursor = false
                note = "This Chat page exceeds the memory budget. Open Terminal."
                return
            }
            changes.removed.formUnion(order)
            clearValues()
            cursor = snapshot.cursor
            session = snapshot.session
            before = nil
            hasNewerGap = true
            needsHistoryCursor = false
            note = "This Chat page exceeds the memory budget. Open Terminal."
            changes.didReset = true
            return
        }
        if shouldReset {
            changes.removed.formUnion(order)
            clearValues()
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
            clearValues()
            before = snapshot.before
            hasNewerGap = false
            needsHistoryCursor = false
            changes.didReset = true
            return
        }
        let protect = !shouldReset && (protectsHistory || hasNewerGap)
        if !shouldReset, hasNewerGap {
            for item in snapshot.items where items[item.id] != nil { _ = upsertSnapshot(item, protectsHistory: protect, changes: &changes) }
            return
        }
        if !shouldReset, !order.isEmpty, !snapshot.items.contains(where: { items[$0.id] != nil }) {
            hasNewerGap = true
            return
        }
        if !shouldReset, let overlap = snapshot.items.first(where: { items[$0.id] != nil }),
           let index = order.firstIndex(of: overlap.id) {
            let incoming = Set(snapshot.items.map(\.id))
            for identifier in order.suffix(from: index) where !incoming.contains(identifier) {
                discard(identifier)
                changes.removed.insert(identifier)
            }
            order.removeSubrange(index...)
        }
        if order.isEmpty { before = snapshot.before }
        var arranged = Set(order)
        for item in snapshot.items {
            if upsertSnapshot(item, protectsHistory: protect, changes: &changes), arranged.insert(item.id).inserted { order.append(item.id) }
        }
        if let first = snapshot.items.first, items[first.id] != nil { boundaries[first.id] = snapshot.before ?? 0 }
        changes.removed.subtract(items.keys)
    }

    private mutating func upsertSnapshot(_ item: TimelineItem, protectsHistory: Bool, changes: inout TimelineChanges) -> Bool {
        if let current = items[item.id], current.revision >= item.revision { return true }
        if items[item.id] == nil, protectsHistory, hasNewerGap || items.count >= limit {
            hasNewerGap = true
            return false
        }
        guard store(item, weight: TimelineValueWeight.of(item), protectsHistory: protectsHistory) else { return items[item.id] != nil }
        changes.changed.insert(item.id)
        return true
    }

    private mutating func trimOldest(protectsHistory: Bool, changes: inout TimelineChanges) {
        guard order.count > limit || retainedBytes > byteLimit || needsHistoryCursor else { return }
        guard !order.isEmpty else { needsHistoryCursor = false; before = nil; return }
        if protectsHistory, !changes.didReset, order.count <= limit, retainedBytes <= byteLimit {
            // A reader can stop following while a boundary refresh is in flight. Do not
            // discard their rows merely to align the window with a later known boundary.
            needsHistoryCursor = false
            changes.needsHistoryCursor = false
            before = nil
            hasNewerGap = true
            note = "Earlier Chat history is unavailable in this window. Open Terminal."
            return
        }
        var minimum = max(0, order.count - limit)
        var remaining = retainedBytes
        for id in order.prefix(minimum) { remaining -= weights[id] ?? 0 }
        while remaining > byteLimit, minimum < order.count {
            remaining -= weights[order[minimum]] ?? 0
            minimum += 1
        }
        let boundary = (minimum..<order.count).first { boundaries[order[$0]] != nil }
        let count = boundary ?? minimum
        for identifier in order.prefix(count) {
            discard(identifier)
            changes.removed.insert(identifier)
        }
        order.removeFirst(count)
        let position = order.first.flatMap { boundaries[$0] }
        before = position.flatMap { $0 == 0 ? nil : $0 }
        needsHistoryCursor = position == nil
        changes.needsHistoryCursor = needsHistoryCursor
    }
}
