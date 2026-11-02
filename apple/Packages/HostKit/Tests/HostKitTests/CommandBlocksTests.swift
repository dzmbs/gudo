import Foundation
import Testing
@testable import HostKit
import GudoCore

/// Command blocks from the daemon's command list (rows named from the bottom, as anchors are),
/// running commands for the sidebar, prompt jumps, and the words around them.
@MainActor
struct CommandBlocksTests {
    private func mark(_ id: UInt64, _ command: String, exit: Int32?? = .some(0), pane: UInt64 = 1) -> CommandMark {
        CommandMark(
            paneId: pane, commandId: id, command: command, cwd: "/p", startedAtMs: 1000 * id, atSeq: 10 * id,
            finished: exit.map { CommandEnd(exit: $0, durationMs: 50) })
    }

    private func info(_ mark: CommandMark, prompt: UInt64?, output: UInt64?, end: UInt64?) -> CommandInfo {
        CommandInfo(mark: mark, promptRow: prompt, outputRow: output, endRow: end)
    }

    @Test func blocksRunFromThePromptToTheLastOutputRow() {
        // Rows: 0 "$ false", 1 "boom", 2 "$ true" (end of false; next prompt), 3 "$ " (end of
        // true; the live prompt), 4 blank. Ten rows on screen.
        let list = CommandList(atSeq: 99, totalRows: 10, commands: [
            info(mark(1, "false", exit: 1), prompt: 0, output: 1, end: 2),
            info(mark(2, "true"), prompt: 2, output: 3, end: 3),
        ])
        let blocks = CommandBlocks.blocks(list)
        #expect(blocks.count == 2)
        // `false`: rows 0…1 → 9…8 from the bottom; it failed.
        #expect(blocks[0].first == 9 && blocks[0].last == 8 && !blocks[0].lastMayBePrompt)
        #expect(blocks[0].status == .failed(1) && blocks[0].atSeq == 99)
        // `true`: its end row may be the live prompt; only the terminal can say.
        #expect(blocks[1].first == 7 && blocks[1].last == 6 && blocks[1].lastMayBePrompt)
        #expect(blocks[1].status == .succeeded)
    }

    @Test func outputWithoutANewlineKeepsItsLastRow() {
        // `printf x` leaves the cursor after "x" on row 1; the next prompt fresh-lines to row 2.
        let list = CommandList(atSeq: 5, totalRows: 4, commands: [
            info(mark(1, "printf x"), prompt: 0, output: 1, end: 1),
            info(mark(2, "ls", exit: nil), prompt: 2, output: 3, end: nil),
        ])
        let blocks = CommandBlocks.blocks(list)
        #expect(blocks[0].first == 3 && blocks[0].last == 2)
        // A running command runs to the cursor.
        #expect(blocks[1].last == nil && blocks[1].status == .running)
        #expect(CommandBlocks.running(list)?.commandId == 2)
    }

    @Test func blocksLeaveWithTheirRows() {
        // The first command's prompt and output left the scrollback; the second's prompt too
        // (its output start is what is left).
        let list = CommandList(atSeq: 5, totalRows: 3, commands: [
            info(mark(1, "seq 1000"), prompt: nil, output: nil, end: nil),
            info(mark(2, "seq 9"), prompt: nil, output: 0, end: 2),
        ])
        let blocks = CommandBlocks.blocks(list)
        #expect(blocks.map(\.id) == [2])
        #expect(blocks[0].first == 2 && blocks[0].last == 0)
        #expect(CommandBlocks.running(list) == nil)
    }

    @Test func promptJumpsGoToTheNearestPromptPastTheViewportTop() {
        let prompts = [3, 40, 12]
        #expect(CommandBlocks.promptTarget(prompts: prompts, viewportTop: 20, direction: -1) == 12)
        #expect(CommandBlocks.promptTarget(prompts: prompts, viewportTop: 12, direction: -1) == 3)
        #expect(CommandBlocks.promptTarget(prompts: prompts, viewportTop: 3, direction: -1) == nil)
        #expect(CommandBlocks.promptTarget(prompts: prompts, viewportTop: 12, direction: 1) == 40)
        #expect(CommandBlocks.promptTarget(prompts: prompts, viewportTop: 40, direction: 1) == nil)
    }

    @Test func elapsedTimeReadsLikeTheSidebar() {
        #expect(CommandBlocks.elapsed(seconds: 8) == "8s")
        #expect(CommandBlocks.elapsed(seconds: 72) == "1m 12s")
        #expect(CommandBlocks.elapsed(seconds: 3600 + 180 + 5) == "1h 03m")
    }

    @Test func lastLineIsTheLastNonEmptyOne() {
        #expect(CommandBlocks.lastLine(of: "a\nerror: boom  \n\n   \n") == "error: boom")
        #expect(CommandBlocks.lastLine(of: "\n\n") == nil)
        #expect(CommandBlocks.lastLine(of: String(repeating: "x", count: 300), limit: 10) == "xxxxxxxxx…")
    }

    @Test func agentPromptIsPlainTextAnAgentTakes() {
        let prompt = CommandBlocks.agentPrompt(command: "cargo test", status: .failed(101), output: "\u{1b}[31merror\u{1b}[0m\r\nfailed\n")
        #expect(prompt.hasPrefix("I ran `cargo test` in the terminal and it failed with exit status 101."))
        #expect(prompt.contains("[31merror[0m\nfailed"))
        #expect(!prompt.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" })

        // Long output keeps its end, from a line start, within the limit.
        let long = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let cut = CommandBlocks.agentPrompt(command: nil, status: .succeeded, output: long, limit: 2000)
        #expect(cut.utf8.count <= 2000)
        #expect(cut.hasPrefix("I ran a command in the terminal. Its output:"))
        #expect(cut.contains("…\nline "))
        #expect(cut.hasSuffix("line 5000\n"))
        #expect(CommandBlocks.agentPrompt(command: "true", status: .succeeded, output: "").contains("(no output)"))
    }

    @Test func runningCommandsFollowMarksAndLists() async throws {
        let client = FakeWorkspaceAPI()
        let connection = DaemonConnection(hostId: "h", ticket: "t") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        let hub = connection.workspace
        var seen: [UInt64] = []
        hub.observeCommandMarks { seen.append($0.commandId) }

        client.send(.commandMark(mark: mark(7, "cargo build", exit: nil)))
        try await eventually("running") { hub.runningCommands[1]?.commandId == 7 }
        client.send(.commandMark(mark: mark(7, "cargo build", exit: 0)))
        try await eventually("finished") { hub.runningCommands[1] == nil }
        #expect(seen == [7, 7])

        // A list read after a reconnect says what runs now.
        hub.noteCommands(CommandList(atSeq: 1, totalRows: 2, commands: [info(mark(8, "sleep 60", exit: nil), prompt: 0, output: 1, end: nil)]), pane: 1)
        #expect(hub.runningCommands[1]?.command == "sleep 60")
        client.send(.paneClosed(paneId: 1))
        try await eventually("closed") { hub.runningCommands[1] == nil }
    }
}
