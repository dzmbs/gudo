#if os(iOS)
import DrawingKit
import os
import PencilKit
import UIKit
import GudoCore

/// Pencil ink on the draw overlay: PencilKit draws the live stroke (for its latency and
/// prediction), points stream to other clients every ~16 ms, and on lift the stroke becomes an
/// Excalidraw `freedraw` element in the overlay's scene.
///
/// `InkHandoff` keeps the PencilKit stroke until the page says it has drawn the element, so the
/// stroke never disappears:
/// - elements made before the page has loaded its scene are held until it has, since the scene
///   load would replace them;
/// - confirmed strokes are removed from PencilKit only between strokes, because replacing the
///   drawing while the Pencil is down cancels the stroke in flight;
/// - unconfirmed elements are resent (the page de-duplicates by id);
/// - strokes are matched by identity, not by count, so a stroke PencilKit reports late is still
///   converted.
@MainActor
final class InkCanvasController: NSObject, PKCanvasViewDelegate {
    let canvas = InkCanvas()
    private weak var overlay: DrawOverlay?
    private var handoff = InkHandoff()
    /// Converted elements by id, kept for resends, and their PencilKit strokes.
    private var elements: [String: [String: Any]] = [:]
    private var strokes: [String: StrokeKey] = [:]
    private var known: Set<StrokeKey> = []
    private var settingDrawing = false
    private let live = LiveInk()
    private var resendTimer: Timer?
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private static let log = CanvasWebView.log

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
        resendTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resendOverdue() }
        }
    }

    /// Pen inks every touch; Select inks the Pencil only and lets fingers through to the editor;
    /// other tools leave every touch to the editor.
    func setTool(_ tool: DrawTool) {
        let routing = DrawRouting.inkLayer(for: tool)
        canvas.isUserInteractionEnabled = routing.interactive
        canvas.drawingPolicy = routing.pencilOnly ? .pencilOnly : .anyInput
        canvas.fingersPassThrough = routing.pencilOnly
        Self.log.info("ink: tool \(tool.rawValue, privacy: .public) (ink layer \(routing.interactive ? (routing.pencilOnly ? "pencil only" : "all touches") : "off", privacy: .public))")
    }

    /// Two fingers scroll the terminal, so drop the stroke the first finger started.
    func cancelStroke() {
        let recognizer = canvas.drawingGestureRecognizer
        guard recognizer.isEnabled else { return }
        recognizer.isEnabled = false
        recognizer.isEnabled = true
        live.end()
    }

    func tearDown() {
        resendTimer?.invalidate()
        resendTimer = nil
        live.end()
        canvas.delegate = nil
        canvas.removeFromSuperview()
        settleWaiters.forEach { $0.resume() }
        settleWaiters = []
    }

    // MARK: Page

    func pageLoaded() {
        let held = handoff.loaded(at: CACurrentMediaTime())
        if !held.isEmpty { Self.log.info("ink: page loaded, sending \(held.count) held stroke(s)") }
        post(held)
        convertNew()
    }

    func pageReloading() {
        handoff.reloading()
    }

    /// Drops the PencilKit strokes of elements the page drew, or once the Pencil lifts if it is down.
    func applied(ids: [String]) {
        let result = handoff.applied(ids, at: CACurrentMediaTime())
        for (id, latency) in result.latency {
            Self.log.info("ink: \(id, privacy: .public) drawn by the page \(String(format: "%.1f", latency * 1000), privacy: .public) ms after sending")
        }
        if result.drop.isEmpty, !result.latency.isEmpty {
            Self.log.info("ink: keeping \(result.latency.count) confirmed stroke(s) until the Pencil lifts")
        }
        drop(result.drop)
        if handoff.isSettled {
            settleWaiters.forEach { $0.resume() }
            settleWaiters = []
        }
    }

    /// Waits until every converted stroke is in the scene, up to `timeout`.
    func settle(timeout: Duration = .seconds(2)) async {
        convertNew()
        guard !handoff.isSettled else { return }
        Self.log.info("ink: waiting for \(self.handoff.pending.count) stroke(s) before placing")
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !self.settleWaiters.isEmpty else { return }
            Self.log.error("ink: \(self.handoff.pending.count) stroke(s) not confirmed by the page after \(String(describing: timeout), privacy: .public)")
            self.settleWaiters.forEach { $0.resume() }
            self.settleWaiters = []
        }
        await withCheckedContinuation { settleWaiters.append($0) }
        timer.cancel()
    }

    var hasStrokes: Bool { !canvas.drawing.strokes.isEmpty || !handoff.isSettled }

    private func post(_ ids: [String]) {
        let list = ids.compactMap { elements[$0] }
        guard !list.isEmpty else { return }
        overlay?.addInk(list)
    }

    private func resendOverdue() {
        let ids = handoff.overdue(at: CACurrentMediaTime(), timeout: 1.0)
        guard !ids.isEmpty else { return }
        Self.log.error("ink: resending \(ids.count) stroke(s) the page has not confirmed: \(ids.joined(separator: " "), privacy: .public)")
        post(ids)
    }

    private func drop(_ ids: [String]) {
        let keys = Set(ids.compactMap { strokes.removeValue(forKey: $0) })
        for id in ids { elements[id] = nil }
        guard !keys.isEmpty else { return }
        let all = canvas.drawing.strokes
        let remaining = all.filter { !keys.contains(StrokeKey($0)) }
        guard remaining.count != all.count else { return }
        settingDrawing = true
        canvas.drawing = PKDrawing(strokes: remaining)
        settingDrawing = false
        Self.log.info("ink: handed \(all.count - remaining.count) stroke(s) to the scene, \(remaining.count) still PencilKit's")
    }

    // MARK: Live ink

    private func sample(_ touch: UITouch, in view: UIView) {
        guard let overlay, let geometry = overlay.currentGeometry, let artifactId = overlay.artifactId else { return }
        let point = geometry.scene(fromView: touch.preciseLocation(in: view))
        let pressure = touch.maximumPossibleForce > 0 ? min(1, touch.force / touch.maximumPossibleForce * 1.5) : 0.5
        live.add(InkPoint(
            x: Float(point.x), y: Float(point.y), pressure: Float(max(pressure, 0.05)),
            altitude: Float(touch.altitudeAngle), azimuth: Float(touch.azimuthAngle(in: view)), tMs: 0),
            artifactId: artifactId, client: overlay.client)
    }

    // MARK: Commit

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        handoff.strokeBegan()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        let confirmed = handoff.strokeEnded()
        if !confirmed.isEmpty { drop(confirmed) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !settingDrawing else { return }
        convertNew()
    }

    /// Converts new PencilKit strokes once the overlay knows its geometry.
    func convertNew() {
        guard let overlay else { return }
        let fresh = canvas.drawing.strokes.filter { !known.contains(StrokeKey($0)) }
        guard !fresh.isEmpty else { return }
        guard let geometry = overlay.currentGeometry else {
            Self.log.info("ink: \(fresh.count) stroke(s) wait for the overlay's geometry")
            return
        }
        var send: [String] = []
        let now = CACurrentMediaTime()
        for stroke in fresh {
            let key = StrokeKey(stroke)
            known.insert(key)
            let id = "ink-" + UUID().uuidString.lowercased().prefix(20)
            let ink = InkStroke(stroke, geometry: geometry)
            guard let element = Freedraw.element(
                ink, id: String(id), seed: Int.random(in: 1..<Int(Int32.max)),
                versionNonce: Int.random(in: 1..<Int(Int32.max)), updatedMs: Int64(Date().timeIntervalSince1970 * 1000))
            else {
                Self.log.info("ink: stroke of \(stroke.path.count) point(s) too short for an element")
                continue
            }
            elements[String(id)] = element
            strokes[String(id)] = key
            let sentNow = handoff.converted(String(id), at: now)
            Self.log.info("ink: stroke \(String(id), privacy: .public) \(stroke.path.count) pts \(String(format: "%.0f", stroke.renderBounds.width), privacy: .public)×\(String(format: "%.0f", stroke.renderBounds.height), privacy: .public) pt → \(sentNow ? "sent" : "held until the page loads", privacy: .public)")
            if sentNow { send.append(String(id)) }
        }
        overlay.markEdited()
        post(send)
    }

    /// The Pencil stroke that opened draw mode, captured by the terminal before the overlay
    /// existed, in canvas points.
    func adopt(_ samples: [PencilSample]) {
        guard samples.count >= 2, let start = samples.first?.time else { return }
        let ink = (canvas.tool as? PKInkingTool)?.ink ?? PKInk(.pen, color: .label)
        let base = (canvas.tool as? PKInkingTool)?.width ?? 3
        let points = samples.map { sample in
            let width = base * (0.7 + 0.6 * min(1, sample.force))
            return PKStrokePoint(
                location: sample.location, timeOffset: sample.time - start, size: CGSize(width: width, height: width),
                opacity: 1, force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        settingDrawing = true
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])
        settingDrawing = false
        Self.log.info("ink: adopted the stroke that opened draw mode (\(samples.count) samples)")
        convertNew()
    }
}

/// Identity of a PencilKit stroke across `PKDrawing` copies.
struct StrokeKey: Hashable {
    let created: Date
    let seed: UInt32
    let count: Int

    init(_ stroke: PKStroke) {
        created = stroke.path.creationDate
        seed = stroke.randomSeed
        count = stroke.path.count
    }
}

/// A Pencil sample captured outside PencilKit, from the touch that opens draw mode.
struct PencilSample {
    var location: CGPoint
    var time: TimeInterval
    var force: CGFloat
    var altitude: CGFloat
    var azimuth: CGFloat

    init(_ touch: UITouch, in view: UIView) {
        location = touch.preciseLocation(in: view)
        time = touch.timestamp
        force = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0.5
        altitude = touch.altitudeAngle
        azimuth = touch.azimuthAngle(in: view)
    }
}

/// PencilKit's canvas. With Select it inks only the Pencil and lets fingers through to the
/// editor underneath. Telling them apart relies on the new touch being in `event.allTouches`
/// during hit-testing; when it is not, the touch goes to the editor, whose page turns a Pencil
/// stroke into freedraw anyway, so the Pencil still draws.
final class InkCanvas: PKCanvasView {
    var fingersPassThrough = false
    private var loggedHitTest = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if fingersPassThrough {
            let touches = event?.allTouches ?? []
            if touches.isEmpty, !loggedHitTest {
                loggedHitTest = true
                CanvasWebView.log.info("ink: hit-test saw no touches (Select): the editor takes this one")
            }
            guard touches.contains(where: { $0.type == .pencil && $0.phase == .began }) else { return nil }
        }
        return super.hitTest(point, with: event)
    }
}

/// Watches the touches PencilKit inks; never recognizes or cancels them.
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
        for coalesced in event.coalescedTouches(for: touch) ?? [touch] { onSample?(coalesced, view) }
    }

    override func canPrevent(_ gesture: UIGestureRecognizer) -> Bool { false }
}

/// Chunks of live points sent every ~16 ms.
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
