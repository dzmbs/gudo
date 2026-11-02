#if os(iOS)
import XCTest

/// Scrollback search, links tapped in a pane and mouse reporting on the iPad against a real
/// local `gudo-hostd` (`TEST_RUNNER_PAIR_TICKET=$(apple/scripts/local-daemon.sh start)`):
/// - ⌘F finds every match, Return / ⇧⌘G step through them, the pane scrolls to an old one and
///   the renderer draws the match colors; Esc closes and the highlights go;
/// - a dev server's URL printed in a pane opens in the in-app browser through a forward; a
///   web link asks once where links go;
/// - a program that turns on mouse reporting receives a tap as a click.
@MainActor
final class FindLinksMouseUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES", "-resetLinkOpening"]
        app.launch()
        if !pane.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        pane.tap()
        sleep(2)  // the software keyboard resizes the pane
        // The simulator drops the first hardware key event after launch.
        app.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
    }

    private var pane: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
    }

    private var screen: XCUIElement {
        app.descendants(matching: .any)[pane.identifier + "-screen"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10, _ message: String) {
        let predicate = NSPredicate(format: format)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        if result != .completed { shot("failed") }
        XCTAssertEqual(result, .completed, message)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pixels in the pane close to `rgb` (the renderer's search colors), from a screenshot.
    private func pixels(near rgb: (Int, Int, Int)) -> Int {
        let image = app.screenshot().image
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / app.frame.width
        let frame = pane.frame
        var count = 0
        for y in stride(from: Int(frame.minY * scale), to: min(height, Int(frame.maxY * scale)), by: 2) {
            for x in stride(from: Int(frame.minX * scale), to: min(width, Int(frame.maxX * scale)), by: 2) {
                let offset = (y * width + x) * 4
                if abs(Int(data[offset]) - rgb.0) < 14, abs(Int(data[offset + 1]) - rgb.1) < 14, abs(Int(data[offset + 2]) - rgb.2) < 14 { count += 1 }
            }
        }
        return count
    }

    /// The browser's Done goes back to the Ports list; that list's Done closes the sheet.
    private func closeBrowser() {
        element("browser-done").tap()
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(element("browser-address").waitForNonExistence(timeout: 5), "the browser closed")
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "the sheet closed")
    }

    private static let matchColor = (0xFF, 0xE0, 0x82)
    private static let selectedColor = (0xF2, 0xA5, 0x7E)

    // MARK: Find

    func testFindHighlightsStepsAndScrolls() throws {
        try launch()
        // 300 lines; every 50th says "needle", so the oldest ones are far above the screen.
        app.typeText("clear; for i in $(seq 1 300); do if [ $((i % 50)) = 0 ]; then echo \"needle $i\"; else echo \"line $i\"; fi; done\n")
        wait(screen, "value CONTAINS 'needle 300'", timeout: 20, "the output is on screen")
        XCTAssertFalse((screen.value as? String ?? "").contains("needle 50"), "the oldest needle is above the screen")

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F opens the find bar")
        field.typeText("needle")
        let searchBar = element("search-bar")
        // Six output lines; the command line itself says "needle" too.
        wait(searchBar, "value MATCHES '-/[0-9]+'", timeout: 10, "the bar counts the matches")
        let total = Int(((searchBar.value as? String) ?? "").split(separator: "/").last ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(total, 6)
        XCTAssertGreaterThan(pixels(near: Self.matchColor), 50, "the matches in view are highlighted")
        shot("find-matches")

        // Return: the newest match, then the one above it.
        field.typeText("\n")
        wait(searchBar, "value == '1/\(total)'", "Return selects the newest match")
        XCTAssertGreaterThan(pixels(near: Self.selectedColor), 20, "the selected match has its own color")
        field.typeText("\n")
        wait(searchBar, "value == '2/\(total)'", "Return again goes up")
        app.typeKey("g", modifierFlags: [.command, .shift])
        wait(searchBar, "value == '1/\(total)'", "⇧⌘G goes back down")

        // Up to the oldest output match: the pane scrolls to it.
        for _ in 0..<5 { app.typeKey("g", modifierFlags: .command) }
        wait(searchBar, "value == '6/\(total)'", "⌘G steps up through every match")
        wait(screen, "value CONTAINS 'needle 50'", timeout: 5, "the pane scrolled to the oldest match")
        XCTAssertGreaterThan(pixels(near: Self.selectedColor), 20)
        shot("find-oldest")

        // Match Case: no "Needle" anywhere.
        element("search-case").tap()
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Needle")
        wait(searchBar, "value == '-/0'", timeout: 10, "case-sensitive: no \"Needle\" anywhere")
        element("search-case").tap()
        wait(searchBar, "value MATCHES '-/[0-9]+' AND NOT value == '-/0'", timeout: 10, "case-insensitive again")

        // Esc (⌘. on an iPad keyboard; the simulator never delivers a synthesized Esc) closes; the highlights go.
        field.tap()
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc closes the bar")
        sleep(1)
        XCTAssertLessThan(pixels(near: Self.matchColor) + pixels(near: Self.selectedColor), 10, "no highlights after closing")
    }

    // MARK: Links

    func testDevServerLinkOpensInTheInAppBrowser() throws {
        try launch()
        app.typeText("python3 -m http.server 18767 --bind 127.0.0.1 >/dev/null 2>&1 &\n")
        sleep(2)
        // The URL on every row, so a tap anywhere on the left lands on one.
        app.typeText("clear; for i in $(seq 1 80); do echo http://127.0.0.1:18767/; done\n")
        wait(screen, "value CONTAINS 'http://127.0.0.1:18767/'", timeout: 10, "the URL is printed")
        sleep(1)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.4)).tap()
        XCTAssertTrue(text(containing: "Directory listing").waitForExistence(timeout: 20), "the page loads in the in-app browser, through a forward")
        shot("link-browser")
        closeBrowser()
    }

    func testWebLinkAsksOnceWhereLinksOpen() throws {
        try launch()
        app.typeText("clear; for i in $(seq 1 80); do echo https://example.com/docs; done\n")
        wait(screen, "value CONTAINS 'https://example.com/docs'", timeout: 10, "the URL is printed")
        sleep(1)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.4)).tap()
        let inApp = app.buttons["In-App Browser"].firstMatch
        XCTAssertTrue(inApp.waitForExistence(timeout: 5), "the first web link asks where links open")
        shot("link-ask")
        inApp.tap()
        XCTAssertTrue(element("browser-address").waitForExistence(timeout: 10), "it opens in the in-app browser")
        closeBrowser()

        sleep(1)
        // Not asked again.
        shot("before-second-link")
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        let reopened = element("browser-address").waitForExistence(timeout: 10)
        if !reopened { shot("second-link-failed") }
        XCTAssertTrue(reopened, "the choice is kept")
        XCTAssertFalse(app.buttons["Safari"].exists)
        closeBrowser()
    }

    // MARK: Mouse

    func testMouseReportingSendsTapsToTheProgram() throws {
        try launch()
        // X10/normal mouse tracking on, then show what arrives on stdin.
        app.typeText("clear; printf '\\033[?1000h'; cat -v\n")
        sleep(2)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // A press and a release: ESC [ M <button> <x> <y>.
        wait(screen, "value CONTAINS '^[[M'", timeout: 10, "the program receives the tap as a mouse click")
        shot("mouse-report")
        app.typeKey("c", modifierFlags: .control)
        app.typeText("printf '\\033[?1000l'; clear\n")
    }
}
#endif
