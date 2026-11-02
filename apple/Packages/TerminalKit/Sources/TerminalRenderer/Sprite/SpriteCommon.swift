import CoreGraphics

// Ported from Ghostty src/font/sprite/draw/common.zig (MIT).

/// Subtraction clamped at zero, Ghostty's `-|` on unsigned metrics.
@inline(__always) func sat(_ a: Int, _ b: Int) -> Int { max(0, a - b) }

/// Line weights, as multiples of the font's box thickness (its underline thickness).
enum Thickness {
    case superLight, light, heavy

    func px(_ base: Int) -> Int {
        switch self {
        case .superLight: max(base / 2, 1)
        case .light: base
        case .heavy: base * 2
        }
    }
}

/// Coverage values for shaded blocks.
enum Shade {
    static let off: UInt8 = 0x00
    static let light: UInt8 = 0x40
    static let medium: UInt8 = 0x80
    static let dark: UInt8 = 0xC0
    static let on: UInt8 = 0xFF
}

struct Quads: OptionSet {
    let rawValue: UInt8
    static let tl = Quads(rawValue: 1)
    static let tr = Quads(rawValue: 2)
    static let bl = Quads(rawValue: 4)
    static let br = Quads(rawValue: 8)
}

enum Corner { case tl, tr, bl, br }
enum Edge { case top, left, bottom, right }

/// Position of a figure within the cell.
struct Alignment {
    enum Horizontal { case left, right, center }
    enum Vertical { case top, bottom, middle }
    var horizontal: Horizontal = .center
    var vertical: Vertical = .middle

    static let upper = Alignment(vertical: .top)
    static let lower = Alignment(vertical: .bottom)
    static let left = Alignment(horizontal: .left)
    static let right = Alignment(horizontal: .right)
    static let center = Alignment()
    static let upperLeft = Alignment(horizontal: .left, vertical: .top)
    static let upperRight = Alignment(horizontal: .right, vertical: .top)
    static let lowerLeft = Alignment(horizontal: .left, vertical: .bottom)
    static let lowerRight = Alignment(horizontal: .right, vertical: .bottom)
    static let upperCenter = upper
    static let lowerCenter = lower
    static let middleLeft = left
    static let middleRight = right
    static let middleCenter = center
}

/// A fraction of the cell along one axis. `min`/`max` round so that adjacent blocks always share
/// an edge: `min` rounds from the far edge, `max` from the near one (so for a 7 px cell the halves
/// are 0–4 and 3–7... and never leave a gap).
struct Fraction {
    let value: Double

    static let zero = Fraction(value: 0)
    static let oneEighth = Fraction(value: 0.125)
    static let quarter = Fraction(value: 0.25)
    static let third = Fraction(value: 1.0 / 3.0)
    static let threeEighths = Fraction(value: 0.375)
    static let half = Fraction(value: 0.5)
    static let fiveEighths = Fraction(value: 0.625)
    static let twoThirds = Fraction(value: 2.0 / 3.0)
    static let threeQuarters = Fraction(value: 0.75)
    static let sevenEighths = Fraction(value: 0.875)
    static let one = Fraction(value: 1)

    static let eighths = (0...8).map { Fraction(value: Double($0) / 8) }
    static let quarters = (0...4).map { Fraction(value: Double($0) / 4) }

    func min(_ size: Int) -> Int {
        let s = Double(size)
        return Int(s - ((1 - value) * s).rounded())
    }

    func max(_ size: Int) -> Int {
        Int((value * Double(size)).rounded())
    }

    func float(_ size: Int) -> Double { value * Double(size) }
}

/// Fills the part of the cell between two horizontal and two vertical fractions.
func fill(_ metrics: CellMetrics, _ canvas: SpriteCanvas, _ x0: Fraction, _ x1: Fraction, _ y0: Fraction, _ y1: Fraction) {
    canvas.box(x0.min(metrics.cellWidth), y0.min(metrics.cellHeight), x1.max(metrics.cellWidth), y1.max(metrics.cellHeight), Shade.on)
}

func vlineMiddle(_ metrics: CellMetrics, _ canvas: SpriteCanvas, _ thickness: Thickness) {
    let t = thickness.px(metrics.boxThickness)
    vline(canvas, 0, metrics.cellHeight, sat(metrics.cellWidth, t) / 2, t)
}

func hlineMiddle(_ metrics: CellMetrics, _ canvas: SpriteCanvas, _ thickness: Thickness) {
    let t = thickness.px(metrics.boxThickness)
    hline(canvas, 0, metrics.cellWidth, sat(metrics.cellHeight, t) / 2, t)
}

/// Vertical line with its left edge at `x`, from `y1` to `y2`.
func vline(_ canvas: SpriteCanvas, _ y1: Int, _ y2: Int, _ x: Int, _ thickness: Int) {
    canvas.box(x, y1, x + thickness, y2, Shade.on)
}

/// Horizontal line with its top edge at `y`, from `x1` to `x2`.
func hline(_ canvas: SpriteCanvas, _ x1: Int, _ x2: Int, _ y: Int, _ thickness: Int) {
    canvas.box(x1, y, x2, y + thickness, Shade.on)
}

extension CGPoint {
    @inline(__always) init(_ x: Double, _ y: Double) { self.init(x: x, y: y) }
}
