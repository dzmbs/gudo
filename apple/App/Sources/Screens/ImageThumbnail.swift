import CoreGraphics
import Foundation
import ImageIO

/// An image file decoded only as large as it is shown. A few hundred KiB of PNG can declare
/// gigapixels, so the size is read from the header before anything is decoded.
nonisolated enum ImageThumbnail {
    static let maximumSourcePixels = 200_000_000

    enum Failure: Error, Equatable {
        case unreadable
        case tooLarge(width: Int, height: Int)
    }

    static func decode(_ data: Data, maximumPixelSize: Int) throws(Failure) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw .unreadable }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumSourcePixels else { throw .tooLarge(width: width, height: height) }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximumPixelSize, max(width, height))),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw .unreadable }
        return image
    }
}
