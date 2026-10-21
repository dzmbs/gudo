#if os(iOS)
import PaneLayout
import UIKit
import XCTest
@testable import App

/// The external display (docs/APP-ARCHITECTURE.md "Windows", `Windows/ExternalDisplay.swift`).
/// The simulator cannot attach a display from the command line (only from Simulator's
/// I/O menu), so this checks the scene layer: which scene an external display gets, which tab
/// it mirrors, and the font that makes the iPad's grid fill it.
@MainActor
final class ExternalDisplayTests: XCTestCase {
    func testOnlyANonInteractiveExternalDisplayGetsThePresentationScene() throws {
        let configuration = try XCTUnwrap(ExternalDisplay.configuration(for: .windowExternalDisplayNonInteractive))
        XCTAssertEqual(configuration.role, .windowExternalDisplayNonInteractive)
        XCTAssertTrue(configuration.delegateClass == ExternalDisplaySceneDelegate.self)
        // Every other scene (iPad windows, Stage Manager windows on the display) is SwiftUI's.
        XCTAssertNil(ExternalDisplay.configuration(for: .windowApplication))
    }

    func testTheDisplayMirrorsTheIPadsTabAndAMixedTabsFocusedHost() {
        let tab = TabRef(hostId: "studio", tab: TabId(4))
        XCTAssertEqual(ExternalDisplay.mirroredTab(current: tab, activeTab: TabId(4), focusedGroup: "studio"), tab)
        // A mixed tab belongs to its window: the display shows the focused pane's host tab.
        let mixed = TabRef(hostId: HostGroups.mixedId, tab: TabId(1))
        XCTAssertEqual(
            ExternalDisplay.mirroredTab(current: mixed, activeTab: TabId(7), focusedGroup: "build-box"),
            TabRef(hostId: "build-box", tab: TabId(7)))
        XCTAssertNil(ExternalDisplay.mirroredTab(current: mixed, activeTab: nil, focusedGroup: "build-box"))
        XCTAssertNil(ExternalDisplay.mirroredTab(current: nil, activeTab: TabId(7), focusedGroup: "studio"))
    }

    func testTheFontScalesTheIPadsGridToTheDisplay() {
        // A 13" iPad terminal area on a 1080p display: limited by height (1080 / 900 = 1.2).
        XCTAssertEqual(ExternalDisplay.fontSize(14, presenterArea: CGSize(width: 1100, height: 900), display: CGSize(width: 1920, height: 1080)), 16)
        // Wider than tall: limited by width, never a column short (rounded down, 1 % under).
        XCTAssertEqual(ExternalDisplay.fontSize(13, presenterArea: CGSize(width: 1000, height: 400), display: CGSize(width: 2000, height: 2000)), 25)
        // Not laid out yet: no change.
        XCTAssertNil(ExternalDisplay.fontSize(13, presenterArea: .zero, display: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(ExternalDisplay.fontSize(13, presenterArea: CGSize(width: 800, height: 600), display: .zero))
    }

    /// The scene a real external display gets: a presentation window model that shows a
    /// terminal only and never takes the keyboard.
    func testThePresentationWindowIsAPresentation() {
        let model = WindowModel(app: AppModel.shared, isPresentation: true)
        XCTAssertTrue(model.isPresentation)
        model.close()
    }
}
#endif
