import GudoCore
import HostKit
import PaneLayout
import XCTest
@testable import App
#if os(iOS)
import UIKit
#endif

/// Paths clicked in a terminal: where they open, how they resolve, and what the viewer reads.
@MainActor
final class FileLinksTests: XCTestCase {
    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private func windowWithTerminals() -> WindowModel {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        model.activeMixedTab = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        return model
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FileLinkOpening.key)
        super.tearDown()
    }

    func testAPathOpensInTheViewerAndTheLeafIsReused() throws {
        let model = windowWithTerminals()
        let first = FileTarget(hostId: "h1", path: "/w/src/a.rs", line: 12, column: 5)
        model.openFile(first, kind: .file, choice: .gudo)
        if isPhone {
            XCTAssertEqual(model.sheet, .fileViewer)
            XCTAssertEqual(model.fileViewerTarget, first)
            return
        }
        XCTAssertNil(model.sheet)
        let viewer = try XCTUnwrap(model.activeMixed?.focusedTool)
        XCTAssertEqual(viewer.tool, .viewer)
        XCTAssertEqual(viewer.path, "/w/src/a.rs")
        XCTAssertEqual(viewer.line, 12)
        XCTAssertEqual(model.activeMixed?.leaves.count, 3)

        let second = FileTarget(hostId: "h1", path: "/w/README.md")
        model.openFile(second, kind: .unknown, choice: .gudo)
        XCTAssertEqual(model.activeMixed?.leaves.count, 3, "the viewer shows the next file")
        XCTAssertEqual(model.activeMixed?.focusedTool?.id, viewer.id)
        XCTAssertEqual(model.activeMixed?.focusedTool?.path, "/w/README.md")
        XCTAssertNil(model.activeMixed?.focusedTool?.line)
    }

    func testAFolderOpensInFiles() throws {
        let model = windowWithTerminals()
        model.openFile(FileTarget(hostId: "h1", path: "/w/src"), kind: .directory, choice: .gudo)
        if isPhone {
            XCTAssertEqual(model.sheet, .files)
            XCTAssertEqual(model.filesStartFolder, "/w/src")
            return
        }
        let files = try XCTUnwrap(model.activeMixed?.focusedTool)
        XCTAssertEqual(files.tool, .files)
        XCTAssertEqual(model.filesNavigator(for: files.id, root: "~").place, .folder("/w/src"))
    }

    func testVSCodeChoiceNeverOpensTheViewer() {
        let model = windowWithTerminals()
        model.openFile(FileTarget(hostId: "h1", path: "/w/a.rs", line: 3), kind: .file, choice: .vsCode)
        XCTAssertNotEqual(model.sheet, .fileViewer)
        XCTAssertNil(model.activeMixed?.leaf(showing: .viewer))
    }

    func testThePreferenceDefaultsToGudoAndOptionMeansVSCode() {
        XCTAssertEqual(FileLinkOpening.current, .gudo)
        XCTAssertEqual(FileLinkOpening.forClick(optionHeld: false), .gudo)
        XCTAssertEqual(FileLinkOpening.forClick(optionHeld: true), .vsCode)
        FileLinkOpening.current = .vsCode
        XCTAssertEqual(FileLinkOpening.forClick(optionHeld: false), .vsCode)
    }

    func testTheDaemonsAnswerWinsAndOldDaemonsKeepTheAppsJoin() async {
        let joined = FileTarget(hostId: "h1", path: "/now/notes.txt", line: 2)
        let daemon = FakePathDaemon(offers: true, answer: ResolvedPath(path: "/then/notes.txt", found: .file(size: 5)))
        let (resolved, kind) = await FileLinks.resolve(joined, printed: "notes.txt", daemon: daemon, pane: 7, command: 3)
        XCTAssertEqual(resolved.path, "/then/notes.txt")
        XCTAssertEqual(resolved.line, 2)
        XCTAssertEqual(kind, .file)
        XCTAssertEqual(daemon.asked, [FakePathDaemon.Question(pane: 7, command: 3, paths: ["notes.txt"])])

        let old = FakePathDaemon(offers: false, answer: nil)
        let (kept, unknown) = await FileLinks.resolve(joined, printed: "notes.txt", daemon: old, pane: 7, command: 3)
        XCTAssertEqual(kept, joined)
        XCTAssertEqual(unknown, .unknown)
        XCTAssertTrue(old.asked.isEmpty)
    }

    func testAFileHostNamingAnotherMachineIsNotThisOne() {
        XCTAssertTrue(FileLinks.isThisMachine("studio", machineName: "Studio.local"))
        XCTAssertTrue(FileLinks.isThisMachine("build-box", machineName: ""), "a name the app can't check")
        XCTAssertFalse(FileLinks.isThisMachine("build-box", machineName: "studio"))
    }

    func testOnlyPathsThatExistUnderlineOnceThePointerRests() async throws {
        var looked: [PathUnderlines.Key] = []
        var learned = 0
        let underlines = PathUnderlines(
            lookup: { key in
                looked.append(key)
                return key.printed != "gone.txt"
            },
            onLearned: { learned += 1 })
        let notes = PathUnderlines.Key(command: 3, printed: "notes.txt")
        let gone = PathUnderlines.Key(command: 3, printed: "gone.txt")
        XCTAssertFalse(underlines.underlines(PathUnderlines.Key(command: 3, printed: "passing.txt")))
        XCTAssertFalse(underlines.underlines(notes), "nothing until the daemon says")
        try await waitUntil { learned == 1 }
        XCTAssertEqual(looked, [notes], "the path the pointer only passed was never asked about")
        XCTAssertTrue(underlines.underlines(notes))
        XCTAssertFalse(underlines.underlines(gone))
        try await waitUntil { learned == 2 }
        XCTAssertFalse(underlines.underlines(gone))
        XCTAssertEqual(looked, [notes, gone], "answers are kept")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    // MARK: Viewer

    func testTheViewerReadsOnToALineBeyondTheFirstChunk() async throws {
        let lineCount = 200_000
        let text = (1...lineCount).map { "line \($0) of a long log" }.joined(separator: "\n")
        XCTAssertGreaterThan(text.utf8.count, Int(FileViewerModel.chunkSize) * 2)
        let model = FileViewerModel(
            target: FileTarget(hostId: nil, path: "/log.txt", line: 150_000), reader: TextReader(files: ["/log.txt": text]))
        await model.load()
        guard case .text(let window) = model.content else { return XCTFail("\(model.content)") }
        XCTAssertTrue(window.hasEarlier)
        XCTAssertGreaterThan(window.firstLine, 1)
        XCTAssertLessThanOrEqual(window.firstLine, 150_000)
        XCTAssertGreaterThanOrEqual(window.lastLine, 150_000)
        XCTAssertEqual(window.lines[150_000 - window.firstLine], "line 150000 of a long log")
    }

    func testTheViewerShowsAShortFileWholeAndSaysWhatIsMissing() async {
        let reader = TextReader(files: ["/a.md": "# A\n\nb\n", "/bin": "\u{0}\u{1}ELF"])
        let short = FileViewerModel(target: FileTarget(hostId: nil, path: "/a.md"), reader: reader)
        await short.load()
        XCTAssertEqual(short.content, .text(FileWindow(lines: ["# A", "", "b"], firstLine: 1, hasEarlier: false, hasLater: false)))
        let binary = FileViewerModel(target: FileTarget(hostId: nil, path: "/bin"), reader: reader)
        await binary.load()
        XCTAssertEqual(binary.content, .binary(size: 5))
        let missing = FileViewerModel(target: FileTarget(hostId: nil, path: "/gone.txt"), reader: reader)
        await missing.load()
        XCTAssertEqual(missing.content, .missing)
    }

    func testMarkdownBecomesBlocks() {
        let blocks = MarkdownBlock.parse("# Title\n\nSome **bold** text.\n\n- one\n- two\n\n```\nlet x = 1\n```\n\n> quoted\n")
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1), .paragraph, .listItem(marker: "•"), .listItem(marker: "•"), .code, .paragraph,
        ])
        XCTAssertEqual(String(blocks[4].text.characters), "let x = 1")
        XCTAssertTrue(blocks[5].isQuote)
    }
}

private struct TextReader: FileReading {
    let files: [String: String]

    func stat(_ path: String) async throws -> FileFacts {
        guard let text = files[path] else { throw WorkspaceError.NotFound(message: path) }
        return FileFacts(isDirectory: false, size: UInt64(text.utf8.count))
    }

    func read(_ path: String, offset: UInt64, length: UInt32) async throws -> FileBytes {
        guard let text = files[path] else { throw WorkspaceError.NotFound(message: path) }
        let all = Data(text.utf8)
        let start = min(all.count, Int(offset))
        let end = min(all.count, start + Int(length))
        return FileBytes(data: all.subdata(in: start..<end), isEnd: end == all.count)
    }
}

private final class FakePathDaemon: DaemonPathAPI, @unchecked Sendable {
    struct Question: Equatable {
        var pane: UInt64
        var command: UInt64?
        var paths: [String]
    }

    let offers: Bool
    let answer: ResolvedPath?
    private(set) var asked: [Question] = []

    init(offers: Bool, answer: ResolvedPath?) {
        self.offers = offers
        self.answer = answer
    }

    func resolvePaths(paneId: UInt64, commandId: UInt64?, paths: [String]) async throws -> [ResolvedPath] {
        asked.append(Question(pane: paneId, command: commandId, paths: paths))
        return answer.map { [$0] } ?? []
    }

    func offersResolvePaths() -> Bool { offers }
}
