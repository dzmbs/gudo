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
    /// The latest item, while it is a reply still streaming: its rows end the frame.
    var streamingReply: String?
}

extension TimelineFrame {
    /// This frame as one step from `earlier`'s parent, for a transcript that never applied
    /// `earlier`: it still redraws only the rows that changed since what it shows.
    nonisolated func folding(after earlier: TimelineFrame) -> TimelineFrame {
        guard parentRevision == earlier.revision, generation == earlier.generation,
              let rows = changedRows, let earlierRows = earlier.changedRows else { return self }
        var folded = self
        let later = Set(rows.lazy.map(\.id))
        folded.changedRows = earlierRows.filter { !later.contains($0.id) } + rows
        folded.parentRevision = earlier.parentRevision
        folded.keptOrder = keptOrder.flatMap { kept in earlier.keptOrder.map { min(kept, $0) } }
        return folded
    }
}

/// What the views around the transcript read from a frame. It changes far less often than the
/// rows, so a streamed row redraws the transcript alone.
nonisolated struct TimelineOutline: Equatable, Sendable {
    var capabilities: AgentCapabilities = []
    var capabilityGeneration = UUID()
    var session: TimelineSession?
    var epoch: UInt64?
    var hasRows = false
    /// The latest turn end among the last rows, for the context meter.
    var lastTurnEnd: TimelineTurnEnd?

    init() {}

    init(_ frame: TimelineFrame) {
        capabilities = frame.capabilities
        capabilityGeneration = frame.capabilityGeneration
        session = frame.session
        epoch = frame.cursor?.epoch
        hasRows = !frame.rows.isEmpty
        lastTurnEnd = ChatContextUsage.lastTurnEnd(in: frame.rows)
    }
}

nonisolated enum TimelineJob: Sendable {
    case snapshot(String)
    case update(String)
    case older(String)
    case highlights
    case regroup
    /// Renders the rows a newest-first page held back.
    case olderRows

    var bytes: Int {
        switch self {
        case .snapshot(let json), .update(let json), .older(let json): json.utf8.count
        case .highlights, .regroup, .olderRows: 0
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
    /// The frame holds only the newest turns; the next apply renders the rest.
    var holdsOlderRows = false
}

actor TimelineRenderWorker {
    /// A page longer than this many items shows its newest turns first.
    static let newestFirstItems = 96
    /// How far before those items a turn's start is looked for; past it the page renders whole.
    static let turnStartSearch = 512

    private var window: TimelineWindow
    private let builder: RowBuilder
    private var rowsByItem: [String: RenderedChatRows] = [:]
    private var renderCost = LRUCost()
    private var revision = 0
    private var generation = UUID()
    private var capabilities: AgentCapabilities = []
    private var capabilityGeneration = UUID()
    private var orderRevision = 0
    private var fold = ChatTimelineFold()
    private var identifierCount = 0
    private var rowIDs: Set<ChatRowID> = []
    private var groupRows: [ChatRowID: ChatRow] = [:]
    /// Items before the newest turns of a page shown newest first, rendered by the next apply.
    private var heldBack: [String] = []
    private let pane: UInt64

    init(pane: UInt64, valueByteLimit: Int = TimelineWindow.defaultByteLimit,
         highlightAllowance: Duration = RowBuilder.highlightAllowance) {
        self.pane = pane
        builder = RowBuilder(highlightAllowance: highlightAllowance)
        window = TimelineWindow(byteLimit: valueByteLimit)
    }

    /// `newestFirst`: a reset page longer than `newestFirstItems` renders its newest turns alone
    /// and says so in its result, so they show while the rest renders.
    func apply(_ jobs: [TimelineJob], resetsSnapshot: Bool, protectsHistory: Bool, historyAnchor: String? = nil,
               expanded: Set<ChatRowID> = [], collapsesTurns: Bool = false, newestFirst: Bool = false) throws -> TimelineRenderResult {
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
            case .highlights, .regroup, .olderRows:
                continue
            }
            changed.formUnion(changes.changed)
            removed.formUnion(changes.removed)
            didReset = didReset || changes.didReset
        }
        removed.subtract(next.items.keys)
        changed.formUnion(builder.itemsAwaitingHighlights.subtracting(removed))
        let newestStart = newestFirst && didReset ? Self.newestTurnsStart(in: next) : nil
        let renderedHeldBack = !didReset && !heldBack.isEmpty
        if renderedHeldBack { changed.formUnion(heldBack.lazy.filter { next.items[$0] != nil }) }
        heldBack.removeAll()
        let prepared = try prepareRows(in: next, changed: changed, removed: removed, resetting: didReset,
                                       from: newestStart ?? 0)
        var changedRows: [ChatRow]
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
        let foldStart = prepared == nil ? 0 : newestStart ?? 0
        if foldStart > 0 { heldBack = Array(window.order[..<foldStart]) }
        let parentRevision = revision
        revision += 1
        let items = window.items
        let rowsByItem = rowsByItem
        let change = fold.update(order: foldStart > 0 ? Array(window.order[foldStart...]) : window.order,
                                 rowsOf: { rowsByItem[$0]?.rows ?? [] }, changed: changed, removed: removed,
                                 resets: didReset || prepared == nil || renderedHeldBack,
                                 expanded: expanded, collapses: collapsesTurns, reply: { identifier in
            guard case .assistant(let assistant) = items[identifier]?.body else { return nil }
            return assistant.text
        }, previous: groupRows)
        let rows = fold.rows
        let tail = rows[change.from...]
        // A group's line and the calls it uncovers are rows no item changed.
        let shown = Set(change.replaced.lazy.map(\.id))
        var listed = Set(changedRows.lazy.map(\.id))
        var replacedGroups: [ChatRowID: ChatRow] = [:]
        for row in change.replaced where row.content.isDerived { replacedGroups[row.id] = groupRows.removeValue(forKey: row.id) }
        for row in tail {
            let isNew = replacedGroups[row.id].map { $0 != row } ?? !shown.contains(row.id)
            if row.content.isDerived { groupRows[row.id] = row }
            if isNew, listed.insert(row.id).inserted { changedRows.append(row) }
        }
        for row in change.replaced { rowIDs.remove(row.id) }
        for row in tail { rowIDs.insert(row.id) }
        let keptTail = zip(change.replaced, tail).prefix { $0.id == $1.id }.count
        let keptOrder = change.from + keptTail
        if keptOrder != rows.count || keptOrder != identifierCount {
            orderRevision += 1
        }
        identifierCount = rows.count
        assert(rowIDs.count == rows.count, "row identifiers are not unique")
        let streamingReply = window.order.last.flatMap { identifier -> String? in
            guard case .assistant(let assistant) = items[identifier]?.body, assistant.streaming,
                  rows.last?.id.item == identifier else { return nil }
            return identifier
        }
        let frame = TimelineFrame(
            capabilities: capabilities, capabilityGeneration: capabilityGeneration,
            rows: rows, rowIDs: rowIDs, session: window.session,
            cursor: window.cursor, before: window.before, hasNewerGap: window.hasNewerGap,
            note: window.note, revision: revision, generation: generation,
            parentRevision: parentRevision, orderRevision: orderRevision, keptOrder: keptOrder, changedRows: changedRows,
            streamingReply: streamingReply)
        return TimelineRenderResult(frame: frame, needsHistoryCursor: window.needsHistoryCursor, consumedSnapshot: consumedSnapshot,
                                    consumedHistory: consumedHistory, hasLiveChanges: hasLiveChanges,
                                    awaitsHighlights: !builder.itemsAwaitingHighlights.isEmpty, holdsOlderRows: !heldBack.isEmpty)
    }

    /// Where the newest turns of a long page start: the first prompt of a turn at least
    /// `newestFirstItems` from the end, so they fold exactly as in the whole page.
    private static func newestTurnsStart(in window: TimelineWindow) -> Int? {
        let order = window.order
        guard order.count > newestFirstItems else { return nil }
        let isPrompt = { (index: Int) -> Bool in
            switch window.items[order[index]]?.body {
            case .user: true
            case .longText(let longText): longText.role == .known(.user)
            default: false
            }
        }
        let latest = order.count - newestFirstItems
        let earliest = max(1, latest - turnStartSearch)
        var index = latest
        while index >= earliest {
            if isPrompt(index), !isPrompt(index - 1) { return index }
            index -= 1
        }
        return nil
    }

    /// A reset renders the items from `start` on; the rest wait for the next apply.
    private func prepareRows(in next: TimelineWindow, changed: Set<String>, removed: Set<String>,
                             resetting: Bool, from start: Int) throws -> RenderedPage? {
        if resetting { builder.clear() }
        builder.beginPage()
        defer { builder.endPage() }
        var prepared = resetting ? RenderedPage() : RenderedPage(items: rowsByItem, cost: renderCost)
        for identifier in removed { prepared.remove(identifier) }
        builder.remove(removed)
        let identifiers = resetting ? Set(next.order[start...]) : changed
        for identifier in identifiers {
            try Task.checkCancellation()
            guard let item = next.items[identifier] else { continue }
            let rendered = builder.render(item)
            guard prepared.store(rendered, for: identifier) else { return nil }
            let previous = rowsByItem[identifier]?.rows ?? []
            let unchanged = min(rendered.unchanged, previous.count)
            assert(previous.prefix(unchanged) == rendered.rows.prefix(unchanged), "rows reported unchanged differ")
            for (index, row) in rendered.rows.enumerated().dropFirst(unchanged) {
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
    /// A long page shows its newest turns first on iOS, whose first rows missed their budget
    /// laying out the whole page. The Mac lays a whole page out within it, and rendering in two
    /// steps cost it 3 MB more at open.
    #if os(iOS)
    static let showsNewestFirst = true
    #else
    static let showsNewestFirst = false
    #endif

    let pane: UInt64
    let valueByteLimit: Int
    /// The latest frame. Views read `outline`; the transcript takes each frame from `onFrame`
    /// and commits it on the next display refresh.
    @ObservationIgnored private(set) var frame = TimelineFrame() {
        didSet {
            let next = TimelineOutline(frame)
            if next != outline { outline = next }
            onFrame?(frame)
        }
    }
    private(set) var outline = TimelineOutline()
    @ObservationIgnored var onFrame: ((TimelineFrame) -> Void)?
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    private(set) var hasNewItems = false
    private(set) var error: String?
    private(set) var historyError: String?
    var followsBottom = true
    var expanded: Set<ChatRowID> = []
    /// Finished turns fold behind one line (`ChatTurnCollapse`); a setting turns it off.
    var collapsesTurns = ChatPreferences.collapsesTurns {
        didSet { if collapsesTurns != oldValue { enqueue(.regroup) } }
    }

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
        // Without a gap the window already holds the latest rows; reloading them all would only
        // redraw the transcript.
        guard frame.hasNewerGap else { return }
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
        if ChatToolGroups.isGroup(identifier) || ChatTurnCollapse.isSummary(identifier) { enqueue(.regroup) }
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
                    let result = try await worker.apply(jobs, resetsSnapshot: resetsSnapshot, protectsHistory: !followsBottom,
                                                        historyAnchor: readingItem, expanded: expanded,
                                                        collapsesTurns: collapsesTurns, newestFirst: Self.showsNewestFirst)
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    if !followsBottom, result.hasLiveChanges, !hasNewItems { hasNewItems = true }
                    frame = result.frame
                    if error != result.frame.note { error = result.frame.note }
                    if isLoading { isLoading = false }
                    if result.consumedSnapshot { self.resetsSnapshot = false }
                    if result.consumedHistory { isLoadingHistory = false; historyError = nil }
                    if !expanded.isEmpty, !expanded.isSubset(of: frame.rowIDs) { expanded.formIntersection(frame.rowIDs) }
                    if result.needsHistoryCursor { channel?.requestSnapshot() }
                    if result.holdsOlderRows, pending.isEmpty { pending.append(.olderRows) }
                    if result.awaitsHighlights, pending.isEmpty { pending.append(.highlights) }
                } catch TimelineWindowError.valueTooLarge, TimelineWindowError.historyBudget {
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    self.error = "This Chat page exceeds the memory budget."
                    isLoading = false
                    isLoadingHistory = false
                } catch is TimelineWindowError {
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    isLoadingHistory = false
                    channel?.requestSnapshot()
                } catch {
                    guard self.lifetime == lifetime, !Task.isCancelled else { return }
                    self.error = "Chat could not read this session."
                    isLoading = false
                    isLoadingHistory = false
                }
            }
        }
    }
}
