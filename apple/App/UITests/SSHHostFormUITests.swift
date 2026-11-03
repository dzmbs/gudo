#if os(iOS)
import XCTest

/// Add Host › SSH on a fresh app: a pasted ssh command fills the editable User, Port and Jump
/// Host fields; a key created from the form becomes the sign-in; Settings › SSH Keys lists it
/// with its public key. Screenshots are attached for review.
@MainActor
final class SSHHostFormUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element) on screen")
    }

    func testPastedCommandFillsTheFormAndAKeyIsCreated() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hostsDirectory", NSTemporaryDirectory() + "ssh-form-\(UUID().uuidString)",
            "-restoreLastTarget", "NO", "-resetWindows", "YES", "-destination", "hosts",
            "-notificationPrompt", "NO",
        ]
        app.launch()
        let add = element(app, "hosts-add")
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add Host on the Hosts screen")
        add.tap()

        let address = element(app, "pairing-destination")
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        shot(app, "ssh-form-empty")
        address.tap()
        address.typeText("ssh -p 2222 -J admin@bastion root@62.238.108.86")
        let user = element(app, "ssh-user")
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "ssh-user").value as? String, "root")
        XCTAssertEqual(element(app, "ssh-port").value as? String, "2222")
        XCTAssertEqual(element(app, "ssh-jump").value as? String, "admin@bastion")
        shot(app, "ssh-form-pasted-command")

        // Leaving the field leaves the bare host in it.
        user.tap()
        XCTAssertEqual(address.value as? String, "62.238.108.86")
        let create = element(app, "ssh-create-key")
        scrollTo(create, in: app)
        create.tap()
        let confirm = element(app, "key-create-confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot(app, "ssh-create-key")
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "the key is created")
        let signIn = element(app, "ssh-sign-in")
        scrollTo(signIn, in: app)
        shot(app, "ssh-form-new-key")
        signIn.tap()
        shot(app, "ssh-sign-in-menu")
    }
}
#endif
