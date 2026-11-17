#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import SwiftUI
import VoiceKit
import XCTest
@testable import App

/// Every control in every Settings pane, clicked or chosen the way a person does: each writes
/// the setting it names and nothing else, and a Settings window opened afterwards shows the
/// choice.
@MainActor
final class SettingsControlsTests: XCTestCase {
    /// A control of the pane, top to bottom, and the setting it writes (nil: shown disabled).
    private struct Expected {
        let kind: ControlKind
        let key: String?
        /// Settings the control may write as well, as part of what it does.
        var alongside: Set<String> = []
        /// Why the control does not yet do what it says.
        var knownIssue: String?
    }

    private static func toggle(_ key: String?, alongside: Set<String> = []) -> Expected {
        Expected(kind: .toggle, key: key, alongside: alongside)
    }
    private static func popUp(_ key: String?) -> Expected { Expected(kind: .popUp, key: key) }

    /// The settings that change which rows a pane shows, put at their defaults so each pane
    /// starts the same whatever the development app had.
    private static let layoutKeys = [
        ThemePair.enabledKey, TerminalPreferences.Key.windowTheme, TerminalPreferences.Key.paneStyle,
        VoiceSettings.enabledKey,
    ]

    private var saved: SavedDefaults?

    override func setUp() async throws {
        saved = SavedDefaults()
        for key in Self.layoutKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        saved?.restore()
    }

    private static let notificationPrefs = "notification-prefs"

    private static let panes: [(SettingsPane, [Expected])] = [
        (.appearance, [
            // Following light and dark mode picks the theme for the system's appearance.
            toggle(ThemePair.enabledKey, alongside: [TerminalPreferences.Key.theme]),
            popUp(TerminalPreferences.Key.sidebarTextSize),
            popUp(ToastPosition.key),
            popUp(ProgramTileTint.key),
            toggle(TabNaming.titleFromShell),
            toggle(TabPlacement.showsTabBarKey),
            toggle(TerminalPreferences.Key.windowTheme),
            // Inset Content Card is for comfortable panes; compact is the default.
            toggle(nil),
            toggle(TerminalPreferences.Key.paneActiveBorder),
            popUp(LaunchTabs.key),
        ]),
        (.terminal, [
            Expected(kind: .stepper, key: TerminalPreferences.Key.fontSize),
            popUp(TerminalPreferences.Key.cursorStyle),
            toggle(TerminalPreferences.Key.cursorBlink),
            Expected(kind: .slider, key: TerminalPreferences.Key.unfocusedSplitOpacity),
            popUp(TerminalPreferences.Key.resizeOverlay),
            popUp(FileLinkOpening.key),
        ]),
        (.keyboard, [
            popUp(KeyboardSettings.optionAsMeta),
            toggle(VoiceSettings.enabledKey),
            popUp(VoiceSettings.localeKey),
        ]),
        (.browser, [
            popUp(SearchEngine.key),
            popUp(WebsiteLanguage.key),
            popUp(SearchRegion.key),
            popUp(BrowserAppearance.key),
            toggle(ReplayStore.enabledKey),
        ]),
        (.notifications, [
            toggle(notificationPrefs), toggle(notificationPrefs), toggle(notificationPrefs),
            toggle(notificationPrefs), toggle(notificationPrefs), toggle(notificationPrefs),
            popUp(notificationPrefs), popUp(notificationPrefs), popUp(notificationPrefs), popUp(notificationPrefs),
            Expected(kind: .toggle, key: MenuBarAgents.key, knownIssue: """
                The menu bar item is taken back as soon as it is put in (MenuBarExtra sets isInserted \
                false again in the test host), so the switch flips back off.
                """),
            toggle(TerminalPreferences.Key.bellFeatures),
        ]),
        (.git, [
            popUp(GitSettings.mergeStrategyKey),
            popUp(GitSettings.autoDeleteDaysKey),
        ]),
    ]

    func testEveryControlWritesTheSettingItNamesAndAReopenedWindowShowsIt() async throws {
        for (pane, expected) in Self.panes {
            let driver = try await SettingsDriver.open(SettingsNavigation(pane: pane))
            defer { driver.close() }
            let controls = driver.controls(.toggle) + driver.controls(.popUp) + driver.controls(.stepper) + driver.controls(.slider)
            let ordered = controls.sorted { driver.frame(of: $0).maxY > driver.frame(of: $1).maxY }
            XCTAssertEqual(ordered.map { kind(of: $0) }, expected.map(\.kind), "\(pane): the pane's controls")
            guard ordered.count == expected.count else { continue }
            for index in expected.indices {
                let baseline = SavedDefaults()
                let control = try XCTUnwrap(currentControl(at: index, in: driver))
                let before = UserDefaults.standard.dictionaryRepresentation()
                let shownBefore = await shown(control, in: driver)
                await operate(control, in: driver)
                let changed = changedKeys(since: before)
                let shownAfter = await shown(control, in: driver)
                var shownAgain: String?
                if expected[index].key != nil {
                    let reopened = try await SettingsDriver.open(SettingsNavigation(pane: pane))
                    if let again = currentControl(at: index, in: reopened) { shownAgain = await shown(again, in: reopened) }
                    reopened.close()
                }
                let isEnabled = (control as? NSControl)?.isEnabled ?? true
                let check = {
                    guard let key = expected[index].key else {
                        XCTAssertFalse(isEnabled, "\(pane) control \(index) is shown disabled")
                        XCTAssertEqual(changed, [], "\(pane) control \(index) is disabled and writes nothing")
                        return
                    }
                    XCTAssertTrue(changed.contains(key) && changed.subtracting([key]).isSubset(of: expected[index].alongside),
                                  "\(pane) control \(index) (\(expected[index].kind)) writes \(key), not \(changed)")
                    if let shownBefore {
                        XCTAssertNotEqual(shownAfter, shownBefore, "\(pane) control \(index) shows the change")
                    }
                    XCTAssertEqual(shownAgain, shownAfter, "\(pane) control \(index): a new Settings window shows \(key) as chosen")
                }
                if let issue = expected[index].knownIssue { XCTExpectFailure(issue, strict: false, failingBlock: check) } else { check() }
                baseline.restore()
                await driver.pump(0.4)
            }
        }
    }

    // MARK: Helpers

    private func kind(of view: NSView) -> ControlKind {
        [ControlKind.toggle, .popUp, .stepper, .slider].first { $0.matches(view) } ?? .focusable
    }

    private func currentControl(at index: Int, in driver: SettingsDriver) -> NSView? {
        let controls = driver.controls(.toggle) + driver.controls(.popUp) + driver.controls(.stepper) + driver.controls(.slider)
        let ordered = controls.sorted { driver.frame(of: $0).maxY > driver.frame(of: $1).maxY }
        return ordered.indices.contains(index) ? ordered[index] : nil
    }

    /// What the control shows: a switch's state, a pop-up's chosen item, a slider's value; nil
    /// for a stepper, whose value is the label beside it.
    private func shown(_ control: NSView, in driver: SettingsDriver) async -> String? {
        switch control {
        case is NSPopUpButton: await driver.chosenTitle(of: control)
        case let toggle as NSSwitch: "\(toggle.state.rawValue)"
        case let slider as NSSlider: "\(slider.doubleValue)"
        default: nil
        }
    }

    /// One click or choice on `control` that changes it.
    private func operate(_ control: NSView, in driver: SettingsDriver) async {
        switch control {
        case is NSPopUpButton:
            await driver.choose(in: control) { $0.state != .on && !$0.isSeparatorItem && $0.isEnabled }
        case let stepper as NSStepper:
            await driver.reveal(stepper)
            let frame = driver.frame(of: stepper)
            await driver.click(CGPoint(x: frame.midX, y: frame.maxY - frame.height / 4))
        case let slider as NSSlider:
            await driver.reveal(slider)
            let frame = driver.frame(of: slider)
            await driver.click(CGPoint(x: frame.minX + frame.width * 0.3, y: frame.midY))
        default:
            await driver.click(control)
        }
        await driver.pump(0.3)
    }

    /// Written by the app's windows as they come and go, not by a setting.
    private static let windowState: Set<String> = ["sidebarShown", "recent-themes"]

    private func changedKeys(since before: [String: Any]) -> Set<String> {
        let now = UserDefaults.standard.dictionaryRepresentation()
        let keys = Set(now.keys).union(before.keys)
        return keys.filter { key in
            switch (before[key], now[key]) {
            case (nil, nil): false
            case let (old?, new?): !(old as AnyObject).isEqual(new)
            default: true
            }
        }
        // Written by AppKit and SwiftUI as windows open and move, not by a setting.
        .filter { !$0.hasPrefix("NS") && !$0.hasPrefix("com.apple") && !$0.hasPrefix("Apple") && !Self.windowState.contains($0) }
    }
}

#endif
