import CoreGraphics

/// How the key bar's scrolling keys show that more wait past an edge: a key cut by it fades, a fling
/// comes to rest with a whole key at the leading edge (so a part of the next one shows at the
/// trailing edge), and the first few times the bar comes up the keys settle in from further along.
struct KeyStripScroll: Equatable {
    /// Times the bar settles its keys in before the user has scrolled them.
    static let hintLimit = 3

    var keyWidths: [CGFloat]
    var viewportWidth: CGFloat

    var contentWidth: CGFloat { keyWidths.reduce(0, +) }
    var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    var overflows: Bool { maximumOffset > 1 }

    /// A whole key shows fully; one cut by an edge fades the more of it is hidden. A key out of
    /// sight stays opaque (the strip clips it), so VoiceOver still reaches it.
    func opacity(ofKeyFrom minX: CGFloat, to maxX: CGFloat, at offset: CGFloat) -> CGFloat {
        let width = maxX - minX
        let shown = min(maxX, offset + viewportWidth) - max(minX, offset)
        guard width > 0, shown > 0 else { return 1 }
        let fraction = min(shown / width, 1)
        return fraction * fraction
    }

    /// The key edge nearest `proposed`, or the very end when the fling reaches it.
    func restingOffset(near proposed: CGFloat) -> CGFloat {
        guard overflows else { return 0 }
        if proposed >= maximumOffset - 1 { return maximumOffset }
        var edges: [CGFloat] = [0]
        for width in keyWidths { edges.append((edges.last ?? 0) + width) }
        let nearest = edges.min { abs($0 - proposed) < abs($1 - proposed) } ?? 0
        return min(max(0, nearest), maximumOffset)
    }

    /// Where the keys start when they settle in: about two keys along, on a key edge.
    var hintOffset: CGFloat {
        restingOffset(near: keyWidths.prefix(2).reduce(0, +))
    }

    func showsHint(hintsShown: Int, hasScrolled: Bool, reduceMotion: Bool) -> Bool {
        overflows && !hasScrolled && !reduceMotion && hintsShown < Self.hintLimit && hintOffset > 0
    }
}
