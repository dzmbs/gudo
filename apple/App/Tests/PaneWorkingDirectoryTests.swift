import XCTest
@testable import App

/// A pane's directory from its OSC 7 report reads as the daemon reads it, whatever the shell's
/// integration sends: project names, home checks and paths depend on it.
final class PaneWorkingDirectoryTests: XCTestCase {
    func testFileAndKittyURLsGiveThePath() {
        XCTAssertEqual(Pane.directory(fromOSC7: "file://mac/Users/a%20b"), "/Users/a b")
        XCTAssertEqual(Pane.directory(fromOSC7: "file://mac/Users/me/"), "/Users/me")
        // Ghostty's shell integration: the path verbatim after the host.
        XCTAssertEqual(Pane.directory(fromOSC7: "kitty-shell-cwd://mac.local/Users/me"), "/Users/me")
        XCTAssertEqual(Pane.directory(fromOSC7: "kitty-shell-cwd://mac/Users/a%20b"), "/Users/a%20b")
        XCTAssertEqual(Pane.directory(fromOSC7: "kitty-shell-cwd://mac"), "/")
        XCTAssertEqual(Pane.directory(fromOSC7: "/srv/app"), "/srv/app")
    }

    func testAnythingElseIsNoDirectory() {
        for url in ["", "rm -rf ~", "https://example.com/x", "kitty-shell-cwd:/nohost", "relative/dir"] {
            XCTAssertEqual(Pane.directory(fromOSC7: url), "", url)
        }
    }
}
