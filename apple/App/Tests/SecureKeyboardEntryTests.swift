#if os(macOS)
import AppKit
import Carbon
import XCTest
@testable import App

/// Secure Keyboard Entry follows the panes at a password prompt: on while one wants it and the
/// app is active, off as soon as none does or the app resigns, and every enable balanced.
@MainActor
final class SecureKeyboardEntryTests: XCTestCase {
    private var calls: [String] = []
    private var isActive = true
    private var notifications: NotificationCenter!
    private var entry: SecureKeyboardEntry!

    override func setUp() async throws {
        calls = []
        isActive = true
        notifications = NotificationCenter()
        entry = SecureKeyboardEntry(
            system: SecureKeyboardEntry.System(
                enable: { [unowned self] in calls.append("enable"); return noErr },
                disable: { [unowned self] in calls.append("disable"); return noErr },
                isAppActive: { [unowned self] in isActive }),
            notifications: notifications)
    }

    private var balance: Int {
        calls.reduce(0) { $0 + ($1 == "enable" ? 1 : -1) }
    }

    func testItIsOnOnlyWhileAPaneWantsIt() {
        let first = UUID(), second = UUID()

        entry.set(first, wanted: false)
        XCTAssertEqual(calls, [])
        entry.set(first, wanted: true)
        entry.set(second, wanted: true)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(calls, ["enable"], "one enable however many panes want it")

        entry.set(first, wanted: false)
        XCTAssertTrue(entry.isEnabled)
        entry.remove(second)
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(calls, ["enable", "disable"])
    }

    func testItIsGivenUpWhileTheAppIsNotActive() {
        let pane = UUID()
        entry.set(pane, wanted: true)

        isActive = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(balance, 0)

        entry.set(pane, wanted: true)
        XCTAssertEqual(calls, ["enable", "disable"], "nothing while inactive")

        isActive = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(calls, ["enable", "disable", "enable"])

        entry.remove(pane)
        XCTAssertEqual(balance, 0)
    }

    func testAPaneThatLeftWhileInactiveIsNotTurnedBackOn() {
        let pane = UUID()
        entry.set(pane, wanted: true)
        isActive = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        entry.remove(pane)

        isActive = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(calls, ["enable", "disable"])
    }

    func testAFailedCallLeavesTheStateAsItWas() {
        let failing = SecureKeyboardEntry(
            system: SecureKeyboardEntry.System(
                enable: { OSStatus(paramErr) }, disable: { noErr }, isAppActive: { true }),
            notifications: notifications)
        let pane = UUID()

        failing.set(pane, wanted: true)
        XCTAssertFalse(failing.isEnabled)
        failing.remove(pane)
        XCTAssertFalse(failing.isEnabled, "no disable for an enable that failed")
    }
}
#endif
