import DesignSystem
import Foundation
import GudoCore
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

    func testTheModeMenuListsEveryModeWithAOneLineDescription() {
        XCTAssertEqual(Set(ChatSessionControls.modes.map(\.mode)), Set(TimelinePermissionModeTag.allCases))
        XCTAssertEqual(ChatSessionControls.modes.first?.mode, .default)
        for option in ChatSessionControls.modes {
            XCTAssertFalse(option.detail.isEmpty)
            XCTAssertFalse(option.detail.contains("\n") || option.detail.contains("—") || option.detail.contains("–"))
            XCTAssertEqual(ChatSessionControls.modeName(.known(option.mode)), option.title)
        }
    }

    func testTheModelMenuOpensOnTheRunningFamily() {
        XCTAssertEqual(ChatSessionControls.modelChoices(current: "claude-sonnet-4-6").map(\.title),
                       ["Sonnet", "Default", "Opus", "Haiku"])
        XCTAssertEqual(ChatSessionControls.modelChoices(current: "custom-model[1m]"), ChatSessionControls.models)
        XCTAssertEqual(ChatSessionControls.modelChoices(current: nil), ChatSessionControls.models)
    }

    func testAnEmptyChatSaysWhyWhenTheSessionIsNotKnownYet() throws {
        XCTAssertEqual(ChatEmptyState(isLoading: true, session: nil), .opening)
        XCTAssertEqual(ChatEmptyState(isLoading: false, session: nil), .empty)
        let unknown = try session(native: "")
        let state = ChatEmptyState(isLoading: false, session: unknown)
        XCTAssertEqual(state, .findingSession(.known(.claude)))
        XCTAssertTrue(state.offersTerminal)
        XCTAssertNotEqual(state.title, "No messages yet")
        XCTAssertNotNil(state.detail)
        XCTAssertEqual(ChatEmptyState(isLoading: false, session: try session(native: "known")), .empty)
        for text in [state.title, state.detail ?? ""] {
            XCTAssertFalse(text.contains("—") || text.contains("–"))
        }
    }

    func testAnAgentWithoutAConversationIsWaitingInTerminal() throws {
        let noSession = ChatEmptyState(isLoading: false, session: nil, agent: .claude)
        XCTAssertEqual(noSession, .waitingInTerminal(agent: .claude, reason: nil))
        XCTAssertEqual(noSession.title, "Claude Code is waiting in Terminal")
        XCTAssertTrue(noSession.offersTerminal)
        XCTAssertNotNil(noSession.detail)

        let signIn = "Claude Code is not signed in on this host"
        let blocked = ChatEmptyState(isLoading: true, session: try session(native: "known"), agent: .claude,
                                     terminalWait: signIn)
        XCTAssertEqual(blocked, .waitingInTerminal(agent: .claude, reason: signIn))
        XCTAssertTrue(blocked.detail?.hasPrefix(signIn) == true)
        XCTAssertTrue(blocked.offersTerminal)
        for text in [noSession.title, noSession.detail ?? "", blocked.detail ?? ""] {
            XCTAssertFalse(text.contains("—") || text.contains("–"))
        }
    }

    func testOnlyABlockerWithoutChoicesWaitsInTerminal() {
        XCTAssertEqual(ChatEmptyState.terminalWait(.blocked(requestId: 1, summary: " Sign in ", options: [])), "Sign in")
        XCTAssertEqual(ChatEmptyState.terminalWait(.blocked(requestId: 1, summary: "", options: [])), "")
        let choice = DecisionOption(id: 0, label: "Yes")
        XCTAssertNil(ChatEmptyState.terminalWait(.blocked(requestId: 1, summary: "Run ls?", options: [choice])))
        XCTAssertNil(ChatEmptyState.terminalWait(.idle))
        XCTAssertNil(ChatEmptyState.terminalWait(nil))
        XCTAssertEqual(ChatEmptyState(isLoading: false, session: nil, agent: .claude, terminalWait: ""),
                       .waitingInTerminal(agent: .claude, reason: nil))
    }

    func testAPiChatThatFoundNoSessionYetTalksAboutPi() throws {
        var unknown = try session(native: "")
        unknown.agent = .known(.pi)
        let state = ChatEmptyState(isLoading: false, session: unknown)
        XCTAssertEqual(state, .findingSession(.known(.pi)))
        XCTAssertTrue(state.offersTerminal)
        XCTAssertTrue(state.detail?.contains("pi") == true)
        XCTAssertFalse(state.detail?.contains("Claude") == true)
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

    func testTableColumnsShrinkTheWidestToFitThePhoneBeforeScrolling() {
        let rows: [[AttributedString]] = [
            [AttributedString("Reading"), AttributedString("Now"), AttributedString("Card maximum")],
            [AttributedString("Memory"), AttributedString(String(repeating: "y", count: 40)),
             AttributedString(String(repeating: "z", count: 30))],
        ]
        let spacing = DS.Space.l
        let natural = ChatTableColumns.widths(rows, characterWidth: ChatTableColumns.characterWidth)
        XCTAssertGreaterThan(ChatTableColumns.width(of: natural, spacing: spacing), 353)
        let fitted = ChatTableColumns.widths(rows, characterWidth: ChatTableColumns.characterWidth, spacing: spacing, available: 353)
        XCTAssertEqual(ChatTableColumns.width(of: fitted, spacing: spacing), 353, accuracy: 0.5)
        XCTAssertEqual(fitted[0], natural[0], "a column narrower than the others keeps its width")
        XCTAssertLessThan(fitted[1], natural[1])
        XCTAssertTrue(fitted.allSatisfy { $0 >= DS.Size.proseTableColumn })
        let wide = Array(repeating: AttributedString(String(repeating: "w", count: 60)), count: 6)
        let crowded = ChatTableColumns.widths([wide], characterWidth: ChatTableColumns.characterWidth, spacing: spacing, available: 353)
        XCTAssertEqual(crowded, Array(repeating: DS.Size.proseTableColumn, count: 6), "past the narrowest columns it scrolls")
        let small = [[AttributedString("a"), AttributedString("b")]]
        XCTAssertEqual(ChatTableColumns.widths(small, characterWidth: ChatTableColumns.characterWidth, spacing: spacing, available: 353),
                       ChatTableColumns.widths(small, characterWidth: ChatTableColumns.characterWidth))
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
