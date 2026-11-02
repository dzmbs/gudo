#if canImport(PencilKit)
import CoreGraphics
import PencilKit

extension InkStroke {
    /// A PencilKit stroke in the overlay's scene px. `geometry` is in the coordinate space of
    /// the canvas the stroke was drawn on. The path is resampled every `step` view points along
    /// PencilKit's own interpolation (what it renders), widths carry the pen's pressure.
    ///
    /// Colors are kept as PencilKit stores them (the light-appearance color): PencilKit and
    /// Excalidraw both invert dark ink in dark mode, so the stroke looks the same in both.
    public init(_ stroke: PKStroke, geometry: OverlayGeometry, step: CGFloat = 1.5) {
        let transform = stroke.transform
        var samples: [InkSample] = []
        for point in stroke.path.interpolatedPoints(by: .distance(step)) {
            let scene = geometry.scene(fromView: point.location.applying(transform))
            let width = max(point.size.width, point.size.height) / geometry.zoom
            samples.append(InkSample(
                x: scene.x, y: scene.y, width: width, time: point.timeOffset,
                altitude: point.altitude, azimuth: point.azimuth))
        }
        let srgb = stroke.ink.color.cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let components = srgb?.components ?? [0, 0, 0, 1]
        let rgb = components.count >= 3
            ? (components[0], components[1], components[2])
            : (components[0], components[0], components[0])
        let alpha = components.last ?? 1
        let markerOpacity: CGFloat = stroke.ink.inkType == .marker ? 0.5 : 1
        self.init(samples: samples, color: Freedraw.hex(r: rgb.0, g: rgb.1, b: rgb.2), opacity: alpha * markerOpacity)
    }
}
#endif
