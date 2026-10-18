import CoreGraphics

// Ported from Ghostty src/font/sprite/canvas.zig (MIT). Ghostty draws with z2d; paths here go
// through a CoreGraphics alpha-only context over the same buffer, rectangles are written directly.

/// An 8-bit coverage bitmap for one sprite glyph, with a quarter-cell margin on every side so
/// shapes may overshoot the cell (diagonals that meet across corners, low underlines).
///
/// Coordinates are cell-relative and y-down: (0, 0) is the top-left of the cell and
/// (`width`, `height`) its bottom-right, exactly as in Ghostty's sprite draw functions.
final class SpriteCanvas {
    /// The size of the cell (or cells, for a wide sprite) being drawn.
    let width: Int
    let height: Int
    let paddingX: Int
    let paddingY: Int
    /// Bitmap size including the margins.
    let bitmapWidth: Int
    let bitmapHeight: Int
    private(set) var pixels: [UInt8]

    /// Rows/columns excluded from the final glyph on each side (in bitmap pixels). Draw functions
    /// set these to the cell margins to discard anything drawn outside the cell; `trim()` then
    /// grows them over fully transparent edges.
    var clipLeft = 0, clipRight = 0, clipTop = 0, clipBottom = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        paddingX = width / 4
        paddingY = height / 4
        bitmapWidth = width + 2 * paddingX
        bitmapHeight = height + 2 * paddingY
        pixels = [UInt8](repeating: 0, count: bitmapWidth * bitmapHeight)
    }

    /// Restricts the glyph to the cell itself.
    func clipToCell() {
        clipLeft = paddingX
        clipRight = paddingX
        clipTop = paddingY
        clipBottom = paddingY
    }

    // MARK: Pixels and rectangles

    /// Coverage at a cell-relative pixel (0 outside the bitmap). For tests and diagnostics.
    func value(x: Int, y: Int) -> UInt8 {
        let bx = x + paddingX, by = y + paddingY
        guard bx >= 0, by >= 0, bx < bitmapWidth, by < bitmapHeight else { return 0 }
        return pixels[by * bitmapWidth + bx]
    }

    /// Sets one pixel (Ghostty's `putPixel`: the value replaces what was there).
    func pixel(_ x: Int, _ y: Int, _ value: UInt8) {
        let bx = x + paddingX, by = y + paddingY
        guard bx >= 0, by >= 0, bx < bitmapWidth, by < bitmapHeight else { return }
        pixels[by * bitmapWidth + bx] = value
    }

    /// Fills a rectangle with `value`, replacing what was there.
    func rect(x: Int, y: Int, width w: Int, height h: Int, _ value: UInt8 = 255) {
        let x0 = max(0, x + paddingX), x1 = min(bitmapWidth, x + w + paddingX)
        let y0 = max(0, y + paddingY), y1 = min(bitmapHeight, y + h + paddingY)
        guard x0 < x1, y0 < y1 else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in y0..<y1 {
                let start = row * bitmapWidth
                for col in x0..<x1 { buffer[start + col] = value }
            }
        }
    }

    /// Fills the rectangle between two corners in either order.
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8 = 255) {
        rect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0), value)
    }

    // MARK: Paths

    /// Runs `body` with a CoreGraphics context over the bitmap whose user space is the
    /// cell-relative, y-down coordinate system of the draw functions.
    func draw(_ body: (CGContext) -> Void) {
        let (w, h, px, py) = (bitmapWidth, bitmapHeight, paddingX, paddingY)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: CGFloat(px), y: CGFloat(py))
            body(context)
        }
    }

    func fill(_ path: CGPath, _ value: UInt8 = 255) {
        draw { context in
            context.setFillColor(gray: 1, alpha: CGFloat(value) / 255)
            context.addPath(path)
            context.fillPath()
        }
    }

    func stroke(_ path: CGPath, lineWidth: CGFloat, cap: CGLineCap = .butt, _ value: UInt8 = 255) {
        draw { context in
            context.setStrokeColor(gray: 1, alpha: CGFloat(value) / 255)
            context.setLineWidth(lineWidth)
            context.setLineCap(cap)
            context.addPath(path)
            context.strokePath()
        }
    }

    /// Ghostty's `innerStrokePath`: a stroke that lies entirely inside `region`. z2d offsets the
    /// path inwards by half the line width; clipping a double-width stroke to the region draws the
    /// same pixels.
    func innerStroke(_ path: CGPath, region: CGPath, lineWidth: CGFloat, _ value: UInt8 = 255) {
        draw { context in
            context.addPath(region)
            context.clip()
            context.setStrokeColor(gray: 1, alpha: CGFloat(value) / 255)
            context.setLineWidth(2 * lineWidth)
            context.setLineCap(.butt)
            context.addPath(path)
            context.strokePath()
        }
    }

    /// A straight line with butt caps.
    func line(_ p0: CGPoint, _ p1: CGPoint, thickness: CGFloat, _ value: UInt8 = 255) {
        let path = CGMutablePath()
        path.move(to: p0)
        path.addLine(to: p1)
        stroke(path, lineWidth: thickness, value)
    }

    func polygon(_ points: [CGPoint], _ value: UInt8 = 255) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        fill(path, value)
    }

    // MARK: Whole-canvas operations

    func invert() {
        for i in pixels.indices { pixels[i] = 255 - pixels[i] }
    }

    func flipHorizontal() {
        let clone = pixels
        for y in 0..<bitmapHeight {
            let row = y * bitmapWidth
            for x in 0..<bitmapWidth { pixels[row + x] = clone[row + bitmapWidth - x - 1] }
        }
        swap(&clipLeft, &clipRight)
    }

    func flipVertical() {
        let clone = pixels
        for y in 0..<bitmapHeight {
            let src = (bitmapHeight - y - 1) * bitmapWidth
            for x in 0..<bitmapWidth { pixels[y * bitmapWidth + x] = clone[src + x] }
        }
        swap(&clipTop, &clipBottom)
    }

    // MARK: Export

    /// Grows the clip over fully transparent edge rows and columns (Ghostty's `trim`).
    func trim() {
        let w = bitmapWidth, h = bitmapHeight
        func rowEmpty(_ y: Int) -> Bool {
            for x in clipLeft..<(w - clipRight) where pixels[y * w + x] != 0 { return false }
            return true
        }
        func columnEmpty(_ x: Int) -> Bool {
            for y in clipTop..<(h - clipBottom) where pixels[y * w + x] != 0 { return false }
            return true
        }
        while clipTop < h - clipBottom, clipLeft < w - clipRight, rowEmpty(clipTop) { clipTop += 1 }
        while clipBottom < h - clipTop, clipLeft < w - clipRight, rowEmpty(h - clipBottom - 1) { clipBottom += 1 }
        while clipLeft < w - clipRight, clipTop < h - clipBottom, columnEmpty(clipLeft) { clipLeft += 1 }
        while clipRight < w - clipLeft, clipTop < h - clipBottom, columnEmpty(w - clipRight - 1) { clipRight += 1 }
    }

    /// The trimmed glyph: its tightly packed pixels and Ghostty's bearings (`offsetX` from the
    /// left of the cell, `offsetY` from the bottom of the cell to the top of the bitmap). Nil
    /// when nothing was drawn.
    func export() -> (pixels: [UInt8], width: Int, height: Int, offsetX: Int, offsetY: Int)? {
        trim()
        let w = bitmapWidth - clipLeft - clipRight
        let h = bitmapHeight - clipTop - clipBottom
        guard w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = (row + clipTop) * bitmapWidth + clipLeft
            out.replaceSubrange(row * w..<(row + 1) * w, with: pixels[src..<(src + w)])
        }
        return (out, w, h, clipLeft - paddingX, h + clipBottom - paddingY)
    }
}
