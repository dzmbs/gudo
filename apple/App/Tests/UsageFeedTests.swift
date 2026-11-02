import Foundation
import HostKit
import GudoCore
import XCTest
@testable import App

/// The usage feed the sidebar and the Inbox read: the fake report the UI test and screenshots
/// use reads as designed, and watching is balanced.
@MainActor
final class UsageFeedTests: XCTestCase {
    func testFakeReportReadsAsTheSidebarShowsIt() throws {
        let now = Date(timeIntervalSince1970: 1_792_411_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let meters = UsageMeter.compact(FakeUsageFeed.report(now: now), now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(meters.map(\.text), [
            "Claude · 62% of 5h · resets 14:20",
            "Codex · 92% of weekly · resets Wed",
        ])
        XCTAssertEqual(meters.map(\.tone), [.quiet, .attention])
        XCTAssertNil(UsageTone.quiet.color, "quiet meters keep the surface's own style")
        XCTAssertNotNil(UsageTone.attention.color)
        XCTAssertNotNil(UsageTone.limited.color)
    }

    func testFakeFeedReportsEveryHostAndCountsWatchers() {
        let feed = FakeUsageFeed { [UsageHost(id: "a", name: "studio"), UsageHost(id: "b", name: "devbox")] }
        XCTAssertEqual(feed.reportingHosts.map(\.name), ["studio", "devbox"])
        XCTAssertEqual(feed.usage(forHost: "a")?.agents.count, 2)
        feed.watch(host: "a")
        feed.watch(host: "a")
        feed.unwatch(host: "a")
        XCTAssertEqual(feed.watched["a"], 1)
        feed.unwatch(host: "a")
        XCTAssertEqual(feed.watched["a"], 0)
    }

    func testDetailOfTheFakeReportNamesItsSources() {
        let now = Date()
        let details = FakeUsageFeed.report(now: now).agents.map { UsageDetail($0, now: now) }
        XCTAssertEqual(details.map(\.title), ["Claude Code · Max", "Codex · Plus"])
        XCTAssertEqual(details[0].rows.map(\.name), ["5h", "weekly"])
        XCTAssertTrue(details[0].source?.hasPrefix("From Claude Code's status line") == true)
        XCTAssertTrue(details[1].source?.hasPrefix("From Codex's session logs on the host") == true)
    }
}
