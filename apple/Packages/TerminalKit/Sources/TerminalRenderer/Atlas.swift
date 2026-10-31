/// A square glyph texture packed with a skyline bottom-left bin packer.
///
/// Port of Ghostty's `src/font/Atlas.zig` (itself after Jukka Jylänki's "A Thousand Ways to Pack
/// the Bin" and freetype-gl): same 1px border, best-fit node choice, node shrinking and merging,
/// and grow-by-doubling. Unlike Ghostty, which re-uploads the whole texture whenever it changes,
/// this records the regions written since the last sync so the GPU copy uploads only those.
/// Growth stops at `maxSize`: a full atlas returns nil and its owner starts over (`reset`).
struct Atlas {
    struct Region: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    enum Format {
        /// One byte of coverage per pixel (`r8Unorm`).
        case grayscale
        /// Premultiplied BGRA, Display P3 (`bgra8Unorm_srgb`).
        case color

        var depth: Int { self == .grayscale ? 1 : 4 }
    }

    private struct Node {
        var x: Int
        var y: Int
        var width: Int
    }

    let format: Format
    /// Largest edge the atlas grows to. Doubling on would soon pass Metal's 16384 texture limit
    /// and cost hundreds of MB; a whole 6K screen of distinct glyphs fits in this.
    let maxSize: Int
    private let initialSize: Int
    private(set) var size: Int
    private(set) var pixels: [UInt8]
    /// Bumped on every write or grow; lets each GPU texture know whether it is stale.
    private(set) var generation = 0
    /// Regions written since the last `takePendingUploads()`, or nil after a grow (upload all).
    private var pendingRegions: [Region]? = []
    private var nodes: [Node]

    init(format: Format, size: Int = 512, maxSize: Int? = nil) {
        self.format = format
        self.size = size
        initialSize = size
        self.maxSize = max(size, maxSize ?? (format == .grayscale ? 8192 : 4096))
        pixels = [UInt8](repeating: 0, count: size * size * format.depth)
        // Keep a 1px border so linear sampling never bleeds between neighbours.
        nodes = [Node(x: 1, y: 1, width: size - 2)]
    }

    /// Reserves space and copies `data` (tightly packed rows) into it, growing the atlas if
    /// needed; nil when it is full at `maxSize`.
    mutating func insert(width: Int, height: Int, data: UnsafeRawBufferPointer) -> Region? {
        while true {
            if let region = reserve(width: width, height: height) {
                set(region, data: data)
                return region
            }
            guard size * 2 <= maxSize else { return nil }
            grow()
        }
    }

    /// Empties the atlas back to its initial size; every region handed out so far is void.
    mutating func reset() {
        self = Atlas(format: format, size: initialSize, maxSize: maxSize)
    }

    /// Returns the regions to upload since the last call; nil means the whole texture.
    mutating func takePendingUploads() -> [Region]? {
        defer { pendingRegions = [] }
        return pendingRegions
    }

    private mutating func reserve(width: Int, height: Int) -> Region? {
        var bestHeight = Int.max
        var bestWidth = Int.max
        var bestIndex: Int?
        var region = Region(x: 0, y: 0, width: width, height: height)

        for i in nodes.indices {
            guard let y = fit(index: i, width: width, height: height) else { continue }
            let node = nodes[i]
            if y + height < bestHeight || (y + height == bestHeight && node.width > 0 && node.width < bestWidth) {
                bestIndex = i
                bestWidth = node.width
                bestHeight = y + height
                region.x = node.x
                region.y = y
            }
        }
        guard let bestIndex else { return nil }

        nodes.insert(Node(x: region.x, y: region.y + height, width: width), at: bestIndex)
        let i = bestIndex + 1
        while i < nodes.count {
            let prev = nodes[i - 1]
            guard nodes[i].x < prev.x + prev.width else { break }
            let shrink = prev.x + prev.width - nodes[i].x
            nodes[i].x += shrink
            nodes[i].width -= shrink
            if nodes[i].width <= 0 {
                nodes.remove(at: i)
                continue
            }
            break
        }
        merge()
        return region
    }

    private func fit(index: Int, width: Int, height: Int) -> Int? {
        let node = nodes[index]
        guard node.x + width <= size - 1 else { return nil }
        var y = node.y
        var widthLeft = width
        var i = index
        while widthLeft > 0 {
            guard i < nodes.count else { return nil }
            y = max(y, nodes[i].y)
            guard y + height <= size - 1 else { return nil }
            widthLeft -= nodes[i].width
            i += 1
        }
        return y
    }

    private mutating func merge() {
        var i = 0
        while i < nodes.count - 1 {
            if nodes[i].y == nodes[i + 1].y {
                nodes[i].width += nodes[i + 1].width
                nodes.remove(at: i + 1)
            } else {
                i += 1
            }
        }
    }

    private mutating func set(_ region: Region, data: UnsafeRawBufferPointer) {
        let depth = format.depth
        let rowBytes = region.width * depth
        precondition(data.count >= rowBytes * region.height)
        pixels.withUnsafeMutableBytes { dst in
            for row in 0..<region.height {
                let dstOffset = ((region.y + row) * size + region.x) * depth
                dst.baseAddress!.advanced(by: dstOffset)
                    .copyMemory(from: data.baseAddress!.advanced(by: row * rowBytes), byteCount: rowBytes)
            }
        }
        pendingRegions?.append(region)
        generation += 1
    }

    /// Doubles the texture, keeping existing glyphs at their coordinates.
    private mutating func grow() {
        let old = size
        let depth = format.depth
        let newSize = old * 2
        var grown = [UInt8](repeating: 0, count: newSize * newSize * depth)
        grown.withUnsafeMutableBytes { dst in
            pixels.withUnsafeBytes { src in
                for row in 0..<old {
                    dst.baseAddress!.advanced(by: row * newSize * depth)
                        .copyMemory(from: src.baseAddress!.advanced(by: row * old * depth), byteCount: old * depth)
                }
            }
        }
        pixels = grown
        size = newSize
        nodes.append(Node(x: old - 1, y: 1, width: newSize - old))
        merge()
        pendingRegions = nil
        generation += 1
    }
}
