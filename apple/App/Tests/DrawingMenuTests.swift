import XCTest
@testable import App

/// Where a finished drawing can go (`DrawingMenu`): the overlay's Send To… menu and a
/// placement's tap menu are built from the same data, so they list the same destinations.
@MainActor
final class DrawingMenuTests: XCTestCase {
    private let here = AgentDestination(hostId: "h1", hostName: "studio", pane: 4, agent: .claude, title: "fix-login", sameHost: true)
    private let there = AgentDestination(hostId: "h2", hostName: "hetzner", pane: 9, agent: .codex, title: "Codex", sameHost: false)

    private func titles(_ menu: DrawingMenu) -> [String] {
        menu.sections.flatMap { $0.items.map(\.title) }
    }

    func testWithNoAgentTheMenuSaysWhatADrawingIsFor() {
        let menu = DrawingMenu.make(destinations: [], primary: nil, canStart: true, includeKeep: true, placement: false)
        #if os(iOS)
        XCTAssertEqual(titles(menu), [
            "Start Claude Code with This Drawing", "Start Codex with This Drawing",
            "Copy Image", "Share…", "Keep in Terminal",
        ])
        #else
        XCTAssertEqual(titles(menu), [
            "Start Claude Code with This Drawing", "Start Codex with This Drawing",
            "Copy Image", "Save Image…", "Share…", "Keep in Terminal",
        ])
        #endif
    }

    func testThePrimaryAgentIsItsOwnButtonInTheOverlayButListedOnAPlacement() {
        let overlay = DrawingMenu.make(destinations: [here, there], primary: here, canStart: true, includeKeep: false, placement: false)
        let send = overlay.sections.first { $0.title == "Send to" }
        XCTAssertEqual(send?.items.map(\.title), ["Codex"], "the primary agent is the Send button, not repeated")
        XCTAssertEqual(send?.items.first?.subtitle, "hetzner", "another host's agent names its host")
        XCTAssertFalse(titles(overlay).contains("Keep in Terminal"), "Keep is its own button next to Send")

        let placement = DrawingMenu.make(destinations: [here, there], primary: here, canStart: true, includeKeep: false, placement: true)
        let all = titles(placement)
        XCTAssertEqual(all.first, "Claude Code · fix-login")
        XCTAssertTrue(all.contains("Edit Drawing"))
        XCTAssertEqual(all.last, "Delete Drawing")
        XCTAssertTrue(placement.sections.last?.items.last?.destructive ?? false)
    }

    func testNoStartWhenAgentsCannotBeLaunched() {
        let menu = DrawingMenu.make(destinations: [], primary: nil, canStart: false, includeKeep: true, placement: false)
        XCTAssertFalse(titles(menu).contains { $0.hasPrefix("Start") })
    }

    func testDestinationLabels() {
        XCTAssertEqual(here.label, "Claude Code · fix-login")
        XCTAssertEqual(there.label, "Codex", "a title that only repeats the agent is dropped")
    }
}
