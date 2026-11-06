import Foundation
import HostKit
import Observation

nonisolated struct TimelineFrame: Sendable {
    var rows: [ChatRow] = []
    var rowIDs: Set<ChatRowID> = []
    var session: TimelineSession?
    var cursor: TimelineCursor?
    var before: UInt64?
    var hasNewerGap = false
    var note: String?
    var revision = 0
}

nonisolated enum TimelineJob: Sendable {
    case snapshot(String)
    case update(String)
    case older(String)

    var bytes: Int {
        switch self {
        case .snapshot(let json), .update(let json), .older(let json): json.utf8.count
        }
    }
}

nonisolated struct TimelineRenderResult: Sendable {
    let frame: TimelineFrame
    let needsHistoryCursor: Bool
    let consumedSnapshot: Bool
    let consumedHistory: Bool
    let hasLiveChanges: Bool
}

actor TimelineRenderWorker {
    private var window = TimelineWindow()
    private let builder = RowBuilder()
    private var rowsByItem: [String: [ChatRow]] = [:]
    private var revision = 0
    private let pane: UInt64

    init(pane: UInt64) { self.pane = pane }

    func apply(_ jobs: [TimelineJob], resetsSnapshot: Bool, protectsHistory: Bool) async throws -> TimelineRenderResult {
        var next = window
        var changed: Set<String> = []
        var removed: Set<String> = []
        var didReset = false
        var consumedSnapshot = false
        var consumedHistory = false
        var hasLiveChanges = false
        for job in jobs {
            let changes: TimelineChanges
            switch job {
            case .snapshot(let json):
                let snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: json)
                changes = next.reconcile(snapshot, reset: resetsSnapshot && !consumedSnapshot)
                consumedSnapshot = true
                hasLiveChanges = hasLiveChanges || !changes.changed.isEmpty || !changes.removed.isEmpty
            case .update(let json):
                let update = try TimelineJSON.decode(TimelineUpdate.self, from: json)
                guard update.paneId == pane else { continue }
                changes = try next.apply(update, protectsHistory: protectsHistory)
                hasLiveChanges = hasLiveChanges || !changes.changed.isEmpty || !changes.removed.isEmpty
            case .older(let json):
                let snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: json)
                changes = try next.prepend(snapshot)
                consumedHistory = true
            }
            changed.formUnion(changes.changed)
            removed.formUnion(changes.removed)
            didReset = didReset || changes.didReset
        }
        window = next
        if didReset {
            rowsByItem.removeAll(keepingCapacity: false)
            await builder.clear()
            changed.formUnion(window.order)
        }
        removed.subtract(window.items.keys)
        for identifier in removed { rowsByItem[identifier] = nil }
        await builder.remove(removed)
        let values = changed.compactMap { window.items[$0] }
        let rendered = await builder.rows(for: values)
        for (identifier, rows) in rendered { rowsByItem[identifier] = rows }
        revision += 1
        let rows = window.order.flatMap { rowsByItem[$0] ?? [] }
        let frame = TimelineFrame(
            rows: rows, rowIDs: Set(rows.map(\.id)), session: window.session,
            cursor: window.cursor, before: window.before, hasNewerGap: window.hasNewerGap,
            note: window.note, revision: revision)
        return TimelineRenderResult(frame: frame, needsHistoryCursor: window.needsHistoryCursor, consumedSnapshot: consumedSnapshot, consumedHistory: consumedHistory, hasLiveChanges: hasLiveChanges)
    }

    func clearRenderCache() async { await builder.clear() }
}

@MainActor
@Observable
final class TimelineModel {
    let pane: UInt64
    private(set) var frame = TimelineFrame()
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    private(set) var hasNewItems = false
    private(set) var error: String?
    var followsBottom = true
    var expanded: Set<ChatRowID> = []
    var draft = ""

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

    init(pane: UInt64) {
        self.pane = pane
        worker = TimelineRenderWorker(pane: pane)
    }

    func start(in hub: DaemonWorkspace) {
        if observer != nil {
            if self.hub === hub { return }
            stop()
        }
        if let lastHubIdentity, lastHubIdentity != ObjectIdentifier(hub) { draft = "" }
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
        guard !isLoadingHistory, let before = frame.before, let hub else { return }
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
                self.error = "History could not load. Try again or open Terminal."
            }
        }
    }

    func jumpToLatest() {
        followsBottom = true
        hasNewItems = false
        resetsSnapshot = true
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        isLoading = frame.rows.isEmpty
        channel?.requestSnapshot()
    }

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
            worker = TimelineRenderWorker(pane: pane)
            pending.removeAll(keepingCapacity: false)
            pendingBytes = 0
            frame = TimelineFrame()
            expanded.removeAll()
            isLoading = true
            isLoadingHistory = false
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
                    let result = try await worker.apply(jobs, resetsSnapshot: resetsSnapshot, protectsHistory: !followsBottom)
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    if !followsBottom, result.hasLiveChanges { hasNewItems = true }
                    frame = result.frame
                    error = result.frame.note
                    isLoading = false
                    if result.consumedSnapshot { self.resetsSnapshot = false }
                    if result.consumedHistory { isLoadingHistory = false }
                    expanded.formIntersection(frame.rowIDs)
                    if result.needsHistoryCursor { channel?.requestSnapshot() }
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
