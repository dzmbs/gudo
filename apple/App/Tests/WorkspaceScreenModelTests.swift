import DesignSystem
import Foundation
import HostKit
import PaneLayout
import GudoCore
import Network
import XCTest
@testable import App

/// The workspace screens' models against a fake daemon client (no daemon, no UI).
@MainActor
final class WorkspaceScreenModelTests: XCTestCase {
    // MARK: Inbox

    private func meta(_ pane: UInt64, title: String = "fix tests", cwd: String = "/home/me/proj", agent: AgentStatus?) -> PaneMeta {
        PaneMeta(
            paneId: pane, title: title, cwd: cwd, exit: nil, agent: agent, size: PaneSize(cols: 80, rows: 24),
            sizePolicy: .smallest, sizedBy: nil)
    }

    private func attention(_ id: UInt64, pane: UInt64, kind: AttentionKind, body: String = "", seen: Bool = false, title: String = "proj") -> AttentionItem {
        AttentionItem(id: id, atMs: 1_700_000_000_000 + id * 1000, paneId: pane, sessionId: 1, kind: kind, title: title, body: body, seen: seen, whileViewed: false)
    }

    func testFinishedAgentsWithoutAMessageHaveNoSummary() throws {
        let metadata = [PaneId(1): meta(1, title: "[ ! ] Action Required | task | project", agent: AgentStatus(kind: "codex", state: .idle))]
        let notices = [attention(1, pane: 1, kind: .agentDone(agent: "codex"), title: "codex finished")]
        let agent = try XCTUnwrap(LiveAgentFeed.items(hostId: "host", hostName: "Host", meta: metadata, attention: notices).first)
        XCTAssertNil(agent.summary)
        XCTAssertNil(AgentToasts.summary(for: agent))
    }

    func testADriveRequestShowsItsActionAndOffersThePane() {
        let options = [DecisionOption(id: 0, label: "Allow once"),
                       DecisionOption(id: 1, label: "Allow for this pane until it closes"),
                       DecisionOption(id: 2, label: "Deny")]
        let drive = DriveRequestInfo(id: 9, paneId: 1, target: 2, title: "Claude wants to run a command in ~/api · zsh",
                                     action: "Run $ npm test")
        let metas: [PaneId: PaneMeta] = [
            PaneId(1): meta(1, title: "claude", agent: AgentStatus(kind: "claude", state: .blocked(
                requestId: 9, summary: "\(drive.title): \(drive.action)", options: options))),
        ]
        let feed = [attention(1, pane: 1, kind: .agentBlocked(agent: "claude", requestId: 9))]
        let items = LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, attention: feed, drives: [9: drive])
        let item = try! XCTUnwrap(items.first)
        XCTAssertTrue(item.drive)
        XCTAssertEqual(item.request, .permission(tool: "Claude wants to run a command in ~/api · zsh", detail: "Run $ npm test"))
        XCTAssertEqual(item.prompt, "Waiting for your approval")
        XCTAssertEqual(LiveAgentFeed.option(options, allow: true)?.id, 0, "old clients' Approve is Allow once")

        // Another pane's request with the same id is not this one.
        let stray = DriveRequestInfo(id: 9, paneId: 7, target: 2, title: "x", action: "y")
        let plain = LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, attention: feed, drives: [9: stray])
        XCTAssertFalse(plain.first!.drive)
    }

    func testInboxMergesLiveAgentsWithTheAttentionFeed() {
        let options = [DecisionOption(id: 1, label: "Yes"), DecisionOption(id: 2, label: "No, and tell Claude what to do differently")]
        let metas: [PaneId: PaneMeta] = [
            PaneId(1): meta(1, agent: AgentStatus(kind: "claude", state: .blocked(requestId: 9, summary: "rm -rf build", options: options))),
            PaneId(2): meta(2, agent: AgentStatus(kind: "codex", state: .idle)),
            PaneId(3): meta(3, agent: nil),
        ]
        let feed = [
            attention(1, pane: 1, kind: .agentBlocked(agent: "claude", requestId: 9)),
            attention(2, pane: 2, kind: .agentDone(agent: "codex"), body: "Migrated 3 tables", seen: true),
            attention(3, pane: 5, kind: .agentFailed(agent: "claude"), body: "rate limited"),
            attention(4, pane: 3, kind: .commandFinished(mark: CommandMark(
                paneId: 3, commandId: 1, command: "cargo test", cwd: "/home/me/proj", startedAtMs: 0, atSeq: 0,
                finished: CommandEnd(exit: 101, durationMs: 252_000)))),
        ]
        let items = LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, attention: feed)

        let blocked = try! XCTUnwrap(items.first { $0.id == "h/1" })
        XCTAssertEqual(blocked.state, .blocked)
        XCTAssertEqual(blocked.request, .permission(tool: "Wants to run", detail: "rm -rf build"))
        XCTAssertEqual(blocked.prompt, "fix tests", "a title that is not the request stays")
        XCTAssertTrue(blocked.unseen)
        XCTAssertFalse(blocked.canReply, "a permission prompt is answered, not typed into")

        let done = try! XCTUnwrap(items.first { $0.id == "h/2" })
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.summary, "Migrated 3 tables")
        XCTAssertFalse(done.unseen)
        XCTAssertTrue(done.canReply)

        let gone = try! XCTUnwrap(items.first { $0.id == "h/a3" })
        XCTAssertEqual(gone.state, .error, "a failed agent whose pane is gone stays in history")
        XCTAssertEqual(gone.summary, "rate limited")

        let command = try! XCTUnwrap(items.first { $0.id == "h/a4" })
        XCTAssertTrue(command.isCommand)
        XCTAssertEqual(command.prompt, "cargo test")
        XCTAssertEqual(command.state, .error)
        XCTAssertTrue(command.summary?.hasPrefix("Exited 101") == true)

        XCTAssertNil(items.first { $0.id == "h/3" }, "plain shells are not agents")
        XCTAssertNil(items.first { $0.id == "h/a1" }, "a blocked item is the live agent's row, not history")
    }

    /// Any program's own report (pi) is a row of its own, a status only: no request to answer.
    /// Where an agent integration knows the pane, it wins.
    func testProgramReportsListAsStatusOnly() {
        let blocked = ProgramReport(state: .blocked, kind: .question, app: "pi", message: "Which framework?", progress: 40)
        let metas: [PaneId: PaneMeta] = [
            PaneId(1): meta(1, title: "pi", agent: nil),
            PaneId(2): meta(2, agent: AgentStatus(kind: "claude", state: .idle)),
        ]
        let programs = [PaneId(1): blocked, PaneId(2): ProgramReport(state: .working, kind: nil, app: "claude-code", message: nil, progress: nil)]
        let items = LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, programs: programs, attention: [])

        let pi = try! XCTUnwrap(items.first { $0.id == "h/1" })
        XCTAssertEqual(pi.state, .blocked)
        XCTAssertNil(pi.request, "no approval card for a status")
        XCTAssertEqual(pi.prompt, "Which framework? · 40%")
        XCTAssertEqual(pi.title, "pi")
        XCTAssertTrue(pi.canReply)

        let claude = try! XCTUnwrap(items.first { $0.id == "h/2" })
        XCTAssertEqual(claude.state, .done, "the agent integration wins over the report")
        XCTAssertNil(claude.program)
        XCTAssertEqual(items.count, 2)

        let report = try! XCTUnwrap(PaneReport(meta: metas[PaneId(1)], program: ProgramReport(state: .blocked, kind: .auth, app: nil, message: nil, progress: nil)))
        XCTAssertEqual(report.detail, "Needs you to sign in")
        XCTAssertEqual(PaneReport(meta: metas[PaneId(2)], program: blocked)?.state, .idle)
        var exited = meta(1, agent: nil)
        exited.exit = 0
        XCTAssertNil(PaneReport(meta: exited, program: blocked), "a pane whose process ended reports nothing")
    }

    func testAnsweredRequestShowsAsWorkingUntilTheDaemonMovesOn() {
        let metas: [PaneId: PaneMeta] = [
            PaneId(1): meta(1, agent: AgentStatus(kind: "claude", state: .blocked(requestId: 9, summary: "ls", options: [DecisionOption(id: 1, label: "Allow")]))),
        ]
        let items = LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, attention: [], answered: ["h/1": 9])
        XCTAssertEqual(items.first?.state, .working)
        XCTAssertNil(items.first?.request)
    }

    /// A dialog read off the screen (Claude's folder-trust menu) has no words: no empty request,
    /// and no shared approval card.
    func testADialogWithoutWordsMakesNoEmptyRequest() {
        let metas: [PaneId: PaneMeta] = [
            PaneId(1): meta(1, agent: AgentStatus(kind: "claude", state: .blocked(requestId: 3, summary: "", options: []))),
        ]
        let item = try! XCTUnwrap(LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, attention: []).first)
        XCTAssertEqual(item.state, .blocked)
        XCTAssertNil(item.request)
        XCTAssertFalse(SharedApproval.shows(summary: ""))
        XCTAssertFalse(SharedApproval.shows(summary: " \n"))
        XCTAssertTrue(SharedApproval.shows(summary: "rm -rf build"))
    }

    func testChatApprovalsRemainVisibleForTheSoloOwnerButNotBeforeJoining() {
        XCTAssertTrue(SharedApproval.shows(hasOthers: false, joined: true, placement: .chatComposer))
        XCTAssertFalse(SharedApproval.shows(hasOthers: false, joined: true, placement: .sharedOverlay))
        XCTAssertTrue(SharedApproval.shows(hasOthers: true, joined: true, placement: .sharedOverlay))
        for placement in [SharedApproval.Placement.sharedOverlay, .chatComposer] {
            XCTAssertFalse(SharedApproval.shows(hasOthers: true, joined: false, placement: placement))
        }
    }

    /// The daemon drops a pane's agent once its process exits: the pane leaves the Agents list.
    func testAnAgentThatExitedLeavesTheList() {
        let running: [PaneId: PaneMeta] = [PaneId(1): meta(1, agent: AgentStatus(kind: "claude", state: .idle))]
        XCTAssertEqual(LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: running, attention: []).map(\.id), ["h/1"])
        let exited: [PaneId: PaneMeta] = [PaneId(1): meta(1, agent: nil)]
        XCTAssertTrue(LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: exited, attention: []).isEmpty)
    }

    /// A pane titled with its directory and an agent in the home directory: the row says what
    /// the agent waits for and "~", never a lone "~" and the user's name.
    func testAgentInHomeDirectoryReadsAsAState() {
        let metas: [PaneId: PaneMeta] = [
            PaneId(1): meta(1, title: "~", cwd: "/home/me", agent: AgentStatus(kind: "claude", state: .idle)),
            PaneId(2): meta(2, title: "/srv/app", cwd: "/srv/app", agent: AgentStatus(kind: "codex", state: .idle)),
        ]
        let items = LiveAgentFeed.items(hostId: "h", hostName: "studio", meta: metas, attention: [])
        let home = try! XCTUnwrap(items.first { $0.id == "h/1" })
        XCTAssertEqual(home.prompt, "Waiting for your next prompt")
        XCTAssertEqual(home.sessionTitle, "~")
        let app = try! XCTUnwrap(items.first { $0.id == "h/2" })
        XCTAssertEqual(app.prompt, "Waiting for your next prompt")
        XCTAssertEqual(app.sessionTitle, "app")
        XCTAssertEqual(LiveAgentFeed.folder("/Users/me"), "~")
        XCTAssertEqual(LiveAgentFeed.folder("/root"), "~")
        XCTAssertEqual(LiveAgentFeed.folder("/home/me/proj"), "proj")
    }

    func testDecisionOptionsMatchWholeWords() {
        let options = [
            DecisionOption(id: 1, label: "Yes"),
            DecisionOption(id: 2, label: "Yes, and don't ask again"),
            DecisionOption(id: 3, label: "No, and tell Claude what to do differently"),
        ]
        XCTAssertEqual(LiveAgentFeed.option(options, allow: true)?.id, 1)
        XCTAssertEqual(LiveAgentFeed.option(options, allow: false)?.id, 3)
        let odd = [DecisionOption(id: 7, label: "Proceed"), DecisionOption(id: 8, label: "Stop here")]
        XCTAssertEqual(LiveAgentFeed.option(odd, allow: true)?.id, 7)
        XCTAssertEqual(LiveAgentFeed.option(odd, allow: false)?.id, 8)
        let unnamed = [DecisionOption(id: 4, label: "1"), DecisionOption(id: 5, label: "2")]
        XCTAssertEqual(LiveAgentFeed.option(unnamed, allow: true)?.id, 4)
        XCTAssertEqual(LiveAgentFeed.option(unnamed, allow: false)?.id, 5)
    }

    // MARK: Files

    func testListingCarriesGitLetters() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { state in
            state.listings["/home/me/proj"] = DirListing(path: "/home/me/proj", entries: [
                FakeWorkspaceClient.stat("/home/me/proj/src", size: 0, kind: .dir),
                FakeWorkspaceClient.stat("/home/me/proj/README.md", size: 120),
                FakeWorkspaceClient.stat("/home/me/proj/new.txt", size: 3),
                FakeWorkspaceClient.stat("/home/me/proj/.env", size: 3),
            ], truncated: false)
            state.status = GudoCore.GitStatus(root: "/home/me/proj", branch: "main", head: "abc", upstream: nil, ahead: 0, behind: 0, files: [
                GitFileStatus(path: "src/deep/a.rs", origPath: nil, staged: .unmodified, unstaged: .modified),
                GitFileStatus(path: "new.txt", origPath: nil, staged: .unmodified, unstaged: .untracked),
                GitFileStatus(path: "README.md", origPath: nil, staged: .added, unstaged: .unmodified),
            ])
        }
        let source = LiveFileSource(app: .shared)
        let context = try fakeContext(client)
        source.contextOverride = { context }
        XCTAssertEqual(source.root, "/home/me/proj")
        XCTAssertEqual(source.hostName, "studio")
        let entries = try await source.list("/home/me/proj")
        let letters = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.git) })
        XCTAssertEqual(letters["src"], .modified, "a directory with changes inside is marked")
        XCTAssertEqual(letters["new.txt"], .untracked)
        XCTAssertEqual(letters["README.md"], .added)
        XCTAssertEqual(letters[".env"] ?? nil, nil)
        XCTAssertTrue(entries.first { $0.name == ".env" }!.isHidden)
        XCTAssertTrue(entries.first { $0.name == "src" }!.isDirectory)
    }

    func testPreviewTellsTextFromBinaryAndImages() async throws {
        let client = FakeWorkspaceClient()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        client.state.withLock { state in
            state.files["/p/a.txt"] = Data("héllo\nworld".utf8)
            state.files["/p/blob.bin"] = Data([1, 2, 0, 3])
            state.files["/p/logo.png"] = png
        }
        let source = LiveFileSource(app: .shared)
        let context = try fakeContext(client)
        source.contextOverride = { context }
        let text = try await source.preview("/p/a.txt")
        XCTAssertEqual(text, .text("héllo\nworld", truncated: false))
        let binary = try await source.preview("/p/blob.bin")
        XCTAssertEqual(binary, .binary(size: 4))
        let image = try await source.preview("/p/logo.png")
        XCTAssertEqual(image, .image(png))
    }

    func testPreviewOfAChunkCutInsideACharacter() {
        let data = Data("ab€".utf8).dropLast(1)
        XCTAssertEqual(LiveFileSource.preview(Data(data), size: 10, eof: false), .text("ab", truncated: true))
    }

    func testUploadNeverReplacesAFile() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { $0.existing = ["/p/notes.md", "/p/notes 2.md"] }
        let source = LiveFileSource(app: .shared)
        let context = try fakeContext(client)
        source.contextOverride = { context }
        let local = FileManager.default.temporaryDirectory.appending(path: "notes.md")
        try Data("x".utf8).write(to: local)
        var progress: [Double] = []
        try await source.upload(local, to: "/p") { progress.append($0) }
        let targets = client.state.withLock { $0.uploads.map(\.path) }
        XCTAssertEqual(targets, ["/p/notes.md", "/p/notes 2.md", "/p/notes 3.md"])
        XCTAssertTrue(client.state.withLock { $0.uploads.allSatisfy(\.createNew) })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(progress.last, 1)
    }

    func testRenameTrashMkdirAndDownload() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { $0.files["/p/a.txt"] = Data("abc".utf8) }
        let source = LiveFileSource(app: .shared)
        let context = try fakeContext(client)
        source.contextOverride = { context }
        try await source.rename("/p/a.txt", to: "b.txt")
        try await source.trash("/p/old")
        try await source.mkdir("/p/new")
        let url = try await source.download("/p/a.txt") { _ in }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "abc")
        XCTAssertEqual(url.lastPathComponent, "a.txt")
        let calls = client.calls
        XCTAssertTrue(calls.contains("rename /p/a.txt /p/b.txt"))
        XCTAssertTrue(calls.contains("delete /p/old trash"))
        XCTAssertTrue(calls.contains("mkdir /p/new"))
    }

    func testNoHostMeansAReasonNotAnError() {
        let source = LiveFileSource(app: .shared)
        source.contextOverride = { nil }
        XCTAssertNotNil(source.unavailableReason)
        XCTAssertEqual(source.root, "~")
    }

    // MARK: Diffs

    func testDaemonDiffGetsLineNumbers() {
        let hunk = Hunk(oldStart: 10, oldLines: 3, newStart: 10, newLines: 4, header: "@@ -10,3 +10,4 @@ fn x", lines: [
            GudoCore.DiffLine(kind: .context, text: "a"),
            GudoCore.DiffLine(kind: .removed, text: "b"),
            GudoCore.DiffLine(kind: .added, text: "B"),
            GudoCore.DiffLine(kind: .added, text: "C"),
            GudoCore.DiffLine(kind: .context, text: "d"),
            GudoCore.DiffLine(kind: .noNewline, text: "\\ No newline at end of file"),
        ])
        let file = DiffFile(FileDiff(path: "src/x.rs", oldPath: nil, change: .modified, binary: false, additions: 2, deletions: 1, hunks: [hunk], hunksOmitted: false))
        let lines = file.hunks[0].lines
        XCTAssertEqual(lines.count, 5, "the no-newline marker is not a line")
        XCTAssertEqual(lines.map(\.oldNumber), [10, 11, nil, nil, 12])
        XCTAssertEqual(lines.map(\.newNumber), [10, nil, 11, 12, 13])
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(Set(lines.map(\.id)).count, 5)
    }

    func testSplitRowsPairRemovedWithAdded() {
        let lines: [App.DiffLine] = [
            .init(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "a"),
            .init(id: 1, kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
            .init(id: 2, kind: .removed, oldNumber: 3, newNumber: nil, text: "c"),
            .init(id: 3, kind: .added, oldNumber: nil, newNumber: 2, text: "B"),
            .init(id: 4, kind: .context, oldNumber: 4, newNumber: 3, text: "d"),
            .init(id: 5, kind: .added, oldNumber: nil, newNumber: 4, text: "e"),
        ]
        let rows = DiffHunk(id: 0, header: "", lines: lines).splitRows
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[1].left?.text, "b")
        XCTAssertEqual(rows[1].right?.text, "B")
        XCTAssertEqual(rows[2].left?.text, "c")
        XCTAssertNil(rows[2].right)
        XCTAssertEqual(rows[3].left?.text, "d")
        XCTAssertNil(rows[4].left)
        XCTAssertEqual(rows[4].right?.text, "e")
    }

    func testReviewGoesToTheTurnsAgent() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { state in
            state.status = GudoCore.GitStatus(root: "/home/me/proj", branch: "main", head: nil, upstream: nil, ahead: 1, behind: 0, files: [])
            state.turns[4] = [TurnInfo(turn: 2, root: "/home/me/proj", startedAtMs: 1_000, endedAtMs: 2_000, startTree: "a", endTree: "b")]
        }
        let source = LiveDiffSource(app: .shared)
        let context = try fakeContext(client)
        client.send(.paneMeta(meta: meta(4, cwd: "/home/me/proj/src", agent: AgentStatus(kind: "claude", state: .idle))))
        client.send(.paneMeta(meta: meta(5, cwd: "/elsewhere", agent: AgentStatus(kind: "codex", state: .idle))))
        for _ in 0..<100 where context.daemon.meta.all.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        source.contextOverride = { context }

        let repository = try await source.repository()
        XCTAssertEqual(repository.branch, "main")
        XCTAssertEqual(repository.ahead, 1)
        let turns = try await source.turns()
        XCTAssertEqual(turns.map(\.turn), [2])
        XCTAssertEqual(turns.first?.agent, "Claude Code")
        XCTAssertEqual(source.reviewer(for: turns[0].scope), "Claude Code")
        _ = try await source.files(turns[0].scope)
        XCTAssertTrue(client.calls.contains("turnDiff 4 2"))

        try await source.sendReview(
            [App.ReviewNote(path: "src/x.rs", startLine: 12, endLine: 12, oldSide: false, quote: "let x = 1;", note: "use a const")],
            scope: turns[0].scope, preamble: nil)
        let review = try XCTUnwrap(client.state.withLock { $0.reviews.first })
        XCTAssertEqual(review.paneId, 4, "the agent outside the repository is not asked")
        XCTAssertTrue(review.submit)
        XCTAssertEqual(review.notes.first?.note, "use a const")
        XCTAssertEqual(review.notes.first?.quote, "let x = 1;")
    }

    func testReviewWithoutAnAgentSaysSo() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { $0.status = GudoCore.GitStatus(root: "/r", branch: nil, head: nil, upstream: nil, ahead: 0, behind: 0, files: []) }
        let source = LiveDiffSource(app: .shared)
        let context = try fakeContext(client)
        source.contextOverride = { context }
        _ = try await source.repository()
        XCTAssertNil(source.reviewer(for: .workingTree))
        do {
            try await source.sendReview([], scope: .workingTree, preamble: nil)
            XCTFail("no agent to send to")
        } catch {
            XCTAssertTrue(ScreenError.describe(error).contains("No agent"))
        }
    }

    // MARK: Editor

    func testEditorShowsInstallThenLoadsAndReusesTheSession() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { state in
            state.status = GudoCore.GitStatus(root: "/home/me/proj", branch: "main", head: nil, upstream: nil, ahead: 0, behind: 0, files: [])
            state.editorDelay = .milliseconds(300)
        }
        let editor = LiveEditorSource(app: .shared)
        editor.licence = Self.freshLicence()
        let context = try fakeContext(client, directory: "/home/me/proj/src")
        editor.contextOverride = { context }

        // First use on the host: the licence sheet, and nothing asked of the host yet.
        await editor.open()
        XCTAssertEqual(editor.phase, .needsLicence)
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("openEditor") }, "nothing starts before the user accepts")

        var phases: [EditorPhase] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if phases.last != editor.phase { phases.append(editor.phase) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await editor.acceptLicence()
        watcher.cancel()
        XCTAssertTrue(editor.licence.isAccepted(host: "h1"), "kept for the host")
        XCTAssertTrue(phases.contains(.installing), "the first run says it is setting VS Code up: \(phases)")
        XCTAssertEqual(editor.folder, "/home/me/proj", "the repository root, not the pane's subdirectory")
        guard case .loading(let url) = editor.phase else { return XCTFail("loading: \(editor.phase)") }
        XCTAssertEqual(url.host(), "localhost")
        XCTAssertTrue(client.calls.contains("openEditor /home/me/proj true"), "the user's acceptance goes to the host")
        editor.didLoad()
        XCTAssertEqual(editor.phase, .ready(url))

        // Closing keeps the server; opening again reuses it without asking the host.
        await editor.close(stopServer: false)
        XCTAssertEqual(editor.phase, .idle)
        await editor.open()
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("openEditor") }.count, 1)
        XCTAssertEqual(editor.phase, .loading(url))

        // A file at a line opens in the running editor.
        await editor.open(path: "/home/me/proj/src/main.rs", line: 42, column: nil)
        XCTAssertTrue(client.calls.contains("editorOpen /home/me/proj/src/main.rs:42"))
        XCTAssertNotNil(editor.pendingURL)

        await editor.close(stopServer: true)
        XCTAssertTrue(client.calls.contains("closeEditor true"))
    }

    func testEditorStartsWithoutWaitingForTheHostsEditorList() async throws {
        let client = FakeWorkspaceClient()
        client.state.withLock { $0.editorStatusDelay = .seconds(5) }
        let editor = LiveEditorSource(app: .shared)
        editor.licence = Self.freshLicence()
        editor.licence.accept(host: "h1")
        let context = try fakeContext(client, directory: "/home/me/proj")
        editor.contextOverride = { context }

        let started = ContinuousClock.now
        await editor.open()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        guard case .loading = editor.phase else { return XCTFail("loading: \(editor.phase)") }
    }

    private static func freshLicence() -> EditorLicence {
        let suite = "editor-licence-tests-\(UUID().uuidString)"
        return EditorLicence(defaults: UserDefaults(suiteName: suite)!)
    }

    func testEditorLicenceIsPerHostAndDeclineStartsNothing() async throws {
        let client = FakeWorkspaceClient()
        let licence = Self.freshLicence()
        let editor = LiveEditorSource(app: .shared)
        editor.licence = licence
        let context = try fakeContext(client)
        editor.contextOverride = { context }

        await editor.open()
        XCTAssertEqual(editor.phase, .needsLicence)
        editor.declineLicence()
        XCTAssertEqual(editor.phase, .idle)
        XCTAssertFalse(licence.isAccepted(host: "h1"))
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("openEditor") })

        // Accepted on another host only: this one still asks.
        licence.accept(host: "other")
        await editor.open()
        XCTAssertEqual(editor.phase, .needsLicence)

        // Accepted here (earlier, in another window): no sheet.
        licence.accept(host: "h1")
        editor.declineLicence()
        let second = LiveEditorSource(app: .shared)
        second.licence = licence
        second.contextOverride = { context }
        await second.open()
        guard case .loading = second.phase else { return XCTFail("\(second.phase)") }
        licence.withdraw(host: "h1")
        XCTAssertFalse(licence.isAccepted(host: "h1"))
    }

    func testEditorTunnelShowsTheDeviceCodeThenOpensVscodeDev() async throws {
        let client = FakeWorkspaceClient()
        let editor = LiveEditorSource(app: .shared)
        editor.licence = Self.freshLicence()
        let context = try fakeContext(client)
        editor.contextOverride = { context }

        await editor.openTunnel(account: .github)
        XCTAssertEqual(editor.mode, .tunnel)
        XCTAssertEqual(editor.phase, .needsLicence, "the tunnel needs the same terms")
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("tunnelStart") })

        await editor.acceptLicence()
        XCTAssertTrue(client.calls.contains("tunnelStart true gitHub"), "\(client.calls)")
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("cliInstall") }, "the host has a CLI")
        guard case .signingIn(let login) = editor.phase else { return XCTFail("\(editor.phase)") }
        XCTAssertEqual(login.code, "ABCD-1234")
        XCTAssertEqual(login.verificationURL.host(), "github.com")
        XCTAssertEqual(login.account, .github)

        // The user signs in in their browser; the daemon pushes Running.
        client.pushTunnel(.running(name: "studio", webUrl: "https://vscode.dev/tunnel/studio", adopted: false))
        for _ in 0..<200 where editor.phase.url == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .loading(let url) = editor.phase else { return XCTFail("\(editor.phase)") }
        XCTAssertEqual(url.host(), "vscode.dev")
        XCTAssertEqual(editor.tunnelDesktopURI?.scheme, "vscode")

        // A file opens through the tunnel too.
        await editor.open(path: "/home/me/proj/src/main.rs", line: 7, column: nil)
        XCTAssertTrue(client.calls.contains("tunnelOpen /home/me/proj/src/main.rs:7"))
        XCTAssertNotNil(editor.pendingURL)

        // Stopping ends the tunnel; the next open is the default editor.
        await editor.close(stopServer: true)
        XCTAssertTrue(client.calls.contains("tunnelStop"))
        XCTAssertEqual(editor.mode, .server)
    }

    func testTunnelWebStandInForTests() {
        XCTAssertEqual(TunnelWeb.url("https://vscode.dev/tunnel/box/home/me", base: nil)?.absoluteString, "https://vscode.dev/tunnel/box/home/me")
        XCTAssertEqual(
            TunnelWeb.url("https://vscode.dev/tunnel/box/home/me", base: "http://127.0.0.1:47712")?.absoluteString,
            "http://127.0.0.1:47712/tunnel/box/home/me")
    }

    func testRemoteSSHPlan() {
        let defaults = UserDefaults(suiteName: "remote-ssh-tests-\(UUID().uuidString)")!
        let port = RemoteSSHPlan.port(for: "host-a", defaults: defaults)
        XCTAssertTrue(RemoteSSHPlan.portRange.contains(port))
        XCTAssertEqual(RemoteSSHPlan.port(for: "host-a", defaults: defaults), port, "stable per host")
        var seen: Set<UInt16> = [port]
        for i in 0..<50 { XCTAssertTrue(seen.insert(RemoteSSHPlan.port(for: "host-\(i)-x", defaults: defaults)).inserted, "no two hosts share a port") }
        RemoteSSHPlan.reassign("host-a", to: 22999, defaults: defaults)
        XCTAssertEqual(RemoteSSHPlan.port(for: "host-a", defaults: defaults), 22999)

        XCTAssertEqual(RemoteSSHPlan.user(sshUser: "deploy", folder: "/home/me/proj"), "deploy")
        XCTAssertEqual(RemoteSSHPlan.user(sshUser: nil, folder: "/home/me/proj"), "me")
        XCTAssertEqual(RemoteSSHPlan.user(sshUser: "", folder: "/Users/me/src"), "me")
        XCTAssertEqual(RemoteSSHPlan.user(sshUser: nil, folder: "/root/x"), "root")
        XCTAssertNil(RemoteSSHPlan.user(sshUser: nil, folder: "/srv/app"))
        XCTAssertNil(RemoteSSHPlan.user(sshUser: nil, folder: nil))

        XCTAssertTrue(RemoteSSHPlan.isSSHBanner(Data("SSH-2.0-OpenSSH_9.6\r\n".utf8)))
        XCTAssertFalse(RemoteSSHPlan.isSSHBanner(Data("HTTP/1.1 400".utf8)))
        XCTAssertFalse(RemoteSSHPlan.isSSHBanner(Data()))

        XCTAssertEqual(RemoteSSHPlan.uri("vscode://vscode-remote/ssh-remote+x/p", insiders: true), "vscode-insiders://vscode-remote/ssh-remote+x/p")
        XCTAssertEqual(RemoteSSHPlan.uri("vscode://vscode-remote/ssh-remote+x/p", insiders: false), "vscode://vscode-remote/ssh-remote+x/p")
        // The URI desktop VS Code gets: Remote - SSH's hex-JSON authority for 127.0.0.1 + user + port.
        let uri = vscodeRemoteSshUri(host: VsCodeSshHost(host: "127.0.0.1", user: "me", port: port), path: "/home/me/proj", line: nil, column: nil)
        XCTAssertTrue(uri.hasPrefix("vscode://vscode-remote/ssh-remote+"), uri)
        XCTAssertTrue(uri.hasSuffix("/home/me/proj"), uri)
    }

    func testEditorWithoutAHostFailsInWords() async {
        let editor = LiveEditorSource(app: .shared)
        editor.contextOverride = { nil }
        await editor.open()
        guard case .failed(let reason) = editor.phase else { return XCTFail("\(editor.phase)") }
        XCTAssertTrue(reason.contains("Hosts"))
    }

    // MARK: Ports

    /// The fallback (no proxy): a forward on the same port number, else any.
    func testPortsSortHTTPFirstAndForwardOnTheSamePort() async throws {
        DevServerRouting.shared.isEnabled = false
        defer { DevServerRouting.shared.isEnabled = true }
        let client = FakeWorkspaceClient()
        client.state.withLock { state in
            state.ports = [
                PortInfo(port: 5432, loopbackOnly: true, paneId: nil, pid: 1, process: "postgres", kind: .other, url: nil),
                PortInfo(port: 5173, loopbackOnly: true, paneId: 1, pid: 2, process: "node", kind: .http, url: "http://localhost:5173/app?x=1"),
            ]
            state.takenPorts = [8000]
        }
        let ports = LivePortSource(app: .shared)
        let context = try fakeContext(client)
        ports.contextOverride = { context }
        XCTAssertEqual(ports.ports.map(\.port), [5173, 5432])

        let url = try await ports.open(ports.ports[0])
        XCTAssertEqual(url.absoluteString, "http://localhost:5173/app?x=1", "same port number, the printed path kept")
        let again = try await ports.open(ports.ports[0])
        XCTAssertEqual(again, url)
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("forward") }.count, 1, "an existing forward is reused")

        let busy = DetectedPort(port: 8000, process: "python3", url: nil, isHTTP: true, loopbackOnly: false, pane: nil)
        let fallback = try await ports.open(busy)
        XCTAssertEqual(fallback.port, 50_000, "a port taken here falls back to any free one")
    }

    /// A dev server opens at the URL it printed, in the host's own data store, and its
    /// connections reach the host's forward of that port.
    func testPortsOpenAtThePrintedURLThroughTheHost() async throws {
        let client = FakeWorkspaceClient()
        let ports = LivePortSource(app: .shared)
        let context = try fakeContext(client)
        ports.contextOverride = { context }
        XCTAssertEqual(ports.hostId, "h1")

        let named = DetectedPort(port: 48_325, process: "node", url: "http://app.localhost:48325/app?x=1", isHTTP: true, loopbackOnly: true, pane: nil)
        let url = try await ports.open(named)
        XCTAssertEqual(url.absoluteString, "http://app.localhost:48325/app?x=1", "the printed name and port are kept")
        let store = try XCTUnwrap(DevServerRouting.shared.store(forHost: "h1"))
        XCTAssertEqual(store.proxyConfigurations.count, 1, "the host's store goes through its proxy")
        XCTAssertNil(DevServerRouting.shared.store(forHost: "other"), "other hosts have their own")
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("forward") }, "forwards are made when the page connects")

        let plain = DetectedPort(port: 48_326, process: "python3", url: nil, isHTTP: true, loopbackOnly: true, pane: nil)
        let localURL = try await ports.open(plain)
        XCTAssertEqual(localURL.absoluteString, "http://localhost:48326/", "the same port here, served by the app")
        // Another program on this device, without the host's route cookie, gets nothing.
        let stranger = NWConnection(host: "127.0.0.1", port: 48_326, using: .tcp)
        stranger.start(queue: .global())
        stranger.send(content: Data("GET / HTTP/1.1\r\nHost: localhost:48326\r\n\r\n".utf8), completion: .idempotent)
        defer { stranger.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(client.forwards().contains { $0.target == .tcp(port: 48_326) }, "\(client.forwards())")
        // The host's pages carry the cookie: a connection asks the host for a forward of 48326.
        let cookie = try XCTUnwrap(DevServerRouting.shared.routeCookie(forHost: "h1"))
        let connection = NWConnection(host: "127.0.0.1", port: 48_326, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data("GET / HTTP/1.1\r\nHost: localhost:48326\r\nCookie: \(LoopbackRouter.routeCookie)=\(cookie)\r\n\r\n".utf8), completion: .idempotent)
        defer { connection.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !client.forwards().contains(where: { if case .tcp(48_326) = $0.target { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(client.forwards().contains { $0.localPort >= 50_000 && $0.target == .tcp(port: 48_326) }, "\(client.forwards())")
    }

    func testOnlyPortsOpenedForTheBrowserReachTheHost() {
        XCTAssertTrue(DevServerRouting.isOpened(5173, opened: [5173], panePorts: []))
        XCTAssertTrue(DevServerRouting.isOpened(8000, opened: [5173], panePorts: [8000]), "an API server in a pane")
        XCTAssertFalse(DevServerRouting.isOpened(6379, opened: [5173], panePorts: [8000]), "the host's other services")
    }

    func testDevServerPageURLs() {
        func url(_ port: UInt16, _ printed: String?) -> String {
            DevServerRouting.pageURL(for: DetectedPort(port: port, process: "", url: printed, isHTTP: true, loopbackOnly: true, pane: nil)).absoluteString
        }
        XCTAssertEqual(url(3000, nil), "http://localhost:3000/")
        XCTAssertEqual(url(3000, "http://127.0.0.1:3000/a"), "http://127.0.0.1:3000/a")
        XCTAssertEqual(url(5173, "https://app.localhost:5173/"), "https://app.localhost:5173/")
        XCTAssertEqual(url(3000, "http://192.168.1.4:3000/x?y=1"), "http://localhost:3000/x?y=1", "a LAN address: the host's loopback")
        XCTAssertEqual(DevServerRouting.storeIdentifier("h1"), DevServerRouting.storeIdentifier("h1"), "the same store across launches")
        XCTAssertNotEqual(DevServerRouting.storeIdentifier("h1"), DevServerRouting.storeIdentifier("h2"))
    }

    func testNewHTTPPortIsOffered() throws {
        let client = FakeWorkspaceClient()
        let ports = LivePortSource(app: .shared)
        let context = try fakeContext(client)
        ports.contextOverride = { context }
        ports.portsChanged("h1", [])
        XCTAssertNil(ports.offer)
        ports.portsChanged("h1", [PortInfo(port: 3000, loopbackOnly: true, paneId: nil, pid: 3, process: "node", kind: .http, url: nil)])
        XCTAssertEqual(ports.offer?.port, 3000)
        // The URL the server printed arrives after its listener: the offer opens there.
        ports.portsChanged("h1", [PortInfo(port: 3000, loopbackOnly: true, paneId: nil, pid: 3, process: "node", kind: .http, url: "http://web.localhost:3000/")])
        let offer = try XCTUnwrap(ports.offer)
        XCTAssertEqual(DevServerRouting.pageURL(for: offer).absoluteString, "http://web.localhost:3000/")
        ports.dismissOffer()
        ports.portsChanged("h1", [
            PortInfo(port: 3000, loopbackOnly: true, paneId: nil, pid: 3, process: "node", kind: .http, url: nil),
            PortInfo(port: 6379, loopbackOnly: true, paneId: nil, pid: 4, process: "redis", kind: .other, url: nil),
        ])
        XCTAssertNil(ports.offer, "known ports and non-HTTP ones are not offered")
    }

    func testAgentListenersAreNeitherListedNorOffered() throws {
        let client = FakeWorkspaceClient()
        let ports = LivePortSource(app: .shared)
        let context = try fakeContext(client)
        ports.contextOverride = { context }
        ports.portsChanged("h1", [])
        // Claude Code's sign-in callback, as an older helper reports it.
        let callback = PortInfo(port: 39563, loopbackOnly: true, paneId: nil, pid: 7, process: "claude", kind: .http, url: nil)
        ports.portsChanged("h1", [callback])
        XCTAssertNil(ports.offer, "an agent's listener is never offered")

        XCTAssertTrue(DetectedPort.isAgentListener(process: "claude", port: 3000, inAgentPane: false))
        XCTAssertTrue(DetectedPort.isAgentListener(process: "codex", port: 1455, inAgentPane: false))
        XCTAssertTrue(DetectedPort.isAgentListener(process: "2.1.307", port: 40_000, inAgentPane: false), "Claude's native binary")
        XCTAssertTrue(DetectedPort.isAgentListener(process: "node", port: 45_101, inAgentPane: true), "an agent pane's ephemeral port")
        XCTAssertFalse(DetectedPort.isAgentListener(process: "node", port: 3000, inAgentPane: true), "a server an agent started")
        XCTAssertFalse(DetectedPort.isAgentListener(process: "node", port: 45_101, inAgentPane: false))
        XCTAssertFalse(DetectedPort.isAgentListener(process: "python3", port: 8000, inAgentPane: false))
    }

    // MARK: Links

    func testDaemonLinksMapAndDeduplicate() {
        let links = Links(cwd: "/home/me/proj", links: [
            Link(kind: .path, text: "src/a.rs:12:4", target: "/home/me/proj/src/a.rs", line: 12, column: 4, exists: true, source: .screen),
            Link(kind: .url, text: "http://localhost:5173/", target: "http://localhost:5173/", line: nil, column: nil, exists: nil, source: .screen),
            Link(kind: .path, text: "src/a.rs:12:4", target: "/home/me/proj/src/a.rs", line: 12, column: 4, exists: true, source: .command(commandId: 3)),
            Link(kind: .hyperlink, text: "docs", target: "https://example.com/docs", line: nil, column: nil, exists: nil, source: .command(commandId: 3)),
            Link(kind: .path, text: "~/gone.txt", target: "/home/me/gone.txt", line: nil, column: nil, exists: false, source: .command(commandId: 3)),
        ])
        let mapped = LiveLinkSource.links(links)
        XCTAssertEqual(mapped.map(\.text), ["src/a.rs:12:4", "http://localhost:5173/", "docs", "~/gone.txt"])
        XCTAssertEqual(mapped[0].targetLine, 12)
        XCTAssertEqual(mapped[0].resolved, "/home/me/proj/src/a.rs")
        XCTAssertEqual(mapped[2].kind, .url)
        XCTAssertEqual(mapped[2].resolved, "https://example.com/docs")
        XCTAssertTrue(mapped[2].fromCommand)
        XCTAssertEqual(mapped[3].exists, false)
    }

    func testLocalScanFindsURLsAndPaths() {
        let found = LiveLinkSource.scan("open http://localhost:3000/.\nerror at ./src/main.rs:4 (see ~/notes.md)")
        XCTAssertEqual(Set(found.map(\.text)), ["http://localhost:3000/", "./src/main.rs:4", "~/notes.md"])
    }

    func testPathPartsSplitPositions() {
        let parts = PathParts("crates/a/src/lib.rs:142:9")
        XCTAssertEqual(parts.directory, "crates/a/src/")
        XCTAssertEqual(parts.name, "lib.rs")
        XCTAssertEqual(parts.position, ":142:9")
        XCTAssertEqual(parts.numbers.line, 142)
        XCTAssertEqual(parts.numbers.column, 9)
    }

    func testShellAndGitPathsMatchAcrossPrivate() {
        XCTAssertTrue(PathMatch.isInside("/var/folders/x/proj/src", "/private/var/folders/x/proj"))
        XCTAssertTrue(PathMatch.isInside("/private/tmp/a", "/tmp/a/"))
        XCTAssertFalse(PathMatch.isInside("/var/folders/x/project", "/var/folders/x/proj"))
    }

    // MARK: Errors

    func testWorkspaceErrorsReadAsWords() {
        XCTAssertEqual(ScreenError.describe(WorkspaceError.Unavailable(message: "git is not installed")), "git is not installed")
        XCTAssertTrue(ScreenError.describe(WorkspaceError.Disconnected).contains("not connected"))
        XCTAssertFalse(ScreenError.describe(WorkspaceError.NotFound(message: "x")).contains("GudoCore"))
    }
}
