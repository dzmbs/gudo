import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import App

final class AgentImageTests: XCTestCase {
    private func image(width: Int, height: Int, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let picture = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    private func properties(_ data: Data) throws -> (type: String, width: Int, height: Int, all: [String: Any]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let all = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        return (try XCTUnwrap(CGImageSourceGetType(source) as String?),
                try XCTUnwrap(all[kCGImagePropertyPixelWidth as String] as? Int),
                try XCTUnwrap(all[kCGImagePropertyPixelHeight as String] as? Int), all)
    }

    func testAPhotoArrivesUprightWithoutWhereOrWithWhatItWasTaken() throws {
        let photo = try image(width: 64, height: 32, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Camera", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Paris"],
        ])
        XCTAssertNotNil(try properties(photo).all[kCGImagePropertyGPSDictionary as String])

        let sent = try properties(AgentImage.prepare(photo))
        XCTAssertEqual(sent.type, UTType.jpeg.identifier)
        XCTAssertNil(sent.all[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(sent.all[kCGImagePropertyIPTCDictionary as String])
        XCTAssertNil((sent.all[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String])
        XCTAssertEqual(sent.all[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
        XCTAssertEqual([sent.width, sent.height], [32, 64], "turned upright in its pixels")
    }

    func testAScreenshotStaysPngAndALargeOneIsScaledDown() throws {
        let screenshot = try properties(AgentImage.prepare(image(width: 4_000, height: 1_000, type: .png)))
        XCTAssertEqual(screenshot.type, UTType.png.identifier)
        XCTAssertEqual([screenshot.width, screenshot.height], [AgentImage.maximumPixels, AgentImage.maximumPixels / 4])
    }

    /// Graphics keep their transparency as PNG; only photos become JPEG.
    func testGraphicsBecomePngAndPhotosJpeg() throws {
        for type in [UTType.tiff, .gif] {
            XCTAssertEqual(try properties(AgentImage.prepare(image(width: 8, height: 8, type: type))).type, UTType.png.identifier, "\(type)")
        }
        let heic = NSMutableData()
        if CGImageDestinationCreateWithData(heic, UTType.heic.identifier as CFString, 1, nil) != nil {
            XCTAssertEqual(try properties(AgentImage.prepare(image(width: 8, height: 8, type: .heic))).type, UTType.jpeg.identifier)
        }
    }

    func testWhatIsNotAnImageOrIsTooLargeIsRefused() {
        XCTAssertThrowsError(try AgentImage.prepare(Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? AgentImage.Failure, .unreadable)
        }
        XCTAssertThrowsError(try AgentImage.prepare(Data(count: AgentImage.maximumInputBytes + 1))) { error in
            XCTAssertEqual(error as? AgentImage.Failure, .tooLarge)
        }
    }
}
