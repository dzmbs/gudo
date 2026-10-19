import CoreGraphics
import Foundation

/// One sample of a pen stroke in scene px.
public struct InkSample: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    /// Stroke width at this point in scene px (PencilKit's `size`, which carries pressure).
    public var width: CGFloat
    /// Seconds since the stroke began.
    public var time: TimeInterval
    /// Pencil altitude and azimuth (radians), for live ink.
    public var altitude: CGFloat
    public var azimuth: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, time: TimeInterval = 0, altitude: CGFloat = .pi / 2, azimuth: CGFloat = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.time = time
        self.altitude = altitude
        self.azimuth = azimuth
    }
}

/// A finished pen stroke in scene px.
public struct InkStroke: Equatable, Sendable {
    public var samples: [InkSample]
    /// `#rrggbb`.
    public var color: String
    /// 0…1.
    public var opacity: CGFloat

    public init(samples: [InkSample], color: String, opacity: CGFloat = 1) {
        self.samples = samples
        self.color = color
        self.opacity = opacity
    }
}

/// PencilKit strokes → Excalidraw `freedraw` elements (the overlay's ink is part of its
/// Excalidraw scene, docs/DAEMON.md §7.11 step 3).
public enum Freedraw {
    /// Excalidraw draws a freedraw outline with perfect-freehand at `size = strokeWidth · 4.25`
    /// (its diameter at pressure 0.5).
    public static let outlineFactor: CGFloat = 4.25

    /// The element JSON (as a dictionary for `JSONSerialization`): points relative to the first
    /// sample, pressures from each sample's width relative to the stroke's median (0.5 = median),
    /// `simulatePressure` off. `id`, `seed` and `versionNonce` come from the caller so tests are
    /// deterministic.
    public static func element(
        _ stroke: InkStroke, id: String, seed: Int, versionNonce: Int, updatedMs: Int64
    ) -> [String: Any]? {
        let samples = dedupe(stroke.samples)
        guard let first = samples.first else { return nil }
        let points = samples.map { [Double($0.x - first.x), Double($0.y - first.y)] }
        let xs = points.map { $0[0] }, ys = points.map { $0[1] }
        let widths = samples.map(\.width).sorted()
        let median = max(widths[widths.count / 2], 0.01)
        let pressures = samples.map { Double(min(max($0.width / median * 0.5, 0.05), 1)) }
        let strokeWidth = max(Double(median / outlineFactor), 0.25)
        return [
            "id": id,
            "type": "freedraw",
            "x": Double(first.x),
            "y": Double(first.y),
            "width": (xs.max()! - xs.min()!),
            "height": (ys.max()! - ys.min()!),
            "angle": 0,
            "strokeColor": stroke.color,
            "backgroundColor": "transparent",
            "fillStyle": "solid",
            "strokeWidth": (strokeWidth * 100).rounded() / 100,
            "strokeStyle": "solid",
            "roughness": 0,
            "opacity": Int((stroke.opacity * 100).rounded()),
            "groupIds": [String](),
            "frameId": NSNull(),
            "roundness": NSNull(),
            "seed": seed,
            "version": 1,
            "versionNonce": versionNonce,
            "isDeleted": false,
            "boundElements": NSNull(),
            "updated": updatedMs,
            "link": NSNull(),
            "locked": false,
            "points": points,
            "pressures": pressures,
            "simulatePressure": false,
            "lastCommittedPoint": NSNull(),
        ]
    }

    /// A stroke as live-ink points (scene px, pressure 0…1, ms since the stroke began).
    public static func livePoints(_ samples: [InkSample], medianWidth: CGFloat) -> [(x: Float, y: Float, pressure: Float, altitude: Float, azimuth: Float, tMs: UInt32)] {
        let median = max(medianWidth, 0.01)
        return samples.map {
            (Float($0.x), Float($0.y), Float(min(max($0.width / median * 0.5, 0.05), 1)), Float($0.altitude), Float($0.azimuth),
             UInt32(max(0, $0.time * 1000)))
        }
    }

    /// Drops consecutive duplicates (perfect-freehand needs movement between points).
    static func dedupe(_ samples: [InkSample]) -> [InkSample] {
        var out: [InkSample] = []
        for s in samples {
            if let last = out.last, abs(last.x - s.x) < 0.01, abs(last.y - s.y) < 0.01 { continue }
            out.append(s)
        }
        return out
    }

    /// `#rrggbb` for an sRGB color.
    public static func hex(r: CGFloat, g: CGFloat, b: CGFloat) -> String {
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}
