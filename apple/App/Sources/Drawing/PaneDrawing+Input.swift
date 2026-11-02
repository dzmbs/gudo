import DesignSystem
import DrawingKit
import Foundation
import SwiftUI
import TerminalRenderer
import UniformTypeIdentifiers
import UnnamedCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
extension PaneDrawing: UIGestureRecognizerDelegate, UIDropInteractionDelegate {
    /// Pencil on the terminal → draw mode at that row, the stroke becoming the drawing's first;
    /// Pencil held still → Write; two-finger long press → draw mode; tap on a placement → reopen
    /// it; drop and paste of images and `.excalidraw` files → import.
    func installInput(on view: TerminalView) {
        // Fingers keep scrolling and selecting: the terminal's own recognizers take direct
        // touches only.
        let pencil = PencilCaptureGesture(target: self, action: #selector(pencilCaptured(_:)))
        pencil.delegate = self
        view.addGestureRecognizer(pencil)

        let twoFinger = UILongPressGestureRecognizer(target: self, action: #selector(twoFingerPressed(_:)))
        twoFinger.numberOfTouchesRequired = 2
        twoFinger.minimumPressDuration = 0.45
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.delegate = self
        view.addGestureRecognizer(twoFinger)

        // A tap on a drawing in the output opens its menu: its marker is a menu button
        // (`PlacementMarker.offerMenu`).

        view.addInteraction(UIDropInteraction(delegate: self))
        view.onPasteAttachment = { [weak self] pasteboard in
            guard let self, let image = pasteboard.image, let png = image.pngData() else { return false }
            importAttachment(name: "Pasted Image.png", data: png)
            return true
        }
    }

    private var capture: PencilCapture? {
        get { objc_getAssociatedObject(self, &PaneDrawing.captureKey) as? PencilCapture }
        set { objc_setAssociatedObject(self, &PaneDrawing.captureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private static nonisolated(unsafe) var captureKey: UInt8 = 0

    /// A Pencil touch on the terminal outside draw and write mode. Moving draws: draw mode opens
    /// at the touched row and the stroke (drawn meanwhile as a preview) becomes its first
    /// stroke. Held still for half a second: Write. A tap: draw mode, nothing drawn.
    @objc private func pencilCaptured(_ gesture: PencilCaptureGesture) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began:
            guard overlay == nil, writer == nil, canvas == nil, !isReadOnly, let start = gesture.samples.first else {
                capture = nil
                return
            }
            let capture = PencilCapture(start: start.location, color: isDarkTheme ? .white : .black)
            capture.preview.frame = view.bounds
            view.layer.addSublayer(capture.preview)
            capture.update(gesture.samples)
            capture.holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self, weak capture] _ in
                MainActor.assumeIsolated {
                    guard let self, let capture, capture.phase == .pending, self.capture === capture else { return }
                    capture.phase = .writing
                    capture.preview.removeFromSuperlayer()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    CanvasWebView.log.info("pencil: held still on pane \(self.paneId): Write")
                    self.startWriting()
                }
            }
            self.capture = capture
        case .changed:
            guard let capture else { return }
            capture.update(gesture.samples)
            if capture.phase == .pending, capture.moved > 6 {
                capture.phase = .drawing
                capture.holdTimer?.invalidate()
                CanvasWebView.log.info("pencil: stroke on pane \(self.paneId) opens draw mode")
                beginDrawing(at: capture.start, tool: .pen) { [weak capture] _ in capture?.opened = true }
            }
        case .ended:
            guard let capture else { return }
            self.capture = nil
            capture.holdTimer?.invalidate()
            capture.update(gesture.samples)
            switch capture.phase {
            case .pending:
                capture.preview.removeFromSuperlayer()
                beginDrawing(at: capture.start, tool: .pen)
            case .drawing:
                if capture.opened, let overlay {
                    overlay.adoptFirstStroke(gesture.samples, from: view)
                } else {
                    CanvasWebView.log.info("pencil: draw mode did not open; the stroke is dropped")
                }
                // PencilKit draws the adopted stroke from the next frame on.
                DispatchQueue.main.async { capture.preview.removeFromSuperlayer() }
            case .writing:
                break
            }
        default:
            capture?.holdTimer?.invalidate()
            capture?.preview.removeFromSuperlayer()
            capture = nil
        }
    }

    @objc private func twoFingerPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view = gesture.view else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        beginDrawing(at: gesture.location(in: view))
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // Draw and write mode take their own touches (and the Pencil in them is PencilKit's or
        // Scribble's).
        isIdle
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// A placement's menu as a `UIMenu`: sections inline, Export and Version History as
    /// submenus (the history is fetched when it opens).
    func uiMenu(forPlacement id: UInt64) -> [UIMenuElement] {
        guard let placement = placement(id: id) else { return [] }
        let anchor = frame(of: placement) ?? .zero
        return menu(for: placement).sections.map { section in
            let children: [UIMenuElement] = section.items.map { item in
                if item.placementAction == .history { return historyMenu(placement) }
                let action = UIAction(
                    title: item.title, subtitle: item.subtitle, image: UIImage(systemName: item.systemImage),
                    identifier: UIAction.Identifier("drawing.menu.\(item.id)"),
                    attributes: item.destructive ? .destructive : []
                ) { [weak self] _ in
                    self?.perform(item, on: placement, anchor: anchor)
                }
                action.accessibilityIdentifier = "drawing.menu.\(item.id)"
                return action
            }
            if section.submenu {
                let submenu = UIMenu(title: section.title ?? "", image: section.systemImage.flatMap { UIImage(systemName: $0) }, children: children)
                submenu.accessibilityIdentifier = "drawing.menu.\((section.title ?? "").lowercased())"
                return submenu
            }
            return UIMenu(title: section.title ?? "", options: .displayInline, children: children)
        }
    }

    /// Version History: every finished version with its render, the shown one checked; picking
    /// another restores it.
    private func historyMenu(_ placement: Placement) -> UIMenu {
        let list = UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated {
                guard let self else { return completion([]) }
                Task { @MainActor in
                    let versions = await self.history(of: placement)
                    guard !versions.isEmpty else {
                        return completion([UIAction(title: "No earlier versions", attributes: .disabled) { _ in }])
                    }
                    var items: [UIMenuElement] = []
                    for version in versions {
                        let current = version.version == placement.version
                        var image: UIImage?
                        if let hash = version.image?.hash, let png = await self.hub.png(hash: hash) {
                            image = await UIImage(data: png)?.byPreparingThumbnail(ofSize: CGSize(width: 96, height: 54))
                        }
                        let action = UIAction(
                            title: Self.when(version), subtitle: Self.versionDetail(version, current: current),
                            image: image ?? UIImage(systemName: "scribble"),
                            identifier: UIAction.Identifier("drawing.history.\(version.version)"),
                            attributes: current ? .disabled : [], state: current ? .on : .off
                        ) { _ in
                            self.restore(placement, to: version)
                        }
                        action.accessibilityIdentifier = "drawing.history.\(version.version)"
                        items.append(action)
                    }
                    completion(items)
                }
            }
        }
        let menu = UIMenu(title: "Version History", image: UIImage(systemName: "clock.arrow.circlepath"), children: [list])
        menu.accessibilityIdentifier = "drawing.menu.history"
        return menu
    }

    // MARK: Drop

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        // An image lifted from this pane's own output and dropped back is a slip, not an import.
        if let view = interaction.view, session.localDragSession?.items.contains(where: { $0.localObject as? UIView === view }) == true {
            return false
        }
        return !isReadOnly && session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.fileURL.identifier, UTType.excalidraw.identifier, UTType.json.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        // A drawing dragged from a pane of this app: the same drawing, not a copy of its pixels.
        let refs = session.localDragSession?.items.compactMap { $0.localObject as? DrawingDragRef } ?? []
        if !refs.isEmpty {
            refs.forEach(dropped)
            return
        }
        for item in session.items {
            let provider = item.itemProvider
            let name = provider.suggestedName ?? "Dropped Image"
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let png = UIImage(data: data).flatMap { $0.pngData() } ?? data
                    Task { @MainActor [weak self] in self?.importAttachment(name: name + ".png", data: png) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.excalidraw.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.excalidraw.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor [weak self] in self?.importAttachment(name: name + ".excalidraw", data: data) }
                }
            } else {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                    guard let url, PaneDrawing.acceptsFile(named: url.lastPathComponent), let data = try? Data(contentsOf: url) else { return }
                    let file = url.lastPathComponent
                    Task { @MainActor [weak self] in self?.importAttachment(name: file, data: data) }
                }
            }
        }
    }
}

/// Follows one Pencil touch on the terminal with its coalesced samples (never cancels the
/// terminal's touches; the terminal's own recognizers take fingers only).
final class PencilCaptureGesture: UIGestureRecognizer {
    private(set) var samples: [PencilSample] = []
    private var touch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let first = touches.first(where: { $0.type == .pencil }) else { return }
        touch = first
        append(first, event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        append(touch, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        append(touch, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        touch = nil
        samples = []
    }

    private func append(_ touch: UITouch, _ event: UIEvent) {
        guard let view else { return }
        for t in event.coalescedTouches(for: touch) ?? [touch] { samples.append(PencilSample(t, in: view)) }
    }

    override func canPrevent(_ gesture: UIGestureRecognizer) -> Bool { false }
}

/// The Pencil touch being followed outside draw mode, and its live preview (drawn until the
/// overlay's PencilKit layer has the stroke).
@MainActor
final class PencilCapture {
    enum Phase { case pending, drawing, writing }

    let start: CGPoint
    var phase = Phase.pending
    var opened = false
    var moved: CGFloat = 0
    var holdTimer: Timer?
    let preview = CAShapeLayer()

    init(start: CGPoint, color: UIColor) {
        self.start = start
        preview.strokeColor = color.cgColor
        preview.fillColor = nil
        preview.lineWidth = 2.5
        preview.lineCap = .round
        preview.lineJoin = .round
        preview.zPosition = 10
    }

    func update(_ samples: [PencilSample]) {
        guard let first = samples.first else { return }
        let path = CGMutablePath()
        path.move(to: first.location)
        for s in samples.dropFirst() {
            path.addLine(to: s.location)
            moved = max(moved, hypot(s.location.x - start.x, s.location.y - start.y))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = path
        CATransaction.commit()
    }
}

/// Over a drawing placed in the output: its accessibility element (VoiceOver, UI tests) and,
/// with `offerMenu`, its menu: a tap (finger or pointer) opens Send to… / Start… / Copy / Share
/// / Edit / Delete, anchored to the drawing. The Pencil, two-finger scrolls and every touch while
/// the pane draws or writes pass through to the terminal.
final class PlacementMarker: UIView, UIDragInteractionDelegate {
    private weak var drawing: PaneDrawing?
    private var placementId: UInt64 = 0
    /// Presents the menu (a tap asks it to). A menu button of its own would open on touch
    /// down and swallow the long press that lifts the drawing.
    private let menuButton = UIButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .image
        menuButton.frame = bounds
        menuButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menuButton.isUserInteractionEnabled = false
        menuButton.isAccessibilityElement = false
        addSubview(menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func offerMenu(drawing: PaneDrawing, placementId: UInt64) {
        self.drawing = drawing
        self.placementId = placementId
        isUserInteractionEnabled = true
        // Long press lifts the drawing: into other apps (PNG + `.excalidraw`), other panes,
        // windows and hosts (`PaneDrawing.dropped`).
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        addInteraction(drag)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showMenu)))
        accessibilityTraits = [.image, .button]
        accessibilityHint = "Send, copy, share or edit the drawing; touch and hold to drag it"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated {
                guard let self, let drawing = self.drawing else { return completion([]) }
                completion(drawing.uiMenu(forPlacement: self.placementId))
            }
        }])
    }

    @objc private func showMenu() {
        menuButton.performPrimaryAction()
    }

    override func accessibilityActivate() -> Bool {
        showMenu()
        return true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let drawing, drawing.isIdle else { return nil }
        // The Pencil draws over the output, drawings included.
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return nil }
        return super.hitTest(point, with: event)
    }

    func setIdentifier(_ id: String, label: String) {
        accessibilityIdentifier = id
        accessibilityLabel = label
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let drawing, drawing.isIdle, let placement = drawing.placement(id: placementId), let ref = drawing.dragRef(placement) else { return [] }
        let item = UIDragItem(itemProvider: drawing.itemProvider(for: placement))
        item.localObject = ref
        if let png = drawing.hub.cachedPNG(hash: placement.image.hash), let image = UIImage(data: png) {
            item.previewProvider = { [bounds] in
                let view = UIImageView(image: image)
                view.frame = bounds
                view.contentMode = .scaleAspectFit
                return UIDragPreview(view: view)
            }
        }
        CanvasWebView.log.info("drag: placement \(placement.placementId) lifted")
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        // The image is drawn by Metal under this (transparent) marker: lift a copy of it.
        guard let drawing, let placement = drawing.placement(id: placementId),
              let png = drawing.hub.cachedPNG(hash: placement.image.hash), let image = UIImage(data: png), let superview
        else { return nil }
        let view = UIImageView(image: image)
        view.frame = bounds
        view.contentMode = .scaleAspectFit
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedDragPreview(view: view, parameters: parameters, target: UIDragPreviewTarget(container: superview, center: center))
    }

    /// Outlines the placement for a moment: where Done put it.
    func flash() {
        layer.borderColor = UIColor(ChromePalette.fromPreferences().accentColor).cgColor
        layer.cornerRadius = 3
        layer.borderWidth = 1.5
        let fade = CABasicAnimation(keyPath: "borderWidth")
        fade.fromValue = 1.5
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.2
        fade.duration = 0.6
        fade.fillMode = .backwards
        layer.add(fade, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.layer.borderWidth = 0 }
    }
}
#else
extension PaneDrawing {
    /// Click on a placement → reopen it; drop and paste of images and `.excalidraw` files →
    /// import (⌥-drop onto an agent pane sends the image to the agent).
    func installInput(on view: TerminalView) {
        // Clicks and drags on a drawing go to its marker (`PlacementMarker`).
        view.onPasteAttachment = { [weak self] pasteboard in
            self?.importFromPasteboard(pasteboard, send: false) ?? false
        }
        view.onDropAttachment = { [weak self] pasteboard, _ in
            self?.importFromPasteboard(pasteboard, send: NSEvent.modifierFlags.contains(.option)) ?? false
        }
    }

    private func importFromPasteboard(_ pasteboard: NSPasteboard, send: Bool) -> Bool {
        guard !isReadOnly else { return false }
        // A drawing dragged from a pane of this app: the same drawing, not a copy of its pixels.
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(DrawingDragRef.typeIdentifier)),
           let ref = try? JSONDecoder().decode(DrawingDragRef.self, from: data) {
            dropped(ref)
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let accepted = urls.filter { PaneDrawing.acceptsFile(named: $0.lastPathComponent) }
            for url in accepted {
                if let data = try? Data(contentsOf: url) { importAttachment(name: url.lastPathComponent, data: data, send: send) }
            }
            return !accepted.isEmpty
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        importAttachment(name: "Pasted Image.png", data: png, send: send)
        return true
    }

    /// A click on a drawing in the output opens its menu (Send to… / Start… / Copy / Export /
    /// Share / Version History / Edit / Delete) at the click.
    func showMenu(forPlacement id: UInt64, at point: CGPoint) {
        guard let view = pane?.view, let placement = placement(id: id) else { return }
        let anchor = frame(of: placement) ?? CGRect(origin: point, size: .zero)
        let popup = NSMenu()
        for (index, section) in menu(for: placement).sections.enumerated() {
            let entries = section.items.map { item -> NSMenuItem in
                if item.placementAction == .history { return historyItem(placement) }
                let entry = MenuAction.item(item.title, item.systemImage) { [weak self] in
                    self?.perform(item, on: placement, anchor: anchor)
                }
                if let subtitle = item.subtitle { entry.subtitle = subtitle }
                entry.setAccessibilityIdentifier("drawing.menu.\(item.id)")
                return entry
            }
            if index > 0 { popup.addItem(.separator()) }
            if section.submenu, let title = section.title {
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.image = section.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                parent.submenu = NSMenu(title: title)
                entries.forEach { parent.submenu?.addItem($0) }
                parent.setAccessibilityIdentifier("drawing.menu.\(title.lowercased())")
                popup.addItem(parent)
                continue
            }
            if let title = section.title { popup.addItem(.sectionHeader(title: title)) }
            entries.forEach(popup.addItem)
        }
        popup.popUp(positioning: nil, at: point, in: view)
    }

    /// Version History: fetched as the menu opens; every finished version with its render,
    /// the shown one checked; picking another restores it.
    private func historyItem(_ placement: Placement) -> NSMenuItem {
        let parent = NSMenuItem(title: "Version History", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        parent.setAccessibilityIdentifier("drawing.menu.history")
        let submenu = NSMenu(title: "Version History")
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)
        parent.submenu = submenu
        Task { [weak self, weak submenu] in
            guard let self else { return }
            let versions = await self.history(of: placement)
            var items: [NSMenuItem] = []
            for version in versions {
                let current = version.version == placement.version
                let entry = MenuAction.item(Self.when(version), "scribble") { [weak self] in
                    self?.restore(placement, to: version)
                }
                entry.subtitle = Self.versionDetail(version, current: current)
                entry.state = current ? .on : .off
                entry.isEnabled = !current
                if let hash = version.image?.hash, let png = await self.hub.png(hash: hash), let image = NSImage(data: png) {
                    let height: CGFloat = 32
                    image.size = NSSize(width: min(96, height * image.size.width / max(image.size.height, 1)), height: height)
                    entry.image = image
                }
                entry.setAccessibilityIdentifier("drawing.history.\(version.version)")
                items.append(entry)
            }
            guard let submenu else { return }
            submenu.removeAllItems()
            if items.isEmpty {
                let none = NSMenuItem(title: "No earlier versions", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            items.forEach(submenu.addItem)
        }
        return parent
    }

    /// What dragging `placement` out offers: a PNG file (Finder, Mail), PNG data, the
    /// `.excalidraw` scene when it is at hand, and a reference for this app's panes.
    func dragWriter(for placement: Placement) -> NSPasteboardWriting? {
        guard let ref = dragRef(placement), let png = hub.cachedPNG(hash: placement.image.hash) else { return nil }
        let scene = sceneCache[placement.artifactId]
        return DrawingFilePromise(png: png, scene: scene, ref: ref, name: Self.fileName(.png))
    }

    /// Fetches the scene a drag may carry, ahead of the drag (pasteboards are answered at once).
    func prefetchScene(_ placement: Placement) {
        guard sceneCache[placement.artifactId] == nil else { return }
        let client = hub.client
        Task { [weak self] in
            guard let scene = try? await client.excalidrawFile(artifactId: placement.artifactId) else { return }
            self?.sceneCache[placement.artifactId] = scene
        }
    }

    private var sceneCache: [UInt64: Data] {
        get { objc_getAssociatedObject(self, &PaneDrawing.sceneKey) as? [UInt64: Data] ?? [:] }
        set { objc_setAssociatedObject(self, &PaneDrawing.sceneKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private static nonisolated(unsafe) var sceneKey: UInt8 = 0
}

/// Over a drawing placed in the output: its accessibility element (VoiceOver, UI tests), its
/// menu on a click, and a drag source (into other apps as a PNG file + data + the scene, into
/// this app's panes as the drawing itself). Passes everything through while the pane draws.
final class PlacementMarker: NSView, NSDraggingSource {
    private weak var drawing: PaneDrawing?
    private var placementId: UInt64 = 0
    private var down: NSPoint?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let drawing, drawing.isIdle else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
        if let drawing, let placement = drawing.placement(id: placementId) { drawing.prefetchScene(placement) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, let drawing, let placement = drawing.placement(id: placementId) else { return }
        let at = convert(event.locationInWindow, from: nil)
        guard hypot(at.x - start.x, at.y - start.y) > 4 else { return }
        down = nil
        guard let writer = drawing.dragWriter(for: placement) else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = drawing.hub.cachedPNG(hash: placement.image.hash).flatMap(NSImage.init(data:))
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
        CanvasWebView.log.info("drag: placement \(placement.placementId) lifted")
    }

    override func mouseUp(with event: NSEvent) {
        guard down != nil, let drawing, let view = drawing.pane?.view else { return }
        down = nil
        drawing.showMenu(forPlacement: placementId, at: view.convert(event.locationInWindow, from: nil))
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        DrawingFilePromise.operation
    }

    func setIdentifier(_ id: String, label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(id)
        setAccessibilityLabel(label)
    }

    /// Outlines the placement for a moment: where Done put it.
    func flash() {
        wantsLayer = true
        layer?.borderColor = NSColor(ChromePalette.fromPreferences().accentColor).cgColor
        layer?.cornerRadius = 3
        layer?.borderWidth = 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.layer?.borderWidth = 0 }
    }

    func offerMenu(drawing: PaneDrawing, placementId: UInt64) {
        self.drawing = drawing
        self.placementId = placementId
        setAccessibilityRole(.button)
        setAccessibilityHelp("Click to send, copy, export or edit the drawing; drag it to move it")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let drawing, let view = drawing.pane?.view else { return false }
        drawing.showMenu(forPlacement: placementId, at: view.convert(NSPoint(x: frame.midX, y: frame.midY), from: superview))
        return true
    }
}
#endif
