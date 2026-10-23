import Foundation
import SwiftUI

/// An opaque sRGB colour with the arithmetic the chrome is derived with: alpha blending, WCAG
/// contrast and CIEDE2000 distance. Plain values, so the derivation is testable without drawing.
nonisolated public struct ThemeColor: Hashable, Sendable, CustomStringConvertible {
    /// Channels in 0…1.
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    /// `#RRGGBB` or `RRGGBB`; nil for anything else.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255)
    }

    public static let white = ThemeColor(1, 1, 1)
    public static let black = ThemeColor(0, 0, 0)

    public var hex: String {
        func byte(_ c: Double) -> String { String(format: "%02x", Int((c * 255).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b)
    }

    public var description: String { hex }

    public var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// `self` with `top` laid over it at `alpha` (per channel `self·(1−a) + top·a`).
    public func blended(with top: ThemeColor, _ alpha: Double) -> ThemeColor {
        ThemeColor(r + (top.r - r) * alpha, g + (top.g - g) * alpha, b + (top.b - b) * alpha)
    }

    // MARK: Contrast (WCAG 2)

    /// Relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// The WCAG contrast ratio, 1…21.
    public func contrast(with other: ThemeColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: CIELAB

    /// CIELAB (D65).
    public var lab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        let y = (0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb) / 1.0
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// OKLab (Ottosson 2020): perceptual lightness and hue that hold while chroma changes,
    /// where CIELAB turns a desaturated blue purple.
    public var oklab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// From OKLab; out-of-gamut channels clamp.
    public init(oklab: (l: Double, a: Double, b: Double)) {
        let l = pow(oklab.l + 0.3963377774 * oklab.a + 0.2158037573 * oklab.b, 3)
        let m = pow(oklab.l - 0.1055613458 * oklab.a - 0.0638541728 * oklab.b, 3)
        let s = pow(oklab.l - 0.0894841775 * oklab.a - 1.2914855480 * oklab.b, 3)
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055 }
        self.init(
            gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// CIELAB chroma: 0 for greys, ~30+ for a clearly coloured hue.
    public var chroma: Double {
        let lab = lab
        return (lab.a * lab.a + lab.b * lab.b).squareRoot()
    }

    /// CIELAB hue angle in degrees, 0…360.
    public var hue: Double {
        let lab = lab
        let h = atan2(lab.b, lab.a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    /// CIEDE2000 colour difference (Sharma, Wu and Dalal 2005), with kL = kC = kH = 1.
    public static func deltaE2000(_ c1: ThemeColor, _ c2: ThemeColor) -> Double {
        let (l1, a1, b1) = c1.lab
        let (l2, a2, b2) = c2.lab
        let rad = Double.pi / 180
        let cBar = ((a1 * a1 + b1 * b1).squareRoot() + (a2 * a2 + b2 * b2).squareRoot()) / 2
        let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hueAngle(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let h1p = hueAngle(b1, a1p), h2p = hueAngle(b2, a2p)
        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * rad)
        let lBarp = (l1 + l2) / 2
        let cBarp = (c1p + c2p) / 2
        var hBarp = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) > 180 { hBarp += h1p + h2p < 360 ? 360 : -360 }
            hBarp /= 2
        }
        let t = 1 - 0.17 * cos((hBarp - 30) * rad) + 0.24 * cos(2 * hBarp * rad)
            + 0.32 * cos((3 * hBarp + 6) * rad) - 0.20 * cos((4 * hBarp - 63) * rad)
        let dTheta = 30 * exp(-pow((hBarp - 275) / 25, 2))
        let rc = 2 * (pow(cBarp, 7) / (pow(cBarp, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lBarp - 50, 2) / (20 + pow(lBarp - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cBarp
        let sh = 1 + 0.015 * cBarp * t
        let rt = -sin(2 * dTheta * rad) * rc
        let x = dLp / sl, y = dCp / sc, z = dHp / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }
}

nonisolated public extension TerminalTheme {
    var bgRGB: ThemeColor { ThemeColor(hex: bg) ?? .black }
    var fgRGB: ThemeColor { ThemeColor(hex: fg) ?? .white }
    var cursorRGB: ThemeColor? { cursor.flatMap(ThemeColor.init(hex:)) }
    func ansiRGB(_ index: Int) -> ThemeColor {
        palette.indices.contains(index) ? ThemeColor(hex: palette[index]) ?? .black : .black
    }
}
