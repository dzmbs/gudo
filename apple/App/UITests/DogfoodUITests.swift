#if os(iOS)
import XCTest

/// Thin XCUITest adapter for dogfood scenarios (apple/Dogfood/README.md) on the iPad simulator,
/// where XCUITest needs no approval. It runs the steps XCUITest can express — type, key/shortcut,
/// paste, waitText (any pane's accessibility value, which is its visible text), assert
/// panes/tabs, sleep, screenshot — and skips the rest (process, PTY and mouse steps exist only
/// in the in-app macOS runner). Runs only when a scenario is given:
///
///     TEST_RUNNER_DOGFOOD_SCENARIO=$PWD/Dogfood/ios-smoke.json TEST_RUNNER_DOGFOOD_OUT=/tmp/out \
///       xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$DEVICE" \
///       -only-testing:AppUITests/DogfoodUITests
final class DogfoodUITests: XCTestCase {
    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    @MainActor
    func testScenario() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DOGFOOD_SCENARIO"] else { throw XCTSkip("set TEST_RUNNER_DOGFOOD_SCENARIO") }
        let outputDirectory = environment["DOGFOOD_OUT"].map { URL(fileURLWithPath: $0) }
        if let outputDirectory { try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true) }
        let scenario = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])

        let app = XCUIApplication()
        app.launchArguments += (scenario["iosLaunchArguments"] as? [String] ?? []) + ["-localEcho", "YES"]
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        // Focus the terminal (hardware-keyboard input, as the other UI tests do).
        pane.tap()

        var results: [[String: Any]] = []
        for testCase in scenario["cases"] as? [[String: Any]] ?? [] {
            let name = testCase["name"] as? String ?? "case"
            var passed = true
            var steps: [[String: Any]] = []
            for (index, step) in (testCase["steps"] as? [[String: Any]] ?? []).enumerated() {
                let action = step["do"] as? String ?? "?"
                var record: [String: Any] = ["index": index, "action": action]
                do {
                    record["detail"] = try perform(action, step, app: app, outputDirectory: outputDirectory, caseName: name)
                    record["passed"] = true
                } catch {
                    record["passed"] = false
                    let screens = Self.paneTexts(app).map { String($0.suffix(300)) }.joined(separator: " || ")
                    record["error"] = "\(error) | panes: \(screens)"
                    let shot = app.screenshot()
                    let attachment = XCTAttachment(screenshot: shot)
                    attachment.name = "FAIL-\(name)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    if let outputDirectory { try? shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("FAIL-\(name).png")) }
                    passed = false
                }
                steps.append(record)
                if !passed { break }
            }
            results.append(["name": name, "passed": passed, "steps": steps])
            XCTAssertTrue(passed, "\(name): \(steps.last?["error"] ?? "")")
        }
        if let outputDirectory {
            let report: [String: Any] = ["scenario": path, "platform": "ios-xcuitest", "cases": results,
                                         "passed": results.allSatisfy { $0["passed"] as? Bool == true }]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: outputDirectory.appendingPathComponent("report.json"))
        }
    }

    @MainActor
    private func perform(_ action: String, _ step: [String: Any], app: XCUIApplication, outputDirectory: URL?, caseName: String) throws -> String {
        switch action {
        case "type":
            let text = step["text"] as? String ?? ""
            // Needs the focused terminal (tapped at launch); "\n" is Return.
            app.typeText(text)
            return "\(text.count) characters"
        case "key", "shortcut":
            let spec = (step["key"] ?? step["keys"]) as? String ?? ""
            let (key, flags) = try Self.parse(spec)
            switch key {
            case .named(let named): app.typeKey(named, modifierFlags: flags)
            case .text(let text): app.typeKey(text, modifierFlags: flags)
            }
            return spec
        case "paste":
            UIPasteboard.general.string = step["text"] as? String ?? ""
            app.typeKey("v", modifierFlags: .command)
            return "pasted"
        case "waitText":
            let needle = step["text"] as? String
            let regex = try (step["regex"] as? String).map { try NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
            let absent = step["absent"] as? Bool == true
            let deadline = Date().addingTimeInterval(step["timeout"] as? Double ?? 10)
            repeat {
                let found = Self.paneTexts(app).contains { text in
                    if let needle { return text.contains(needle) }
                    if let regex { return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
                    return false
                }
                if found != absent { return needle ?? regex?.pattern ?? "" }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            throw Failure(description: "\(absent ? "still showing" : "never saw") \(needle ?? regex?.pattern ?? "")")
        case "assert":
            if let panes = step["panes"] as? Int {
                let count = Set(Self.panes(app).map { $0.identifier }).count
                guard count == panes else { throw Failure(description: "\(count) panes, expected \(panes)") }
                return "\(count) panes"
            }
            return "assertion not supported on iOS (skipped)"
        case "sleep":
            Thread.sleep(forTimeInterval: step["seconds"] as? Double ?? 1)
            return ""
        case "screenshot":
            let name = step["name"] as? String ?? caseName
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let outputDirectory { try shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name).png")) }
            return name
        default:
            return "\(action): macOS runner only (skipped)"
        }
    }

    /// Each pane's screen element ("pane-<n>-screen"), whose value is its visible text.
    @MainActor private static func panes(_ app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+-screen'"))
            .allElementsBoundByIndex
    }

    @MainActor private static func paneTexts(_ app: XCUIApplication) -> [String] {
        panes(app).compactMap { $0.value as? String }
    }

    private enum Key { case named(XCUIKeyboardKey), text(String) }

    private static func parse(_ spec: String) throws -> (Key, XCUIElement.KeyModifierFlags) {
        var parts = spec.split(separator: "+").map(String.init)
        let name = parts.removeLast()
        var flags: XCUIElement.KeyModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            case "opt", "alt": flags.insert(.option)
            default: throw Failure(description: "unknown modifier \(modifier)")
            }
        }
        let named: [String: XCUIKeyboardKey] = [
            "return": .return, "escape": .escape, "tab": .tab, "backspace": .delete, "space": .space,
            "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
        ]
        return (named[name].map(Key.named) ?? .text(name), flags)
    }
}
#endif
