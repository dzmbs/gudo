import XCTest
@testable import App

/// The commands shown for registering the agent tools read as the shell runs them.
final class AgentToolsTests: XCTestCase {
    func testWordsAreQuotedOnlyWhenNeeded() {
        let argv = ["claude", "mcp", "add", "--scope", "user", "gudo", "--", "/home/me/My Tools/gudo-hook", "mcp", "--state", "/s/it's"]
        XCTAssertEqual(
            argv.map(ShellWord.quote).joined(separator: " "),
            #"claude mcp add --scope user gudo -- '/home/me/My Tools/gudo-hook' mcp --state '/s/it'\''s'"#)
        XCTAssertEqual(ShellWord.quote(""), "''")
    }
}
