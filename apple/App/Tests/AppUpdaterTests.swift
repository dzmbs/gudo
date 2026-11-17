#if os(macOS)
import Sparkle
import XCTest
@testable import App

/// The Mac app's updates: the menu item, the palette and Settings ▸ About drive Sparkle's updater.
@MainActor
final class AppUpdaterTests: XCTestCase {
    private final class FakeUpdater: UpdateChecking {
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var allowsAutomaticUpdates: Bool { automaticallyChecksForUpdates }
        var checks = 0
        func checkForUpdates() { checks += 1 }
    }

    private var savedShared: AppUpdater!

    override func setUp() {
        savedShared = AppUpdater.shared
    }

    override func tearDown() {
        AppUpdater.shared = savedShared
    }

    func testDebugAndTestBuildsDoNotUpdateThemselves() {
        XCTAssertFalse(savedShared.isAvailable)
        XCTAssertFalse(savedShared.canCheckForUpdates)
        savedShared.checkForUpdates()
    }

    func testTheInfoPlistNamesTheFeedAndKey() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, "https://gudo.dev/appcast.xml")
        let key = try? XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        XCTAssertEqual(key.flatMap { Data(base64Encoded: $0) }?.count, 32, "an Ed25519 public key")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
    }

    func testSettingsSwitchesReachTheUpdater() {
        let fake = FakeUpdater()
        let updater = AppUpdater(updater: fake)
        XCTAssertTrue(updater.isAvailable)
        XCTAssertTrue(updater.checksAutomatically)
        XCTAssertTrue(updater.allowsAutomaticDownloads)

        updater.downloadsAutomatically = true
        XCTAssertTrue(fake.automaticallyDownloadsUpdates)
        updater.checksAutomatically = false
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.allowsAutomaticDownloads, "downloads follow automatic checks")
    }

    func testMenuItemChecksAndFollowsTheUpdater() {
        let fake = FakeUpdater()
        let updater = AppUpdater(updater: fake)
        XCTAssertEqual(AppUpdater.checkTitle, "Check for Updates…")
        updater.checkForUpdates()
        XCTAssertEqual(fake.checks, 1)

        fake.canCheckForUpdates = false
        XCTAssertFalse(AppUpdater(updater: fake).canCheckForUpdates, "off while Sparkle is busy")
    }

    func testPaletteOffersACheckOnlyInBuildsThatUpdate() throws {
        let window = WindowModel(app: .shared)
        window.start()
        defer { window.close() }
        let workspace = try XCTUnwrap(window.workspace)
        XCTAssertFalse(PaletteCommands.all(workspace: workspace, model: window).contains { $0.id == "check-for-updates" })

        let fake = FakeUpdater()
        AppUpdater.shared = AppUpdater(updater: fake)
        let command = PaletteCommands.all(workspace: workspace, model: window).first { $0.id == "check-for-updates" }
        XCTAssertEqual(command?.title, "Check for Updates")
        command?.action()
        XCTAssertEqual(fake.checks, 1)
    }
}
#endif
