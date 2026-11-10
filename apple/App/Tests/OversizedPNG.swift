import Foundation

/// A valid all-black 1-bit greyscale PNG of any size: a few hundred KiB that decode into
/// gigabytes.
nonisolated enum OversizedPNG {
    static func declaring(width: UInt32, height: UInt32) -> Data {
        let rowBytes = 1 + (Int(width) + 7) / 8
        let pixelBytes = Data(count: rowBytes * Int(height))
        // zlib stream: header, raw DEFLATE, then Adler-32, which for all zero bytes is
        // (count mod 65521) << 16 | 1.
        var zlib = Data([0x78, 0x01])
        zlib.append((try? (pixelBytes as NSData).compressed(using: .zlib) as Data) ?? Data())
        zlib.append(bigEndian: UInt32(pixelBytes.count % 65_521) << 16 | 1)

        var header = Data()
        header.append(bigEndian: width)
        header.append(bigEndian: height)
        header.append(contentsOf: [1, 0, 0, 0, 0])

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.appendChunk("IHDR", header)
        png.appendChunk("IDAT", zlib)
        png.appendChunk("IEND", Data())
        return png
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        append(bigEndian: UInt32(body.count))
        let typed = Data(type.utf8) + body
        append(typed)
        append(bigEndian: Self.crc32(typed))
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
