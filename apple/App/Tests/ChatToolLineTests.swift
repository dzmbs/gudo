import HostKit
import XCTest
@testable import App

final class ChatToolLineTests: XCTestCase {
    func testEachKindReadsAsAVerbAndWhatItActedOn() {
        let shell = ChatToolLine(tool(.shell, name: "Bash", input: #"{"command":"git status   --short\n--branch","description":"Show status"}"#))
        XCTAssertEqual(shell.verb, "Shell")
        XCTAssertEqual(shell.detail, "git status --short --branch")
        XCTAssertEqual(shell.symbol, "terminal")

        let codex = ChatToolLine(tool(.shell, name: "shell", input: #"{"command":["bash","-lc","cargo test -p proto"]}"#))
        XCTAssertEqual(codex.text, "Shell cargo test -p proto")

        let read = ChatToolLine(tool(.read, name: "Read", input: #"{"file_path":"/work/app/src/app.ts"}"#), workingDirectory: "/work/app")
        XCTAssertEqual(read.text, "Read src/app.ts")
        XCTAssertEqual(read.symbol, "eye")
        let outside = ChatToolLine(tool(.read, name: "Read", input: #"{"file_path":"/etc/hosts"}"#), workingDirectory: "/work/app")
        XCTAssertEqual(outside.detail, "/etc/hosts")

        XCTAssertEqual(ChatToolLine(tool(.edit, name: "Edit", input: #"{"file_path":"/w/a.swift"}"#)).text, "Edit /w/a.swift")
        XCTAssertEqual(ChatToolLine(tool(.search, name: "Grep", input: #"{"pattern":"TODO"}"#)).text, "Search TODO")
        XCTAssertEqual(ChatToolLine(tool(.fetch, name: "WebFetch", input: #"{"url":"https://example.com"}"#)).text, "Fetch https://example.com")
        XCTAssertEqual(ChatToolLine(tool(.webSearch, name: "WebSearch", input: #"{"query":"swift 6"}"#)).text, "Web search swift 6")
        XCTAssertEqual(ChatToolLine(tool(.task, name: "Task", input: #"{"subagent_type":"code-reviewer","description":"Review the diff"}"#)).text,
                       "Code reviewer Review the diff")
        XCTAssertEqual(ChatToolLine(tool(.mcp, name: "mcp__gudo__pane_send", input: "{}")).text, "Gudo Pane send")
    }

    func testAToolWithoutReadableInputFallsBackToItsTitle() {
        let unknown = ChatToolLine(tool(.other, name: "codeReview", title: "Look at the parser", input: "not json"))
        XCTAssertEqual(unknown.verb, "Code review")
        XCTAssertEqual(unknown.detail, "Look at the parser")
        let bare = ChatToolLine(tool(.shell, name: "Bash", title: "Bash", input: "{}"))
        XCTAssertEqual(bare.text, "Shell")
    }

    func testCodexRowsReadTheSameWay() {
        let edit = ChatToolLine(tool(.edit, name: "Edit", title: "/work/app/src/a.rs, /work/app/src/b.rs",
                                     input: "/work/app/src/a.rs\n/work/app/src/b.rs"), workingDirectory: "/work/app")
        XCTAssertEqual(edit.text, "Edit src/a.rs, src/b.rs")
        let image = ChatToolLine(tool(.read, name: "View image", title: "/work/app/shot.png", input: "/work/app/shot.png"),
                                 workingDirectory: "/work/app")
        XCTAssertEqual(image.text, "Read shot.png")
        let shell = ChatToolLine(tool(.shell, name: "shell", title: "cargo test -p proto", input: "cargo test -p proto"))
        XCTAssertEqual(shell.text, "Shell cargo test -p proto")
        XCTAssertEqual(ChatToolLine(tool(.webSearch, name: "web_search", title: "swift 6", input: "swift 6")).text, "Web search swift 6")
    }

    func testAGroupTakesTheGlyphOfItsMostCommonKind() {
        let tools = [tool(.read, name: "Read", input: "{}"), tool(.shell, name: "Bash", input: "{}"), tool(.read, name: "Read", input: "{}")]
        XCTAssertEqual(ChatToolGroups.symbol(tools), "eye")
    }

    private func tool(_ kind: TimelineToolKindTag, name: String, title: String? = nil, input: String) -> TimelineTool {
        ChatFixtures.tool(kind.rawValue, name: name, title: title ?? name, input: input)
    }
}
