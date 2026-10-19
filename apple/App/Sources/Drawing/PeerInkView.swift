import DrawingKit
import QuartzCore
import UnnamedCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Other people's live strokes (`ArtifactEvent.ink`) over a pane, in their presence colour,
/// following the drawing's anchor row; they fade once the stroke is committed to the scene.
final class PeerInkView: PlatformView {
    private struct Stroke {
        var artifactId: UInt64
        var points: [CGPoint] = []
        var pressure: [CGFloat] = []
        var geometry: () -> OverlayGeometry?
        var layer = CAShapeLayer()
        var finished = false
    }

    private var strokes: [String: Stroke] = [:]

    /// Presence hues are the terminal's ANSI hues (DesignSystem `PresenceAvatar`).
    static func color(for principal: String) -> CGColor {
        let hues: [(CGFloat, CGFloat, CGFloat)] = [
            (0x81, 0xA2, 0xBE), (0xB2, 0x94, 0xBB), (0x8A, 0xBE, 0xB7), (0xB5, 0xBD, 0x68), (0xF0, 0xC6, 0x74),
        ]
        let index = abs(principal.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % hues.count
        let h = hues[index]
        return CGColor(srgbRed: h.0 / 255, green: h.1 / 255, blue: h.2 / 255, alpha: 0.95)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        wantsLayer = true
        autoresizingMask = [.width, .height]
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var hostLayer: CALayer? { layer }
    #else
    private var hostLayer: CALayer? { layer }
    #endif

    func add(_ ink: InkLive, geometry: @escaping () -> OverlayGeometry?, color: CGColor) {
        let key = "\(ink.actor.device)/\(ink.strokeId)"
        var stroke = strokes[key] ?? {
            let stroke = Stroke(artifactId: ink.artifactId, geometry: geometry)
            stroke.layer.strokeColor = color
            stroke.layer.fillColor = nil
            stroke.layer.lineCap = .round
            stroke.layer.lineJoin = .round
            hostLayer?.addSublayer(stroke.layer)
            return stroke
        }()
        for point in (try? unpackInkPoints(packed: ink.points)) ?? [] {
            stroke.points.append(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            stroke.pressure.append(CGFloat(point.pressure))
        }
        stroke.finished = ink.done
        strokes[key] = stroke
        redraw(key)
    }

    /// The scene has the committed strokes now: fade the live ones.
    func finish(artifactId: UInt64) {
        for (key, stroke) in strokes where stroke.artifactId == artifactId && stroke.finished {
            let layer = stroke.layer
            CATransaction.begin()
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.25
            layer.opacity = 0
            layer.add(fade, forKey: "fade")
            CATransaction.commit()
            strokes[key] = nil
        }
    }

    func setNeedsRedraw() {
        guard !strokes.isEmpty else { return }
        for key in strokes.keys { redraw(key) }
    }

    private func redraw(_ key: String) {
        guard let stroke = strokes[key], let geometry = stroke.geometry() else { return }
        let path = CGMutablePath()
        for (i, p) in stroke.points.enumerated() {
            let v = geometry.view(fromScene: p)
            if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
        }
        let pressure = stroke.pressure.isEmpty ? 0.5 : stroke.pressure.reduce(0, +) / CGFloat(stroke.pressure.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.layer.frame = bounds
        stroke.layer.path = path
        stroke.layer.lineWidth = max(1.5, 4 * pressure * geometry.zoom * 1.6)
        CATransaction.commit()
    }
}
