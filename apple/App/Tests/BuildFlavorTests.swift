import Foundation
import XCTest
@testable import App

@MainActor
final class BuildFlavorTests: XCTestCase {
    func testDebugIdentityIsSeparateFromRelease() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try String(contentsOf: directory.appending(path: "Brand.xcconfig"), encoding: .utf8)
        let values = Dictionary(configuration.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.components(separatedBy: " = ")
            guard parts.count == 2, parts[0].hasPrefix("BRAND_") else { return nil }
            return (parts[0], parts[1])
        }, uniquingKeysWith: { _, last in last })
        for key in ["BRAND_NAME", "BRAND_BUNDLE_ID_PREFIX", "BRAND_URL_SCHEME", "BRAND_DAEMON_BIN", "BRAND_CLI_BIN", "BRAND_APP_ICON", "BRAND_HELPER_DIRECTORY"] {
            XCTAssertNotEqual(try XCTUnwrap(values[key]), try XCTUnwrap(values["\(key)[config=Debug]"]))
        }
        #if DEBUG
        XCTAssertTrue(Brand.isDev)
        XCTAssertEqual(Brand.name, values["BRAND_NAME[config=Debug]"])
        XCTAssertEqual(Brand.daemonBinary, values["BRAND_DAEMON_BIN[config=Debug]"])
        XCTAssertEqual(Bundle.main.bundleIdentifier, try XCTUnwrap(values["BRAND_BUNDLE_ID_PREFIX[config=Debug]"]) + ".app")
        #else
        XCTAssertFalse(Brand.isDev)
        XCTAssertEqual(Brand.name, values["BRAND_NAME"])
        XCTAssertEqual(Brand.daemonBinary, values["BRAND_DAEMON_BIN"])
        #endif
    }
}
