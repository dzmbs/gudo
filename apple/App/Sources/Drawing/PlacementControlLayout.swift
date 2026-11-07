import CoreGraphics

struct PlacementControlLayout {
    let frame: CGRect
    let close: CGRect

    init(image: CGRect, viewport: CGRect, target: CGFloat) {
        let width = min(target, viewport.width), height = min(target, viewport.height)
        let button = CGRect(
            x: min(max(image.maxX - width, viewport.minX), viewport.maxX - width),
            y: min(max(image.minY, viewport.minY), viewport.maxY - height),
            width: width, height: height)
        frame = image.union(button)
        close = button.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}
