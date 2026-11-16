import DesignSystem
import GudoCore
import XCTest
@testable import App

/// New Agent offers pi beside Claude Code and Codex where the host's helper launches it, starts
/// it as pi, and marks it with pi's own logo.
@MainActor
final class NewAgentRunnersTests: XCTestCase {
    func testPiIsOfferedOnlyWhereTheHelperLaunchesIt() {
        XCTAssertEqual(NewTaskSheet.Runner.offered(startsPi: false), [.claude, .codex, .shell])
        XCTAssertEqual(NewTaskSheet.Runner.offered(startsPi: true), [.claude, .codex, .pi, .shell])
    }

    func testEachRunnerStartsItsOwnAgent() {
        XCTAssertEqual(NewTaskSheet.Runner.pi.agent, .pi)
        XCTAssertEqual(NewTaskSheet.Runner.pi.title, "pi")
        XCTAssertEqual(AgentKind.pi.launched, GudoCore.AgentKind.pi)
        XCTAssertEqual(AgentKind.codex.launched, GudoCore.AgentKind.codex)
        XCTAssertEqual(AgentKind.claude.launched, GudoCore.AgentKind.claude)
        XCTAssertNil(AgentKind.other.launched)
    }

    func testPiCarriesItsLogoWhereverAgentsShowTheirs() {
        XCTAssertEqual(AgentKind.pi.identity.logo?.asset, "PiLogo")
        XCTAssertEqual(AgentKind.claude.identity.logo?.asset, "ClaudeLogo")
        XCTAssertEqual(AgentKind("pi").identity.id, "pi")
    }
}
