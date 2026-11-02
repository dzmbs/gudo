import XCTest

/// Multiplayer flows against real local daemons (apple/scripts/multiplayer-flows-ui-test.sh):
///
/// - **Join link**: a guest opens `<scheme>://join/…` (another daemon, whose owner is the `gudo`
///   CLI), reads the card and joins; the session shows them as a viewer.
/// - **Knock**: "Kim Lee" knocks with an ask-first link (`gudo join` waits in the script); the
///   owner app shows the knock over the terminal and admits her as a driver.
/// - **Take control**: "Rex Diaz" (CLI driver) holds the pane's lease; the owner sees who drives
///   and takes control.
/// - **Mirror**: the joined guest follows its inviter into a tab opened after joining.
/// - **Manage sharing**: the owner copies and revokes a link and removes a person.
///
/// Each test skips without the environment the script provides.
@MainActor
final class MultiplayerFlowsUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchOwner() throws -> XCUIApplication {
        let ticket = env["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/multiplayer-flows-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-liveActivities", "NO"]
        app.launch()
        XCTAssertTrue(element(app, "presence-button").waitForExistence(timeout: 40), "paired with the daemon")
        return app
    }

    /// A guest opens an invite link from Messages: the card says who invites and with what
    /// rights, they join, and the window shows them as a viewer of the owner's terminal.
    func testJoinLinkAsGuest() throws {
        let link = env["JOIN_LINK"] ?? ""
        try XCTSkipIf(link.isEmpty, "no invite link (run apple/scripts/multiplayer-flows-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += ["-testRelay", "disabled", "-liveActivities", "NO"]
        app.launch()
        app.open(try XCTUnwrap(URL(string: link)))

        let inviter = element(app, "join-inviter")
        XCTAssertTrue(inviter.waitForExistence(timeout: 20), "the deep link opens the join card")
        XCTAssertEqual(inviter.label, "Ola invites you")
        let join = element(app, "join-button")
        XCTAssertTrue(join.label.contains("Viewer"), join.label)
        shot(app, "flows-1-join-card")
        join.tap()

        let banner = element(app, "guest-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 40), "joined: the guest's role banner shows")
        XCTAssertTrue(banner.label.contains("View only"), banner.label)
        shot(app, "flows-2-joined")

        // A full mirror: Ola opens a tab after Gus joined and writes there; Gus's window goes
        // along by itself and shows the draft live.
        guard !(env["MIRROR"] ?? "").isEmpty else { return }
        let pill = element(app, "follow-pill")
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "a guest follows whoever invited them")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Following '")).firstMatch.exists)
        XCTAssertTrue(element(app, "pane-2").waitForExistence(timeout: 30), "the new tab shows in the guest's window")
        let mirror = element(app, "draft-mirror-2")
        XCTAssertTrue(mirror.waitForExistence(timeout: 20), "the leader's draft in the new tab shows live")
        XCTAssertTrue(mirror.label.contains("is writing: S"), mirror.label)
        shot(app, "flows-2b-mirrored")
    }

    /// Scrolls the sheet until `target` is on screen.
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, up: Bool = true) {
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            up ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow)
        }
    }

    private func confirm(_ app: XCUIApplication, _ title: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'remove-')", title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the \(title) confirmation")
        button.tap()
    }

    private func palette(_ app: XCUIApplication, _ command: String) {
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        if !field.waitForExistence(timeout: 2) { element(app, "open-palette").tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("\(command)\n")
    }

    /// The owner's sharing: Active Links copies a link made on another device and revokes it;
    /// People removes Pat now; Manage Sharing and the Hosts badge show what is left.
    func testManageSharing() throws {
        try XCTSkipIf((env["SHARING"] ?? "").isEmpty, "no sharing fixtures (run apple/scripts/multiplayer-flows-ui-test.sh)")
        let app = try launchOwner()
        element(app, "presence-button").tap()
        let share = element(app, "people-share-session")
        if share.waitForExistence(timeout: 3) { share.tap() }

        let copy = element(app, "copy-link-Temp")
        reveal(app, copy)
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "the link made by the CLI is listed")
        copy.tap()
        let copied = NSPredicate { _, _ in copy.label == "Copied" }
        wait(for: [expectation(for: copied, evaluatedWith: nil)], timeout: 10)
        shot(app, "flows-12-active-links")
        element(app, "revoke-link-Temp").tap()
        confirm(app, "Revoke Link")
        XCTAssertTrue(copy.waitForNonExistence(timeout: 10), "a revoked link leaves Active Links")

        let remove = element(app, "remove-Pat Quinn")
        reveal(app, remove, up: false)
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "a connected guest can be removed")
        shot(app, "flows-13-people")
        remove.tap()
        confirm(app, "Remove")
        XCTAssertTrue(element(app, "person-Pat Quinn").waitForNonExistence(timeout: 10), "removed at once")
        element(app, "share-done").tap()

        palette(app, "Manage Sharing")
        XCTAssertTrue(element(app, "sharing-list").waitForExistence(timeout: 10), "every shared host in one place")
        XCTAssertFalse(element(app, "remove-Pat Quinn").exists)
        XCTAssertFalse(element(app, "copy-link-Temp").exists)
        shot(app, "flows-14-manage-sharing")
        element(app, "sharing-done").tap()

        palette(app, "Go to Hosts")
        let badge = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sharing-' AND label BEGINSWITH 'Shared'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the host's row says it is shared")
        shot(app, "flows-15-hosts-badge")
    }

    /// Kim knocks with an ask-first link; the owner sees her over the terminal and lets her in
    /// as a driver from the banner.
    func testKnockAndAdmit() throws {
        try XCTSkipIf((env["KNOCKER"] ?? "").isEmpty, "no knock in progress (run apple/scripts/multiplayer-flows-ui-test.sh)")
        let app = try launchOwner()
        let banner = element(app, "knock-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "the knock shows over the terminal")
        XCTAssertTrue(app.staticTexts["Kim Lee is asking to join"].firstMatch.exists, "by name")
        shot(app, "flows-3-knock")

        element(app, "knock-admit").tap()
        // Menu items carry their titles (identifiers do not reach UIKit's menu).
        let driver = app.buttons["Driver"].firstMatch
        XCTAssertTrue(driver.waitForExistence(timeout: 5), "Admit as… lists the roles")
        shot(app, "flows-4-admit-as")
        driver.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 20), "answered: the banner goes away")

        // The audit log records the knock and the admission.
        element(app, "presence-button").tap()
        // With people here the button lists them; Share Session is its last row.
        let share = element(app, "people-share-session")
        if share.waitForExistence(timeout: 3) { share.tap() }
        let audit = element(app, "open-audit")
        for _ in 0..<8 where !(audit.exists && audit.isHittable) {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        audit.tap()
        XCTAssertTrue(element(app, "audit-chain-ok").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Let someone in"].firstMatch.waitForExistence(timeout: 10), "the admission is audited")
        // Access records only: the knock sits among the joins, not under every lease and prompt.
        app.buttons["Access"].firstMatch.tap()
        let knocked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Kim Lee knocked'")).firstMatch
        for _ in 0..<6 where !knocked.exists {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        shot(app, "flows-5-audit-access")
        XCTAssertTrue(knocked.exists, "the knock is audited")
        shot(app, "flows-5-audit")
    }

    /// Live presence: Rex (CLI) writes a prompt in pane 1 and the owner watches it grow as he
    /// types, with his name; the tab shows he is in it; the owner follows him and goes along
    /// when he moves to pane 2 (the script checks Rex saw the owner arrive); an agent's
    /// permission request shows on the pane with who may answer, and the owner's answer shows
    /// for everyone (the script checks Rex heard it).
    func testLivePresenceFollowAndSharedApproval() throws {
        try XCTSkipIf((env["PRESENCE"] ?? "").isEmpty, "no live presence fixtures (run apple/scripts/multiplayer-flows-ui-test.sh)")
        let app = try launchOwner()

        // The draft, live: the mirror's text changes while Rex types.
        let mirror = element(app, "draft-mirror-1")
        XCTAssertTrue(mirror.waitForExistence(timeout: 40), "Rex's draft shows on the pane")
        XCTAssertTrue(mirror.label.hasPrefix("Rex Diaz is writing: "), mirror.label)
        let first = mirror.label
        let grew = NSPredicate { _, _ in mirror.exists && mirror.label != first }
        let moved = expectation(for: grew, evaluatedWith: nil)
        wait(for: [moved], timeout: 15)
        XCTAssertTrue("Rex Diaz is writing: Fix the flaky reconnect test".hasPrefix(mirror.label) || mirror.label.hasSuffix("test"), mirror.label)
        shot(app, "flows-8-live-draft")

        // The tab says who is in it.
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'Rex Diaz here'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "presence on the tab")

        // The agent's request, on the pane for everyone, with who answers here.
        let approval = element(app, "shared-approval")
        XCTAssertTrue(approval.waitForExistence(timeout: 20), "the agent's request shows on the pane")
        XCTAssertEqual(element(app, "shared-approval-who").label, "You answer")
        shot(app, "flows-9-shared-approval")
        element(app, "shared-approval-allow").tap()
        XCTAssertTrue(element(app, "shared-approval-answered").waitForExistence(timeout: 10), "who answered shows")
        XCTAssertTrue(approval.waitForNonExistence(timeout: 10))

        // Follow Rex from the people popover; the pill names him.
        element(app, "presence-button").tap()
        let follow = element(app, "follow-Rex Diaz")
        XCTAssertTrue(follow.waitForExistence(timeout: 10))
        follow.tap()
        let pill = element(app, "follow-pill")
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the window says whom it follows")
        XCTAssertTrue(app.staticTexts["Following Rex"].firstMatch.exists)
        shot(app, "flows-10-following")
        // Rex moves to pane 2 once followed; give the window time to go along (the script
        // checks Rex saw it arrive).
        sleep(4)
        // Scrolling by hand stops following, quietly, with a way back.
        let pane = element(app, "pane-2")
        XCTAssertTrue(pane.waitForExistence(timeout: 5), "following brought the window to Rex's pane")
        pane.swipeDown(velocity: .slow)
        XCTAssertTrue(pill.waitForNonExistence(timeout: 5), "a scroll of one's own ends following")
        let banner = element(app, "toast")
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertEqual(banner.label, "Stopped following Rex")
        shot(app, "flows-11-stopped-following")
        element(app, "toast-action").tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Follow Again follows again")
        element(app, "stop-following").tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 5))
    }

    /// Rex drives the pane; the owner's pane says so and Take Control moves the lease to them
    /// (at once if Rex is idle, else after he hands over or goes idle).
    func testTakeControlFromDriver() throws {
        try XCTSkipIf((env["DRIVER"] ?? "").isEmpty, "no driver holding a lease (run apple/scripts/multiplayer-flows-ui-test.sh)")
        let app = try launchOwner()
        let take = element(app, "take-control")
        XCTAssertTrue(take.waitForExistence(timeout: 30), "the pane shows who drives and offers Take Control")
        XCTAssertTrue(app.staticTexts["Rex Diaz is driving"].firstMatch.exists, "names the driver")
        shot(app, "flows-6-driven")
        take.tap()
        XCTAssertTrue(app.staticTexts["Rex Diaz is driving"].firstMatch.waitForNonExistence(timeout: 20), "the lease moves to the owner")
        XCTAssertFalse(take.exists)
        // Share Session shows the owner (this device) driving now.
        element(app, "presence-button").tap()
        // With people here the button lists them; Share Session is its last row.
        let share = element(app, "people-share-session")
        if share.waitForExistence(timeout: 3) { share.tap() }
        let ownRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS '(you)'")).firstMatch
        XCTAssertTrue(ownRow.waitForExistence(timeout: 10))
        XCTAssertTrue(ownRow.label.contains("Driving"), ownRow.label)
        shot(app, "flows-7-driving")
    }
}
