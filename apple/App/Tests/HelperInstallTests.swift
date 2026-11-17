#if os(macOS)
import XCTest
@testable import App

/// The helper copied out of the bundle into `Helper/Versions`: checked by running the copy,
/// swapped into `Current` without touching the file a running helper started from, and old
/// builds pruned.
final class HelperInstallTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "hi-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A stand-in helper that reports the hash of its own file, as `build-info --json --hash` does;
    /// `build` makes each build's bytes differ.
    private func bundledHelper(build: String, reports report: String? = nil, builtUnix: UInt64? = nil) throws -> URL {
        let app = folder.appending(path: "App-\(build).app/Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let helper = app.appending(path: "gudo-hostd")
        let hash = report.map { "'\($0)'" } ?? #""$(/usr/bin/shasum -a 256 "$0" | /usr/bin/cut -d' ' -f1)""#
        let info = builtUnix.map { #","version":"0.1.\#($0)","build":"\#(build)","built_unix":\#($0),"protocol":1"# } ?? ""
        let script = """
            #!/bin/sh
            # build \(build)
            [ "$1" = build-info ] && printf '{"exe_sha256":"%s"\(info)}\\n' \(hash)
            exit 0

            """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private var state: URL { folder.appending(path: "state", directoryHint: .isDirectory) }

    private func install(_ bundled: URL, version: String = "7") -> HelperInstall {
        HelperInstall(bundled: bundled, stateDirectory: state, bundleVersion: version)
    }

    func testTheBundledBuildIsCopiedCheckedAndMadeCurrent() async throws {
        let bundled = try bundledHelper(build: "a")
        let quarantine = "0081;00000000;Safari;"
        XCTAssertEqual(setxattr(bundled.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0), 0)

        let current = try await install(bundled).install()

        let versions = state.appending(path: "Helper/Versions", directoryHint: .isDirectory)
        XCTAssertEqual(current, versions.appending(path: "Current/gudo-hostd"))
        XCTAssertEqual(try Data(contentsOf: current), try Data(contentsOf: bundled))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: current.path))
        XCTAssertEqual(getxattr(current.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "out of quarantine")
        let identity = try HelperInstall.codeIdentity(of: bundled)
        let names = try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted()
        XCTAssertEqual(names, ["7-\(identity.prefix(12))", "Current"])
    }

    func testTheSameBuildAgainLeavesCurrentAlone() async throws {
        let bundled = try bundledHelper(build: "a")
        let current = try await install(bundled).install()
        let before = try FileManager.default.attributesOfItem(atPath: current.path)[.systemFileNumber] as? Int

        _ = try await install(bundled).install()

        let after = try FileManager.default.attributesOfItem(atPath: current.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after)
    }

    func testANewBuildIsSwappedInWhileTheRunningOneKeepsItsFile() async throws {
        let current = try await install(try bundledHelper(build: "a")).install()
        let running = try FileHandle(forReadingFrom: current)
        defer { try? running.close() }
        let before = try FileManager.default.attributesOfItem(atPath: current.path)[.systemFileNumber] as? Int

        let newer = try bundledHelper(build: "b")
        _ = try await install(newer, version: "8").install()

        XCTAssertEqual(try Data(contentsOf: current), try Data(contentsOf: newer), "Current is the new build")
        let after = try FileManager.default.attributesOfItem(atPath: current.path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(before, after, "a new file at the path, never the old one written over")
        let kept = String(decoding: try running.readToEnd() ?? Data(), as: UTF8.self)
        XCTAssertTrue(kept.contains("# build a"), "the running helper's file is as it was")
    }

    func testANewerBuildInCurrentIsKeptWhenAnOlderAppStarts() async throws {
        let current = try await install(try bundledHelper(build: "b", builtUnix: 200), version: "8").install()
        let newer = try Data(contentsOf: current)

        let kept = try await install(try bundledHelper(build: "a", builtUnix: 100), version: "7").install()

        XCTAssertEqual(kept, current)
        XCTAssertEqual(try Data(contentsOf: kept), newer, "never swapped back to the older build")
    }

    func testCurrentThatLostItsBuildIsRepaired() async throws {
        let bundled = try bundledHelper(build: "a", builtUnix: 100)
        let current = try await install(bundled).install()
        try FileManager.default.removeItem(at: current)

        let repaired = try await install(bundled).install()

        XCTAssertEqual(try Data(contentsOf: repaired), try Data(contentsOf: bundled))
    }

    func testACopyThatIsNotTheBuildInTheAppIsRefused() async throws {
        let bundled = try bundledHelper(build: "a", reports: String(repeating: "0", count: 64))
        do {
            _ = try await install(bundled).install()
            XCTFail("installed a copy that reports another build")
        } catch {
            XCTAssertEqual(error as? HelperInstallError, .copyDiffers)
        }
        let versions = state.appending(path: "Helper/Versions", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: versions.appending(path: "Current").path))
    }

    func testOldBuildsArePrunedKeepingCurrentAndTheOneBefore() async throws {
        for (build, version) in [("a", "1"), ("b", "2"), ("c", "3")] {
            _ = try await install(try bundledHelper(build: build), version: version).install()
            try await Task.sleep(for: .milliseconds(20))
        }
        let versions = state.appending(path: "Helper/Versions", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted()
        XCTAssertEqual(names.count, 3, "\(names)")
        XCTAssertTrue(names.contains("Current"))
        XCTAssertTrue(names.contains { $0.hasPrefix("3-") })
        XCTAssertTrue(names.contains { $0.hasPrefix("2-") })
    }

    func testPruningSparesCurrentTheKeptBuildTheNewestOtherAndFreshStaging() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries = [
            HelperInstall.Entry(name: "Current", modified: now.addingTimeInterval(-9000)),
            .init(name: "5-aaa", modified: now.addingTimeInterval(-10)),
            .init(name: "4-bbb", modified: now.addingTimeInterval(-500)),
            .init(name: "3-ccc", modified: now.addingTimeInterval(-900)),
            .init(name: "2-ddd", modified: now.addingTimeInterval(-9000)),
            .init(name: ".staging-new", modified: now.addingTimeInterval(-5)),
            .init(name: ".staging-old", modified: now.addingTimeInterval(-3600)),
            .init(name: ".DS_Store", modified: now),
        ]
        XCTAssertEqual(
            HelperInstall.prunable(entries, keeping: "5-aaa", now: now).sorted(),
            [".staging-old", "2-ddd", "3-ccc"])
    }

    func testEachBuildHasItsOwnFolder() {
        XCTAssertEqual(HelperInstall.versionName(bundleVersion: "42", codeIdentity: "0123456789abcdef"), "42-0123456789ab")
        XCTAssertEqual(HelperInstall.versionName(bundleVersion: "../x", codeIdentity: "ff"), "x-ff")
        XCTAssertEqual(HelperInstall.versionName(bundleVersion: "", codeIdentity: "ff"), "0-ff")
    }

    func testASignedCopyKeepsItsCodeHash() throws {
        let system = URL(fileURLWithPath: "/bin/ls")
        let copy = folder.appending(path: "ls")
        try FileManager.default.copyItem(at: system, to: copy)
        let hash = try XCTUnwrap(HelperInstall.codeHash(of: system))
        XCTAssertEqual(HelperInstall.codeHash(of: copy), hash)
        XCTAssertEqual(try HelperInstall.codeIdentity(of: copy), hash)
    }
}
#endif
