import SwiftUI

#if os(macOS)
import AppKit

struct NativeDiffList<Content: View>: NSViewRepresentable {
    let document: DiffRenderDocument
    @ViewBuilder var content: (DiffRenderRow) -> Content

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
        collection.collectionViewLayout = DiffCollectionLayout(document: document)
        collection.register(DiffCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("diff-row"))
        collection.dataSource = context.coordinator
        scroll.documentView = collection
        context.coordinator.update(self, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, scroll: scroll)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource {
        var parent: NativeDiffList
        let collection = NSCollectionView()
        private var revision: UUID?

        init(parent: NativeDiffList) { self.parent = parent }

        func update(_ parent: NativeDiffList, scroll: NSScrollView) {
            let position = scroll.contentView.bounds.origin
            let anchor = self.parent.document.anchor(at: position.y)
            self.parent = parent
            guard revision != parent.document.revision else {
                for path in collection.indexPathsForVisibleItems() {
                    (collection.item(at: path) as? DiffCollectionItem)?.configure(AnyView(parent.content(parent.document.rows[path.item])))
                }
                return
            }
            revision = parent.document.revision
            guard let layout = collection.collectionViewLayout as? DiffCollectionLayout else { return }
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
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("diff-row"), for: indexPath)
            (item as? DiffCollectionItem)?.configure(AnyView(parent.content(parent.document.rows[indexPath.item])))
            return item
        }
    }

}

private final class DiffCollectionItem: NSCollectionViewItem {
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

final class DiffCollectionLayout: NSCollectionViewLayout {
    var document: DiffRenderDocument

    init(document: DiffRenderDocument) {
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
        switch item.content {
        case .line, .hunk: break
        default:
            frame.origin.x = bounds.minX
            frame.size.width = bounds.width
        }
        if case .file = item.content {
            frame.origin.y = max(frame.minY, min(bounds.minY, document.nextHeaderPosition(after: indexPath.item) - frame.height))
            attributes.zIndex = 1
        }
        attributes.frame = frame
        return attributes
    }
}
#else
import UIKit

struct NativeDiffList<Content: View>: UIViewRepresentable {
    let document: DiffRenderDocument
    @ViewBuilder var content: (DiffRenderRow) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = DiffCollectionLayout(document: document)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.register(DiffCollectionCell.self, forCellWithReuseIdentifier: "diff-row")
        context.coordinator.attach(collection)
        context.coordinator.update(self, collection: collection)
        return collection
    }

    func updateUIView(_ collection: UICollectionView, context: Context) {
        context.coordinator.update(self, collection: collection)
    }

    final class Coordinator {
        var parent: NativeDiffList
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var revision: UUID?

        init(parent: NativeDiffList) { self.parent = parent }

        func attach(_ collection: UICollectionView) {
            dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, indexPath, identifier in
                guard let self, let index = parent.document.indices[identifier] else { return nil }
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "diff-row", for: indexPath)
                cell.contentConfiguration = UIHostingConfiguration { self.parent.content(self.parent.document.rows[index]) }
                    .margins(.all, 0)
                    .minSize(width: 0, height: 0)
                cell.backgroundConfiguration = .clear()
                return cell
            }
        }

        func update(_ parent: NativeDiffList, collection: UICollectionView) {
            let anchor = self.parent.document.anchor(at: collection.contentOffset.y)
            let position = collection.contentOffset
            self.parent = parent
            guard revision != parent.document.revision else {
                for path in collection.indexPathsForVisibleItems {
                    guard parent.document.rows.indices.contains(path.item), let cell = collection.cellForItem(at: path) else { continue }
                    cell.contentConfiguration = UIHostingConfiguration { parent.content(parent.document.rows[path.item]) }
                        .margins(.all, 0)
                        .minSize(width: 0, height: 0)
                }
                return
            }
            revision = parent.document.revision
            guard let layout = collection.collectionViewLayout as? DiffCollectionLayout else { return }
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

private final class DiffCollectionCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }
}

final class DiffCollectionLayout: UICollectionViewLayout {
    var document: DiffRenderDocument

    init(document: DiffRenderDocument) {
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
        switch item.content {
        case .line, .hunk: break
        default:
            frame.origin.x = bounds.minX
            frame.size.width = bounds.width
        }
        if case .file = item.content {
            frame.origin.y = max(frame.minY, min(bounds.minY, document.nextHeaderPosition(after: indexPath.item) - frame.height))
            attributes.zIndex = 1
        }
        attributes.frame = frame
        return attributes
    }
}
#endif
