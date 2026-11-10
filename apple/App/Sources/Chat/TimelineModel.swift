import Foundation
import HostKit
import Observation

nonisolated struct TimelineFrame: Sendable {
    var capabilities: AgentCapabilities = []
    var capabilityGeneration = UUID()
    var rows: [ChatRow] = []
    var rowIDs: Set<ChatRowID> = []
    var session: TimelineSession?
    var cursor: TimelineCursor?
    var before: UInt64?
    var hasNewerGap = false
    var note: String?
    var revision = 0
    var generation = UUID()
    var parentRevision: Int?
    var orderRevision: Int?
    /// How many leading rows are where they were in the parent frame.
    var keptOrder: Int?
    var changedRows: [ChatRow]?
}

nonisolated enum TimelineJob: Sendable {
    case snapshot(String)
    case update(String)
    case older(String)
    case highlights

    var bytes: Int {
        switch self {
        case .snapshot(let json), .update(let json), .older(let json): json.utf8.count
        case .highlights: 0
        }
    }
}

nonisolated struct TimelineRenderResult: Sendable {
    let frame: TimelineFrame
    let needsHistoryCursor: Bool
    let consumedSnapshot: Bool
    let consumedHistory: Bool
    let hasLiveChanges: Bool
    let awaitsHighlights: Bool
}

actor TimelineRenderWorker {
    private var window: TimelineWindow
    private let builder = RowBuilder()
    private var rowsByItem: [String: RenderedChatRows] = [:]
    private var renderCost = LRUCost()
    private var revision = 0
    private var generation = UUID()
    private var capabilities: AgentCapabilities = []
    private var capabilityGeneration = UUID()
    private var orderRevision = 0
    private var identifiers: [ChatRowID] = []
    private let pane: UInt64

    init(pane: UInt64, valueByteLimit: Int = TimelineWindow.defaultByteLimit) {
        self.pane = pane
        window = TimelineWindow(byteLimit: valueByteLimit)
    }

    func apply(_ jobs: [TimelineJob], resetsSnapshot: Bool, protectsHistory: Bool, historyAnchor: String? = nil) throws -> TimelineRenderResult {
        var next = window
        var changed: Set<String> = []
        var removed: Set<String> = []
        var didReset = false
        var consumedSnapshot = false
        var consumedHistory = false
        var hasLiveChanges = false
        for job in jobs {
            try Task.checkCancellation()
            let changes: TimelineChanges
            switch job {
            case .snapshot(let json):
                let snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: json)
                let advertised = snapshot.capabilities ?? [.read]
                if capabilities != advertised { capabilities = advertised; capabilityGeneration = UUID() }
                changes = next.reconcile(snapshot, reset: resetsSnapshot && !consumedSnapshot, protectsHistory: protectsHistory)
                consumedSnapshot = true
                hasLiveChanges = hasLiveChanges || !changes.changed.isEmpty || !changes.removed.isEmpty
            case .update(let json):
                let update = try TimelineJSON.decode(TimelineUpdate.self, from: json)
                guard update.paneId == pane else { continue }
                changes = try next.apply(update, protectsHistory: protectsHistory)
                hasLiveChanges = hasLiveChanges || !changes.changed.isEmpty || !changes.removed.isEmpty
            case .older(let json):
                let snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: json)
                changes = try next.prepend(snapshot, protecting: historyAnchor)
                consumedHistory = true
            case .highlights:
                continue
            }
            changed.formUnion(changes.changed)
            removed.formUnion(changes.removed)
            didReset = didReset || changes.didReset
        }
        removed.subtract(next.items.keys)
        changed.formUnion(builder.itemsAwaitingHighlights.subtracting(removed))
        let prepared = try prepareRows(in: next, changed: changed, removed: removed, resetting: didReset)
        let changedRows: [ChatRow]
        if let prepared {
            window = next
            rowsByItem = prepared.items
            renderCost = prepared.cost
            changedRows = prepared.changedRows
            if didReset { generation = UUID() }
        } else {
            let preserve = !didReset && !window.order.isEmpty && (protectsHistory || window.hasNewerGap)
            window.rejectRenderedPage(from: next, preservingHistory: preserve,
                                      markNewerGap: consumedSnapshot || hasLiveChanges || !consumedHistory)
            if !preserve {
                rowsByItem.removeAll(keepingCapacity: false)
                renderCost = LRUCost()
                generation = UUID()
            }
            builder.clear()
            changedRows = []
        }
        let parentRevision = revision
        revision += 1
        let rows = window.order.flatMap { rowsByItem[$0]?.rows ?? [] }
        let identifiers = rows.map(\.id)
        let keptOrder = zip(self.identifiers, identifiers).prefix { $0 == $1 }.count
        if keptOrder != identifiers.count || keptOrder != self.identifiers.count {
            orderRevision += 1
            self.identifiers = identifiers
        }
        let frame = TimelineFrame(
            capabilities: capabilities, capabilityGeneration: capabilityGeneration,
            rows: rows, rowIDs: Set(identifiers), session: window.session,
            cursor: window.cursor, before: window.before, hasNewerGap: window.hasNewerGap,
            note: window.note, revision: revision, generation: generation,
            parentRevision: parentRevision, orderRevision: orderRevision, keptOrder: keptOrder, changedRows: changedRows)
        return TimelineRenderResult(frame: frame, needsHistoryCursor: window.needsHistoryCursor, consumedSnapshot: consumedSnapshot,
                                    consumedHistory: consumedHistory, hasLiveChanges: hasLiveChanges,
                                    awaitsHighlights: !builder.itemsAwaitingHighlights.isEmpty)
    }

    private func prepareRows(in next: TimelineWindow, changed: Set<String>, removed: Set<String>,
                             resetting: Bool) throws -> RenderedPage? {
        if resetting { builder.clear() }
        builder.beginPage()
        defer { builder.endPage() }
        var prepared = resetting ? RenderedPage() : RenderedPage(items: rowsByItem, cost: renderCost)
        for identifier in removed { prepared.remove(identifier) }
        builder.remove(removed)
        let identifiers = resetting ? Set(next.order) : changed
        for identifier in identifiers {
            try Task.checkCancellation()
            guard let item = next.items[identifier] else { continue }
            let rendered = builder.render(item)
            guard prepared.store(rendered, for: identifier) else { return nil }
            let previous = rowsByItem[identifier]?.rows ?? []
            for (index, row) in rendered.rows.enumerated() {
                if !previous.indices.contains(index) || previous[index] != row { prepared.changedRows.append(row) }
            }
        }
        return prepared
    }

    func clearRenderCache() { builder.clear() }
}

@MainActor
@Observable
final class TimelineModel {
    let pane: UInt64
    let valueByteLimit: Int
    private(set) var frame = TimelineFrame()
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    private(set) var hasNewItems = false
    private(set) var error: String?
    private(set) var historyError: String?
    var followsBottom = true
    var expanded: Set<ChatRowID> = []

    @ObservationIgnored var readingItem: String?
    @ObservationIgnored private var channel: TimelineChannel?
    @ObservationIgnored private weak var hub: DaemonWorkspace?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var worker: TimelineRenderWorker
    @ObservationIgnored private var pending: [TimelineJob] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var processing: Task<Void, Never>?
    @ObservationIgnored private var history: Task<Void, Never>?
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private var resetsSnapshot = false
    @ObservationIgnored private var lastHubIdentity: ObjectIdentifier?
    @ObservationIgnored private var lastHubGeneration: Int?

    init(pane: UInt64, valueByteLimit: Int = TimelineWindow.defaultByteLimit) {
        self.pane = pane
        self.valueByteLimit = max(TimelineWindow.minimumByteLimit, valueByteLimit)
        worker = TimelineRenderWorker(pane: pane, valueByteLimit: self.valueByteLimit)
    }

    isolated deinit { stop() }

    func start(in hub: DaemonWorkspace) {
        if observer != nil {
            if self.hub === hub { return }
            stop()
        }
        if lastHubIdentity != ObjectIdentifier(hub) || lastHubGeneration != hub.generation { receive(.reset) }
        lastHubIdentity = ObjectIdentifier(hub)
        lastHubGeneration = hub.generation
        self.hub = hub
        let channel = hub.timelineChannel(pane: pane)
        self.channel = channel
        isLoading = frame.rows.isEmpty
        observer = channel.observe { [weak self] packet in self?.receive(packet) }
    }

    func stop() {
        if let observer { channel?.removeObserver(observer) }
        observer = nil
        channel = nil
        hub = nil
        lifetime = UUID()
        processing?.cancel()
        processing = nil
        history?.cancel()
        history = nil
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        isLoading = false
        isLoadingHistory = false
    }

    func requestOlder() {
        guard frame.note != ChatRenderLimits.pageNotice, !isLoadingHistory, historyError == nil,
              let before = frame.before, let hub else { return }
        isLoadingHistory = true
        let lifetime = self.lifetime
        let pane = self.pane
        history = Task { [weak self] in
            do {
                let client = try hub.timelineClient()
                let json = try await client.timelineItemsBefore(paneId: pane, before: before, limit: 100)
                guard let self, self.lifetime == lifetime, !Task.isCancelled else { return }
                history = nil
                enqueue(.older(json))
            } catch {
                guard let self, self.lifetime == lifetime, !Task.isCancelled else { return }
                history = nil
                isLoadingHistory = false
                historyError = "History could not load. Scroll up to try again, or open Terminal."
            }
        }
    }

    func jumpToLatest() {
        history?.cancel()
        history = nil
        isLoadingHistory = false
        historyError = nil
        followsBottom = true
        hasNewItems = false
        resetsSnapshot = true
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        isLoading = frame.rows.isEmpty
        channel?.requestSnapshot()
    }

    func allowHistoryRetry() { historyError = nil }

    func retry() {
        error = nil
        channel?.requestSnapshot()
    }

    func toggle(_ identifier: ChatRowID) {
        if expanded.contains(identifier) { expanded.remove(identifier) } else { expanded.insert(identifier) }
    }

    func reachedBottom() { hasNewItems = false }

    func releaseRenderCaches() {
        let worker = worker
        Task { await worker.clearRenderCache() }
    }

    func receive(_ packet: TimelineChannel.Packet) {
        switch packet {
        case .reset:
            lastHubGeneration = hub?.generation
            lifetime = UUID()
            processing?.cancel()
            processing = nil
            history?.cancel()
            history = nil
            worker = TimelineRenderWorker(pane: pane, valueByteLimit: valueByteLimit)
            pending.removeAll(keepingCapacity: false)
            pendingBytes = 0
            frame = TimelineFrame()
            expanded.removeAll()
            readingItem = nil
            isLoading = true
            isLoadingHistory = false
            historyError = nil
            hasNewItems = false
            followsBottom = true
            error = nil
            resetsSnapshot = true
        case .snapshot(let json): enqueue(.snapshot(json))
        case .update(let json): enqueue(.update(json))
        case .unavailable(let message):
            error = message
            isLoading = false
        }
    }

    private func enqueue(_ job: TimelineJob) {
        guard pending.count < 64, pendingBytes + job.bytes <= 8 * 1_024 * 1_024 else {
            pending.removeAll(keepingCapacity: false)
            pendingBytes = 0
            isLoadingHistory = false
            channel?.requestSnapshot()
            return
        }
        pending.append(job)
        pendingBytes += job.bytes
        guard processing == nil else { return }
        let lifetime = self.lifetime
        let worker = self.worker
        processing = Task { [weak self] in
            while let self, self.lifetime == lifetime, !Task.isCancelled {
                guard !pending.isEmpty else { processing = nil; return }
                let jobs = pending
                let resetsSnapshot = self.resetsSnapshot
                pending.removeAll(keepingCapacity: true)
                pendingBytes = 0
                do {
                    let result = try await worker.apply(jobs, resetsSnapshot: resetsSnapshot, protectsHistory: !followsBottom, historyAnchor: readingItem)
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    if !followsBottom, result.hasLiveChanges { hasNewItems = true }
                    frame = result.frame
                    error = result.frame.note
                    isLoading = false
                    if result.consumedSnapshot { self.resetsSnapshot = false }
                    if result.consumedHistory { isLoadingHistory = false; historyError = nil }
                    expanded.formIntersection(frame.rowIDs)
                    if result.needsHistoryCursor { channel?.requestSnapshot() }
                    if result.awaitsHighlights, pending.isEmpty { pending.append(.highlights) }
                } catch TimelineWindowError.valueTooLarge, TimelineWindowError.historyBudget {
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    self.error = "This Chat page exceeds the memory budget. Open Terminal."
                    isLoading = false
                    isLoadingHistory = false
                } catch is TimelineWindowError {
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    isLoadingHistory = false
                    channel?.requestSnapshot()
                } catch {
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    self.error = "Chat could not read this session. Open Terminal."
                    isLoading = false
                    isLoadingHistory = false
                }
            }
        }
    }
}
