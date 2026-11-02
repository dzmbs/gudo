#if os(iOS)
import UIKit
import XCTest

/// Lifecycle under load, on a paired local daemon: a flooding pane among several splits goes
/// through background/foreground cycles and a rotation storm while memory warnings arrive from
/// outside, and afterwards it still draws its text and takes input.
/// Run with `apple/scripts/lifecycle-stress.sh` (makes its own simulator and daemon, sends the
/// memory warnings, samples the app's footprint, deletes the simulator).
@MainActor
final class LifecycleStressUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testPanesSurviveLifecycleChurnUnderLoad() throws {
        let env = ProcessInfo.processInfo.environment
        let ticket = env["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        let cycles = env["CYCLES"].flatMap(Int.init) ?? 10
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled"]
        app.launch()
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        let paneId = first.identifier
        first.tap()
        // A flood that runs until interrupted, in the first pane.
        app.typeText("while :; do seq 1 100000; done\n")
        // More panes on screen: each split takes the keyboard.
        for _ in 0..<3 {
            app.typeKey("d", modifierFlags: .command)
            app.typeKey("d", modifierFlags: [.command, .shift])
        }
        Thread.sleep(forTimeInterval: 2)

        for round in 0..<cycles {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: round.isMultiple(of: 3) ? 2 : 0.3)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "round \(round): back in front")
        }
        for turn in 0..<(cycles * 2) {
            XCUIDevice.shared.orientation = turn.isMultiple(of: 2) ? .portrait : .landscapeLeft
        }
        XCUIDevice.shared.orientation = .landscapeLeft

        // The flooding pane still takes input and draws.
        let pane = app.descendants(matching: .any)[paneId].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        app.typeKey("c", modifierFlags: .control)
        app.typeText("clear; printf 'INK%.0s' $(seq 1 30)\n")
        let screen = app.descendants(matching: .any)[paneId + "-screen"].firstMatch
        expectation(for: NSPredicate(format: "value CONTAINS 'INKINKINK'"), evaluatedWith: screen)
        waitForExpectations(timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let frame = pane.frame
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: min(frame.height, 160) * scale)
        let crop = try XCTUnwrap(image.cropping(to: rect.integral))
        XCTAssertGreaterThan(Self.inkFraction(crop), 0.004, "the pane's text is drawn after the churn")
    }

    /// The share of pixels whose brightness differs clearly from the most common one.
    private static func inkFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lumas = [Int](repeating: 0, count: width * height)
        var counts: [Int: Int] = [:]
        for i in 0..<(width * height) {
            let luma = (Int(pixels[i * 4]) * 3 + Int(pixels[i * 4 + 1]) * 6 + Int(pixels[i * 4 + 2])) / 10
            lumas[i] = luma
            counts[luma, default: 0] += 1
        }
        let background = counts.max { $0.value < $1.value }?.key ?? 0
        return Double(lumas.filter { abs($0 - background) > 60 }.count) / Double(max(1, lumas.count))
    }
}
#endif
