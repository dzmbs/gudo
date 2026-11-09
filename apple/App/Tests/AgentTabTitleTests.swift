import XCTest
@testable import App

final class AgentTabTitleTests: XCTestCase {
    func testARenameAlwaysWins() {
        let title = AgentTabTitle(
            rename: "Pricing copy", sessionTitle: "Refactor auth", firstPrompt: "fix the login", terminalTitle: "✳ Tests", kind: .claude)
        XCTAssertEqual(title.resolved, "Pricing copy")
    }

    func testTheSessionTitleComesBeforeThePromptAndTheTerminal() {
        XCTAssertEqual(
            AgentTabTitle(sessionTitle: "Refactor auth", firstPrompt: "fix the login", terminalTitle: "✳ Tests", kind: .claude).resolved,
            "Refactor auth")
        XCTAssertEqual(AgentTabTitle(firstPrompt: "fix the login\nand the tests", terminalTitle: "✳ Tests", kind: .codex).resolved, "fix the login")
    }

    func testTheTerminalTitleLosesItsStatusMarks() {
        XCTAssertEqual(AgentTabTitle(terminalTitle: "✳ Refactor auth middleware", kind: .claude).resolved, "Refactor auth middleware")
        XCTAssertEqual(AgentTabTitle(terminalTitle: "⠂ Onboarding tests", kind: .claude).resolved, "Onboarding tests")
    }

    func testAPathOrTheAgentsOwnNameFallsBackToTheKind() {
        XCTAssertEqual(AgentTabTitle(terminalTitle: "~/src/gudo", kind: .claude).resolved, "Claude Code")
        XCTAssertEqual(AgentTabTitle(terminalTitle: "✳ Claude Code", kind: .claude).resolved, "Claude Code")
        XCTAssertEqual(AgentTabTitle(terminalTitle: "codex", kind: .codex).resolved, "Codex")
        XCTAssertEqual(AgentTabTitle(rename: "  ", terminalTitle: nil, kind: .codex).resolved, "Codex")
    }
}
