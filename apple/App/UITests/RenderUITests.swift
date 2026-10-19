#if os(iOS)
import UIKit
import XCTest

/// The terminal draws its text, not only the cursor, every time it comes up: first launch and
/// relaunches that restore the host (seen on Hetzner: after a relaunch only the cursor showed).
/// Checks pixels, since the accessibility value comes from the model and stays right either way.
/// The bug: a remote pane resized by layout while output from the old size was in flight, and
/// bash's prompt redraw at the wrong size wiped the line (zsh reprints its prompt, hiding it).
/// Run the daemon with bash: `SHELL=/bin/bash apple/scripts/local-daemon.sh start`, and pass the
/// ticket as `TEST_RUNNER_PAIR_TICKET`.
@MainActor
final class RenderUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testTextIsDrawnAfterEveryRelaunch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled"]
        app.launch()
        let pane = paneElement(app)
        XCTAssertTrue(pane.waitForExistence(timeout: 30))
        pane.tap()
        app.typeText("printf 'INK%.0s' $(seq 1 30)\n")
        let screen = app.descendants(matching: .any)[pane.identifier + "-screen"].firstMatch
        expectation(for: NSPredicate(format: "value CONTAINS 'INKINKINK'"), evaluatedWith: screen)
        waitForExpectations(timeout: 20)
        try assertInk(app, pane, "first launch")

        for round in 1...3 {
            app.terminate()
            app.launchArguments = ["-restoreLastTarget", "YES", "-testRelay", "disabled"]
            app.launch()
            let restored = paneElement(app)
            XCTAssertTrue(restored.waitForExistence(timeout: 30), "relaunch \(round): a pane")
            // The keyboard comes up and the pane shrinks: the resize that wiped the prompt.
            restored.tap()
            let restoredScreen = app.descendants(matching: .any)[restored.identifier + "-screen"].firstMatch
            expectation(for: NSPredicate(format: "value CONTAINS 'INKINKINK'"), evaluatedWith: restoredScreen)
            waitForExpectations(timeout: 30)
            try assertInk(app, restored, "relaunch \(round)")
        }
    }

    private func paneElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
    }

    /// The pane's top rows hold text: enough pixels differ clearly from the background.
    private func assertInk(_ app: XCUIApplication, _ pane: XCUIElement, _ when: String) throws {
        // Let a frame or two land.
        Thread.sleep(forTimeInterval: 1.5)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "ink-\(when)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let frame = pane.frame
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: min(frame.height, 160) * scale).integral
        let crop = try XCTUnwrap(image.cropping(to: rect))
        let ink = Self.inkFraction(crop)
        XCTAssertGreaterThan(ink, 0.004, "\(when): the pane's text is drawn (ink \(ink))")
    }

    /// The share of pixels whose brightness differs from the most common (background) pixel.
    private static func inkFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts: [Int: Int] = [:]
        var lumas = [Int](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let luma = (Int(pixels[i * 4]) * 3 + Int(pixels[i * 4 + 1]) * 6 + Int(pixels[i * 4 + 2])) / 10
            lumas[i] = luma
            counts[luma, default: 0] += 1
        }
        let background = counts.max { $0.value < $1.value }?.key ?? 0
        let inked = lumas.filter { abs($0 - background) > 40 }.count
        return Double(inked) / Double(max(lumas.count, 1))
    }
}
#endif
