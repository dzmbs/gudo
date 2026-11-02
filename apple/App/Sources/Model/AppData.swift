import Foundation

/// Where the app keeps its data. Test and tooling launches get a folder of their own so they
/// never read or change the user's hosts.
nonisolated enum AppData {
    /// The test folder, or nil for the user's own data.
    static let isolatedDirectory: URL? = isolatedDirectory(
        arguments: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain),
        flags: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment,
        temporary: FileManager.default.temporaryDirectory,
        bundleId: Bundle.main.bundleIdentifier ?? "app")

    static var isIsolated: Bool { isolatedDirectory != nil }

    /// `-hostsDirectory <path>` names the folder; otherwise test launches get one under the temporary directory.
    static func isolatedDirectory(
        arguments: [String: Any], flags: [String], environment: [String: String], temporary: URL, bundleId: String
    ) -> URL? {
        if let path = arguments["hostsDirectory"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let byArgument = arguments.keys.contains { key in
            key.hasPrefix("test") || toolingArguments.contains(key)
        }
        let byFlag = flags.contains("-mock")
        let byEnvironment = testEnvironment.contains { environment[$0] != nil }
        guard byArgument || byFlag || byEnvironment else { return nil }
        // Hosted unit tests get a folder apart from the launches UI tests make, whose paired
        // daemons and windows would otherwise show up in the unit tests' models.
        let name = byArgument || byFlag ? "test-data" : "unit-test-data"
        return temporary.appending(path: "\(bundleId).\(name)", directoryHint: .isDirectory)
    }

    /// Launch arguments only tests, dogfood runs and scripts pass (besides every `-test…`).
    static let toolingArguments: Set<String> = [
        "dogfood", "snapshot", "screen", "localEcho", "fakeUsage", "fixtureTabs", "drawingDemo", "echoFixture",
    ]

    /// Set by XCTest in a process it runs tests in.
    static let testEnvironment = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    static var replays: URL {
        (isolatedDirectory ?? URL.applicationSupportDirectory).appending(path: "Replays", directoryHint: .isDirectory)
    }
}
