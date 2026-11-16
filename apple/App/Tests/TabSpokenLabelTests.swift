import DesignSystem
import XCTest
@testable import App

/// VoiceOver reads a tab row as its name, its program or agent state and its host; a path title
/// names its folder rather than spelling out "tilde slash".
@MainActor
final class TabSpokenLabelTests: XCTestCase {
    func testAPathTitleIsReadAsItsFolder() {
        XCTAssertEqual(TabLeadingMark.spoken("~"), "Home folder")
        XCTAssertEqual(TabLeadingMark.spoken("~/projects/gudo"), "gudo folder")
        XCTAssertEqual(TabLeadingMark.spoken("/var/log/"), "log folder")
        XCTAssertEqual(TabLeadingMark.spoken("/"), "Root folder")
        XCTAssertEqual(TabLeadingMark.spoken("cargo test"), "cargo test")
    }

    func testARowNamesItsTitleProgramStateAndHost() {
        XCTAssertEqual(TabLeadingMark.label(title: "~", program: .shell, state: nil, host: "studio"), "Home folder, Shell, studio")
        XCTAssertEqual(TabLeadingMark.label(title: "~/projects/gudo", program: .shell, state: .blocked, host: "studio"),
                       "gudo folder, Shell, \(AgentState.blocked.title), studio")
    }
}
