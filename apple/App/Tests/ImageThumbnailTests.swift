import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import App

final class ImageThumbnailTests: XCTestCase {
    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    func testALargePhotoIsDecodedAtTheShownSize() throws {
        let image = try ImageThumbnail.decode(try jpeg(width: 4_000, height: 3_000), maximumPixelSize: 1_024)
        XCTAssertEqual(max(image.width, image.height), 1_024)
        XCTAssertEqual(image.width, 1_024)
    }

    func testASmallImageIsNotEnlarged() throws {
        let image = try ImageThumbnail.decode(try jpeg(width: 120, height: 80), maximumPixelSize: 2_048)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    func testAnImageDeclaringGigapixelsIsRefusedBeforeDecoding() {
        let png = OversizedPNG.declaring(width: 30_000, height: 30_000)
        XCTAssertLessThan(png.count, 1_024 * 1_024)
        XCTAssertThrowsError(try ImageThumbnail.decode(png, maximumPixelSize: 1_024)) { error in
            XCTAssertEqual(error as? ImageThumbnail.Failure, .tooLarge(width: 30_000, height: 30_000))
        }
    }

    func testBytesThatAreNoImageAreUnreadable() {
        XCTAssertThrowsError(try ImageThumbnail.decode(Data("not an image".utf8), maximumPixelSize: 512)) { error in
            XCTAssertEqual(error as? ImageThumbnail.Failure, .unreadable)
        }
    }
}
