import SwiftUI

extension EnvironmentValues {
    @Entry var nativeListHorizontalOffset: CGFloat = 0
}

#if os(macOS)
import AppKit

struct NativeVirtualList<Content: View>: NSViewRepresentable {
    let document: NativeListLayout
    @ViewBuilder var content: (Int) -> Content
    @Environment(\.self) private var environment

    func rowContent(_ index: Int, horizontalOffset: CGFloat) -> some View {
        content(index).id(document.rows[index].id)
            .environment(\.nativeListHorizontalOffset, horizontalOffset)
            .environment(\.self, environment)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let collection = context.coordinator.collection
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.collectionViewLayout = NativeCollectionLayout(document: document)
        collection.register(NativeCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("virtual-list-row"))
        collection.dataSource = context.coordinator
        scroll.documentView = collection
        context.coordinator.observe(scroll)
        context.coordinator.update(self, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, scroll: scroll)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource {
        var parent: NativeVirtualList
        let collection = NSCollectionView()
        private var revision: Int?
        private var observation: NSObjectProtocol?
        private var horizontalOffset: CGFloat = 0

        init(parent: NativeVirtualList) { self.parent = parent }

        isolated deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }

        func observe(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let offset = self.collection.visibleRect.minX
                        guard offset != self.horizontalOffset else { return }
                        self.horizontalOffset = offset
                        self.refreshVisibleContent()
                    }
                }
        }

        private func refreshVisibleContent() {
            for path in collection.indexPathsForVisibleItems() where parent.document.rows.indices.contains(path.item) {
                (collection.item(at: path) as? NativeCollectionItem)?.configure(AnyView(parent.rowContent(path.item, horizontalOffset: horizontalOffset)))
            }
        }

        func update(_ parent: NativeVirtualList, scroll: NSScrollView) {
            let position = scroll.contentView.bounds.origin
            let anchor = self.parent.document.anchor(at: position.y)
            self.parent = parent
            guard revision != parent.document.revision else {
                refreshVisibleContent()
                return
            }
            revision = parent.document.revision
            guard let layout = collection.collectionViewLayout as? NativeCollectionLayout else { return }
            layout.document = parent.document
            collection.reloadData()
            layout.invalidateLayout()
            collection.setFrameSize(CGSize(width: max(scroll.contentSize.width, parent.document.contentWidth),
                height: max(scroll.contentSize.height, parent.document.height)))
            collection.layoutSubtreeIfNeeded()
            let y = anchor.flatMap { parent.document.position(of: $0) } ?? position.y
            scroll.contentView.scroll(to: CGPoint(x: position.x, y: max(0, min(y, parent.document.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { parent.document.rows.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("virtual-list-row"), for: indexPath)
            (item as? NativeCollectionItem)?.configure(AnyView(parent.rowContent(indexPath.item, horizontalOffset: collectionView.visibleRect.minX)))
            return item
        }
    }

}

private final class NativeCollectionItem: NSCollectionViewItem {
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

final class NativeCollectionLayout: NSCollectionViewLayout {
    var document: NativeListLayout

    init(document: NativeListLayout) {
        self.document = document
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var collectionViewContentSize: NSSize {
        CGSize(width: max(collectionView?.enclosingScrollView?.contentSize.width ?? 0, document.contentWidth), height: document.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var indices = Set(document.visibleRows(in: rect))
        if let currentHeader = document.header(at: collectionView?.visibleRect.minY ?? 0) { indices.insert(currentHeader) }
        return indices.sorted().compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard document.rows.indices.contains(indexPath.item) else { return nil }
        let item = document.rows[indexPath.item]
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        let bounds = collectionView?.enclosingScrollView?.contentView.bounds ?? .zero
        var frame = CGRect(x: 0, y: document.positions[indexPath.item], width: collectionViewContentSize.width, height: item.height)
        if !item.scrollsHorizontally {
            frame.origin.x = bounds.minX
            frame.size.width = bounds.width
        }
        if item.isHeader {
            frame.origin.y = max(frame.minY, min(bounds.minY, document.nextHeaderPosition(after: indexPath.item) - frame.height))
            attributes.zIndex = 1
        }
        attributes.frame = frame
        return attributes
    }
}
#else
import UIKit

struct NativeVirtualList<Content: View>: UIViewRepresentable {
    let document: NativeListLayout
    @ViewBuilder var content: (Int) -> Content
    @Environment(\.self) private var environment

    func rowContent(_ index: Int, horizontalOffset: CGFloat) -> some View {
        content(index).id(document.rows[index].id)
            .environment(\.nativeListHorizontalOffset, horizontalOffset)
            .environment(\.self, environment)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = NativeCollectionLayout(document: document)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.register(NativeCollectionCell.self, forCellWithReuseIdentifier: "virtual-list-row")
        context.coordinator.attach(collection)
        context.coordinator.update(self, collection: collection)
        return collection
    }

    func updateUIView(_ collection: UICollectionView, context: Context) {
        context.coordinator.update(self, collection: collection)
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: NativeVirtualList
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var revision: Int?
        private var horizontalOffset: CGFloat = 0

        init(parent: NativeVirtualList) { self.parent = parent }

        func attach(_ collection: UICollectionView) {
            collection.delegate = self
            dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, indexPath, identifier in
                guard let self, let index = parent.document.indices[identifier] else { return nil }
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "virtual-list-row", for: indexPath)
                let content = parent.rowContent(index, horizontalOffset: collection.contentOffset.x)
                cell.contentConfiguration = UIHostingConfiguration { content.ignoresSafeArea() }
                    .margins(.all, 0)
                    .minSize(width: 0, height: 0)
                cell.backgroundConfiguration = .clear()
                return cell
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collection = scrollView as? UICollectionView, horizontalOffset != collection.contentOffset.x else { return }
            horizontalOffset = collection.contentOffset.x
            refreshVisibleContent(collection)
        }

        private func refreshVisibleContent(_ collection: UICollectionView) {
            for path in collection.indexPathsForVisibleItems {
                guard parent.document.rows.indices.contains(path.item), let cell = collection.cellForItem(at: path) else { continue }
                let content = parent.rowContent(path.item, horizontalOffset: collection.contentOffset.x)
                cell.contentConfiguration = UIHostingConfiguration { content.ignoresSafeArea() }
                    .margins(.all, 0)
                    .minSize(width: 0, height: 0)
            }
        }

        func update(_ parent: NativeVirtualList, collection: UICollectionView) {
            let anchor = self.parent.document.anchor(at: collection.contentOffset.y)
            let position = collection.contentOffset
            self.parent = parent
            guard revision != parent.document.revision else {
                refreshVisibleContent(collection)
                return
            }
            revision = parent.document.revision
            guard let layout = collection.collectionViewLayout as? NativeCollectionLayout else { return }
            layout.document = parent.document
            layout.invalidateLayout()
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(parent.document.rows.map(\.id))
            dataSource?.applySnapshotUsingReloadData(snapshot)
            collection.layoutIfNeeded()
            let y = anchor.flatMap { parent.document.position(of: $0) } ?? position.y
            collection.setContentOffset(CGPoint(x: position.x, y: max(0, min(y, parent.document.height - collection.bounds.height))), animated: false)
        }
    }
}

private final class NativeCollectionCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }
}

final class NativeCollectionLayout: UICollectionViewLayout {
    var document: NativeListLayout

    init(document: NativeListLayout) {
        self.document = document
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(collectionView?.bounds.width ?? 0, document.contentWidth), height: document.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var indices = Set(document.visibleRows(in: rect))
        if let currentHeader = document.header(at: collectionView?.contentOffset.y ?? 0) { indices.insert(currentHeader) }
        return indices.sorted().compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard document.rows.indices.contains(indexPath.item) else { return nil }
        let item = document.rows[indexPath.item]
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let bounds = collectionView?.bounds ?? .zero
        var frame = CGRect(x: 0, y: document.positions[indexPath.item], width: collectionViewContentSize.width, height: item.height)
        if !item.scrollsHorizontally {
            frame.origin.x = bounds.minX
            frame.size.width = bounds.width
        }
        if item.isHeader {
            frame.origin.y = max(frame.minY, min(bounds.minY, document.nextHeaderPosition(after: indexPath.item) - frame.height))
            attributes.zIndex = 1
        }
        attributes.frame = frame
        return attributes
    }
}
#endif
