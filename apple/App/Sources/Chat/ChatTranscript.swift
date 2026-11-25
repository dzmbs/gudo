#if os(macOS)
import AppKit
import DesignSystem
import os
import SwiftUI

/// The Mac transcript: the touch collection's rows in an AppKit collection, measured into one
/// document of known heights, so the row being read holds still while older pages arrive above
/// it and the latest row stays in view while the reader is at the bottom.
struct NativeChatView<Composer: View>: NSViewControllerRepresentable {
    let model: TimelineModel
    let frame: TimelineFrame
    let expanded: Set<ChatRowID>
    var actions = ChatRowActions()
    var isActive = true
    var isWorking = false
    /// Returns the transcript to show, which may be one kept from an earlier showing.
    var makeController: (() -> ChatTranscriptController)?
    var onControllerReady: ((ChatTranscriptController) -> Void)?
    @ViewBuilder var composer: () -> Composer
    @Environment(\.self) private var environment
    @AppStorage(TerminalPreferences.Key.fontSize) private var fontSize = TerminalPreferences.Default.fontSize

    func makeNSViewController(context: Context) -> ChatTranscriptController {
        let controller = makeController?() ?? ChatTranscriptController(model: model)
        onControllerReady?(controller)
        return controller
    }

    func updateNSViewController(_ controller: ChatTranscriptController, context: Context) {
        controller.update(frame: frame, expanded: expanded, environment: environment, actions: actions,
                          composer: AnyView(composer().environment(\.self, environment).tint(environment.chrome.accentColor)),
                          codeFontSize: fontSize, isActive: isActive)
        controller.showsWorking(isWorking)
    }
}

final class ChatTranscriptController: NSViewController, NSCollectionViewDataSource {
    private struct HeightKey: Hashable {
        let id: ChatRowID
        let revision: UInt32
        let width: CGFloat
        let expanded: Bool
        let fontSize: Double
        let topSpacing: CGFloat
        let revealed: Int?

        var cost: LRUCost { LRUCost(bytes: 2 * (MemoryLayout<Self>.stride + id.item.utf8.count)) }
    }

    static let followDistance: CGFloat = 40
    static let historyDistance: CGFloat = 600
    /// Measuring can grow rows into view that need measuring in turn; past this many passes the
    /// rest waits for the next frame.
    static let measurePassLimit = 8
    private static let proseLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: ChatFont.proseSize))
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("chat-row")

    let model: TimelineModel
    let scroll = ChatScrollView()
    let collection = NSCollectionView()
    private let layout = NativeCollectionLayout(document: NativeListLayout())
    private var document = NativeListLayout()
    private var documentRowIDs: [ChatRowID] = []
    /// The rows the collection holds: it moves to the frame's count with the collection's update.
    private var itemCount = 0
    private var clock: CADisplayLink?
    private var current = TimelineFrame()
    private let reveal = ChatReplyReveal()
    /// The display link is running, so a streaming reply can be paced; otherwise it shows whole.
    private var paintsFrames = false
    /// Paces a streaming reply in a window that is not on screen, committing on the timer, so a
    /// locked screen can still measure the reveal.
    var pacesWhileHidden = false
    private var ceiling: Task<Void, Never>?
    private var lastDisplayTick: ContinuousClock.Instant?
    private var pending: TimelineFrame?
    private var rows: [ChatRowID: ChatRow] = [:]
    private var topSpacings: [ChatRowID: CGFloat] = [:]
    private var expanded: Set<ChatRowID> = []
    private var previousExpanded: Set<ChatRowID> = []
    private var environment = EnvironmentValues()
    private var actions = ChatRowActions()
    private var codeFontSize = TerminalPreferences.Default.fontSize
    private let heights = BoundedLRU<HeightKey, CGFloat>(capacity: ChatCacheLimits.entries, byteLimit: ChatCacheLimits.bytes)
    private var measured: Set<ChatRowID> = []
    private let sizing = NSHostingController(rootView: AnyView(EmptyView()))
    private let footer = NSHostingView(rootView: AnyView(EmptyView()))
    private let latest = NSHostingView(rootView: AnyView(EmptyView()))
    /// The working dots float over the transcript just above the composer, so the agent starting
    /// or stopping never moves a row.
    private let working = NSHostingView(rootView: AnyView(EmptyView()))
    /// Rows pass under the pane's top edge and the composer through a fade into the background.
    private let topFade = ChatEdgeFade(edge: .top, height: DS.Space.l)
    private let bottomFade = ChatEdgeFade(edge: .bottom, height: DS.Space.xxl)
    private var isActive = true
    private var hasChrome = false
    private var isWorking = false
    private var isApplying = false
    private var isMeasuring = false
    private var applyScheduled = false
    private var needsRestyle = true
    private var lastWidth: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private var openedAt = ContinuousClock.now
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "chat")
    private(set) var firstContentLatency: Duration?
    private(set) var applyDurations: [Duration] = []
    private(set) var revealDurations: [Duration] = []
    private(set) var measuredRows = 0
    /// Each display frame that changed the streaming reply: when, and its characters on screen.
    private(set) var revealSamples: [(time: ContinuousClock.Instant, length: Int)] = []
    static let revealSampleLimit = 2_000

    /// A frame waits at most this long for a display refresh. Refreshes stop while the screen is
    /// locked; frames and the reveal then advance on a timer at the reveal's rate.
    static let commitCeiling: Duration = .milliseconds(100)

    init(model: TimelineModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onFrame = { [weak self] frame in self?.offer(frame) }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The rows between the top fade and the composer, top to bottom.
    var visibleRows: [ChatRowID] {
        document.visibleRows(in: readingRect).compactMap { current.rows.indices.contains($0) ? current.rows[$0].id : nil }
    }

    /// The row at the top of the reading area, which the transcript holds still.
    var readingRow: ChatRowID? {
        document.row(at: readingRect.minY).flatMap { documentRowIDs.indices.contains($0) ? documentRowIDs[$0] : nil }
    }

    /// Where the row starts, from the top of the reading area.
    func viewportPosition(of id: ChatRowID) -> CGFloat? {
        document.indices[id.storageKey].map { document.positions[$0] - readingRect.minY }
    }

    /// How far the reader is above the latest row.
    var distanceFromBottom: CGFloat { bottomOffset - scroll.contentView.bounds.minY }

    /// The text field with the keyboard is composing with an input method.
    var hasMarkedText: Bool { (view.window?.firstResponder as? NSTextView)?.hasMarkedText() == true }

    func prepareToPark() -> Bool {
        guard isViewLoaded, let window = view.window, let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: view) else { return true }
        if hasMarkedText { return false }
        return window.makeFirstResponder(nil)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topFade.fadeHeight, left: 0, bottom: 0, right: 0)
        scroll.onUserScroll = { [weak self] in self?.userScrolled() }
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.dataSource = self
        collection.register(ChatTranscriptItem.self, forItemWithIdentifier: Self.rowIdentifier)
        collection.setAccessibilityIdentifier("chat-timeline")
        scroll.documentView = collection
        for subview in [scroll, topFade, bottomFade, working, latest, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        working.isHidden = true
        latest.isHidden = true
        latest.setAccessibilityIdentifier("chat-jump-latest")
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            topFade.topAnchor.constraint(equalTo: root.topAnchor),
            topFade.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topFade.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topFade.heightAnchor.constraint(equalToConstant: topFade.fadeHeight),
            bottomFade.topAnchor.constraint(equalTo: footer.topAnchor, constant: -bottomFade.fadeHeight),
            bottomFade.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomFade.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            latest.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DS.Space.l),
            latest.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -DS.Space.m),
            working.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            working.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -DS.Space.s),
        ])
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        })
        // Dragging the scroller: the wheel and the trackpad arrive through `scrollWheel`.
        observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        })
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard scroll.contentSize.width > 0 else { return }
        let bottomInset = footer.frame.height + bottomFade.fadeHeight
        if scroll.contentInsets.bottom != bottomInset {
            scroll.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = footer.frame.height
            install()
            if model.followsBottom { scrollToBottom() }
        }
        let width = scroll.contentSize.width
        if lastWidth != width {
            lastWidth = width
            measured.removeAll(keepingCapacity: true)
            pending = pending ?? current
            needsRestyle = true
            applyPending()
        } else if pending != nil, current.rows.isEmpty {
            applyPending()
        }
    }

    func update(frame: TimelineFrame, expanded: Set<ChatRowID>, environment: EnvironmentValues,
                actions: ChatRowActions, composer: AnyView, codeFontSize: Double = TerminalPreferences.Default.fontSize,
                isActive: Bool = true) {
        let visibilityChanged = self.isActive != isActive
        self.isActive = isActive
        if visibilityChanged {
            needsRestyle = true
            if isActive, firstContentLatency == nil { openedAt = .now }
        }
        if !self.actions.isEquivalent(to: actions) { needsRestyle = true }
        if self.codeFontSize != codeFontSize || self.environment.layoutDirection != environment.layoutDirection {
            self.codeFontSize = codeFontSize
            measured.removeAll(keepingCapacity: true)
            needsRestyle = true
        }
        needsRestyle = needsRestyle || self.environment.chrome != environment.chrome
            || self.environment.colorScheme != environment.colorScheme
            || self.environment.accessibilityReduceMotion != environment.accessibilityReduceMotion
        let restylesChrome = !hasChrome || self.environment.chrome != environment.chrome
            || self.environment.colorScheme != environment.colorScheme
            || self.environment.accessibilityReduceMotion != environment.accessibilityReduceMotion
        self.environment = environment
        self.actions = actions
        self.expanded = expanded
        footer.rootView = composer
        if restylesChrome {
            hasChrome = true
            latest.rootView = AnyView(Button { [weak self] in self?.jumpToLatest() } label: {
                Label("New", systemImage: "arrow.down").font(ChatFont.button).padding(.horizontal, DS.Space.l)
                    .frame(minHeight: DS.Size.touchTarget)
            }.buttonStyle(.plain).floatingCapsule(interactive: true).environment(\.self, environment))
            working.rootView = AnyView(ChatWorkingIndicator().environment(\.self, environment))
        }
        latest.isHidden = !(model.hasNewItems || frame.hasNewerGap)
        guard isViewLoaded else { pending = frame; return }
        let background = NSColor(environment.chrome.background.color)
        view.layer?.backgroundColor = background.cgColor
        topFade.color = background
        bottomFade.color = background
        offer(frame)
    }

    /// A frame from the model, committed on the next display refresh.
    func offer(_ frame: TimelineFrame) {
        guard isViewLoaded else { pending = frame; return }
        if frame.generation != current.generation { needsRestyle = true }
        guard frame.revision != current.revision || frame.cursor != current.cursor || frame.rows.isEmpty != current.rows.isEmpty
            || previousExpanded != expanded || needsRestyle else { return }
        pending = pending.map { frame.folding(after: $0) } ?? frame
        scheduleApply()
    }

    func showsWorking(_ isWorking: Bool) {
        guard isWorking != self.isWorking else { return }
        self.isWorking = isWorking
        guard isViewLoaded else { return }
        working.isHidden = false
        guard !environment.accessibilityReduceMotion, view.window != nil else {
            working.alphaValue = isWorking ? 1 : 0
            working.isHidden = !isWorking
            return
        }
        NSAnimationContext.animate(DS.Motion.standard) { [working] in
            working.animator().alphaValue = isWorking ? 1 : 0
        } completion: { [weak self] in
            guard let self, !self.isWorking else { return }
            working.isHidden = true
        }
    }

    func scrollToBottom() { scroll(toY: bottomOffset) }

    func jumpToLatest() {
        model.jumpToLatest()
        if !current.hasNewerGap { scrollToBottom() }
        latest.isHidden = true
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { itemCount }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.rowIdentifier, for: indexPath)
        if current.rows.indices.contains(indexPath.item) {
            (item as? ChatTranscriptItem)?.configure(AnyView(rowContent(shown(current.rows[indexPath.item]))))
        }
        return item
    }

    /// The row as the reveal shows it; a row still waiting draws at no height.
    private func shown(_ row: ChatRow) -> ChatRow { reveal.display(row) ?? row }

    private func rowContent(_ row: ChatRow) -> some View {
        ChatRowView(row: row, isExpanded: expanded.contains(row.id), toggle: { [weak self] in self?.model.toggle(row.id) },
                    actions: actions, topSpacing: topSpacings[row.id] ?? 0)
            .environment(\.chatRowWidth, lastWidth)
            .environment(\.self, environment)
            .tint(environment.chrome.accentColor)
    }

    // MARK: Applying frames

    /// Frames that arrive between two screen refreshes are applied once, on the next refresh.
    private func scheduleApply() {
        // An occluded window gets no display refreshes; its frames apply as they come.
        let isVisible = view.window.map { $0.screen != nil && $0.occlusionState.contains(.visible) } ?? false
        if isVisible || pacesWhileHidden {
            if clock == nil {
                let clock = view.displayLink(target: ChatTranscriptClock(owner: self), selector: #selector(ChatTranscriptClock.step))
                clock.add(to: .main, forMode: .common)
                self.clock = clock
            }
            clock?.isPaused = false
            armCeiling()
            return
        }
        paintsFrames = false
        guard !applyScheduled else { return }
        applyScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            applyScheduled = false
            applyPending()
        }
    }

    private func armCeiling() {
        guard ceiling == nil else { return }
        ceiling = Task { @MainActor [weak self] in
            let armed = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatTextReveal.frameInterval)
                guard let self, pending != nil || !reveal.isSettled else { break }
                let now = ContinuousClock.now
                guard armed.duration(to: now) >= Self.commitCeiling,
                      lastDisplayTick.map({ $0.duration(to: now) >= Self.commitCeiling }) ?? true else { continue }
                commitFrame()
            }
            self?.ceiling = nil
        }
    }

    fileprivate func tick() {
        lastDisplayTick = .now
        commitFrame()
        clock?.isPaused = reveal.isSettled && pending == nil
    }

    private func commitFrame() {
        paintsFrames = true
        applyPending()
        advanceReveal()
    }

    /// One display frame of the streaming reply: only the rows it changed are measured and redrawn.
    private func advanceReveal() {
        guard isActive, !isApplying, lastWidth > 0, !reveal.isSettled else { return }
        let start = ContinuousClock.now
        let changed = reveal.advance(at: start)
        guard !changed.isEmpty else { return }
        defer {
            revealDurations.append(ContinuousClock.now - start)
            if revealDurations.count > Self.revealSampleLimit { revealDurations.removeFirst() }
        }
        let following = model.followsBottom
        let anchor = document.anchor(at: readingRect.minY)
        measured.subtract(changed)
        var heights: [Int: CGFloat] = [:]
        for id in changed {
            guard let index = document.indices[id.storageKey], current.rows.indices.contains(index),
                  let height = fittedHeight(current.rows[index]) else { continue }
            if document.rows[index].height != height { heights[index] = height }
        }
        if !heights.isEmpty {
            document.setHeights(heights)
            install()
        }
        reconfigure(changed)
        if following { scrollToBottom() }
        else if let anchor, let y = document.position(of: anchor) { scroll(toY: y - scroll.contentInsets.top) }
        recordRevealSample(at: start)
    }

    private func recordRevealSample(at time: ContinuousClock.Instant) {
        revealSamples.append((time, reveal.revealedLength))
        if revealSamples.count > Self.revealSampleLimit { revealSamples.removeFirst() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        clock?.invalidate()
        clock = nil
        ceiling?.cancel()
        ceiling = nil
    }

    private func applyPending() {
        guard isActive, !isApplying, let frame = pending, lastWidth > 0 else { return }
        let start = ContinuousClock.now
        let interval = signposter.beginInterval("Timeline apply", id: signposter.makeSignpostID())
        defer {
            signposter.endInterval("Timeline apply", interval)
            applyDurations.append(ContinuousClock.now - start)
            if applyDurations.count > 1_000 { applyDurations.removeFirst(applyDurations.count - 1_000) }
        }
        pending = nil
        isApplying = true
        defer { isApplying = false }
        // A row opening or folding stays where the reader put it.
        if previousExpanded != expanded, !current.rows.isEmpty, frame.generation == current.generation {
            model.followsBottom = false
        }
        let following = model.followsBottom
        let anchor = document.anchor(at: readingRect.minY)
        let resets = frame.generation != current.generation
        let changesOrder: Bool
        if resets { changesOrder = true }
        else if let next = frame.orderRevision, let previous = current.orderRevision { changesOrder = next != previous }
        else { changesOrder = frame.rows.map(\.id) != current.rows.map(\.id) }
        if resets {
            heights.removeAll()
            measured.removeAll(keepingCapacity: false)
            document = NativeListLayout()
        }
        let keptOrder = changesOrder && !resets ? keptOrder(of: frame) : nil
        var changed = updateRows(in: frame, resetting: resets, keptOrder: changesOrder ? keptOrder ?? 0 : nil)
        let revealed = reveal.update(frame, paces: paintsFrames).filter(frame.rowIDs.contains)
        measured.subtract(revealed)
        changed.formUnion(revealed)
        let previousCount = current.rows.count
        current = frame
        let restyles = needsRestyle
        if changesOrder || restyles || !changed.isEmpty {
            rebuildDocument(keeping: restyles ? nil : changesOrder ? keptOrder ?? 0 : frame.rows.count, changed: changed)
        }
        assert(document.rows.count == current.rows.count && documentRowIDs.count == current.rows.count,
               "the document and the frame disagree on the rows")
        needsRestyle = false
        previousExpanded = expanded
        fitViewport(anchor: anchor, following: following)
        install()
        if resets || restyles || itemCount == 0 || itemCount != previousCount {
            itemCount = current.rows.count
            collection.reloadData()
        }
        else if changesOrder { replaceItems(from: keptOrder ?? 0, previousCount: previousCount, changed: changed) }
        else { reconfigure(changed) }
        if following { scrollToBottom() }
        else if let anchor, let y = document.position(of: anchor) { scroll(toY: y - scroll.contentInsets.top) }
        if changesOrder, rows.count > current.rowIDs.count {
            let identifiers = current.rowIDs
            rows = rows.filter { identifiers.contains($0.key) }
            topSpacings = topSpacings.filter { identifiers.contains($0.key) }
            measured.formIntersection(identifiers)
        }
        if firstContentLatency == nil, !current.rows.isEmpty { firstContentLatency = .now - openedAt }
        if !revealed.isEmpty { recordRevealSample(at: start) }
        latest.isHidden = !(model.hasNewItems || current.hasNewerGap)
        model.readingItem = visibleRows.first?.item
    }

    /// `keptOrder`: how many leading rows kept their order, or nil when the order did not change.
    private func updateRows(in frame: TimelineFrame, resetting: Bool, keptOrder: Int?) -> Set<ChatRowID> {
        let usesDelta = !resetting && frame.parentRevision == current.revision && frame.changedRows != nil
        let candidates = usesDelta ? frame.changedRows ?? [] : frame.rows
        var changed = previousExpanded.symmetricDifference(expanded)
        measured.subtract(changed)
        for row in candidates {
            if resetting || rows[row.id]?.revision != row.revision || rows[row.id]?.awaitsHighlights == true {
                measured.remove(row.id)
                changed.insert(row.id)
            }
            rows[row.id] = row
        }
        // A row's spacing follows the row above it: only rows from the first change on can move.
        let firstChanged = keptOrder.map { max(0, $0 - 1) }
            ?? candidates.lazy.compactMap { self.document.indices[$0.id.storageKey] }.min()
            ?? frame.rows.count
        let start = min(firstChanged, frame.rows.count)
        var previous: ChatRow? = start > 0 ? frame.rows[start - 1] : nil
        for row in frame.rows[start...] {
            let spacing = ChatRowSpacing.top(of: row, below: previous)
            if topSpacings[row.id] != spacing {
                topSpacings[row.id] = spacing
                measured.remove(row.id)
                changed.insert(row.id)
            }
            previous = row
        }
        if needsRestyle { changed.formUnion(frame.rowIDs) }
        return changed.intersection(frame.rowIDs)
    }

    /// Rows before `keptOrder` that did not change keep their geometry; the rest is rebuilt at its
    /// measured height, the height it had, or an estimate until it is measured. Returns how many
    /// leading rows were kept.
    @discardableResult
    private func rebuildDocument(keeping keptOrder: Int?, changed: Set<ChatRowID>) -> Int {
        let previous = document
        let width = lastWidth
        let kept = keptOrder.map { keptRowCount(keptOrder: $0, width: width, changed: changed) } ?? 0
        let scale = Self.proseLineHeight / 20
        let tail = current.rows[kept...].map { row -> NativeListRow in
            let height: CGFloat
            if reveal.shown(row.id) == .waiting { height = 0 }
            else if let cached = heights.peek(key(row)) { height = cached }
            else if previous.contentWidth == width, let index = previous.indices[row.id.storageKey] { height = previous.rows[index].height }
            else { height = ChatRowEstimate.height(for: row, rowWidth: ChatReadingColumn.rowWidth(in: width), scale: scale) }
            return NativeListRow(id: row.id.storageKey, height: reveal.shown(row.id) == .waiting ? 0 : max(1, height))
        }
        if kept > 0 { document.replaceRows(from: kept, with: tail) }
        else { document = NativeListLayout(rows: tail, contentWidth: width) }
        documentRowIDs.removeSubrange(min(kept, documentRowIDs.count)...)
        documentRowIDs.append(contentsOf: current.rows[kept...].lazy.map(\.id))
        return kept
    }

    /// The worker counts the rows that kept their place since the frame it built before; a frame
    /// that skipped some is compared here.
    private func keptOrder(of frame: TimelineFrame) -> Int {
        if frame.parentRevision == current.revision, let kept = frame.keptOrder { return kept }
        return zip(frame.rows, documentRowIDs).prefix { $0.id == $1 }.count
    }

    private func keptRowCount(keptOrder: Int, width: CGFloat, changed: Set<ChatRowID>) -> Int {
        guard document.contentWidth == width, documentRowIDs.count == document.rows.count else { return 0 }
        let firstChanged = changed.lazy.compactMap { self.document.indices[$0.storageKey] }.min()
        return min(keptOrder, firstChanged ?? keptOrder, document.rows.count)
    }

    /// The items from `start` on are replaced and the ones before it that changed redrawn, so a
    /// streamed row never reloads the rows above it.
    private func replaceItems(from start: Int, previousCount: Int, changed: Set<ChatRowID>) {
        let start = min(start, previousCount, current.rows.count)
        let removed = Set((start..<previousCount).map { IndexPath(item: $0, section: 0) })
        let inserted = Set((start..<current.rows.count).map { IndexPath(item: $0, section: 0) })
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            collection.performBatchUpdates {
                itemCount = current.rows.count
                if !removed.isEmpty { collection.deleteItems(at: removed) }
                if !inserted.isEmpty { collection.insertItems(at: inserted) }
            }
        }
        reconfigure(changed)
    }

    private func install() {
        layout.document = document
        layout.invalidateLayout()
        collection.setFrameSize(NSSize(width: lastWidth, height: max(document.height, readingRect.height)))
    }

    private func reconfigure(_ changed: Set<ChatRowID>) {
        for path in collection.indexPathsForVisibleItems() where current.rows.indices.contains(path.item) {
            let row = current.rows[path.item]
            guard changed.contains(row.id), let item = collection.item(at: path) as? ChatTranscriptItem else { continue }
            item.configure(AnyView(rowContent(shown(row))))
        }
    }

    // MARK: Measuring

    /// Measures the rows the viewport will show where it is going, until none changes height.
    private func fitViewport(anchor: NativeListLayout.Anchor?, following: Bool) {
        guard readingRect.height > 0 else { return }
        for _ in 0..<Self.measurePassLimit {
            let top = following ? bottomOffset + scroll.contentInsets.top
                : anchor.flatMap { document.position(of: $0) } ?? readingRect.minY
            guard measure(in: CGRect(x: 0, y: top, width: lastWidth, height: readingRect.height)) else { return }
        }
    }

    /// Rows that came into view by scrolling, measured, with the row being read kept in place.
    private func measureVisible() {
        guard !isMeasuring, !isApplying, lastWidth > 0 else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        let anchor = document.anchor(at: readingRect.minY)
        let following = model.followsBottom
        guard measure(in: readingRect.insetBy(dx: 0, dy: -readingRect.height / 2)) else { return }
        install()
        if following { scrollToBottom() }
        else if let anchor, let y = document.position(of: anchor) { scroll(toY: y - scroll.contentInsets.top) }
    }

    /// Measures the unmeasured rows in `rect`; whether any height changed.
    private func measure(in rect: CGRect) -> Bool {
        var changed: [Int: CGFloat] = [:]
        for index in document.visibleRows(in: rect) where current.rows.indices.contains(index) {
            let row = current.rows[index]
            guard !measured.contains(row.id), let height = fittedHeight(row) else { continue }
            if document.rows[index].height != height { changed[index] = height }
        }
        guard !changed.isEmpty else { return false }
        document.setHeights(changed)
        return true
    }

    private func fittedHeight(_ row: ChatRow) -> CGFloat? {
        guard reveal.shown(row.id) != .waiting else {
            measured.insert(row.id)
            return 0
        }
        let key = key(row)
        if let cached = heights.value(for: key) {
            measured.insert(row.id)
            return cached
        }
        let shownRow = shown(row)
        let fitting = nativeFittingHeight(shownRow)
        guard let fitting, fitting.isFinite, fitting > 0 else { return nil }
        let height = ceil(fitting)
        heights.insert(height, for: key, cost: key.cost)
        measured.insert(row.id)
        measuredRows += 1
        return height
    }

    private func nativeFittingHeight(_ row: ChatRow) -> CGFloat? {
        sizing.rootView = AnyView(rowContent(row))
        return sizing.sizeThatFits(in: CGSize(width: lastWidth, height: .greatestFiniteMagnitude)).height
    }

    private func key(_ row: ChatRow) -> HeightKey {
        HeightKey(id: row.id, revision: row.layoutRevision, width: lastWidth, expanded: expanded.contains(row.id),
                  fontSize: codeFontSize, topSpacing: topSpacings[row.id] ?? 0, revealed: reveal.display(row)?.revealed)
    }

    // MARK: Scrolling

    /// The part of the document between the top fade and the composer.
    private var readingRect: CGRect {
        let clip = scroll.contentView.bounds
        let insets = scroll.contentInsets
        return CGRect(x: 0, y: clip.minY + insets.top, width: clip.width,
                      height: max(0, clip.height - insets.top - insets.bottom))
    }

    private var bottomOffset: CGFloat {
        max(-scroll.contentInsets.top, document.height + scroll.contentInsets.bottom - scroll.contentView.bounds.height)
    }

    private func scroll(toY y: CGFloat) {
        let clamped = min(bottomOffset, max(-scroll.contentInsets.top, y))
        guard scroll.contentView.bounds.minY != clamped else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func boundsChanged() {
        guard isActive, !isApplying else { return }
        measureVisible()
    }

    private func userScrolled() {
        guard isActive, !isApplying else { return }
        model.allowHistoryRetry()
        let follows = distanceFromBottom < Self.followDistance
        if model.followsBottom != follows { model.followsBottom = follows }
        if follows {
            model.reachedBottom()
            latest.isHidden = !current.hasNewerGap
        }
        model.readingItem = visibleRows.first?.item
        if !follows, readingRect.minY < Self.historyDistance { model.requestOlder() }
    }
}

private final class ChatTranscriptClock: NSObject {
    weak var owner: ChatTranscriptController?
    init(owner: ChatTranscriptController) { self.owner = owner }
    @MainActor @objc func step() { owner?.tick() }
}

/// Reports the reader's own scrolling with the wheel and the trackpad, apart from Chat's moves.
final class ChatScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }
}

private final class ChatTranscriptItem: NSCollectionViewItem {
    private var host: NSHostingView<AnyView>?

    override func loadView() { view = NSView() }

    func configure(_ content: AnyView) {
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            view.addSubview(host)
            self.host = host
        }
    }
}

/// The background over the rows at an edge: clear where rows show, solid from the edge out.
final class ChatEdgeFade: NSView {
    enum Edge { case top, bottom }

    let edge: Edge
    let fadeHeight: CGFloat
    var color: NSColor? { didSet { updateColors() } }
    private let gradient = CAGradientLayer()

    init(edge: Edge, height: CGFloat) {
        self.edge = edge
        fadeHeight = height
        super.init(frame: .zero)
        layer = gradient
        wantsLayer = true
        // The layer's unit space starts at the view's bottom edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let fade = bounds.height > 0 ? min(1, fadeHeight / bounds.height) : 1
        gradient.locations = edge == .top ? [0, NSNumber(value: fade)] : [0, NSNumber(value: fade), 1]
    }

    private func updateColors() {
        let solid = color ?? .clear
        let clear = solid.withAlphaComponent(0)
        gradient.colors = (edge == .top ? [solid, clear] : [clear, solid, solid]).map(\.cgColor)
    }
}
#endif
