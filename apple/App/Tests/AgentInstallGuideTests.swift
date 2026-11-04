import Foundation
import XCTest
@testable import App

/// The install commands offered for an agent a host lacks are the vendors' own, per system.
final class AgentInstallGuideTests: XCTestCase {
    func testClaudeCodeUsesAnthropicsNativeInstaller() throws {
        for os in ["macos", "linux"] {
            let guide = try XCTUnwrap(AgentInstallGuide(agent: .claude, os: os))
            XCTAssertEqual(guide.command, #"sh -c 'installer_script=$(curl -fsSL https://claude.ai/install.sh) && exec bash -c "$installer_script"'"#)
            XCTAssertEqual(guide.docs.absoluteString, "https://code.claude.com/docs/en/setup")
        }
        XCTAssertEqual(AgentInstallGuide(agent: .claude, os: "windows")?.command, "irm https://claude.ai/install.ps1 | iex")
    }

    func testCodexUsesOpenAIsInstaller() throws {
        for os in ["macos", "linux"] {
            let guide = try XCTUnwrap(AgentInstallGuide(agent: .codex, os: os))
            XCTAssertEqual(guide.command, #"sh -c 'installer_script=$(curl -fsSL https://chatgpt.com/codex/install.sh) && exec sh -c "$installer_script"'"#)
            XCTAssertEqual(guide.docs.host(), "github.com")
        }
        XCTAssertEqual(
            AgentInstallGuide(agent: .codex, os: "windows")?.command,
            #"powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex""#)
    }

    func testOtherSystemsGetOnlyTheGuide() throws {
        let guide = try XCTUnwrap(AgentInstallGuide(agent: .claude, os: "freebsd"))
        XCTAssertNil(guide.command)
        XCTAssertNil(AgentInstallGuide(agent: .codex, os: "")?.command)
        XCTAssertNil(AgentInstallGuide(agent: .other, os: "linux"))
    }
    #if os(macOS)
    func testUnixInstallersLeaveTerminalInputAvailableToTheirChildren() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let curl = directory.appendingPathComponent("curl")
        let installer = "test -t 0 || exit 42; printf 'installer-child-has-terminal\\n'"
        let curlScript = "#!/bin/sh\ncat <<'INSTALLER'\n\(installer)\nINSTALLER\n"
        try curlScript.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        for agent: AgentKind in [.claude, .codex] {
            let guide = try XCTUnwrap(AgentInstallGuide(agent: agent, os: "macos"))
            let command = try XCTUnwrap(guide.command)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(directory.path):/usr/bin:/bin"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let outputBytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let transcript = String(decoding: outputBytes, as: UTF8.self)
            XCTAssertTrue(transcript.contains("installer-child-has-terminal"), "\(agent): \(transcript)")
        }
    }
    #endif

}
