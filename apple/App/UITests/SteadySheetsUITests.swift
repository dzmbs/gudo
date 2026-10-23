#if os(iOS)
import XCTest

/// Sheets open at their final size: what a host answers after the sheet is up changes rows in
/// place, never the sheet or the layout under them.
@MainActor
final class SteadySheetsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testNewAgentKeepsItsFramesWhenTheCheckReturns() throws {
        for answer in ["notOnPath", "missing", "installed"] {
            let app = XCUIApplication()
            app.launchArguments += ["-mock", "-screen", "launchAgent", "-restoreLastTarget", "NO", "-mockAgentInstall", answer, "-mockAgentInstallDelay", "30"]
            app.launch()
            let status = app.descendants(matching: .any)["task-agent-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            XCTAssertTrue(status.label.hasPrefix("Checking"), "the row is there, checking, from the first frame: \(status.label)")
            let watched = ["task-agent-status", "task-runner", "task-worktree", "launch-prompt", "launch-start"]
            let opened = frames(app, watched)

            let answered = NSPredicate(format: "NOT (label BEGINSWITH 'Checking')")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: answered, evaluatedWith: status)], timeout: 40), .completed)
            // Past the row's own cross-fade.
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(frames(app, watched), opened, "\(answer): nothing moved when the answer came")
            app.terminate()
        }
    }

    private func frames(_ app: XCUIApplication, _ identifiers: [String]) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: identifiers.map { id in
            let element = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(element.exists, "\(id) is on the sheet")
            // The status text's own size follows its words; where it starts must hold (the slot
            // it sits in holds the rows below).
            let frame = element.frame
            return (id, id == "task-agent-status" ? CGRect(origin: frame.origin, size: .zero) : frame)
        })
    }
}
#endif
