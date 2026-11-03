import WebKit
import XCTest
@testable import App

/// VS Code on a phone: the window it is laid out in, the defaults it gets and the keys it is sent.
@MainActor
final class EditorPhoneLayoutTests: XCTestCase {
    /// Editor panes on iPhones from the 12 mini to the 17 Pro Max: under the tab bar in portrait,
    /// beside the app's sidebar in landscape.
    func testPortraitPhonesLayOutAboutSixHundredPointsWide() {
        for width: CGFloat in [375, 390, 393, 402, 414, 428, 430, 440] {
            let size = CGSize(width: width, height: 600)
            let scale = EditorPhoneLayout.scale(for: size)
            XCTAssertGreaterThanOrEqual(scale, EditorPhoneLayout.minimumScale, "\(width)")
            XCTAssertLessThan(scale, 0.8, "\(width)")
            let layoutWidth = width / scale
            XCTAssertGreaterThanOrEqual(layoutWidth, 560, "\(width) lays out \(layoutWidth)")
            XCTAssertLessThanOrEqual(layoutWidth, 640, "\(width) lays out \(layoutWidth)")
        }
    }

    func testLandscapeFitsTheRowsNotJustTheWidth() {
        let scale = EditorPhoneLayout.scale(for: CGSize(width: 560, height: 330))
        XCTAssertEqual(scale, 0.8, accuracy: 0.001)
        XCTAssertEqual(EditorPhoneLayout.scale(for: CGSize(width: 900, height: 700)), 1, "a big pane is drawn at actual size")
    }

    func testScaleMovesInStepsSoSmallChangesDoNotReflow() {
        XCTAssertEqual(EditorPhoneLayout.scale(for: CGSize(width: 402, height: 700)),
                       EditorPhoneLayout.scale(for: CGSize(width: 400, height: 690)))
        XCTAssertEqual(EditorPhoneLayout.scale(for: .zero), 1)
    }

    func testViewportIsThePaneAtAFixedScale() throws {
        let viewport = try XCTUnwrap(EditorPhoneLayout.viewport(for: CGSize(width: 390, height: 700)))
        XCTAssertEqual(viewport, "width=600, initial-scale=0.65, minimum-scale=0.65, maximum-scale=0.65, user-scalable=no, viewport-fit=cover")
        XCTAssertNil(EditorPhoneLayout.viewport(for: CGSize(width: 0, height: 700)))
    }

    func testZoomScalesTheFitAndStopsAtTheEnds() throws {
        let size = CGSize(width: 390, height: 700)
        XCTAssertEqual(EditorPhoneLayout.scale(for: size, zoom: 1.3), 0.8, accuracy: 0.001)
        XCTAssertEqual(EditorPhoneLayout.scale(for: size, zoom: 0.8), 0.5, accuracy: 0.001)
        XCTAssertEqual(EditorPhoneLayout.zoom(from: 1, by: 1), 1.15)
        XCTAssertEqual(EditorPhoneLayout.zoom(from: 1, by: -1), 0.9)
        XCTAssertNil(EditorPhoneLayout.zoom(from: 1.5, by: 1))
        XCTAssertNil(EditorPhoneLayout.zoom(from: 0.8, by: -1))
        XCTAssertEqual(EditorPhoneLayout.zoom(from: 1.07, by: 1), 1, "an unknown stored zoom starts over")
    }

    /// Defaults, never the user's settings: the page's own `configurationDefaults` (if a server
    /// sends any) win over them, and VS Code puts the user's settings over both.
    func testSettingsGoIntoTheWorkbenchConfigurationAsDefaults() throws {
        let source = EditorPhoneLayout.userScriptSource
        XCTAssertTrue(source.contains("vscode-workbench-web-configuration"))
        XCTAssertTrue(source.contains("configuration.configurationDefaults = Object.assign({}, defaults, configuration.configurationDefaults || {})"))
        for key in ["editor.wordWrap", "editor.minimap.enabled", "workbench.activityBar.location", "workbench.secondarySideBar.defaultVisibility"] {
            XCTAssertTrue(source.contains("\"\(key)\""), key)
        }
        XCTAssertEqual(EditorPhoneLayout.settings["editor.wordWrap"] as? String, "on")
        XCTAssertEqual(EditorPhoneLayout.settings["editor.minimap.enabled"] as? Bool, false)
        XCTAssertEqual(EditorPhoneLayout.userScript.injectionTime, .atDocumentStart)
        XCTAssertTrue(EditorPhoneLayout.userScript.isForMainFrameOnly)
    }

    func testCommandsPressVSCodesDefaultKeys() {
        XCTAssertEqual(EditorPhoneLayout.Command.quickOpen.key, EditorPhoneLayout.Key(code: "KeyP", key: "p", keyCode: 80, meta: true))
        XCTAssertEqual(EditorPhoneLayout.Command.commandPalette.key.shift, true)
        XCTAssertEqual(EditorPhoneLayout.Command.explorer.sidebarView, "workbench.view.explorer")
        XCTAssertNil(EditorPhoneLayout.Command.quickOpen.sidebarView)
        let explorer = EditorPhoneLayout.script(for: .explorer)
        XCTAssertTrue(explorer.contains("if (sidebarView() === 'workbench.view.explorer') { press(\(EditorPhoneLayout.Key.toggleSidebar.json)); return; }"),
                      "a second tap hides the sidebar")
        XCTAssertFalse(EditorPhoneLayout.script(for: .quickOpen).contains("sidebarView() ==="))
    }

    func testKeyRowSendsTheKeysTheSoftwareKeyboardLacks() {
        XCTAssertEqual(EditorPhoneLayout.Key.row.map(\.accessibilityLabel), ["Escape", "Tab", "Left", "Down", "Up", "Right"])
        XCTAssertEqual(EditorPhoneLayout.Key.escape.label, "esc")
        XCTAssertEqual(EditorPhoneLayout.Key.down.symbol, "arrow.down")
        XCTAssertEqual(EditorPhoneLayout.Key.down.json, "{code:'ArrowDown',key:'ArrowDown',keyCode:40,metaKey:false,shiftKey:false,ctrlKey:false,altKey:false}")
    }

    func testViewportScriptQuotesItsContent() {
        let script = EditorPhoneLayout.viewportScript("width=600, initial-scale=0.65")
        XCTAssertTrue(script.contains("const content = \"width=600, initial-scale=0.65\";"))
        XCTAssertTrue(script.contains("-webkit-text-size-adjust: 100%"))
    }

    func testOnlyPhoneBrowsersGetThePhoneLayout() {
        let phone = TunnelBrowser(dataStore: .nonPersistent(), phoneLayout: true)
        let other = TunnelBrowser(dataStore: .nonPersistent())
        let phoneScripts = phone.webView.configuration.userContentController.userScripts.map(\.source)
        let otherScripts = other.webView.configuration.userContentController.userScripts.map(\.source)
        XCTAssertTrue(phoneScripts.contains(EditorPhoneLayout.userScriptSource))
        XCTAssertFalse(otherScripts.contains(EditorPhoneLayout.userScriptSource))
        XCTAssertEqual(otherScripts.count, 1, "only the reconnect watcher")
        #if os(iOS)
        XCTAssertNotNil((phone.webView as? EditorWebView)?.keyRow)
        XCTAssertFalse(other.webView is EditorWebView)
        #endif

        phone.fit(to: CGSize(width: 390, height: 700))
        let fitted = phone.webView.configuration.userContentController.userScripts.map(\.source)
        XCTAssertTrue(fitted.contains { $0.contains("width=600, initial-scale=0.65") }, "later loads start at the fitted viewport")
        other.fit(to: CGSize(width: 390, height: 700))
        XCTAssertEqual(other.webView.configuration.userContentController.userScripts.count, 1)
    }
}
