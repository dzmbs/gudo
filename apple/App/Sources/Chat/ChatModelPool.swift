import Foundation
#if canImport(UIKit)
import UIKit

typealias ChatTranscriptViewController = ChatViewController
#else
typealias ChatTranscriptViewController = ChatTranscriptController
#endif

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

    /// The pane's transcript, kept with its model: showing the pane again shows its cells,
    /// measured rows and scroll position as they were, instead of building them again.
    func transcript(_ make: () -> ChatTranscriptViewController) -> ChatTranscriptViewController {
        pool?.transcript(for: owner, make: make) ?? make()
    }

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
        var transcript: ChatTranscriptViewController?
        var users = 0
        var recency = 0
        init(model: TimelineModel) { self.model = model }
    }

    private let capacity: Int
    private let modelValueByteLimit: Int
    private var entries: [UUID: Entry] = [:]
    private var recency = 0
    private var memoryWarnings: NSObjectProtocol?

    init(
        capacity: Int = ChatModelPool.maximumCapacity,
        valueByteLimit: Int = TimelineWindow.defaultByteLimit
    ) {
        self.capacity = max(1, min(Self.maximumCapacity, capacity))
        modelValueByteLimit = max(TimelineWindow.minimumByteLimit, valueByteLimit / self.capacity)
        #if canImport(UIKit)
        memoryWarnings = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseIdle() }
        }
        #endif
    }

    isolated deinit {
        if let memoryWarnings { NotificationCenter.default.removeObserver(memoryWarnings) }
    }

    /// How many panes keep a model, shown or not.
    var warmCount: Int { entries.count }

    /// Drops every model no pane shows, with its transcript; the next show builds them again.
    func releaseIdle() {
        entries = entries.filter { $0.value.users > 0 }
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

    /// A lease that costs no other pane its warm model: this pane's own, or a free place.
    func acquireWithoutEvicting(_ owner: UUID, pane: UInt64) -> ChatModelLease? {
        guard entries[owner] != nil || entries.count < capacity else { return nil }
        return acquire(owner, pane: pane)
    }

    func forget(_ owner: UUID) {
        guard let entry = entries[owner], entry.users == 0 else { return }
        entries[owner] = nil
    }

    fileprivate func transcript(for owner: UUID, make: () -> ChatTranscriptViewController) -> ChatTranscriptViewController {
        guard let entry = entries[owner] else { return make() }
        // A transcript still in another view hierarchy (a pane moving between places) is not
        // taken from it; the new one is kept instead.
        if let kept = entry.transcript, kept.parent == nil, kept.viewIfLoaded?.superview == nil { return kept }
        let made = make()
        entry.transcript = made
        return made
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
