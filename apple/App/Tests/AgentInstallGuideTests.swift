import XCTest
@testable import App

/// The install commands offered for an agent a host lacks are the vendors' own, per system.
final class AgentInstallGuideTests: XCTestCase {
    func testClaudeCodeUsesAnthropicsNativeInstaller() throws {
        for os in ["macos", "linux"] {
            let guide = try XCTUnwrap(AgentInstallGuide(agent: .claude, os: os))
            XCTAssertEqual(guide.command, "curl -fsSL https://claude.ai/install.sh | bash")
            XCTAssertEqual(guide.docs.absoluteString, "https://code.claude.com/docs/en/setup")
        }
        XCTAssertEqual(AgentInstallGuide(agent: .claude, os: "windows")?.command, "irm https://claude.ai/install.ps1 | iex")
    }

    func testCodexUsesOpenAIsInstaller() throws {
        for os in ["macos", "linux"] {
            let guide = try XCTUnwrap(AgentInstallGuide(agent: .codex, os: os))
            XCTAssertEqual(guide.command, "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
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
}
