import GudoCore
import HostKit
import XCTest
@testable import App

@MainActor
final class ChatAutocompleteTests: XCTestCase {
    private let commands: [TimelineCommand] = (try? TimelineJSON.decode([TimelineCommand].self, from: """
    [{"name":"review","description":"Review the diff","source":"Built-in"},
     {"name":"compact","description":"Summarise the conversation","source":"Built-in"},
     {"name":"pr-review","description":"Review a pull request","source":"Project"},
     {"name":"deploy:staging","description":"Ship to staging","source":"User"}]
    """)) ?? []

    func testTheWordAtTheCursorDecidesWhatIsOffered() {
        func trigger(_ draft: String, at offset: Int? = nil) -> ChatAutocomplete.Trigger? {
            let cursor = offset.map { draft.index(draft.startIndex, offsetBy: $0) } ?? draft.endIndex
            return ChatAutocomplete.trigger(in: draft, cursor: cursor)
        }
        XCTAssertEqual(trigger("/rev")?.kind, .command)
        XCTAssertEqual(trigger("/rev")?.query, "rev")
        XCTAssertEqual(trigger("/")?.query, "")
        XCTAssertNil(trigger("say /rev"), "a command is the message's first word")
        XCTAssertNil(trigger("/rev now"))
        XCTAssertEqual(trigger("look at @src/ap")?.kind, .file)
        XCTAssertEqual(trigger("look at @src/ap")?.query, "src/ap")
        XCTAssertEqual(trigger("look at @src/app.ts and", at: 13)?.query, "src/")
        XCTAssertNil(trigger("mail me@host"), "@ inside a word is not a mention")
        XCTAssertNil(trigger("look at @src "), "the word has ended")
        let draft = "look at @src/app"
        XCTAssertEqual(trigger(draft).map { String(draft[$0.range]) }, "@src/app")
    }

    func testCommandsRankPrefixesFirstAndEmphasiseTheMatch() {
        let suggestions = ChatAutocomplete.commands(matching: "rev", in: commands)
        XCTAssertEqual(suggestions.map(\.title), ["/review", "/pr-review"])
        XCTAssertEqual(suggestions.first?.insertion, "/review ")
        XCTAssertEqual(suggestions.first?.emphasis, [1, 2, 3])
        XCTAssertEqual(ChatAutocomplete.commands(matching: "", in: commands).count, 4)
        XCTAssertEqual(ChatAutocomplete.commands(matching: "stag", in: commands).map(\.title), ["/deploy:staging"])
    }

    func testAcceptingReplacesTheWordAndPutsTheCursorAfterIt() throws {
        let autocomplete = ChatAutocomplete()
        let draft = "/rev"
        autocomplete.update(draft: draft, cursor: draft.endIndex, commands: commands, files: nil)
        XCTAssertTrue(autocomplete.isPresented)
        autocomplete.moveSelection(by: 1)
        XCTAssertEqual(autocomplete.selection, 1)
        autocomplete.moveSelection(by: 1)
        XCTAssertEqual(autocomplete.selection, 0, "the selection wraps")
        let accepted = try XCTUnwrap(autocomplete.accept(in: draft))
        XCTAssertEqual(accepted.draft, "/review ")
        XCTAssertEqual(accepted.cursor, accepted.draft.endIndex)
        XCTAssertFalse(autocomplete.isPresented)
    }

    func testFilesComeFromTheHostAfterTypingPausesAndFoldersKeepTheListOpen() async throws {
        let autocomplete = ChatAutocomplete()
        var asked: [String] = []
        let source: ChatAutocomplete.FileSource = { query in
            asked.append(query)
            return [ChatFileSuggestion(path: "src/my app.ts", isDirectory: false, positions: [4, 5, 6]),
                    ChatFileSuggestion(path: "src/components", isDirectory: true, positions: [])]
        }
        for draft in ["see @a", "see @ap", "see @app"] {
            autocomplete.update(draft: draft, cursor: draft.endIndex, commands: [], files: source)
        }
        try await wait { autocomplete.suggestions.count == 2 }
        XCTAssertEqual(asked, ["app"], "only the word typing paused on is searched")
        XCTAssertEqual(autocomplete.suggestions.first?.insertion, "@src/my\\ app.ts ")
        XCTAssertEqual(autocomplete.suggestions.last?.insertion, "@src/components/")
        XCTAssertEqual(autocomplete.suggestions.first?.emphasis, [4, 5, 6])
        let accepted = try XCTUnwrap(autocomplete.accept(1, in: "see @app"))
        XCTAssertEqual(accepted.draft, "see @src/components/")
    }

    func testEscapeKeepsTheListClosedUntilTheCursorLeavesTheWord() {
        let autocomplete = ChatAutocomplete()
        autocomplete.update(draft: "/re", cursor: "/re".endIndex, commands: commands, files: nil)
        XCTAssertTrue(autocomplete.isPresented)
        autocomplete.dismiss()
        autocomplete.update(draft: "/rev", cursor: "/rev".endIndex, commands: commands, files: nil)
        XCTAssertFalse(autocomplete.isPresented)
        autocomplete.update(draft: "/rev ", cursor: "/rev ".endIndex, commands: commands, files: nil)
        autocomplete.update(draft: "/", cursor: "/".endIndex, commands: commands, files: nil)
        XCTAssertTrue(autocomplete.isPresented)
    }

    func testAHostThatCannotSearchSaysSo() async throws {
        let autocomplete = ChatAutocomplete()
        autocomplete.update(draft: "@a", cursor: "@a".endIndex, commands: [], files: nil)
        XCTAssertEqual(autocomplete.note, "Update the helper to tag files")
        let refusing: ChatAutocomplete.FileSource = { _ in
            throw WorkspaceError.Unavailable(message: "Files are searched in a project folder, not the home folder.")
        }
        autocomplete.update(draft: "@b", cursor: "@b".endIndex, commands: [], files: refusing)
        try await wait { autocomplete.note?.hasPrefix("Files are searched") == true }
        XCTAssertTrue(autocomplete.suggestions.isEmpty)
    }

    func testTheQueueHoldsAFewMessagesAndPutsBackOneThatDidNotGo() throws {
        let queue = ChatQueue()
        XCTAssertFalse(queue.enqueue("   "))
        for index in 0..<ChatQueue.limit { XCTAssertTrue(queue.enqueue("message \(index)")) }
        XCTAssertFalse(queue.enqueue("one too many"))
        let first = try XCTUnwrap(queue.messages.first)
        XCTAssertEqual(queue.take(first.id)?.text, "message 0")
        XCTAssertNil(queue.take(first.id))
        queue.restore(first)
        XCTAssertEqual(queue.messages.first, first)
        queue.restore(first)
        XCTAssertEqual(queue.messages.count, ChatQueue.limit)
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Autocomplete did not settle", file: file, line: line)
    }
}
