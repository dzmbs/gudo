import XCTest
@testable import App

/// Write mode's commit path (Scribble itself cannot be synthesised): handwriting shows at the
/// prompt as a preview and reaches the shell only when committed, once, as one line.
@MainActor
final class WriteControllerTests: XCTestCase {
    private var previews: [String?] = []
    private var sent: [String] = []

    private func controller() -> WriteController {
        WriteController(preview: { [unowned self] in previews.append($0) }, send: { [unowned self] in sent.append($0) })
    }

    func testHandwritingIsPreviewedButNotSentUntilCommitted() {
        let write = controller()
        write.update("git")
        write.update("git status")
        write.update("git status\n--short")
        XCTAssertEqual(previews, ["git", "git status", "git status --short"])
        XCTAssertTrue(sent.isEmpty, "nothing reaches the shell while writing")

        XCTAssertTrue(write.commit())
        XCTAssertEqual(sent, ["git status --short"])
        XCTAssertEqual(previews.last, .some(nil), "the preview clears on commit")
        XCTAssertTrue(write.isEmpty)

        XCTAssertFalse(write.commit(), "a second Return sends nothing")
        XCTAssertEqual(sent.count, 1)
    }

    func testCancelSendsNothing() {
        let write = controller()
        write.update("rm -rf build")
        write.cancel()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(previews.last, .some(nil))
        XCTAssertFalse(write.commit())
    }

    func testStrikeThroughToEmptyClearsThePreview() {
        let write = controller()
        write.update("ls")
        write.update("")
        XCTAssertEqual(previews, ["ls", nil])
        XCTAssertFalse(write.commit())
        XCTAssertTrue(sent.isEmpty)
    }
}
