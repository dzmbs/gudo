import CoreGraphics
import CoreText
import Foundation

/// Cell geometry in pixels, computed like Ghostty's `font/Metrics.zig` `calc`.
struct CellMetrics: Equatable {
    var cellWidth: Int
    var cellHeight: Int
    /// Distance from the bottom of the cell to the baseline.
    var cellBaseline: Int
    /// From the top of the cell.
    var underlinePosition: Int
    var underlineThickness: Int
    /// From the top of the cell.
    var strikethroughPosition: Int
    var strikethroughThickness: Int
    var cursorThickness: Int
    /// Unrounded advance of the primary face; glyphs are centred on the rounded cell width.
    var faceWidth: Double
}

/// A glyph placed in one of the atlases, with Ghostty's bearing conventions: `offsetX` from the
/// left of the cell, `offsetY` from the bottom of the cell to the top of the bitmap.
struct RenderedGlyph {
    var atlas: CellText.Atlas
    var region: Atlas.Region
    var offsetX: Int
    var offsetY: Int
}

enum FontStyle: Int, CaseIterable {
    case regular, bold, italic, boldItalic

    init(bold: Bool, italic: Bool) {
        self = switch (bold, italic) {
        case (false, false): .regular
        case (true, false): .bold
        case (false, true): .italic
        case (true, true): .boldItalic
        }
    }
}

/// Procedurally drawn glyphs (Ghostty's `font/sprite`): cursor shapes and text decorations.
enum Sprite: Hashable {
    case cursorRect, cursorHollowRect, cursorBar, cursorUnderline, underline, strikethrough
}

/// Fonts, cell metrics, glyph rasterization and the two glyph atlases.
///
/// Mirrors Ghostty's CoreText backend (`font/face/coretext.zig`): bundled JetBrains Mono
/// (Nerd Font build) for the four styles, per-codepoint CoreText fallback (Apple Color Emoji for
/// emoji), grayscale coverage in linear gray, color glyphs in Display P3. Shaping is 1 cell ->
/// 1 glyph; grapheme clusters are shaped as a unit with CTLine.
final class FontGrid {
    let metrics: CellMetrics
    /// Written by rasterization; the renderer drains their pending uploads each frame.
    var grayscale = Atlas(format: .grayscale)
    var color = Atlas(format: .color)

    private var faces: [CTFont]
    private var faceIndexByName: [String: Int] = [:]
    private var resolved: [ResolveKey: (face: Int, glyph: CGGlyph)?] = [:]
    private var glyphs: [GlyphKey: RenderedGlyph?] = [:]
    private var sprites: [SpriteKey: RenderedGlyph] = [:]

    private struct ResolveKey: Hashable {
        var text: String
        var style: FontStyle
    }

    private struct GlyphKey: Hashable {
        var face: Int
        var glyph: CGGlyph
        var span: Int
    }

    private struct SpriteKey: Hashable {
        var sprite: Sprite
        var span: Int
    }

    private static let fontFiles: [FontStyle: String] = [
        .regular: "JetBrainsMonoNerdFont-Regular",
        .bold: "JetBrainsMonoNerdFont-Bold",
        .italic: "JetBrainsMonoNerdFont-Italic",
        .boldItalic: "JetBrainsMonoNerdFont-BoldItalic",
    ]

    /// - Parameter pixelSize: font size in device pixels (points x display scale).
    init(pixelSize: CGFloat) {
        faces = FontStyle.allCases.map { style in
            guard let url = Bundle.module.url(forResource: Self.fontFiles[style], withExtension: "ttf", subdirectory: "Fonts"),
                  let data = try? Data(contentsOf: url),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
                  let descriptor = descriptors.first
            else { fatalError("missing bundled font \(style)") }
            return CTFontCreateWithFontDescriptor(descriptor, pixelSize, nil)
        }
        for (i, face) in faces.enumerated() {
            faceIndexByName[CTFontCopyPostScriptName(face) as String] = i
        }
        metrics = Self.computeMetrics(faces[FontStyle.regular.rawValue])
    }

    // MARK: Glyph lookup

    /// The glyph for a cell's grapheme cluster, or nil when it draws nothing (space, missing).
    /// - Parameter span: number of cells the character occupies (2 for wide characters).
    func glyph(for scalars: [UInt32], style: FontStyle, span: Int) -> RenderedGlyph? {
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars.compactMap(Unicode.Scalar.init))
        let key = ResolveKey(text: text, style: style)
        let hit: (face: Int, glyph: CGGlyph)?
        if let cached = resolved[key] {
            hit = cached
        } else {
            hit = resolve(text, style: style)
            resolved[key] = hit
        }
        guard let hit else { return nil }
        let glyphKey = GlyphKey(face: hit.face, glyph: hit.glyph, span: span)
        if let cached = glyphs[glyphKey] { return cached }
        let rendered = render(glyph: hit.glyph, face: faces[hit.face], span: span)
        glyphs[glyphKey] = rendered
        return rendered
    }

    func sprite(_ sprite: Sprite, span: Int) -> RenderedGlyph {
        let key = SpriteKey(sprite: sprite, span: span)
        if let cached = sprites[key] { return cached }
        let rendered = renderSprite(sprite, span: span)
        sprites[key] = rendered
        return rendered
    }

    private func resolve(_ text: String, style: FontStyle) -> (face: Int, glyph: CGGlyph)? {
        let utf16 = Array(text.utf16)
        let primary = faces[style.rawValue]
        if utf16.count == 1 || (utf16.count == 2 && text.unicodeScalars.count == 1),
           let glyph = glyphInFace(primary, utf16)
        {
            return (style.rawValue, glyph)
        }

        // Fallback (emoji, CJK, symbols) and multi-codepoint clusters: let CoreText pick the face
        // and shape the cluster, then take its first glyph.
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: primary] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0 else { return nil }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName] as! CTFont
        guard glyph != 0 else { return nil }
        return (faceIndex(for: runFont), glyph)
    }

    private func glyphInFace(_ face: CTFont, _ utf16: [UInt16]) -> CGGlyph? {
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(face, utf16, &glyphs, utf16.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    private func faceIndex(for font: CTFont) -> Int {
        let name = CTFontCopyPostScriptName(font) as String
        if let index = faceIndexByName[name] { return index }
        // Fallback faces come back at the requested size already.
        faces.append(font)
        faceIndexByName[name] = faces.count - 1
        return faces.count - 1
    }

    // MARK: Rasterization

    private func render(glyph: CGGlyph, face: CTFont, span: Int) -> RenderedGlyph? {
        var cgGlyph = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(face, .horizontal, &cgGlyph, nil, 1)
        guard rect.width >= 0.25, rect.height >= 0.25 else { return nil }

        let isColor = CTFontGetSymbolicTraits(face).contains(.traitColorGlyphs)
        let cellWidth = Double(metrics.cellWidth)
        var x = rect.origin.x
        var y = rect.origin.y + Double(metrics.cellBaseline)
        var width = rect.width
        var height = rect.height

        if isColor {
            // Ghostty constrains emoji to fit their cells; scale down to the available box and
            // centre it.
            let boxWidth = cellWidth * Double(span)
            let boxHeight = Double(metrics.cellHeight)
            let scale = min(1, boxWidth / width, boxHeight / height)
            width *= scale
            height *= scale
            x = ((boxWidth - width) / 2).rounded()
            y = ((boxHeight - height) / 2).rounded()
            width = width.rounded()
            height = height.rounded()
        } else {
            // Centre the face's advance within the rounded cell width (coretext.zig).
            let dx = (cellWidth - metrics.faceWidth) / 2
            x += dx
            if dx < 0 { x -= dx.rounded(.towardZero) }
        }

        let pxX = Int(x.rounded(.down))
        let pxY = Int(y.rounded(.down))
        let fracX = x - x.rounded(.down)
        let fracY = y - y.rounded(.down)
        let pxWidth = Int((width + fracX).rounded(.up))
        let pxHeight = Int((height + fracY).rounded(.up))
        let depth = isColor ? 4 : 1

        var buffer = [UInt8](repeating: 0, count: pxWidth * pxHeight * depth)
        let drawn: Bool = buffer.withUnsafeMutableBytes { bytes in
            let context: CGContext? = isColor
                ? CGContext(
                    data: bytes.baseAddress, width: pxWidth, height: pxHeight, bitsPerComponent: 8,
                    bytesPerRow: pxWidth * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
                : CGContext(
                    data: bytes.baseAddress, width: pxWidth, height: pxHeight, bitsPerComponent: 8,
                    bytesPerRow: pxWidth, space: CGColorSpace(name: CGColorSpace.linearGray)!,
                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            guard let context else { return false }
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            if isColor {
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            } else {
                context.setFillColor(gray: 1, alpha: 1)
            }
            context.translateBy(x: fracX, y: fracY)
            context.scaleBy(x: width / rect.width, y: height / rect.height)
            var position = CGPoint(x: -rect.origin.x, y: -rect.origin.y)
            CTFontDrawGlyphs(face, &cgGlyph, &position, 1, context)
            return true
        }
        guard drawn else { return nil }

        let region = buffer.withUnsafeBytes { bytes in
            isColor
                ? color.insert(width: pxWidth, height: pxHeight, data: bytes)
                : grayscale.insert(width: pxWidth, height: pxHeight, data: bytes)
        }
        return RenderedGlyph(
            atlas: isColor ? .color : .grayscale,
            region: region,
            offsetX: pxX,
            offsetY: pxY + pxHeight
        )
    }

    /// Draws a sprite as filled rectangles into a coverage bitmap, like Ghostty's sprite canvas.
    private func renderSprite(_ sprite: Sprite, span: Int) -> RenderedGlyph {
        let m = metrics
        let width = m.cellWidth * span
        let height = m.cellHeight
        let underlineY = min(m.underlinePosition, height - m.underlineThickness)

        // Rectangles in cell coordinates (y down from the top of the cell); the bitmap is cropped
        // to their bounding box so decorations stay tiny in the atlas.
        let rects: [(x: Int, y: Int, w: Int, h: Int, on: Bool)] = switch sprite {
        case .cursorRect:
            [(0, 0, width, height, true)]
        case .cursorHollowRect:
            [(0, 0, width, height, true),
             (m.cursorThickness, m.cursorThickness, width - 2 * m.cursorThickness, height - 2 * m.cursorThickness, false)]
        case .cursorBar:
            [(-((m.cursorThickness + 1) / 2), 0, m.cursorThickness, height, true)]
        case .cursorUnderline:
            [(0, underlineY, width, m.cursorThickness, true)]
        case .underline:
            [(0, underlineY, width, m.underlineThickness, true)]
        case .strikethrough:
            [(0, m.strikethroughPosition, width, m.strikethroughThickness, true)]
        }

        let minX = rects.map(\.x).min()!, minY = rects.map(\.y).min()!
        let maxX = rects.map { $0.x + $0.w }.max()!, maxY = rects.map { $0.y + $0.h }.max()!
        let bw = maxX - minX, bh = maxY - minY
        var bitmap = [UInt8](repeating: 0, count: bw * bh)
        for r in rects {
            for row in (r.y - minY)..<(r.y - minY + r.h) {
                for col in (r.x - minX)..<(r.x - minX + r.w) {
                    bitmap[row * bw + col] = r.on ? 255 : 0
                }
            }
        }
        let region = bitmap.withUnsafeBytes { grayscale.insert(width: bw, height: bh, data: $0) }
        return RenderedGlyph(atlas: .grayscale, region: region, offsetX: minX, offsetY: height - minY)
    }

    // MARK: Metrics

    private static func computeMetrics(_ font: CTFont) -> CellMetrics {
        // Advance: the widest printable ASCII glyph (all equal in a monospace face).
        let ascii = (32..<127).map { UInt16($0) }
        var glyphs = [CGGlyph](repeating: 0, count: ascii.count)
        CTFontGetGlyphsForCharacters(font, ascii, &glyphs, ascii.count)
        var advances = [CGSize](repeating: .zero, count: ascii.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, ascii.count)
        let faceWidth = advances.map(\.width).max() ?? 0

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineGap = CTFontGetLeading(font)
        let faceHeight = ascent + descent + lineGap

        let cellWidth = faceWidth.rounded()
        let cellHeight = faceHeight.rounded()
        let faceBaseline = lineGap / 2 + descent
        let cellBaseline = (faceBaseline - (cellHeight - faceHeight) / 2).rounded()
        let topToBaseline = cellHeight - cellBaseline

        let underlineThickness = max(1, CTFontGetUnderlineThickness(font).rounded(.up))
        let underlinePosition = (topToBaseline - CTFontGetUnderlinePosition(font)).rounded()
        let (strikePosition, strikeSize) = strikeout(font) ?? (CTFontGetXHeight(font) / 2, underlineThickness)
        let strikethroughThickness = max(1, strikeSize.rounded(.up))
        let strikethroughPosition = (topToBaseline - strikePosition).rounded()

        return CellMetrics(
            cellWidth: Int(cellWidth),
            cellHeight: Int(cellHeight),
            cellBaseline: Int(cellBaseline),
            underlinePosition: Int(underlinePosition),
            underlineThickness: Int(underlineThickness),
            strikethroughPosition: Int(strikethroughPosition),
            strikethroughThickness: Int(strikethroughThickness),
            cursorThickness: 1,
            faceWidth: faceWidth
        )
    }

    /// `yStrikeoutPosition` and `yStrikeoutSize` from the OS/2 table, in pixels.
    private static func strikeout(_ font: CTFont) -> (position: CGFloat, size: CGFloat)? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 30 else {
            return nil
        }
        func int16(_ offset: Int) -> CGFloat {
            CGFloat(Int16(bitPattern: UInt16(table[offset]) << 8 | UInt16(table[offset + 1])))
        }
        let scale = CTFontGetSize(font) / CGFloat(CTFontGetUnitsPerEm(font))
        let size = int16(26), position = int16(28)
        guard size > 0 else { return nil }
        return (position * scale, size * scale)
    }
}
