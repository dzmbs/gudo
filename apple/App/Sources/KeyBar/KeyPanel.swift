#if os(iOS)
import UIKit

/// Every key, grouped, in place of the software keyboard (like the emoji keyboard): it takes the
/// keyboard's own height, so opening it never moves the terminal. Edit turns it into the bar's
/// editor: tap a key to add or remove it, drag the bar's keys to reorder them.
final class KeyPanel: UIInputView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPress: ((KeySpec) -> Void)?
    var onRelease: (() -> Void)?
    var onKeyboard: (() -> Void)?

    private(set) var isEditing = false

    /// Where the panel's paste key pastes (the system's paste control).
    weak var pasteTarget: (any UIPasteConfigurationSupporting)? {
        didSet { if pasteTarget !== oldValue { collectionView.reloadData() } }
    }

    private let favourites: FavouriteKeys
    private let header = UIView()
    private let keyboardButton = UIButton()
    private let resetButton = UIButton()
    private let titleLabel = UILabel()
    private let editButton = UIButton()
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = PanelCollectionView(frame: .zero, collectionViewLayout: layout)
    private lazy var reorder = UILongPressGestureRecognizer(target: self, action: #selector(reordered(_:)))

    private static let headerHeight: CGFloat = 44
    private static let inset: CGFloat = 12
    private static let spacing: CGFloat = 6

    init(favourites: FavouriteKeys = .shared) {
        self.favourites = favourites
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 260), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = .flexibleWidth
        accessibilityIdentifier = "keypanel"
        configureHeader()
        configureCollection()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        update()
        collectionView.setContentOffset(.zero, animated: false)
    }

    func reload() {
        collectionView.reloadData()
        update()
    }

    func applyTheme() {
        overrideUserInterfaceStyle = KeyBarTheme.style
        tintColor = KeyBarTheme.accent
        collectionView.reloadData()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaInsets
        header.frame = CGRect(x: safe.left, y: 0, width: bounds.width - safe.left - safe.right, height: Self.headerHeight)
        let leftWidth: CGFloat = 96
        keyboardButton.frame = CGRect(x: 4, y: 0, width: leftWidth, height: Self.headerHeight)
        resetButton.frame = keyboardButton.frame
        editButton.frame = CGRect(x: header.bounds.width - leftWidth - 4, y: 0, width: leftWidth, height: Self.headerHeight)
        titleLabel.frame = CGRect(x: leftWidth, y: 0, width: header.bounds.width - 2 * leftWidth, height: Self.headerHeight)
        let collectionFrame = CGRect(x: safe.left, y: Self.headerHeight, width: header.bounds.width, height: bounds.height - Self.headerHeight)
        if collectionView.frame != collectionFrame {
            collectionView.frame = collectionFrame
            layout.invalidateLayout()
        }
    }

    // MARK: Header

    private func configureHeader() {
        addSubview(header)
        keyboardButton.configuration = headerConfiguration(title: nil, symbol: "keyboard")
        keyboardButton.contentHorizontalAlignment = .leading
        keyboardButton.accessibilityIdentifier = "keypanel-keyboard"
        keyboardButton.accessibilityLabel = "Show keyboard"
        keyboardButton.addAction(UIAction { [weak self] _ in self?.onKeyboard?() }, for: .touchUpInside)
        resetButton.configuration = headerConfiguration(title: "Reset", symbol: nil)
        resetButton.contentHorizontalAlignment = .leading
        resetButton.accessibilityIdentifier = "keypanel-reset"
        resetButton.accessibilityLabel = "Reset to Default"
        resetButton.addAction(UIAction { [weak self] _ in self?.confirmReset() }, for: .touchUpInside)
        editButton.contentHorizontalAlignment = .trailing
        editButton.accessibilityIdentifier = "keypanel-edit"
        editButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setEditing(!isEditing)
        }, for: .touchUpInside)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        for view in [keyboardButton, resetButton, titleLabel, editButton] as [UIView] { header.addSubview(view) }
    }

    private func headerConfiguration(title: String?, symbol: String?, bold: Bool = false) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        configuration.baseForegroundColor = .label
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        }
        if let title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.systemFont(ofSize: 16, weight: bold ? .semibold : .regular)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        return configuration
    }

    private func update() {
        keyboardButton.isHidden = isEditing
        resetButton.isHidden = !isEditing
        resetButton.isEnabled = !favourites.isDefault
        titleLabel.text = isEditing ? "Edit Bar" : nil
        editButton.configuration = headerConfiguration(title: isEditing ? "Done" : "Edit", symbol: nil, bold: isEditing)
        editButton.accessibilityLabel = isEditing ? "Done" : "Edit Bar"
        reorder.isEnabled = isEditing
        collectionView.reloadData()
    }

    private func confirmReset() {
        favourites.reset()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        update()
    }

    // MARK: Collection

    private func configureCollection() {
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = UIEdgeInsets(top: 2, left: Self.inset, bottom: 14, right: Self.inset)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.delaysContentTouches = false
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.accessibilityIdentifier = "keypanel-keys"
        collectionView.register(KeyCell.self, forCellWithReuseIdentifier: KeyCell.reuseIdentifier)
        collectionView.register(SectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: SectionHeader.reuseIdentifier)
        reorder.minimumPressDuration = 0.2
        reorder.isEnabled = false
        collectionView.addGestureRecognizer(reorder)
        addSubview(collectionView)
    }

    private enum Section {
        case bar
        case group(KeyCatalog.Group)
    }

    private var sections: [Section] {
        (isEditing ? [.bar] : []) + KeyCatalog.groups.map(Section.group)
    }

    private func keys(in section: Int) -> [KeySpec] {
        switch sections[section] {
        case .bar: favourites.keys
        case .group(let group): group.keys
        }
    }

    private func isBar(_ section: Int) -> Bool {
        if case .bar = sections[section] { return true }
        return false
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        keys(in: section).count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: KeyCell.reuseIdentifier, for: indexPath) as! KeyCell
        let key = keys(in: indexPath.section)[indexPath.item]
        let inBar = isBar(indexPath.section)
        let badge: KeyCell.Badge = !isEditing ? .none : inBar ? .remove : favourites.contains(key.id) ? .added : .add
        let pinned = KeyCatalog.pinnedIDs.contains(key.id)
        cell.configure(key: key, showsCaption: !inBar, badge: pinned && isEditing ? .pinned : badge,
                       identifier: (inBar ? "keypanel-bar-" : "keypanel-") + key.id)
        cell.onDown = { [weak self] in
            guard let self, !isEditing, key.repeatable else { return }
            onPress?(key)
        }
        cell.onUp = { [weak self] in
            guard let self, !isEditing, key.repeatable else { return }
            onRelease?()
        }
        cell.onTap = { [weak self] in
            guard let self else { return }
            if isEditing {
                guard !pinned else { return }
                toggle(key)
            } else if !key.repeatable {
                onPress?(key)
            }
        }
        cell.accessibilityCustomActions = isEditing && inBar ? reorderActions(at: indexPath.item) : nil
        cell.showPasteControl(target: key.isPaste && !isEditing ? pasteTarget : nil)
        return cell
    }

    private func reorderActions(at index: Int) -> [UIAccessibilityCustomAction] {
        let count = favourites.ids.count
        var actions: [UIAccessibilityCustomAction] = []
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(name: "Move Earlier") { [weak self] _ in
                self?.favourites.move(from: index, to: index - 1)
                self?.update()
                return true
            })
        }
        if index < count - 1 {
            actions.append(UIAccessibilityCustomAction(name: "Move Later") { [weak self] _ in
                self?.favourites.move(from: index, to: index + 1)
                self?.update()
                return true
            })
        }
        return actions
    }

    private func toggle(_ key: KeySpec) {
        UISelectionFeedbackGenerator().selectionChanged()
        favourites.toggle(key.id)
        update()
        UIAccessibility.post(notification: .announcement, argument: favourites.contains(key.id) ? "Added to the bar" : "Removed from the bar")
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: SectionHeader.reuseIdentifier, for: indexPath) as! SectionHeader
        switch sections[indexPath.section] {
        case .bar:
            header.configure(title: "In the Bar", detail: "Tap to remove, hold and drag to reorder")
        case .group(let group):
            header.configure(title: group.title, detail: isEditing && indexPath.section == 1 ? "Tap to add" : nil)
        }
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: 28)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let captions = !isBar(indexPath.section) && keys(in: indexPath.section).contains { $0.caption != nil }
        let minimum: CGFloat = captions ? 70 : 44
        let available = collectionView.bounds.width - 2 * Self.inset
        let columns = max(1, floor((available + Self.spacing) / (minimum + Self.spacing)))
        let width = floor((available - (columns - 1) * Self.spacing) / columns)
        return CGSize(width: width, height: captions ? 48 : 40)
    }

    // MARK: Reordering

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        isEditing && isBar(indexPath.section)
    }

    func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        favourites.move(from: sourceIndexPath.item, to: destinationIndexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        guard proposedIndexPath.section == 0 else {
            return IndexPath(item: max(0, favourites.ids.count - 1), section: 0)
        }
        return proposedIndexPath
    }

    @objc private func reordered(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: point), isBar(indexPath.section),
                  collectionView.beginInteractiveMovementForItem(at: indexPath) else {
                gesture.state = .cancelled
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(point)
        case .ended:
            collectionView.endInteractiveMovement()
            update()
        default:
            collectionView.cancelInteractiveMovement()
        }
    }
}

/// A drag that starts on a key still scrolls (UIKit keeps it for the control by default).
private final class PanelCollectionView: UICollectionView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

private final class SectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "header"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, detail: String?) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.secondaryLabel,
        ])
        if let detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.tertiaryLabel,
            ]))
        }
        label.attributedText = text
        accessibilityTraits = .header
    }
}

/// One key in the panel: a keyboard-style key with its label and, under it, what it does.
private final class KeyCell: UICollectionViewCell {
    enum Badge {
        case none, add, added, remove, pinned
    }

    static let reuseIdentifier = "key"

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onTap: (() -> Void)?

    private let button = UIButton()
    private var pasteControl: UIPasteControl?
    private let badgeView = UIImageView()
    private var key: KeySpec?
    private var showsCaption = true
    private var badge = Badge.none

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.configurationUpdateHandler = { [weak self] _ in self?.applyConfiguration() }
        button.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.onDown?()
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in
            self?.onUp?()
            self?.onTap?()
        }, for: .touchUpInside)
        button.addAction(UIAction { [weak self] _ in self?.onUp?() }, for: [.touchUpOutside, .touchCancel])
        button.isPointerInteractionEnabled = true
        contentView.addSubview(button)
        badgeView.contentMode = .scaleAspectFit
        contentView.addSubview(badgeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onDown = nil
        onUp = nil
        onTap = nil
        showPasteControl(target: nil)
    }

    /// The system's paste control in place of the key: its tap is the user's own paste, so the
    /// clipboard reads without a prompt, from another app or another device as well.
    func showPasteControl(target: (any UIPasteConfigurationSupporting)?) {
        pasteControl?.removeFromSuperview()
        pasteControl = nil
        button.isHidden = false
        guard let target else { return }
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 9
        configuration.baseForegroundColor = KeyBarTheme.ink
        configuration.baseBackgroundColor = UIColor(KeyBarTheme.chrome.raised.color)
        let control = UIPasteControl(configuration: configuration)
        control.target = target
        contentView.insertSubview(control, belowSubview: badgeView)
        pasteControl = control
        button.isHidden = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = contentView.bounds
        pasteControl?.frame = contentView.bounds
        badgeView.frame = CGRect(x: contentView.bounds.width - 14, y: -4, width: 18, height: 18)
    }

    func configure(key: KeySpec, showsCaption: Bool, badge: Badge, identifier: String) {
        self.key = key
        self.showsCaption = showsCaption
        self.badge = badge
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = key.accessibilityLabel
        button.accessibilityValue = switch badge {
        case .added, .remove: "In the bar"
        case .pinned: "Always in the bar"
        default: nil
        }
        button.accessibilityHint = switch badge {
        case .add: "Adds it to the bar."
        case .added, .remove: "Removes it from the bar."
        default: nil
        }
        let symbol: String? = switch badge {
        case .none, .pinned: nil
        case .add: "plus.circle.fill"
        case .added: "checkmark.circle.fill"
        case .remove: "minus.circle.fill"
        }
        badgeView.tintColor = badge == .added ? tintColor : badge == .remove ? .systemRed : .secondaryLabel
        badgeView.image = symbol.flatMap { UIImage(systemName: $0) }
        badgeView.isHidden = symbol == nil
        button.setNeedsUpdateConfiguration()
    }

    private func applyConfiguration() {
        guard let key else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        configuration.titleAlignment = .center
        configuration.titlePadding = 1
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.baseForegroundColor = .label
        if let title = key.title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.systemFont(ofSize: 17, weight: .regular)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        } else if let symbol = key.symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        }
        if showsCaption, let caption = key.caption {
            var attributes = AttributeContainer()
            attributes.font = UIFont.systemFont(ofSize: 10, weight: .regular)
            attributes.foregroundColor = UIColor.secondaryLabel
            if key.title != nil {
                configuration.attributedSubtitle = AttributedString(caption, attributes: attributes)
            } else {
                configuration.attributedTitle = AttributedString(caption, attributes: attributes)
                configuration.imagePlacement = .top
                configuration.imagePadding = 3
            }
        }
        var background = UIBackgroundConfiguration.clear()
        let pressed = button.isHighlighted
        background.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: pressed ? 0.32 : 0.16)
                : UIColor(white: pressed ? 0.82 : 1, alpha: 1)
        }
        background.cornerRadius = 9
        background.shadowProperties.color = .black
        background.shadowProperties.opacity = 0.18
        background.shadowProperties.radius = 0
        background.shadowProperties.offset = CGSize(width: 0, height: 1)
        configuration.background = background
        button.configuration = configuration
        button.alpha = badge == .pinned ? 0.45 : 1
    }
}
#endif
