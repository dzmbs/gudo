import CoreGraphics
import CoreText
import Foundation
import Metal

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
    /// From the top of the cell (Ghostty: 0).
    var overlinePosition = 0
    var overlineThickness = 1
    /// Base line thickness for box drawing and other sprites (the underline thickness).
    var boxThickness = 1
    var cursorThickness: Int
    /// Unrounded advance of the primary face; glyphs are centred on the rounded cell width.
    var faceWidth: Double
    /// Unrounded line height of the primary face.
    var faceHeight: Double = 0
    /// Offset from the bottom of the cell to the bottom of the face's line box.
    var faceY: Double = 0
    /// Nerd Font icon heights for multi-cell and single-cell constraints.
    var iconHeight: Double = 0
    var iconHeightSingle: Double = 0

    var constraintMetrics: NerdFontConstraint.Metrics {
        .init(
            cellWidth: Double(cellWidth), cellHeight: Double(cellHeight), faceWidth: faceWidth,
            faceHeight: faceHeight, faceY: faceY, iconHeight: iconHeight, iconHeightSingle: iconHeightSingle)
    }
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

/// Fonts, cell metrics, glyph rasterization and the two glyph atlases.
///
/// Mirrors Ghostty's CoreText backend (`font/face/coretext.zig`): a primary family for the four
/// styles (bundled JetBrains Mono Nerd Font by default), per-codepoint CoreText fallback (Apple
/// Color Emoji, CJK faces), grayscale coverage in linear gray, color glyphs in Display P3, the
/// sprite face for box drawing and friends, and Ghostty's glyph constraints (Nerd Font icons,
/// symbols, emoji). Shaping is 1 cell -> 1 glyph; grapheme clusters are shaped as a unit with CTLine.
final class FontGrid {
    let metrics: CellMetrics
    /// Written by rasterization; the renderer drains their pending uploads each frame.
    var grayscale = Atlas(format: .grayscale)
    var color = Atlas(format: .color)
    /// The atlases on the GPU, kept current by the renderer before each frame.
    var grayscaleTexture: MTLTexture?
    var colorTexture: MTLTexture?

    private var faces: [CTFont]
    private var faceIndexByName: [String: Int] = [:]
    private var resolved: [ResolveKey: (face: Int, glyph: CGGlyph)?] = [:]
    private var glyphs: [GlyphKey: RenderedGlyph?] = [:]
    private var spriteGlyphs: [SpriteGlyphKey: RenderedGlyph?] = [:]
    private var sprites: [SpriteKey: RenderedGlyph] = [:]

    private struct ResolveKey: Hashable {
        var text: String
        var style: FontStyle
    }

    private struct GlyphKey: Hashable {
        var face: Int
        var glyph: CGGlyph
        var span: Int
        /// Cells the glyph may grow into and the constraint applied (both shape the bitmap).
        var constraintWidth: Int
        var codepoint: UInt32
    }

    private struct SpriteGlyphKey: Hashable {
        var codepoint: UInt32
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

    private struct WeakGrid {
        weak var grid: FontGrid?
    }

    /// Grids in use by font and pixel size.
    @MainActor private static var live: [String: WeakGrid] = [:]

    /// The grid for a font and size, shared by every surface that uses them: glyphs are
    /// rasterized, packed and uploaded once instead of once per pane. Freed with its last user.
    @MainActor static func shared(pixelSize: CGFloat, family: String? = nil) -> FontGrid {
        let key = "\(family ?? "")|\(pixelSize)"
        if let grid = live[key]?.grid { return grid }
        live = live.filter { $0.value.grid != nil }
        let grid = FontGrid(pixelSize: pixelSize, family: family)
        live[key] = WeakGrid(grid: grid)
        return grid
    }

    /// - Parameters:
    ///   - pixelSize: font size in device pixels (points x display scale).
    ///   - family: a font family installed on the system, or nil for the bundled JetBrains Mono
    ///     Nerd Font. An unknown family falls back to the bundled font.
    init(pixelSize: CGFloat, family: String? = nil) {
        faces = family.flatMap { Self.systemFaces(family: $0, pixelSize: pixelSize) } ?? Self.bundledFaces(pixelSize: pixelSize)
        for (i, face) in faces.enumerated() {
            faceIndexByName[CTFontCopyPostScriptName(face) as String] = i
        }
        metrics = Self.computeMetrics(faces[FontStyle.regular.rawValue])
    }

    /// The bundled faces' descriptors, read from disk once: every new font size creates its
    /// own grid, and reading and parsing four font files each time stalled it.
    /// Immutable once made; CoreText descriptors are thread-safe.
    nonisolated(unsafe) private static let bundledDescriptors: [CTFontDescriptor] = FontStyle.allCases.map { style in
        guard let url = Bundle.module.url(forResource: fontFiles[style], withExtension: "ttf", subdirectory: "Fonts"),
              let data = try? Data(contentsOf: url),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first
        else { fatalError("missing bundled font \(style)") }
        return descriptor
    }

    private static func bundledFaces(pixelSize: CGFloat) -> [CTFont] {
        bundledDescriptors.map { CTFontCreateWithFontDescriptor($0, pixelSize, nil) }
    }

    /// The four styles of an installed family, or nil if CoreText does not know it (it would
    /// otherwise silently substitute another family).
    private static func systemFaces(family: String, pixelSize: CGFloat) -> [CTFont]? {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let regular = CTFontCreateWithFontDescriptor(descriptor, pixelSize, nil)
        guard (CTFontCopyFamilyName(regular) as String).caseInsensitiveCompare(family) == .orderedSame else { return nil }
        func styled(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, traits, traits) ?? regular
        }
        return [regular, styled(.traitBold), styled(.traitItalic), styled([.traitBold, .traitItalic])]
    }

    // MARK: Glyph lookup

    /// The glyph for a cell's grapheme cluster, or nil when it draws nothing (space, missing).
    /// - Parameters:
    ///   - span: number of cells the character occupies (2 for wide characters).
    ///   - maxSpan: cells a narrow symbol may grow into (Ghostty's constraint width; 2 when the
    ///     next cell is blank, see `NerdFontConstraint.constraintWidth`). Ignored for anything
    ///     that is not a symbol; nil means `span`.
    func glyph(for scalars: [UInt32], style: FontStyle, span: Int, maxSpan: Int? = nil) -> RenderedGlyph? {
        guard let base = scalars.first else { return nil }
        // Hot path: one codepoint, already resolved and rasterized (no String key to build).
        let fastKey = scalars.count == 1
            ? FastKey(codepoint: base, style: style, span: span, maxSpan: maxSpan ?? 1) : nil
        if let fastKey, let cached = fastGlyphs[fastKey] { return cached }
        let result = slowGlyph(for: scalars, base: base, style: style, span: span, maxSpan: maxSpan)
        if let fastKey { fastGlyphs[fastKey] = result }
        return result
    }

    private struct FastKey: Hashable {
        var codepoint: UInt32
        var style: FontStyle
        var span: Int
        var maxSpan: Int
    }

    private var fastGlyphs: [FastKey: RenderedGlyph?] = [:]

    private func slowGlyph(for scalars: [UInt32], base: UInt32, style: FontStyle, span: Int, maxSpan: Int?) -> RenderedGlyph? {
        if scalars.count == 1, SpriteFace.covers(base) {
            return spriteGlyph(base, span: span)
        }

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

        let constraintWidth = span >= 2 ? span : NerdFontConstraint.isSymbol(base) ? max(1, min(2, maxSpan ?? 1)) : 1
        let glyphKey = GlyphKey(face: hit.face, glyph: hit.glyph, span: span, constraintWidth: constraintWidth, codepoint: base)
        if let cached = glyphs[glyphKey] { return cached }
        let rendered = render(
            glyph: hit.glyph, face: faces[hit.face], isFallback: hit.face >= FontStyle.allCases.count,
            codepoint: base, constraintWidth: constraintWidth)
        glyphs[glyphKey] = rendered
        return rendered
    }

    func sprite(_ sprite: Sprite, span: Int) -> RenderedGlyph {
        let key = SpriteKey(sprite: sprite, span: span)
        if let cached = sprites[key] { return cached }
        // Decoration sprites always draw something.
        let rendered = place(SpriteFace.render(sprite, metrics: metrics, span: span))!
        sprites[key] = rendered
        return rendered
    }

    private func spriteGlyph(_ cp: UInt32, span: Int) -> RenderedGlyph? {
        let key = SpriteGlyphKey(codepoint: cp, span: span)
        if let cached = spriteGlyphs[key] { return cached }
        let rendered = SpriteFace.render(cp, metrics: metrics, span: span).flatMap(place)
        spriteGlyphs[key] = rendered
        return rendered
    }

    /// Copies a drawn sprite into the grayscale atlas.
    private func place(_ canvas: SpriteCanvas) -> RenderedGlyph? {
        guard let bitmap = canvas.export() else { return nil }
        let region = bitmap.pixels.withUnsafeBytes { grayscale.insert(width: bitmap.width, height: bitmap.height, data: $0) }
        return RenderedGlyph(atlas: .grayscale, region: region, offsetX: bitmap.offsetX, offsetY: bitmap.offsetY)
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

    /// Rasterizes a font glyph like Ghostty's `coretext.zig` `renderGlyph`: constrain the bounding
    /// box (Nerd Font rules, symbols, emoji), centre on the rounded cell, keep the subpixel
    /// position in the bitmap.
    private func render(glyph: CGGlyph, face: CTFont, isFallback: Bool, codepoint: UInt32, constraintWidth: Int) -> RenderedGlyph? {
        var cgGlyph = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(face, .horizontal, &cgGlyph, nil, 1)
        guard rect.width >= 0.25, rect.height >= 0.25 else { return nil }

        let isColor = CTFontGetSymbolicTraits(face).contains(.traitColorGlyphs)
        var constraint = isColor ? NerdFontConstraint.emoji : NerdFontConstraint.forCodepoint(codepoint)
        // Fallback text faces (CJK, other scripts) are sized for their own metrics; make sure an
        // oversized one at least fits its cells instead of spilling into the neighbours.
        if !constraint.doesAnything, isFallback { constraint = .symbol }

        let cellWidth = Double(metrics.cellWidth)
        let cellHeight = Double(metrics.cellHeight)
        let box = constraint.constrain(
            GlyphBox(width: rect.width, height: rect.height, x: rect.origin.x, y: rect.origin.y + Double(metrics.cellBaseline)),
            metrics: metrics.constraintMetrics, constraintWidth: constraintWidth)
        var x = box.x, y = box.y, width = box.width, height = box.height

        if constraint.size != .stretch {
            // Centre the face's advance within the rounded cell width.
            let dx = (cellWidth - metrics.faceWidth) / 2
            x += dx
            if dx < 0 { x -= dx.rounded(.towardZero) }
        }
        if isColor {
            // Bitmap (sbix) glyphs render in whole pixels; quantize to avoid blur.
            width = cellWidth * Double(constraintWidth) - (cellWidth * Double(constraintWidth) - width - x).rounded() - x.rounded()
            height = cellHeight - (cellHeight - height - y).rounded() - y.rounded()
            x = x.rounded()
            y = y.rounded()
        }

        let pxX = Int(x.rounded(.down))
        let pxY = Int(y.rounded(.down))
        let fracX = x - x.rounded(.down)
        let fracY = y - y.rounded(.down)
        let pxWidth = Int((width + fracX).rounded(.up))
        let pxHeight = Int((height + fracY).rounded(.up))
        guard pxWidth > 0, pxHeight > 0 else { return nil }
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

    // MARK: Metrics

    static func computeMetrics(_ font: CTFont) -> CellMetrics {
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
        let capHeight = CTFontGetCapHeight(font)

        return CellMetrics(
            cellWidth: Int(cellWidth),
            cellHeight: Int(cellHeight),
            cellBaseline: Int(cellBaseline),
            underlinePosition: Int(underlinePosition),
            underlineThickness: Int(underlineThickness),
            strikethroughPosition: Int(strikethroughPosition),
            strikethroughThickness: Int(strikethroughThickness),
            overlinePosition: 0,
            overlineThickness: Int(underlineThickness),
            boxThickness: Int(underlineThickness),
            cursorThickness: 1,
            faceWidth: faceWidth,
            faceHeight: faceHeight,
            faceY: cellBaseline - faceBaseline,
            iconHeight: faceHeight,
            iconHeightSingle: (2 * capHeight + faceHeight) / 3
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
