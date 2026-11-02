import Foundation
import HostKit
import GudoCore
import XCTest
@testable import App

/// Agent accounts in the app: the fixture the screenshots use reads as designed, Settings search
/// finds the page, and a new agent follows the project's default unless the tab picks another.
@MainActor
final class AccountsTests: XCTestCase {
    func testFixtureLabelsTheWorkPaneAndSuggestsAnotherAccountAtItsLimit() throws {
        let book = MockAccounts.book
        XCTAssertEqual(book.paneLabel(3)?.name, "Work")
        // Codex has one account: nothing names it.
        XCTAssertFalse(book.hasChoice(.codex))
        let hint = try XCTUnwrap(book.limitHint(forPane: 3))
        XCTAssertEqual(hint.alternative.label, "Personal", "the signed-out account is never suggested")
        XCTAssertEqual(hint.action, "New Tab with Personal")
        XCTAssertTrue(hint.message().hasPrefix("Work is at its 5h limit"))
    }

    func testNewAgentsFollowTheProjectThenTheHost() {
        let book = MockAccounts.book
        XCTAssertEqual(book.resolve(.claude, project: "acme-api", override: nil), "a1b2c3d4")
        XCTAssertEqual(book.resolve(.claude, project: "blog", override: nil), systemAccount)
        XCTAssertEqual(book.resolve(.claude, project: "acme-api", override: systemAccount), systemAccount)
    }

    func testSettingsSearchFindsAccounts() {
        XCTAssertEqual(SettingsIndex.search("work account").first?.id, "accounts")
        XCTAssertEqual(SettingsIndex.search("sign in").first?.id, "accounts")
    }

    func testRowsSayWhoEachAccountIs() {
        let rows = MockAccounts.book.accounts(of: .claude).map { AccountText.status($0.status) }
        XCTAssertEqual(rows, ["sam@hey.example · Max", "sam@acme.example · Team · Acme", "Not signed in"])
    }
}
