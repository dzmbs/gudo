import Testing
@testable import TerminalRenderer

struct DirectGlyphCacheTests {
    private func glyph(_ x: Int) -> RenderedGlyph {
        RenderedGlyph(atlas: .grayscale, region: .init(x: x, y: 0, width: 1, height: 1), offsetX: 0, offsetY: 0)
    }

    @Test func keysTellEveryFieldApart() {
        let base = DirectGlyphCache.key(codepoint: 0x2500, style: .regular, span: 1, maxSpan: 1)
        #expect(base != DirectGlyphCache.key(codepoint: 0x2501, style: .regular, span: 1, maxSpan: 1))
        #expect(base != DirectGlyphCache.key(codepoint: 0x2500, style: .bold, span: 1, maxSpan: 1))
        #expect(base != DirectGlyphCache.key(codepoint: 0x2500, style: .regular, span: 2, maxSpan: 1))
        #expect(base != DirectGlyphCache.key(codepoint: 0x2500, style: .regular, span: 1, maxSpan: 2))
        #expect(base != DirectGlyphCache.key(codepoint: 0x10FFFF, style: .boldItalic, span: 2, maxSpan: 2))
    }

    @Test func missesUntilInsertedAndRemembersDrawsNothing() {
        let cache = DirectGlyphCache(slotsLog2: 4)
        let key = DirectGlyphCache.key(codepoint: 0x4E00, style: .regular, span: 2, maxSpan: 2)
        #expect(cache.lookup(key) == nil)
        cache.insert(glyph(7), for: key)
        #expect(cache.lookup(key)??.region.x == 7)
        let blank = DirectGlyphCache.key(codepoint: 0x3000, style: .regular, span: 2, maxSpan: 2)
        cache.insert(nil, for: blank)
        let cached = cache.lookup(blank)
        #expect(cached != nil && cached! == nil)
        cache.removeAll()
        #expect(cache.lookup(key) == nil && cache.lookup(blank) == nil)
    }

    @Test func aCollidingKeyReplacesTheSlotAndNeverAnswersForAnother() {
        let cache = DirectGlyphCache(slotsLog2: 2)
        let keys = (UInt32(0x2500)..<0x2540).map { DirectGlyphCache.key(codepoint: $0, style: .regular, span: 1, maxSpan: 1) }
        for (i, key) in keys.enumerated() { cache.insert(glyph(i), for: key) }
        var hits = 0
        for (i, key) in keys.enumerated() {
            if let cached = cache.lookup(key) {
                #expect(cached?.region.x == i)
                hits += 1
            }
        }
        #expect(hits >= 1 && hits <= 4)
    }

    @Test func gridGlyphsMatchWithAndWithoutTheCache() {
        let fonts = FontGrid(pixelSize: 26)
        let codepoints: [(UInt32, Int)] = [(0x2500, 1), (0x3B1, 1), (0x4E00, 2), (0xE0B0, 1), (0x3000, 2)]
        let first = codepoints.map { fonts.glyph(codepoint: $0.0, style: .regular, span: $0.1)?.region }
        let again = codepoints.map { fonts.glyph(codepoint: $0.0, style: .regular, span: $0.1)?.region }
        let throughClusters = codepoints.map { fonts.glyph(for: [$0.0], style: .regular, span: $0.1)?.region }
        #expect(first == again)
        #expect(first == throughClusters)
        #expect(first[0] != nil && first[2] != nil)
    }
}
