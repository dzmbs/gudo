import DesignSystem
import XCTest
@testable import App

final class AgentStatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testTheStateCarriesItsAge() {
        let started = now.addingTimeInterval(-12 * 60)
        XCTAssertEqual(AgentStatusLine(kind: "Claude Code", state: .working, since: started).text(at: now), "Claude Code · working 12m")
        XCTAssertEqual(AgentStatusLine(kind: "Codex", state: .done, since: now.addingTimeInterval(-7300)).text(at: now), "Codex · done 2h ago")
        XCTAssertEqual(AgentStatusLine(kind: "Codex", state: .idle, since: now.addingTimeInterval(-40)).text(at: now), "Codex · idle 40s")
    }

    func testAWaitingAgentSaysWhatItAsks() {
        let line = AgentStatusLine(kind: "Claude Code", state: .blocked, since: now, question: "allow npm run build?")
        XCTAssertEqual(line.text(at: now), "Claude Code · needs you: allow npm run build?")
        XCTAssertEqual(line.stateWords(at: now), "needs you: allow npm run build?")
    }

    func testWithoutATimeTheStateStillShows() {
        XCTAssertEqual(AgentStatusLine(kind: "Claude Code", state: .working).text(at: now), "Claude Code · working")
        XCTAssertEqual(AgentStatusLine(kind: "Claude Code", state: .done).stateWords(at: now), "done")
    }
}
