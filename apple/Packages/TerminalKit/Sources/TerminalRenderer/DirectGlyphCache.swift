/// A fixed-size direct-mapped cache of glyphs by packed key: each key hashes to one slot, and a
/// key that collides replaces the one there. A hit is a multiply, a shift and one compare, where
/// a dictionary hashes the whole key and probes.
struct DirectGlyphCache {
    private static let emptyKey = UInt64.max
    private var keys: [UInt64]
    private var glyphs: [RenderedGlyph?]
    private let shift: UInt64

    init(slotsLog2: Int = 12) {
        keys = .init(repeating: Self.emptyKey, count: 1 << slotsLog2)
        glyphs = .init(repeating: nil, count: 1 << slotsLog2)
        shift = UInt64(64 - slotsLog2)
    }

    static func key(codepoint: UInt32, style: FontStyle, span: Int, maxSpan: Int) -> UInt64 {
        UInt64(codepoint) | UInt64(style.rawValue) << 21 | UInt64(UInt8(clamping: span)) << 24
            | UInt64(UInt8(clamping: maxSpan)) << 32
    }

    /// The cached glyph (`.some(nil)` for "draws nothing"), or nil on a miss.
    func lookup(_ key: UInt64) -> RenderedGlyph?? {
        let slot = index(key)
        return keys[slot] == key ? .some(glyphs[slot]) : nil
    }

    mutating func insert(_ glyph: RenderedGlyph?, for key: UInt64) {
        let slot = index(key)
        keys[slot] = key
        glyphs[slot] = glyph
    }

    mutating func removeAll() {
        for slot in keys.indices { keys[slot] = Self.emptyKey }
    }

    private func index(_ key: UInt64) -> Int {
        // Fibonacci hashing: the top bits of key × 2^64/φ spread neighbouring codepoints apart.
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> shift)
    }
}
