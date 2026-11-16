import XCTest
@testable import App

@MainActor
final class PairingSheetTests: XCTestCase {
    func testPairIsOfferedOnlyForTextThatIsATicket() {
        XCTAssertTrue(PairingSheet.isTicket(LinkSecurityTests.ticket))
        XCTAssertTrue(PairingSheet.isTicket("  \(LinkSecurityTests.ticket)\n"))
        XCTAssertFalse(PairingSheet.isTicket("not-a-ticket"))
        XCTAssertFalse(PairingSheet.isTicket(""))
    }

    func testBothPairingScreensNameTheSameCommand() {
        XCTAssertEqual(PairingSheet.pairCommand, "\(Brand.commandLineTool) pair")
        XCTAssertTrue(PairingHint.message.contains(PairingSheet.pairCommand))
    }
}
