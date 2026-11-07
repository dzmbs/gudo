import CoreGraphics

struct GridFit {
    let scale: CGFloat
    let origin: CGPoint

    static func fit(_ grid: CGSize, in viewport: CGSize, padding: CGFloat) -> Self {
        guard grid.width > 0, grid.height > 0, viewport.width > 0, viewport.height > 0 else {
            return Self(scale: 1, origin: .zero)
        }
        let scale = min(1, max(1, viewport.width - 2 * padding) / grid.width,
                        max(1, viewport.height - 2 * padding) / grid.height)
        return Self(scale: scale, origin: CGPoint(
            x: (viewport.width - grid.width * scale) / 2,
            y: (viewport.height - grid.height * scale) / 2))
    }
}
