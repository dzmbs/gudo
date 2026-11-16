import XCTest
@testable import App

/// The "localhost:N is up" offer reads like the command the user typed and goes away once the
/// server's page is open, however it was opened.
@MainActor
final class PortOfferTests: XCTestCase {
    func testTheOfferShowsTheCommandWithoutClear() {
        XCTAssertEqual(PortOfferBanner.command("clear; npm run dev"), "npm run dev")
        XCTAssertEqual(PortOfferBanner.command("clear && cd site && python3 -m http.server 8765"), "cd site && python3 -m http.server 8765")
        XCTAssertEqual(PortOfferBanner.command("clear;clear; vite"), "vite")
        XCTAssertEqual(PortOfferBanner.command("pnpm dev"), "pnpm dev")
        XCTAssertEqual(PortOfferBanner.command("clearance-server"), "clearance-server")
    }

    func testOpeningTheServersPageAnswersTheOffer() throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let model = WindowModel(app: .shared)
        let ports = try XCTUnwrap(model.ports as? MockPortSource)
        ports.offer = ports.ports[0]
        model.openPage(try XCTUnwrap(URL(string: "http://localhost:8000/")), hostId: nil)
        XCTAssertNotNil(ports.offer, "another server's page leaves the offer")
        model.openPage(try XCTUnwrap(URL(string: "http://localhost:5173/")), hostId: nil)
        XCTAssertNil(ports.offer, "its own page answers it")
    }
}
