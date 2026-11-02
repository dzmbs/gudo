import XCTest
@testable import App

/// Test and tooling launches keep their hosts and secrets away from the user's.
final class AppDataTests: XCTestCase {
    private let temporary = URL(fileURLWithPath: "/tmp/t", isDirectory: true)

    private func directory(_ arguments: [String: Any] = [:], flags: [String] = [], environment: [String: String] = [:]) -> URL? {
        AppData.isolatedDirectory(
            arguments: arguments, flags: flags, environment: environment, temporary: temporary, bundleId: "dev.x.app")
    }

    func testAPlainLaunchUsesTheUsersData() {
        XCTAssertNil(directory())
        XCTAssertNil(directory(["ApplePersistenceIgnoreState": "YES", "theme": "Dark"]))
    }

    func testAnExplicitFolderWins() {
        XCTAssertEqual(directory(["hostsDirectory": "/tmp/h", "testTicket": "t"])?.path, "/tmp/h")
    }

    func testPairingAndToolingLaunchesAreIsolated() {
        let shared = temporary.appending(path: "dev.x.app.test-data").path
        for key in ["testTicket", "testTickets", "testSSH", "testRelay", "dogfood", "snapshot", "screen", "localEcho"] {
            XCTAssertEqual(directory([key: "x"])?.path, shared, key)
        }
        XCTAssertEqual(directory(flags: ["/app", "-mock"])?.path, shared)
    }

    func testTestRunnersAreIsolated() {
        let unit = temporary.appending(path: "dev.x.app.unit-test-data").path
        XCTAssertEqual(directory(environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"])?.path, unit)
        XCTAssertEqual(directory(environment: ["XCTestSessionIdentifier": "1"])?.path, unit)
        // Hosts that UI tests paired never reach the hosted unit tests.
        XCTAssertNotEqual(unit, directory(["testTicket": "t"])?.path)
    }

    func testThisRunIsIsolated() {
        // Hosted unit tests run inside the app: they must not load the user's hosts either.
        XCTAssertTrue(AppData.isIsolated)
    }
}
