import Foundation
import TerminalRenderer
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
extension PaneDrawing: UIGestureRecognizerDelegate, UIDropInteractionDelegate {
    /// Pencil touch → draw mode at that row; two-finger long press → draw mode; tap on a
    /// placement → reopen it; drop and paste of images and `.excalidraw` files → import.
    func installInput(on view: TerminalView) {
        // Pencil on the terminal enters draw mode (fingers keep scrolling and selecting: the
        // terminal's own recognizers take direct touches only).
        let pencil = UILongPressGestureRecognizer(target: self, action: #selector(pencilTouched(_:)))
        pencil.minimumPressDuration = 0
        pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencil.cancelsTouchesInView = false
        view.addGestureRecognizer(pencil)

        let twoFinger = UILongPressGestureRecognizer(target: self, action: #selector(twoFingerPressed(_:)))
        twoFinger.numberOfTouchesRequired = 2
        twoFinger.minimumPressDuration = 0.45
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.delegate = self
        view.addGestureRecognizer(twoFinger)

        let tap = UITapGestureRecognizer(target: self, action: #selector(placementTapped(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        tap.delegate = self
        view.addGestureRecognizer(tap)
        // The terminal's single tap (focus, click, links) waits for ours, which fails at once
        // unless the tap is on a placement.
        for other in view.gestureRecognizers ?? [] where other !== tap {
            if let single = other as? UITapGestureRecognizer, single.numberOfTapsRequired == 1, single.numberOfTouchesRequired == 1 {
                single.require(toFail: tap)
            }
        }
        placementTap = tap

        view.addInteraction(UIDropInteraction(delegate: self))
        view.onPasteAttachment = { [weak self] pasteboard in
            guard let self, let image = pasteboard.image, let png = image.pngData() else { return false }
            importAttachment(name: "Pasted Image.png", data: png)
            return true
        }
    }

    private var placementTap: UITapGestureRecognizer? {
        get { objc_getAssociatedObject(self, &PaneDrawing.tapKey) as? UITapGestureRecognizer }
        set { objc_setAssociatedObject(self, &PaneDrawing.tapKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private static nonisolated(unsafe) var tapKey: UInt8 = 0

    @objc private func pencilTouched(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view = gesture.view else { return }
        beginDrawing(at: gesture.location(in: view))
    }

    @objc private func twoFingerPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view = gesture.view else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        beginDrawing(at: gesture.location(in: view))
    }

    @objc private func placementTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view, let placement = placement(at: gesture.location(in: view)) else { return }
        reopen(placement)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === placementTap, let view = gesture.view else { return overlay == nil }
        return overlay == nil && placement(at: gesture.location(in: view)) != nil
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture !== placementTap
    }

    // MARK: Drop

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        !isReadOnly && session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.fileURL.identifier, "com.excalidraw.json", UTType.json.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        for item in session.items {
            let provider = item.itemProvider
            let name = provider.suggestedName ?? "Dropped Image"
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let png = UIImage(data: data).flatMap { $0.pngData() } ?? data
                    Task { @MainActor [weak self] in self?.importAttachment(name: name + ".png", data: png) }
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

/// An accessibility element over a placement (VoiceOver, UI tests); touches pass through.
final class PlacementMarker: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setIdentifier(_ id: String, label: String) {
        accessibilityIdentifier = id
        accessibilityLabel = label
    }
}
#else
extension PaneDrawing: NSGestureRecognizerDelegate {
    /// Click on a placement → reopen it; drop and paste of images and `.excalidraw` files →
    /// import (⌥-drop onto an agent pane sends the image to the agent).
    func installInput(on view: TerminalView) {
        let click = NSClickGestureRecognizer(target: self, action: #selector(placementClicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = self
        view.addGestureRecognizer(click)

        view.onPasteAttachment = { [weak self] pasteboard in
            self?.importFromPasteboard(pasteboard, send: false) ?? false
        }
        view.onDropAttachment = { [weak self] pasteboard, _ in
            self?.importFromPasteboard(pasteboard, send: NSEvent.modifierFlags.contains(.option)) ?? false
        }
    }

    private func importFromPasteboard(_ pasteboard: NSPasteboard, send: Bool) -> Bool {
        guard !isReadOnly else { return false }
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

    @objc private func placementClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let placement = placement(at: gesture.location(in: view)) else { return }
        reopen(placement)
    }

    func gestureRecognizerShouldBegin(_ gesture: NSGestureRecognizer) -> Bool {
        guard let view = gesture.view else { return false }
        return overlay == nil && placement(at: gesture.location(in: view)) != nil
    }
}

/// An accessibility element over a placement (VoiceOver, UI tests); clicks pass through.
final class PlacementMarker: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setIdentifier(_ id: String, label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(id)
        setAccessibilityLabel(label)
    }
}
#endif
