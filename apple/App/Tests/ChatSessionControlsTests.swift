import Foundation
import HostKit
import XCTest
@testable import App

final class ChatSessionControlsTests: XCTestCase {
    func testModelIdentifiersReadAsTheirFamilyAndVersion() {
        XCTAssertEqual(ChatSessionControls.modelName("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(ChatSessionControls.modelName("claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(ChatSessionControls.modelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ChatSessionControls.modelName("claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertEqual(ChatSessionControls.modelName("custom-model[1m]"), "custom-model[1m]")
    }

    func testPermissionModesHaveShortNamesAndFutureModesStayLiteral() {
        XCTAssertEqual(ChatSessionControls.modeName(.known(.default)), "Ask")
        XCTAssertEqual(ChatSessionControls.modeName(.known(.acceptEdits)), "Accept edits")
        XCTAssertEqual(ChatSessionControls.modeName(.known(.plan)), "Plan")
        XCTAssertEqual(ChatSessionControls.modeName(.known(.auto)), "Auto")
        XCTAssertEqual(ChatSessionControls.modeName(.unknown("future")), "future")
    }

    func testModelChoicesAreClaudeCodeSlashCommands() {
        XCTAssertTrue(ChatSessionControls.models.allSatisfy { $0.command.hasPrefix("/model ") })
        XCTAssertEqual(ChatSessionControls.models.map(\.title), ["Default", "Opus", "Sonnet", "Haiku"])
    }

    func testAnEmptyChatSaysWhyWhenTheSessionIsNotKnownYet() throws {
        XCTAssertEqual(ChatEmptyState(isLoading: true, session: nil), .opening)
        XCTAssertEqual(ChatEmptyState(isLoading: false, session: nil), .empty)
        let unknown = try session(native: "")
        let state = ChatEmptyState(isLoading: false, session: unknown)
        XCTAssertEqual(state, .findingSession)
        XCTAssertTrue(state.offersTerminal)
        XCTAssertNotEqual(state.title, "No messages yet")
        XCTAssertNotNil(state.detail)
        XCTAssertEqual(ChatEmptyState(isLoading: false, session: try session(native: "known")), .empty)
        for text in [state.title, state.detail ?? ""] {
            XCTAssertFalse(text.contains("—") || text.contains("–"))
        }
    }

    func testTableColumnsFitTheirLongestCellUpToTheWrapLimit() {
        let rows: [[AttributedString]] = [
            [AttributedString("A"), AttributedString(String(repeating: "x", count: 20))],
            [AttributedString("B"), AttributedString(String(repeating: "y", count: 400))],
        ]
        let widths = ChatTableColumns.widths(rows, characterWidth: ChatTableColumns.characterWidth)
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[0], 80)
        XCTAssertEqual(widths[1], 240)
        let larger = ChatTableColumns.widths(rows, characterWidth: ChatTableColumns.characterWidth * 2)
        XCTAssertEqual(larger[1], 480)
    }

    func testImagesComeOnlyFromHostPathsOfImageFiles() throws {
        XCTAssertEqual(ChatImages.hostPath("/tmp/shot.PNG"), "/tmp/shot.PNG")
        XCTAssertEqual(ChatImages.hostPath("~/Desktop/a.jpg"), "~/Desktop/a.jpg")
        XCTAssertNil(ChatImages.hostPath("https://example.com/a.png"))
        XCTAssertNil(ChatImages.hostPath("/tmp/notes.txt"))
        XCTAssertNil(ChatImages.hostPath("relative/a.png"))
        let attachments = try JSONDecoder().decode([TimelineAttachment].self, from: Data("""
        [{"path":"/tmp/a.png","media_type":null},{"path":"/tmp/b","media_type":"image/jpeg"},
         {"path":"/tmp/c.txt","media_type":"text/plain"}]
        """.utf8))
        XCTAssertEqual(ChatImages.paths(attachments: attachments), ["/tmp/a.png", "/tmp/b"])
    }

    private func session(native: String) throws -> TimelineSession {
        let value: [String: Any] = ["agent": "Claude", "native_session": native, "title": NSNull(), "model": NSNull(),
                                    "permission_mode": NSNull(), "commands": []]
        return try JSONDecoder().decode(TimelineSession.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
