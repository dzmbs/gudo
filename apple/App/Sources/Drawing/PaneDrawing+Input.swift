import DesignSystem
import DrawingKit
import Foundation
import SwiftUI
import TerminalRenderer
import UniformTypeIdentifiers
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

    @objc private func placementTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view, let placement = placement(at: gesture.location(in: view)) else { return }
        reopen(placement)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // Draw and write mode take their own touches (and the Pencil in them is PencilKit's or
        // Scribble's).
        let idle = overlay == nil && writer == nil && canvas == nil
        guard gesture === placementTap, let view = gesture.view else { return idle }
        return idle && placement(at: gesture.location(in: view)) != nil
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

    /// Outlines the placement for a moment: where Done put it.
    func flash() {
        layer.borderColor = UIColor(DS.Palette.accent).cgColor
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

    /// Outlines the placement for a moment: where Done put it.
    func flash() {
        wantsLayer = true
        layer?.borderColor = NSColor(DS.Palette.accent).cgColor
        layer?.cornerRadius = 3
        layer?.borderWidth = 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.layer?.borderWidth = 0 }
    }
}
#endif
