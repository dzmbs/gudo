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
    }
}

final class ChatViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
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

        var cost: LRUCost {
            LRUCost(bytes: 2 * (MemoryLayout<Self>.stride + id.item.utf8.count + category.utf8.count))
        }
    }

    let model: TimelineModel
    let collection: UICollectionView
    private var source: UICollectionViewDiffableDataSource<Int, ChatRowID>?
    private let layout: NativeCollectionLayout
    private var document = NativeListLayout()
    private var current = TimelineFrame()
    private var pending: TimelineFrame?
    private var rows: [ChatRowID: ChatRow] = [:]
    private var expanded: Set<ChatRowID> = []
    private var previousExpanded: Set<ChatRowID> = []
    private var environment = EnvironmentValues()
    private var actions = ChatRowActions()
    private var codeFontSize = TerminalPreferences.Default.fontSize
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "chat")
    private var openedAt = CACurrentMediaTime()
    private(set) var firstContentLatency: Double?
    var onSnapshot: ((NSDiffableDataSourceSnapshot<Int, ChatRowID>) -> Void)?
    private let heights = BoundedLRU<HeightKey, CGFloat>(
        capacity: ChatCacheLimits.entries, byteLimit: ChatCacheLimits.bytes
    )
    private let paragraphMetrics = ChatParagraphMetrics()
    private var measured: Set<ChatRowID> = []
    private var clock: CADisplayLink?
    private var isActive = true
    private var isApplying = false
    private var isMeasuring = false
    private var needsMeasurement = false
    private var needsRestyle = true
    private var userScrollGeneration = 0
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private var sizingHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var footer = UIHostingController(rootView: AnyView(EmptyView()))
    private var latest = UIHostingController(rootView: AnyView(EmptyView()))
    private(set) var configuredCells = 0
    private(set) var measuredCells = 0
    private(set) var unfittedDisplays = 0
    var retainedMeasurementCount: Int { measured.count }
    var retainedHeightBytes: Int { heights.cost.bytes }
    private(set) var applyDurations: [Double] = []

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
    }

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
        collection.contentInset.top = 52
        collection.verticalScrollIndicatorInsets.top = 52
        collection.delegate = self
        collection.prefetchDataSource = self
        collection.register(ChatCollectionCell.self, forCellWithReuseIdentifier: "chat-block")
        collection.accessibilityIdentifier = "chat-timeline"
        view.addSubview(collection)
        collection.translatesAutoresizingMaskIntoConstraints = false
        install(footer)
        install(latest)
        latest.view.accessibilityIdentifier = "chat-jump-latest"
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: view.topAnchor),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: footer.view.topAnchor),
            footer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            latest.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            latest.view.bottomAnchor.constraint(equalTo: footer.view.topAnchor, constant: -12),
        ])
        source = UICollectionViewDiffableDataSource<Int, ChatRowID>(collectionView: collection) { [weak self] collection, path, identifier in
            let cell = collection.dequeueReusableCell(withReuseIdentifier: "chat-block", for: path)
            guard let self, let row = rows[identifier] else { return cell }
            configure(cell, row: row)
            return cell
        }
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isActive, collection.bounds.width > 0 else { return }
        let topInset = 52 + view.safeAreaInsets.top
        if collection.contentInset.top != topInset {
            collection.contentInset.top = topInset
            collection.verticalScrollIndicatorInsets.top = topInset
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
            if model.followsBottom { scrollToBottom() }
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
        latest.rootView = AnyView(Button { [weak self] in self?.jumpToLatest() } label: {
            Label("New", systemImage: "arrow.down").font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
        }.buttonStyle(.plain).glassEffect(.regular, in: .capsule).environment(\.self, environment))
        latest.view.isHidden = !(model.hasNewItems || frame.hasNewerGap)
        guard isViewLoaded else { pending = frame; return }
        view.backgroundColor = UIColor(environment.chrome.background.color)
        if frame.generation != current.generation { needsRestyle = true }
        if frame.revision != current.revision || frame.cursor != current.cursor || frame.rows.isEmpty != current.rows.isEmpty || previousExpanded != expanded || needsRestyle {
            pending = frame
            ensureClock()
            clock?.isPaused = false
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

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrollGeneration += 1 }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplying, scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
        updateFollowing()
        requestHistoryIfNeeded()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateFollowing() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateFollowing() }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let identifier = source?.itemIdentifier(for: indexPath), !measured.contains(identifier) { unfittedDisplays += 1 }
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
        let content = rowContent(row)
        cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0).minSize(width: 0, height: 0)
        cell.backgroundConfiguration = .clear()
    }

    private func rowContent(_ row: ChatRow) -> some View {
        ChatRowView(row: row, isExpanded: expanded.contains(row.id), toggle: { [weak self] in self?.model.toggle(row.id) }, actions: actions)
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
        if pending != nil { applyPending() }
        if needsMeasurement, !isApplying { measureVisible() }
        clock?.isPaused = pending == nil && !needsMeasurement
    }

    private func applyPending() {
        guard !isApplying, let frame = pending, collection.bounds.width > 0, let source else { return }
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
        let wasFollowing = model.followsBottom
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
        let changed = updateRows(in: frame, resetting: resets)
        current = frame
        if changesOrder || needsRestyle { rebuildDocument() }
        needsRestyle = false
        previousExpanded = expanded
        guard changesOrder || !changed.isEmpty else { isApplying = false; return }
        let initial = source.snapshot().numberOfItems == 0
        measureBeforeSnapshot(anchor: anchor, following: wasFollowing, includingCurrent: !initial)
        var snapshot: NSDiffableDataSourceSnapshot<Int, ChatRowID>
        if changesOrder {
            snapshot = NSDiffableDataSourceSnapshot<Int, ChatRowID>()
            snapshot.appendSections([0])
            snapshot.appendItems(frame.rows.map(\.id))
        } else { snapshot = source.snapshot() }
        snapshot.reconfigureItems(changed)
        onSnapshot?(snapshot)
        let completion: () -> Void = { [weak self] in
            self?.finishSnapshot(anchor: anchor, following: wasFollowing, generation: generation, changesOrder: changesOrder)
        }
        if initial {
            // No cells need retaining yet: fit and place the destination in one initial layout transaction.
            restore(targetOffset(anchor: anchor, following: wasFollowing).y)
            source.applySnapshotUsingReloadData(snapshot)
            completion()
        } else { source.apply(snapshot, animatingDifferences: false, completion: completion) }
    }

    private func finishSnapshot(anchor: NativeListLayout.Anchor?, following: Bool, generation: Int, changesOrder: Bool) {
        if isActive { collection.layoutIfNeeded() }
        if isActive, firstContentLatency == nil, !collection.visibleCells.isEmpty {
            firstContentLatency = (CACurrentMediaTime() - openedAt) * 1_000
        }
        if isActive, generation == userScrollGeneration {
            if following && model.followsBottom { scrollToBottom() }
            else if let anchor, let y = document.position(of: anchor) { restore(y - collection.adjustedContentInset.top) }
        }
        if changesOrder {
            let identifiers = current.rowIDs
            rows = rows.filter { identifiers.contains($0.key) }
            measured.formIntersection(identifiers)
        }
        isApplying = false
        needsMeasurement = true
        clock?.isPaused = !isActive
    }

    private func updateRows(in frame: TimelineFrame, resetting: Bool) -> [ChatRowID] {
        let usesDelta = !resetting && frame.parentRevision == current.revision && frame.changedRows != nil
        let candidates = usesDelta ? frame.changedRows ?? [] : frame.rows
        var changed = previousExpanded.symmetricDifference(expanded)
        measured.subtract(changed)
        for row in candidates {
            if resetting || rows[row.id]?.revision != row.revision {
                measured.remove(row.id)
                changed.insert(row.id)
            }
            rows[row.id] = row
        }
        if needsRestyle { changed.formUnion(frame.rowIDs) }
        return Array(changed.intersection(frame.rowIDs))
    }

    private func rebuildDocument() {
        let old = document
        let width = collection.bounds.width
        let geometry = current.rows.map { row -> NativeListRow in
            let height: CGFloat
            if let cached = heights.peek(key(row)) { height = cached }
            else if old.contentWidth == width, let index = old.indices[row.id.storageKey] { height = old.rows[index].height }
            else { height = estimate(row) }
            return NativeListRow(id: row.id.storageKey, height: max(1, height))
        }
        document = NativeListLayout(rows: geometry, contentWidth: width)
        layout.document = document
        layout.invalidateLayout()
    }

    private func fittedHeight(_ row: ChatRow) -> CGFloat? {
        let key = key(row)
        if let cached = heights.value(for: key) {
            measured.insert(row.id)
            return cached
        }
        let fitting = paragraphMetrics.height(for: row, width: collection.bounds.width,
                                              environment: environment, measure: nativeFittingHeight)
            ?? nativeFittingHeight(row)
        guard let fitting, fitting.isFinite, fitting > 0 else { return nil }
        let height = ceil(fitting)
        heights.insert(height, for: key, cost: key.cost)
        measured.insert(row.id)
        measuredCells += 1
        return height
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
        let atEnd = model.followsBottom
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
        while true {
            let viewport = CGRect(origin: targetOffset(anchor: anchor, following: following), size: collection.bounds.size)
            var candidates = Set(document.visibleRows(in: viewport))
            if includingCurrent { candidates.formUnion(document.visibleRows(in: collection.bounds)) }
            var changed: [Int: CGFloat] = [:]
            for index in candidates {
                guard current.rows.indices.contains(index), !measured.contains(current.rows[index].id),
                      let height = fittedHeight(current.rows[index]) else { continue }
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
            guard let identifier = source?.itemIdentifier(for: path), !measured.contains(identifier),
                  let row = rows[identifier], collection.cellForItem(at: path) != nil else { continue }
            guard let height = fittedHeight(row) else { continue }
            if let index = document.indices[identifier.storageKey], document.rows[index].height != height { changed[index] = height }
        }
        if !changed.isEmpty {
            document.setHeights(changed)
            layout.document = document
            layout.invalidateLayout()
            collection.layoutIfNeeded()
            if model.followsBottom { scrollToBottom() }
            else if let anchor, let y = document.position(of: anchor) { restore(y - collection.adjustedContentInset.top) }
        }
    }

    private func key(_ row: ChatRow) -> HeightKey {
        HeightKey(id: row.id, revision: row.revision, width: collection.bounds.width,
                  category: traitCollection.preferredContentSizeCategory.rawValue, dynamicType: environment.dynamicTypeSize,
                  boldText: environment.legibilityWeight == .bold, rightToLeft: environment.layoutDirection == .rightToLeft,
                  expanded: expanded.contains(row.id), fontSize: codeFontSize)
    }

    private func estimate(_ row: ChatRow) -> CGFloat {
        let scale = UIFont.preferredFont(forTextStyle: .body).lineHeight / 20
        switch row.content {
        case .markdown(let block):
            switch block.kind {
            case .code: return (CGFloat(block.code?.visibleLineCount ?? 1) * 20 + 84) * scale
            case .table: return (CGFloat(block.table.count) * 34 + 44) * scale
            case .list: return (CGFloat(block.list.count) * 28 + 14) * scale
            case .separator: return 31
            default: return 64 * scale
            }
        case .omitted: return 96 * scale
        case .item(let item):
            if case .plan(let plan) = item.body { return CGFloat(min(plan.entries.count, 20) * 30 + 64) * scale }
            return 64 * scale
        }
    }

    private func restore(_ y: CGFloat) {
        let maximum = max(-collection.adjustedContentInset.top, document.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        collection.setContentOffset(CGPoint(x: 0, y: min(maximum, max(-collection.adjustedContentInset.top, y))), animated: false)
    }

    private func updateFollowing() {
        model.readingItem = collection.indexPathsForVisibleItems.min().flatMap { source?.itemIdentifier(for: $0)?.item }
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

private final class ChatFrameClock: NSObject {
    weak var owner: ChatViewController?
    init(owner: ChatViewController) { self.owner = owner }
    @objc func step() { owner?.tick() }
}

private final class ChatCollectionCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { layoutAttributes }
}
#endif
