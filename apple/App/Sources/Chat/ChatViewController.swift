#if os(iOS)
import DesignSystem
import os
import SwiftUI
import UIKit

struct NativeChatView<Composer: View>: UIViewControllerRepresentable {
    let model: TimelineModel
    let frame: TimelineFrame
    let expanded: Set<ChatRowID>
    var actions = ChatRowActions()
    var isActive = true
    var isWorking = false
    var onControllerReady: ((ChatViewController) -> Void)?
    @ViewBuilder var composer: () -> Composer
    @Environment(\.self) private var environment
    @AppStorage(TerminalPreferences.Key.fontSize) private var fontSize = TerminalPreferences.Default.fontSize

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(model: model)
        onControllerReady?(controller)
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.update(frame: frame, expanded: expanded, environment: environment, actions: actions,
                          composer: AnyView(composer().environment(\.self, environment).tint(environment.chrome.accentColor)), codeFontSize: fontSize, isActive: isActive)
        controller.showsWorking(isWorking)
    }
}

final class ChatViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching {
    private struct HeightKey: Hashable {
        let id: ChatRowID
        let revision: UInt32
        let width: CGFloat
        let category: String
        let dynamicType: DynamicTypeSize
        let boldText: Bool
        let rightToLeft: Bool
        let expanded: Bool
        let fontSize: Double
        let topSpacing: CGFloat
        let revealed: Int?

        var cost: LRUCost {
            LRUCost(bytes: 2 * (MemoryLayout<Self>.stride + id.item.utf8.count + category.utf8.count))
        }
    }

    private static let topClearance: CGFloat = 52
    /// Measuring can grow rows into view that need measuring in turn; past this many passes the
    /// rest waits for the next frame.
    static let measurePassLimit = 8

    let model: TimelineModel
    let collection: UICollectionView
    /// The rows the collection holds: it moves to the frame's count with the collection's update.
    private var itemCount = 0
    private let layout: NativeCollectionLayout
    private var document = NativeListLayout()
    private var documentRowIDs: [ChatRowID] = []
    private var current = TimelineFrame()
    private var pending: TimelineFrame?
    private let reveal = ChatReplyReveal()
    private var configuredWhileMeasuring: Set<ChatRowID> = []
    private var rows: [ChatRowID: ChatRow] = [:]
    private var topSpacings: [ChatRowID: CGFloat] = [:]
    private var expanded: Set<ChatRowID> = []
    private var previousExpanded: Set<ChatRowID> = []
    private var environment = EnvironmentValues()
    private var actions = ChatRowActions()
    private var codeFontSize = TerminalPreferences.Default.fontSize
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "chat")
    private var openedAt = CACurrentMediaTime()
    private(set) var firstContentLatency: Double?
    /// Called with the rows an update redraws, just before the collection receives it.
    var onApply: ((Set<ChatRowID>) -> Void)?
    private let heights = BoundedLRU<HeightKey, CGFloat>(
        capacity: ChatCacheLimits.entries, byteLimit: ChatCacheLimits.bytes
    )
    private let paragraphMetrics = ChatParagraphMetrics()
    private var measured: Set<ChatRowID> = []
    private var clock: CADisplayLink?
    /// The display link is firing, so a streaming reply can be paced; otherwise it shows whole.
    private var paintsFrames = false
    private var ceiling: Task<Void, Never>?
    private var lastDisplayTick: ContinuousClock.Instant?
    private var isActive = true
    private var isWorking = false
    private var isApplying = false
    private var isUserDragging = false
    private var isMeasuring = false
    private var needsMeasurement = false
    private var needsRestyle = true
    private var userScrollGeneration = 0
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private var sizingHost = UIHostingController(rootView: AnyView(EmptyView()))
    private(set) var footer = UIHostingController(rootView: AnyView(EmptyView()))
    private var latest = UIHostingController(rootView: AnyView(EmptyView()))
    /// The working dots float over the transcript just above the composer, so the agent starting
    /// or stopping never moves a row.
    private(set) var working = UIHostingController(rootView: AnyView(EmptyView()))
    /// Rows pass under the bar above and the composer below through a fade into the background.
    let topFade = ChatEdgeFade(edge: .top, height: DS.Space.xxxl)
    let bottomFade = ChatEdgeFade(edge: .bottom, height: DS.Space.xxl)
    private(set) var configuredCells = 0
    private(set) var measuredCells = 0
    private(set) var unfittedDisplays = 0
    var retainedMeasurementCount: Int { measured.count }
    var retainedHeightBytes: Int { heights.cost.bytes }
    private(set) var applyDurations: [Double] = []
    private(set) var revealDurations: [Double] = []
    /// Each display frame that changed the streaming reply: when, and its characters on screen.
    private(set) var revealSamples: [(time: ContinuousClock.Instant, length: Int)] = []
    static let revealSampleLimit = 2_000

    var hasMarkedText: Bool {
        (viewIfLoaded?.firstResponderWithin() as? any UITextInput)?.markedTextRange != nil
    }

    func prepareToPark() -> Bool {
        guard isViewLoaded, let responder = view.firstResponderWithin() else { return true }
        if let input = responder as? any UITextInput, input.markedTextRange != nil { return false }
        return responder.resignFirstResponder()
    }

    init(model: TimelineModel) {
        self.model = model
        let layout = NativeCollectionLayout(document: NativeListLayout())
        self.layout = layout
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        layout.beforePreparingAttributes = { [weak self] in self?.prepareRevealedRows() }
        model.onFrame = { [weak self] frame in self?.offer(frame) }
    }

    /// A frame waits at most this long for a display refresh; without refreshes, frames and the
    /// reveal advance on a timer at the reveal's rate.
    static let commitCeiling: Duration = .milliseconds(100)

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        clock?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = UIColor(environment.chrome.background.color)
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .interactive
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset.top = Self.topClearance
        collection.verticalScrollIndicatorInsets.top = Self.topClearance
        collection.dataSource = self
        collection.delegate = self
        collection.prefetchDataSource = self
        collection.register(ChatCollectionCell.self, forCellWithReuseIdentifier: "chat-block")
        collection.accessibilityIdentifier = "chat-timeline"
        view.addSubview(collection)
        collection.translatesAutoresizingMaskIntoConstraints = false
        for fade in [topFade, bottomFade] {
            view.addSubview(fade)
            fade.translatesAutoresizingMaskIntoConstraints = false
            fade.color = view.backgroundColor
        }
        install(footer)
        install(latest)
        install(working)
        working.view.isUserInteractionEnabled = false
        working.view.isHidden = !isWorking
        working.view.alpha = isWorking ? 1 : 0
        latest.view.accessibilityIdentifier = "chat-jump-latest"
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: view.topAnchor),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            topFade.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topFade.heightAnchor.constraint(equalToConstant: topFade.fadeHeight),
            bottomFade.topAnchor.constraint(equalTo: footer.view.topAnchor, constant: -bottomFade.fadeHeight),
            bottomFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomFade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // SwiftUI already lifts this view above the keyboard; a keyboard guide here counted it
            // twice, and kept a dismissed sheet's keyboard, leaving the composer at the top.
            footer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            latest.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -DS.Space.l),
            latest.view.bottomAnchor.constraint(equalTo: footer.view.topAnchor, constant: -DS.Space.m),
            working.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            working.view.bottomAnchor.constraint(equalTo: footer.view.topAnchor, constant: -DS.Space.s),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ChatViewController, _: UITraitCollection) in
            controller.invalidateMetrics()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureClock()
        clock?.isPaused = pending == nil && !needsMeasurement
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.invalidate()
        clock = nil
        ceiling?.cancel()
        ceiling = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isActive, collection.bounds.width > 0 else { return }
        let topInset = Self.topClearance + view.safeAreaInsets.top
        if collection.contentInset.top != topInset {
            collection.contentInset.top = topInset
            collection.verticalScrollIndicatorInsets.top = topInset
        }
        let composerHeight = max(0, view.bounds.maxY - footer.view.frame.minY)
        let bottomInset = composerHeight + bottomFade.fadeHeight
        if collection.contentInset.bottom != bottomInset {
            collection.contentInset.bottom = bottomInset
            collection.verticalScrollIndicatorInsets.bottom = composerHeight
            if model.followsBottom, !holdsPosition { scrollToBottom() }
        }
        let widthChanged = lastWidth != collection.bounds.width
        if widthChanged {
            lastWidth = collection.bounds.width
            measured.removeAll(keepingCapacity: true)
            pending = pending ?? current
            needsRestyle = true
        }
        if pending != nil, current.rows.isEmpty || widthChanged { applyPending() }
        if lastHeight != collection.bounds.height {
            lastHeight = collection.bounds.height
            if model.followsBottom, !holdsPosition { scrollToBottom() }
        }
        if !isApplying { measureVisible() }
    }

    func update(frame: TimelineFrame, expanded: Set<ChatRowID>, environment: EnvironmentValues,
                actions: ChatRowActions, composer: AnyView, codeFontSize: Double = TerminalPreferences.Default.fontSize, isActive: Bool = true) {
        let visibilityChanged = self.isActive != isActive
        self.isActive = isActive
        if visibilityChanged {
            needsRestyle = true
            userScrollGeneration += 1
            if isActive, firstContentLatency == nil { openedAt = CACurrentMediaTime() }
        }
        if self.actions.supportsDiffs != actions.supportsDiffs || self.actions.readsToolDetails != actions.readsToolDetails
            || (self.actions.resend == nil) != (actions.resend == nil) || (self.actions.loadImage == nil) != (actions.loadImage == nil) {
            needsRestyle = true
        }
        let metricsChanged = self.codeFontSize != codeFontSize
            || self.environment.dynamicTypeSize != environment.dynamicTypeSize
            || self.environment.legibilityWeight != environment.legibilityWeight
            || self.environment.layoutDirection != environment.layoutDirection
        if metricsChanged {
            self.codeFontSize = codeFontSize
            measured.removeAll(keepingCapacity: true)
            needsRestyle = true
        }
        needsRestyle = needsRestyle || self.environment.chrome != environment.chrome
            || self.environment.accessibilityReduceMotion != environment.accessibilityReduceMotion
            || self.environment.colorScheme != environment.colorScheme
            || self.environment.locale != environment.locale
        self.environment = environment
        self.actions = actions
        self.expanded = expanded
        if !isActive {
            pending = frame
            if visibilityChanged { footer.rootView = composer; if isViewLoaded { view.endEditing(true) } }
            clock?.isPaused = true
            return
        }
        if visibilityChanged, isViewLoaded { view.setNeedsLayout() }
        footer.rootView = composer
        // The hosting view does not always report a taller draft on its own; the composer
        // grows upward as the field wraps.
        footer.view.invalidateIntrinsicContentSize()
        latest.rootView = AnyView(Button { [weak self] in self?.jumpToLatest() } label: {
            Label("New", systemImage: "arrow.down").font(ChatFont.button).padding(.horizontal, DS.Space.l)
                .frame(minHeight: DS.Size.touchTarget)
        }.buttonStyle(.plain).floatingCapsule(interactive: true).environment(\.self, environment))
        latest.view.isHidden = !(model.hasNewItems || frame.hasNewerGap)
        working.rootView = AnyView(ChatWorkingIndicator().environment(\.self, environment))
        guard isViewLoaded else { pending = frame; return }
        view.backgroundColor = UIColor(environment.chrome.background.color)
        topFade.color = view.backgroundColor
        bottomFade.color = view.backgroundColor
        offer(frame)
    }

    /// A frame from the model, committed on the next display refresh.
    func offer(_ frame: TimelineFrame) {
        guard isActive, isViewLoaded else { pending = frame; return }
        if frame.generation != current.generation { needsRestyle = true }
        guard frame.revision != current.revision || frame.cursor != current.cursor || frame.rows.isEmpty != current.rows.isEmpty
            || previousExpanded != expanded || needsRestyle else { return }
        pending = pending.map { frame.folding(after: $0) } ?? frame
        latest.view.isHidden = !(model.hasNewItems || frame.hasNewerGap)
        ensureClock()
        clock?.isPaused = false
        armCeiling()
    }

    private func armCeiling() {
        guard ceiling == nil else { return }
        ceiling = Task { @MainActor [weak self] in
            let armed = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatTextReveal.frameInterval)
                guard let self, isActive, pending != nil || !reveal.isSettled else { break }
                let now = ContinuousClock.now
                guard armed.duration(to: now) >= Self.commitCeiling,
                      lastDisplayTick.map({ $0.duration(to: now) >= Self.commitCeiling }) ?? true else { continue }
                commitFrame()
            }
            self?.ceiling = nil
        }
    }

    func showsWorking(_ isWorking: Bool) {
        guard isWorking != self.isWorking else { return }
        self.isWorking = isWorking
        guard isViewLoaded else { return }
        working.view.isHidden = false
        guard !environment.accessibilityReduceMotion, view.window != nil else {
            working.view.alpha = isWorking ? 1 : 0
            working.view.isHidden = !isWorking
            return
        }
        UIView.animate(DS.Motion.standard) { [weak self] in
            self?.working.view.alpha = isWorking ? 1 : 0
        } completion: { [weak self] in
            guard let self, !self.isWorking else { return }
            working.view.isHidden = true
        }
    }

    func scrollToBottom() {
        guard isViewLoaded else { return }
        let y = max(-collection.adjustedContentInset.top, document.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        collection.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    func jumpToLatest() {
        userScrollGeneration += 1
        model.jumpToLatest()
        if !current.hasNewerGap { scrollToBottom() }
        latest.view.isHidden = true
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrollGeneration += 1
        isUserDragging = true
        model.followsBottom = false
        model.allowHistoryRetry()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplying, scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
        updateFollowing()
        requestHistoryIfNeeded()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isUserDragging = false
        if !decelerate { updateFollowing() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateFollowing() }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { itemCount }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "chat-block", for: indexPath)
        if current.rows.indices.contains(indexPath.item) { configure(cell, row: current.rows[indexPath.item]) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let identifier = rowID(at: indexPath), !measured.contains(identifier) { unfittedDisplays += 1 }
        needsMeasurement = true
        ensureClock()
        clock?.isPaused = false
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        if indexPaths.contains(where: { $0.item < 20 }) { requestHistoryIfNeeded() }
    }

    private func install(_ child: UIHostingController<AnyView>) {
        addChild(child)
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.backgroundColor = .clear
        child.sizingOptions = [.intrinsicContentSize]
        child.didMove(toParent: self)
    }

    private func configure(_ cell: UICollectionViewCell, row: ChatRow) {
        configuredCells += 1
        (cell as? ChatCollectionCell)?.rowID = row.id
        let content = rowContent(reveal.display(row) ?? row)
        cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0).minSize(width: 0, height: 0)
        cell.backgroundConfiguration = .clear()
    }

    func rowID(at path: IndexPath) -> ChatRowID? {
        current.rows.indices.contains(path.item) ? current.rows[path.item].id : nil
    }

    func indexPath(of id: ChatRowID) -> IndexPath? {
        document.indices[id.storageKey].map { IndexPath(item: $0, section: 0) }
    }

    private func rowContent(_ row: ChatRow) -> some View {
        ChatRowView(row: row, isExpanded: expanded.contains(row.id), toggle: { [weak self] in self?.model.toggle(row.id) },
                    actions: actions, topSpacing: topSpacings[row.id] ?? 0)
            .environment(\.chatRowWidth, collection.bounds.width)
            .environment(\.self, environment)
            .dynamicTypeSize(environment.dynamicTypeSize)
            .tint(environment.chrome.accentColor)
            .ignoresSafeArea()
    }

    private func ensureClock() {
        guard clock == nil, isActive, isViewLoaded, view.window != nil else { return }
        let clock = CADisplayLink(target: ChatFrameClock(owner: self), selector: #selector(ChatFrameClock.step))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        clock.add(to: .main, forMode: .common)
        self.clock = clock
    }

    fileprivate func tick() {
        guard isActive, view.window != nil else { clock?.isPaused = true; return }
        lastDisplayTick = .now
        commitFrame()
        if needsMeasurement, !isApplying { measureVisible() }
        clock?.isPaused = pending == nil && !needsMeasurement && reveal.isSettled
    }

    private func commitFrame() {
        paintsFrames = true
        if pending != nil { applyPending() }
        advanceReveal()
    }

    /// One display frame of the streaming reply: only the rows it changed are measured and redrawn.
    private func advanceReveal() {
        guard !isApplying, collection.bounds.width > 0, !reveal.isSettled else { return }
        let start = ContinuousClock.now
        let changed = reveal.advance(at: start)
        guard !changed.isEmpty else { return }
        defer {
            revealDurations.append((ContinuousClock.now - start) / .milliseconds(1))
            if revealDurations.count > Self.revealSampleLimit { revealDurations.removeFirst() }
        }
        let following = model.followsBottom && !holdsPosition
        let anchor = document.anchor(at: collection.contentOffset.y + collection.adjustedContentInset.top)
        measured.subtract(changed)
        var heights: [Int: CGFloat] = [:]
        for id in changed {
            guard let index = document.indices[id.storageKey], current.rows.indices.contains(index),
                  let height = fittedHeight(current.rows[index]) else { continue }
            if document.rows[index].height != height { heights[index] = height }
        }
        if !heights.isEmpty {
            document.setHeights(heights)
            layout.document = document
            layout.invalidateLayout()
        }
        reconfigureVisible(changed)
        if following { scrollToBottom() }
        else if let anchor, let y = document.position(of: anchor) { restore(y - collection.adjustedContentInset.top) }
        recordRevealSample(at: start)
    }

    private func recordRevealSample(at time: ContinuousClock.Instant) {
        revealSamples.append((time, reveal.revealedLength))
        if revealSamples.count > Self.revealSampleLimit { revealSamples.removeFirst() }
    }

    private func reconfigureVisible(_ changed: Set<ChatRowID>) {
        defer { configuredWhileMeasuring.removeAll(keepingCapacity: true) }
        for path in collection.indexPathsForVisibleItems {
            guard let id = rowID(at: path), changed.contains(id), !configuredWhileMeasuring.contains(id),
                  let cell = collection.cellForItem(at: path) else { continue }
            configure(cell, row: current.rows[path.item])
        }
    }

    private func applyPending() {
        guard !isApplying, let frame = pending, collection.bounds.width > 0 else { return }
        let start = CACurrentMediaTime()
        let interval = signposter.beginInterval("Timeline apply", id: signposter.makeSignpostID())
        defer {
            signposter.endInterval("Timeline apply", interval)
            applyDurations.append((CACurrentMediaTime() - start) * 1_000)
            if applyDurations.count > 1_000 { applyDurations.removeFirst(applyDurations.count - 1_000) }
        }
        pending = nil
        isApplying = true
        let generation = userScrollGeneration
        if previousExpanded != expanded, !current.rows.isEmpty, frame.generation == current.generation {
            model.followsBottom = false
        }
        let wasFollowing = model.followsBottom && !holdsPosition
        let anchor = document.anchor(at: collection.contentOffset.y + collection.adjustedContentInset.top)
        let resets = frame.generation != current.generation
        let changesOrder: Bool
        if resets { changesOrder = true }
        else if let nextOrder = frame.orderRevision, let previousOrder = current.orderRevision { changesOrder = nextOrder != previousOrder }
        else { changesOrder = frame.rows.map(\.id) != current.rows.map(\.id) }
        if resets {
            heights.removeAll()
            measured.removeAll(keepingCapacity: false)
            document = NativeListLayout()
        }
        let keptOrder = changesOrder && !resets ? keptOrder(of: frame) : nil
        var changed = Set(updateRows(in: frame, resetting: resets, keptOrder: changesOrder ? keptOrder ?? 0 : nil))
        let revealed = reveal.update(frame, paces: paintsFrames).filter(frame.rowIDs.contains)
        measured.subtract(revealed)
        changed.formUnion(revealed)
        let previousCount = itemCount
        current = frame
        let restyles = needsRestyle
        if changesOrder || restyles || !revealed.isEmpty {
            rebuildDocument(keeping: restyles ? nil : changesOrder ? keptOrder : frame.rows.count, changed: changed)
        }
        needsRestyle = false
        previousExpanded = expanded
        guard changesOrder || !changed.isEmpty else { isApplying = false; return }
        let reloads = resets || restyles || previousCount == 0
        measureBeforeSnapshot(anchor: anchor, following: wasFollowing, includingCurrent: !reloads)
        onApply?(changed)
        if reloads {
            // No cells need retaining yet: fit and place the destination in one layout pass.
            restore(targetOffset(anchor: anchor, following: wasFollowing).y)
            itemCount = frame.rows.count
            collection.reloadData()
        } else if changesOrder {
            replaceItems(from: min(keptOrder ?? 0, previousCount), previousCount: previousCount)
            reconfigureVisible(changed)
        } else {
            reconfigureVisible(changed)
        }
        if !revealed.isEmpty { recordRevealSample(at: .now) }
        finishSnapshot(anchor: anchor, following: wasFollowing, generation: generation, changesOrder: changesOrder)
    }

    /// The items from `start` on are replaced, so a streamed row never reloads the rows above it.
    private func replaceItems(from start: Int, previousCount: Int) {
        let start = min(start, previousCount, current.rows.count)
        let removed = (start..<previousCount).map { IndexPath(item: $0, section: 0) }
        let inserted = (start..<current.rows.count).map { IndexPath(item: $0, section: 0) }
        UIView.performWithoutAnimation {
            collection.performBatchUpdates {
                itemCount = current.rows.count
                if !removed.isEmpty { collection.deleteItems(at: removed) }
                if !inserted.isEmpty { collection.insertItems(at: inserted) }
            }
        }
    }

    private func finishSnapshot(anchor: NativeListLayout.Anchor?, following: Bool, generation: Int, changesOrder: Bool) {
        if isActive { collection.layoutIfNeeded() }
        if isActive, firstContentLatency == nil, !collection.visibleCells.isEmpty {
            firstContentLatency = (CACurrentMediaTime() - openedAt) * 1_000
        }
        if isActive, generation == userScrollGeneration {
            if following, model.followsBottom, !holdsPosition { scrollToBottom() }
            else if let anchor, let y = document.position(of: anchor) { restore(y - collection.adjustedContentInset.top) }
        }
        if changesOrder, rows.count > current.rowIDs.count {
            let identifiers = current.rowIDs
            rows = rows.filter { identifiers.contains($0.key) }
            topSpacings = topSpacings.filter { identifiers.contains($0.key) }
            measured.formIntersection(identifiers)
        }
        configuredWhileMeasuring.removeAll(keepingCapacity: true)
        isApplying = false
        needsMeasurement = true
        clock?.isPaused = !isActive
    }

    /// `keptOrder`: how many leading rows kept their order, or nil when the order did not change.
    private func updateRows(in frame: TimelineFrame, resetting: Bool, keptOrder: Int?) -> [ChatRowID] {
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
        return Array(changed.intersection(frame.rowIDs))
    }

    /// Rows before `keptOrder` that did not change keep their geometry and only the rest is
    /// rebuilt; streaming appends at the end.
    private func rebuildDocument(keeping keptOrder: Int?, changed: Set<ChatRowID>) {
        let old = document
        let width = collection.bounds.width
        let kept = keptOrder.map { keptRowCount(keptOrder: $0, width: width, changed: changed) } ?? 0
        let scale = UIFont.preferredFont(forTextStyle: .body).lineHeight / 20
        let tail = current.rows[kept...].map { row -> NativeListRow in
            let height: CGFloat
            if reveal.shown(row.id) == .waiting { height = 0 }
            else if let cached = heights.peek(key(row)) { height = cached }
            else if old.contentWidth == width, let index = old.indices[row.id.storageKey] { height = old.rows[index].height }
            else { height = ChatRowEstimate.height(for: row, rowWidth: ChatReadingColumn.rowWidth(in: width), scale: scale) }
            return NativeListRow(id: row.id.storageKey, height: reveal.shown(row.id) == .waiting ? 0 : max(1, height))
        }
        if kept > 0 { document.replaceRows(from: kept, with: tail) }
        else { document = NativeListLayout(rows: tail, contentWidth: width) }
        documentRowIDs.removeSubrange(min(kept, documentRowIDs.count)...)
        documentRowIDs.append(contentsOf: current.rows[kept...].lazy.map(\.id))
        layout.document = document
        layout.invalidateLayout()
    }

    /// The worker counts the rows that kept their place since the frame it built before; a
    /// frame that skipped some is compared here.
    private func keptOrder(of frame: TimelineFrame) -> Int {
        if frame.parentRevision == current.revision, let kept = frame.keptOrder { return kept }
        return zip(frame.rows, documentRowIDs).prefix { $0.id == $1 }.count
    }

    private func keptRowCount(keptOrder: Int, width: CGFloat, changed: Set<ChatRowID>) -> Int {
        guard document.contentWidth == width, documentRowIDs.count == document.rows.count else { return 0 }
        let firstChanged = changed.lazy.compactMap { self.document.indices[$0.storageKey] }.min()
        return min(keptOrder, firstChanged ?? keptOrder, document.rows.count)
    }

    /// While applying, a changed row on screen is measured through its own cell, configured with
    /// the new content, so SwiftUI lays it out once rather than in a sizing host and again in the cell.
    private func fittedHeight(_ row: ChatRow, at index: Int? = nil) -> CGFloat? {
        guard let shownRow = reveal.display(row) else {
            measured.insert(row.id)
            return 0
        }
        let key = key(row)
        if let cached = heights.value(for: key) {
            measured.insert(row.id)
            return cached
        }
        let fitting = paragraphMetrics.height(for: shownRow, width: collection.bounds.width, topSpacing: topSpacings[row.id] ?? 0,
                                              environment: environment, measure: nativeFittingHeight)
            ?? index.flatMap { visibleCellHeight(row, at: $0) }
            ?? nativeFittingHeight(shownRow)
        guard let fitting, fitting.isFinite, fitting > 0 else { return nil }
        let height = ceil(fitting)
        heights.insert(height, for: key, cost: key.cost)
        measured.insert(row.id)
        measuredCells += 1
        return height
    }

    private func visibleCellHeight(_ row: ChatRow, at index: Int) -> CGFloat? {
        guard isApplying, let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? ChatCollectionCell,
              cell.rowID == row.id else { return nil }
        configure(cell, row: row)
        configuredWhileMeasuring.insert(row.id)
        let width = collection.bounds.width
        return cell.contentView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                        withHorizontalFittingPriority: .required,
                                                        verticalFittingPriority: .fittingSizeLevel).height
    }

    private func nativeFittingHeight(_ row: ChatRow) -> CGFloat? {
        // Reused cells can report the previous hosting configuration's fitting size.
        sizingHost.rootView = AnyView(rowContent(row))
        return sizingHost.sizeThatFits(in: CGSize(width: collection.bounds.width, height: .greatestFiniteMagnitude)).height
    }

    private func targetOffset(anchor: NativeListLayout.Anchor?, following: Bool) -> CGPoint {
        let top = -collection.adjustedContentInset.top
        let bottom = max(top, document.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        let reading = anchor.flatMap { document.position(of: $0) }.map { $0 + top } ?? collection.contentOffset.y
        return CGPoint(x: 0, y: following ? bottom : min(bottom, max(top, reading)))
    }

    private func prepareRevealedRows() {
        guard isActive, !isApplying, !isMeasuring, collection.bounds.width > 0, collection.bounds.height > 0 else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        let anchor = document.anchor(at: collection.contentOffset.y + collection.adjustedContentInset.top)
        let atEnd = model.followsBottom && !holdsPosition
            && document.height - collection.bounds.maxY + collection.adjustedContentInset.bottom < 40
        guard fitViewport(anchor: anchor, following: atEnd, includingCurrent: false) else { return }
        layout.document = document
        let destination = targetOffset(anchor: anchor, following: atEnd)
        if destination != collection.contentOffset { collection.setContentOffset(destination, animated: false) }
    }

    private func measureBeforeSnapshot(anchor: NativeListLayout.Anchor?, following: Bool, includingCurrent: Bool) {
        _ = fitViewport(anchor: anchor, following: following, includingCurrent: includingCurrent)
        layout.document = document
        layout.invalidateLayout()
    }

    private func fitViewport(anchor: NativeListLayout.Anchor?, following: Bool, includingCurrent: Bool) -> Bool {
        guard collection.bounds.height > 0 else { return false }
        var updated = false
        for _ in 0..<Self.measurePassLimit {
            let viewport = CGRect(origin: targetOffset(anchor: anchor, following: following), size: collection.bounds.size)
            var candidates = Set(document.visibleRows(in: viewport))
            if includingCurrent { candidates.formUnion(document.visibleRows(in: collection.bounds)) }
            var changed: [Int: CGFloat] = [:]
            for index in candidates {
                guard current.rows.indices.contains(index), !measured.contains(current.rows[index].id),
                      let height = fittedHeight(current.rows[index], at: index) else { continue }
                changed[index] = height
            }
            guard !changed.isEmpty else { break }
            document.setHeights(changed)
            updated = true
        }
        return updated
    }

    private func measureVisible() {
        guard !isMeasuring, !isApplying else { return }
        isMeasuring = true
        let interval = signposter.beginInterval("Timeline measure", id: signposter.makeSignpostID())
        defer { isMeasuring = false; signposter.endInterval("Timeline measure", interval) }
        needsMeasurement = false
        let anchor = document.anchor(at: collection.contentOffset.y + collection.adjustedContentInset.top)
        var changed: [Int: CGFloat] = [:]
        let start = CACurrentMediaTime()
        for path in collection.indexPathsForVisibleItems {
            if CACurrentMediaTime() - start > 0.003 { needsMeasurement = true; break }
            guard let identifier = rowID(at: path), !measured.contains(identifier),
                  let row = rows[identifier], collection.cellForItem(at: path) != nil else { continue }
            guard let height = fittedHeight(row) else { continue }
            if let index = document.indices[identifier.storageKey], document.rows[index].height != height { changed[index] = height }
        }
        if !changed.isEmpty {
            document.setHeights(changed)
            layout.document = document
            layout.invalidateLayout()
            collection.layoutIfNeeded()
            if model.followsBottom, !holdsPosition { scrollToBottom() }
            else if let anchor, let y = document.position(of: anchor) { restore(y - collection.adjustedContentInset.top) }
        }
    }

    private func key(_ row: ChatRow) -> HeightKey {
        HeightKey(id: row.id, revision: row.layoutRevision, width: collection.bounds.width,
                  category: traitCollection.preferredContentSizeCategory.rawValue, dynamicType: environment.dynamicTypeSize,
                  boldText: environment.legibilityWeight == .bold, rightToLeft: environment.layoutDirection == .rightToLeft,
                  expanded: expanded.contains(row.id), fontSize: codeFontSize, topSpacing: topSpacings[row.id] ?? 0,
                  revealed: reveal.display(row)?.revealed)
    }

    private func restore(_ y: CGFloat) {
        let maximum = max(-collection.adjustedContentInset.top, document.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        collection.setContentOffset(CGPoint(x: 0, y: min(maximum, max(-collection.adjustedContentInset.top, y))), animated: false)
    }

    private var holdsPosition: Bool { isUserDragging || collection.isTracking }

    private func updateFollowing() {
        model.readingItem = collection.indexPathsForVisibleItems.min().flatMap { rowID(at: $0)?.item }
        guard !isUserDragging else { return }
        let distance = document.height - collection.bounds.height + collection.adjustedContentInset.bottom - collection.contentOffset.y
        model.followsBottom = distance < 40
        if model.followsBottom { model.reachedBottom(); latest.view.isHidden = !current.hasNewerGap }
    }

    private func requestHistoryIfNeeded() {
        if !model.followsBottom, collection.contentOffset.y + collection.adjustedContentInset.top < 600 { model.requestOlder() }
    }

    private func invalidateMetrics() {
        measured.removeAll(keepingCapacity: true)
        pending = current
        needsRestyle = true
        ensureClock()
        clock?.isPaused = false
    }

    @objc private func memoryWarning() {
        heights.removeAll()
        paragraphMetrics.clear()
        sizingHost.rootView = AnyView(EmptyView())
        model.releaseRenderCaches()
    }
}

/// The background over the rows at an edge: clear where rows show, solid from the edge out.
final class ChatEdgeFade: UIView {
    enum Edge { case top, bottom }

    let edge: Edge
    let fadeHeight: CGFloat
    var color: UIColor? { didSet { updateColors() } }

    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradient: CAGradientLayer? { layer as? CAGradientLayer }

    init(edge: Edge, height: CGFloat) {
        self.edge = edge
        fadeHeight = height
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fade = bounds.height > 0 ? min(1, fadeHeight / bounds.height) : 1
        gradient?.locations = edge == .top ? [0, NSNumber(value: fade)] : [0, NSNumber(value: fade), 1]
    }

    private func updateColors() {
        let solid = color ?? .clear
        let clear = solid.withAlphaComponent(0)
        gradient?.colors = (edge == .top ? [solid, clear] : [clear, solid, solid]).map(\.cgColor)
    }
}

private final class ChatFrameClock: NSObject {
    weak var owner: ChatViewController?
    init(owner: ChatViewController) { self.owner = owner }
    @objc func step() { owner?.tick() }
}

private final class ChatCollectionCell: UICollectionViewCell {
    var rowID: ChatRowID?

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { layoutAttributes }
}
#endif
