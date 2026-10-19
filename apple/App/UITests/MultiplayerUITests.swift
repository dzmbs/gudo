import XCTest

/// Share Session against a real local daemon (apple/scripts/multiplayer-ui-test.sh starts it,
/// pairs the app as the owner with `PAIR_TICKET`, and keeps a guest, "Mira Holt", joined as a
/// viewer through the `un` CLI): presence shows Mira, the invite sheet signs a driver invite
/// (link + QR), Access & Grants lists both invites, revoking Mira removes her, and the audit log
/// shows the join and the revocation with an intact chain. Skipped without a ticket.
@MainActor
final class MultiplayerUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func element(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    /// Scrolls the sheet's list until a lazily built row exists.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, up: Bool = true) -> Bool {
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            let list = app.collectionViews.firstMatch
            if up { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
        }
        return target.exists
    }

    func testShareInviteParticipantsGrantsAudit() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/multiplayer-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-liveActivities", "NO"]
        app.launch()

        // Paired; the guest the script joined shows up in the toolbar's presence button.
        let presence = element(app, "presence-button")
        XCTAssertTrue(presence.waitForExistence(timeout: 40), "the presence button appears for a daemon host")
        let guestShown = NSPredicate(format: "label CONTAINS '1 person'")
        expectation(for: guestShown, evaluatedWith: presence)
        waitForExpectations(timeout: 30)
        shot(app, "mp-1-presence")

        // Share Session: Mira is listed with her role.
        presence.tap()
        let mira = element(app, "person-Mira Holt")
        XCTAssertTrue(mira.waitForExistence(timeout: 15), "the guest is in People Here")
        XCTAssertTrue(mira.label.contains("Viewer"), "her role is shown: \(mira.label)")

        // Invite Sam as a driver: link and QR.
        let name = element(app, "invite-name")
        reveal(app, name)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Sam Ruiz")
        element(app, "role-driver").tap()
        reveal(app, element(app, "create-invite"))
        element(app, "create-invite").tap()
        XCTAssertTrue(element(app, "invite-qr").waitForExistence(timeout: 15), "a QR code of the signed invite")
        let link = element(app, "invite-link")
        XCTAssertTrue(link.exists)
        XCTAssertTrue(element(app, "invite-summary").label.hasPrefix("Driver"), element(app, "invite-summary").label)
        shot(app, "mp-2-invite")

        // Access & Grants lists both invites.
        reveal(app, element(app, "open-grants"))
        element(app, "open-grants").tap()
        XCTAssertTrue(element(app, "grant-Sam Ruiz").waitForExistence(timeout: 15), "Sam's invite is listed")
        XCTAssertTrue(element(app, "grant-Mira Holt").exists, "Mira's invite is listed")
        shot(app, "mp-3-grants")
        app.navigationBars["Access & Grants"].buttons.firstMatch.tap()

        // Revoke Mira from People Here.
        reveal(app, mira, up: false)
        XCTAssertTrue(mira.waitForExistence(timeout: 5))
        mira.swipeLeft()
        app.buttons["Revoke"].firstMatch.tap()
        let confirm = app.buttons["Revoke Access"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(mira.waitForNonExistence(timeout: 15), "Mira is gone once revoked")
        shot(app, "mp-4-revoked")

        // The audit log: intact chain, Mira's join and the revocation.
        reveal(app, element(app, "open-audit"))
        element(app, "open-audit").tap()
        XCTAssertTrue(element(app, "audit-chain-ok").waitForExistence(timeout: 15), "the hash chain verifies")
        let revoked = app.staticTexts["Access revoked"].firstMatch
        XCTAssertTrue(revoked.waitForExistence(timeout: 10), "the revocation is recorded")
        XCTAssertTrue(app.staticTexts["Mira Holt joined"].firstMatch.exists || app.staticTexts["Mira Holt used an invite"].firstMatch.exists,
                      "Mira's join is recorded")
        shot(app, "mp-5-audit")
    }
}
