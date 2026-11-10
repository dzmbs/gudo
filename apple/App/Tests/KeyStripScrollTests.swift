import CoreGraphics
import XCTest
@testable import App

/// How the key bar's scrolling keys show there are more: a key cut by an edge fades,
/// a fling rests on a key edge, and the keys settle in only until the user has scrolled them.
@MainActor
final class KeyStripScrollTests: XCTestCase {
    private let strip = KeyStripScroll(keyWidths: [31, 31, 31, 31, 40, 30, 30], viewportWidth: 100)

    func testAKeyCutByAnEdgeFadesAndAWholeOneDoesNot() {
        XCTAssertTrue(strip.overflows)
        XCTAssertFalse(KeyStripScroll(keyWidths: [31, 31], viewportWidth: 100).overflows)
        XCTAssertEqual(strip.opacity(ofKeyFrom: 0, to: 31, at: 0), 1, "whole")
        XCTAssertEqual(strip.opacity(ofKeyFrom: 93, to: 124, at: 0), (7.0 / 31) * (7.0 / 31), accuracy: 0.001, "mostly past the trailing edge")
        XCTAssertEqual(strip.opacity(ofKeyFrom: 0, to: 31, at: 15.5), 0.25, accuracy: 0.001, "half past the leading edge")
        XCTAssertEqual(strip.opacity(ofKeyFrom: 124, to: 164, at: 0), 1, "out of sight: clipped, and still there for VoiceOver")
        XCTAssertEqual(strip.opacity(ofKeyFrom: 194, to: 224, at: strip.maximumOffset), 1, "the last key, scrolled to")
    }

    func testAFlingRestsOnAKeyEdgeOrAtTheEnd() {
        XCTAssertEqual(strip.restingOffset(near: 0), 0)
        XCTAssertEqual(strip.restingOffset(near: 20), 31)
        XCTAssertEqual(strip.restingOffset(near: 70), 62)
        XCTAssertEqual(strip.restingOffset(near: strip.maximumOffset - 0.5), strip.maximumOffset)
        XCTAssertEqual(strip.restingOffset(near: 500), strip.maximumOffset)
        XCTAssertEqual(strip.restingOffset(near: -40), 0)
        XCTAssertEqual(KeyStripScroll(keyWidths: [31], viewportWidth: 100).restingOffset(near: 20), 0)
    }

    func testTheKeysSettleInOnlyUntilTheUserScrollsThem() {
        XCTAssertEqual(strip.hintOffset, 62)
        XCTAssertTrue(strip.showsHint(hintsShown: 0, hasScrolled: false, reduceMotion: false))
        XCTAssertFalse(strip.showsHint(hintsShown: KeyStripScroll.hintLimit, hasScrolled: false, reduceMotion: false))
        XCTAssertFalse(strip.showsHint(hintsShown: 0, hasScrolled: true, reduceMotion: false))
        XCTAssertFalse(strip.showsHint(hintsShown: 0, hasScrolled: false, reduceMotion: true))
        XCTAssertFalse(KeyStripScroll(keyWidths: [31, 31], viewportWidth: 100)
            .showsHint(hintsShown: 0, hasScrolled: false, reduceMotion: false))
    }
}
