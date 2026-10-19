#if os(iOS)
import DrawingKit
import os
import PencilKit
import UIKit
import UnnamedCore

/// Pencil ink on the draw overlay: PencilKit draws the live stroke (Apple's latency and
/// prediction), points stream to other clients every ~16 ms (`inkLive`), and on pen-up the
/// stroke becomes an Excalidraw `freedraw` element in the overlay's scene. The PencilKit stroke
/// stays until the page says it has drawn the element (`inkApplied`), so the hand-off never
@MainActor
final class InkCanvasController: NSObject, PKCanvasViewDelegate {
    let canvas = InkCanvas()
    private weak var overlay: DrawOverlay?
    private var converted: [String: PKStroke] = [:]
    private var committedAt: [String: CFTimeInterval] = [:]
    private var settingDrawing = false
    private var known = 0
    private let live = LiveInk()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "ink")

    init(overlay: DrawOverlay) {
        self.overlay = overlay
        super.init()
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvas.overrideUserInterfaceStyle = .unspecified
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.accessibilityIdentifier = "drawing.ink"
        let observer = InkObserver(live: live)
        observer.onSample = { [weak self] touch, view in self?.sample(touch, in: view) }
        observer.onEnd = { [weak self] in self?.live.end() }
        canvas.addGestureRecognizer(observer)
    }

    func setTool(_ tool: OverlayModel.Tool, pencilOnly: Bool) {
        canvas.isUserInteractionEnabled = tool == .pen || pencilOnly
        canvas.drawingPolicy = tool == .pen && !pencilOnly ? .anyInput : .pencilOnly
        canvas.fingersPassThrough = pencilOnly || tool != .pen
    }

    func tearDown() {
        live.end()
        canvas.delegate = nil
        canvas.removeFromSuperview()
    }

    // MARK: Live ink

    private func sample(_ touch: UITouch, in view: UIView) {
        guard let overlay, let geometry = overlay.currentGeometry, let artifactId = overlay.artifactId else { return }
        let client = overlay.client
        let p = geometry.scene(fromView: touch.preciseLocation(in: view))
        let pressure = touch.maximumPossibleForce > 0 ? min(1, touch.force / touch.maximumPossibleForce * 1.5) : 0.5
        live.add(InkPoint(
            x: Float(p.x), y: Float(p.y), pressure: Float(max(pressure, 0.05)),
            altitude: Float(touch.altitudeAngle), azimuth: Float(touch.azimuthAngle(in: view)), tMs: 0),
            artifactId: artifactId, client: client)
    }

    // MARK: Commit

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !settingDrawing, let overlay, let geometry = overlay.currentGeometry else { return }
        let strokes = canvasView.drawing.strokes
        guard strokes.count > known else {
            known = strokes.count
            return
        }
        var elements: [[String: Any]] = []
        for stroke in strokes[known...] {
            let id = "ink-" + UUID().uuidString.lowercased().prefix(20)
            let ink = InkStroke(stroke, geometry: geometry)
            guard let element = Freedraw.element(
                ink, id: String(id), seed: Int.random(in: 1..<Int(Int32.max)),
                versionNonce: Int.random(in: 1..<Int(Int32.max)), updatedMs: Int64(Date().timeIntervalSince1970 * 1000))
            else { continue }
            converted[String(id)] = stroke
            committedAt[String(id)] = CACurrentMediaTime()
            elements.append(element)
        }
        known = strokes.count
        if !elements.isEmpty { overlay.addInk(elements) }
    }

    /// The page drew these elements: drop their PencilKit strokes (one-frame overlap).
    func applied(ids: [String]) {
        let now = CACurrentMediaTime()
        var remove: [PKStroke] = []
        for id in ids {
            if let stroke = converted.removeValue(forKey: id) { remove.append(stroke) }
            if let start = committedAt.removeValue(forKey: id) {
                Self.log.info("ink hand-off \(String(format: "%.1f", (now - start) * 1000), privacy: .public) ms")
            }
        }
        guard !remove.isEmpty else { return }
        let remaining = canvas.drawing.strokes.filter { stroke in !remove.contains { $0.path.creationDate == stroke.path.creationDate && $0.path.count == stroke.path.count } }
        settingDrawing = true
        canvas.drawing = PKDrawing(strokes: remaining)
        known = remaining.count
        settingDrawing = false
    }
}

/// PencilKit's canvas that lets finger touches through to the editor underneath when only the
/// Pencil inks (iPad): a touch is hit-tested here only if it is a Pencil touch.
final class InkCanvas: PKCanvasView {
    var fingersPassThrough = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if fingersPassThrough {
            let touches = event?.allTouches ?? []
            guard touches.contains(where: { $0.type == .pencil }) else { return nil }
        }
        return super.hitTest(point, with: event)
    }
}

/// Watches the touches PencilKit inks (never recognizes, never cancels them).
private final class InkObserver: UIGestureRecognizer {
    var onSample: ((UITouch, UIView) -> Void)?
    var onEnd: (() -> Void)?
    let live: LiveInk

    init(live: LiveInk) {
        self.live = live
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        live.begin()
        feed(touches, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        feed(touches, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        feed(touches, event)
        onEnd?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnd?()
        state = .failed
    }

    private func feed(_ touches: Set<UITouch>, _ event: UIEvent) {
        guard let view, let touch = touches.first else { return }
        for t in event.coalescedTouches(for: touch) ?? [touch] { onSample?(t, view) }
    }

    override func canPrevent(_ gesture: UIGestureRecognizer) -> Bool { false }
}

@MainActor
final class LiveInk {
    private var points: [InkPoint] = []
    private var strokeId: UInt64 = 0
    private var chunk: UInt32 = 0
    private var started: CFTimeInterval = 0
    private var lastFlush: CFTimeInterval = 0
    private var target: (artifactId: UInt64, client: DaemonClient)?

    func begin() {
        strokeId = UInt64.random(in: 1..<UInt64.max)
        chunk = 0
        points = []
        started = CACurrentMediaTime()
        lastFlush = started
    }

    func add(_ point: InkPoint, artifactId: UInt64, client: DaemonClient) {
        var point = point
        point.tMs = UInt32(max(0, (CACurrentMediaTime() - started) * 1000))
        points.append(point)
        target = (artifactId, client)
        if CACurrentMediaTime() - lastFlush >= 0.016 { flush(done: false) }
    }

    func end() {
        guard target != nil else { return }
        flush(done: true)
        target = nil
    }

    private func flush(done: Bool) {
        guard let target, !points.isEmpty || done else { return }
        lastFlush = CACurrentMediaTime()
        target.client.inkLive(chunk: InkChunk(
            artifactId: target.artifactId, strokeId: strokeId, chunk: chunk, tool: .pen,
            style: DrawStyle(color: 0x1E1E1EFF, width: 2), points: packInkPoints(points: points), done: done))
        chunk += 1
        points = []
    }
}
#endif
