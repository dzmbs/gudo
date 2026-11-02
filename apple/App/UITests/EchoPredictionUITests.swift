import XCTest

/// Echo prediction on a daemon pane over a slow link (apple/scripts/prediction-ui-test.sh: a
/// real local `gudo-hostd`, every event from it held back 2.5 s by `-testLinkDelayMs`).
/// Typed text is drawn ahead of the echo, the echo confirms it, nothing is mispredicted, and
/// hidden input (a password prompt) is never predicted. Skipped without a ticket.
@MainActor
final class EchoPredictionUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate(format: format)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate.evaluate(with: element) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("\(format): \(element.identifier) is \(String(describing: element.value))")
    }

    /// A counter from the prediction element ("confirmed=12").
    private func count(_ name: String, _ element: XCUIElement) -> Int {
        let value = element.value as? String ?? ""
        guard let range = value.range(of: name + "=") else { return 0 }
        return Int(value[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    func testDaemonPanePredictsAheadOfTheEcho() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/prediction-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-testLinkDelayMs", "2500"]
        app.launch()

        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        pane.tap()
        let screen = app.descendants(matching: .any)[pane.identifier + "-screen"]
        let prediction = app.descendants(matching: .any)[pane.identifier + "-prediction"]
        app.typeText("echo ready-$((1+1))\n")
        waitFor("value CONTAINS 'ready-2'", screen, timeout: 40)

        // `cat` reads a cooked line with echo on: the daemon's hint allows prediction.
        app.typeText("cat\n")
        sleep(6)
        // After a quiet spell only one key is drawn ahead (the program may have gone silent
        // into hidden input); once its echo is back, typing runs ahead of the link.
        let confirmed = count("confirmed", prediction)
        app.typeText("p")
        waitFor("value CONTAINS 'ahead=p'", prediction, timeout: 2)
        let deadline = Date().addingTimeInterval(10)
        while count("confirmed", prediction) <= confirmed, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        app.typeText("redicted")
        waitFor("value CONTAINS 'ahead=redi'", prediction, timeout: 2)
        XCTAssertFalse((screen.value as? String ?? "").contains("predicted"), "still on its way back")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "echo-prediction-daemon"
        shot.lifetime = .keepAlways
        add(shot)
        // The echo arrives and confirms every cell; nothing was wrong.
        waitFor("value CONTAINS 'predicted'", screen, timeout: 10)
        waitFor("value MATCHES '.*confirmed=([9]|[1-9][0-9]+) mispredicted=0 ahead=$'", prediction, timeout: 10)
        app.typeKey("c", modifierFlags: .control)

        // Hidden input is never predicted: `read -s` turns echo off.
        app.typeText("read -s secret; echo got-$secret\n")
        sleep(6)
        let before = prediction.value as? String ?? ""
        app.typeText("hush")
        sleep(1)
        XCTAssertFalse((prediction.value as? String ?? "").contains("ahead=h"), "a password is not drawn")
        app.typeText("\n")
        waitFor("value CONTAINS 'got-hush'", screen, timeout: 15)
        XCTAssertFalse((screen.value as? String ?? "").contains("hushgot"), "never echoed")
        XCTAssertTrue(before.contains("mispredicted=0"))
    }
}
