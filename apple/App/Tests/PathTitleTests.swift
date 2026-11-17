import XCTest
@testable import App

/// A path that does not fit a row keeps its last folders whole ("…/gudo", then "gudo"), never a
/// cut word at its start ("…jects/gudo").
final class PathTitleTests: XCTestCase {
    func testAPathShortensByWholeFoldersFromItsStart() {
        XCTAssertEqual(PathTitle.forms(of: "~/projects/gudo/apple"), ["~/projects/gudo/apple", "…/gudo/apple", "apple"])
        XCTAssertEqual(PathTitle.forms(of: "~/projects/gudo"), ["~/projects/gudo", "gudo"])
        XCTAssertEqual(PathTitle.forms(of: "/var/log/"), ["/var/log/", "log"])
    }

    func testAnythingButAPathIsLeftAlone() {
        XCTAssertEqual(PathTitle.forms(of: "cargo test"), ["cargo test"])
        XCTAssertEqual(PathTitle.forms(of: "~"), ["~"])
        XCTAssertEqual(PathTitle.forms(of: "/"), ["/"])
        XCTAssertEqual(PathTitle.forms(of: "~/src"), ["~/src", "src"])
    }
}
