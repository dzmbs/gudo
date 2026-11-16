import XCTest
@testable import App

/// Generated tab names stay unique: a name given out once never comes back, even after the
/// tab that had it was renamed.
@MainActor
final class FriendlyNameTests: XCTestCase {
    func testANameIsNeverGivenOutTwice() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let name = FriendlyName.make()
            XCTAssertFalse(seen.contains(name), "\(name) came back")
            XCTAssertTrue(FriendlyName.isGenerated(name))
            seen.insert(name)
        }
    }

    func testNamesInUseAreAvoided() {
        let used = Set(FriendlyName.adjectives.flatMap { adjective in FriendlyName.nouns.dropLast().map { "\(adjective)-\($0)" } })
        let name = FriendlyName.make(avoiding: used)
        XCTAssertFalse(used.contains(name))
    }
}
