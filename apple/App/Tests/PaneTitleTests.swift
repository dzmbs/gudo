import HostKit
import PaneLayout
import Synchronization
import XCTest
@testable import App

/// The title a pane gives its tab follows the shell's state, so a quick command never shows.
@MainActor
final class PaneTitleTests: XCTestCase {
    private final class Feed: PaneBackend, @unchecked Sendable {
        let deliver = Mutex<(@Sendable (PaneEvent) -> Void)?>(nil)
        func start(events: @escaping @Sendable (PaneEvent) -> Void) { deliver.withLock { $0 = events } }
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
        func send(_ text: String) { deliver.withLock { $0 }?(.output(Data(text.utf8))) }
    }

    private static let esc = "\u{1b}"
    private static let bel = "\u{07}"

    private static let prompt = [
        "\(esc)]133;D;0\(bel)",
        "\(esc)]7;kitty-shell-cwd://host/Users/me/src\(bel)",
        "\(esc)]2;~/src\(bel)",
        "\r\(esc)[J\(esc)]133;A;cl=line\(bel)~/src % \(esc)]133;B\(bel)",
        "\(esc)[5 q",
    ]

    /// `ls` in zsh with shell integration, in the reads it reached a terminal in.
    private static let quickCommand = [
        "ls",
        "\(esc)[5 q",
        "\(esc)[?2004l\r\r\n",
        "\(esc)]133;C\(bel)",
        "\(esc)]2;ls\(bel)",
        "\(esc)[0 q",
        "Cargo.toml\t\tREADME.md\t\tcrates\r\n",
    ] + prompt

    private var titles: [String] = []

    private func makePane(_ feed: Feed) throws -> Pane {
        let pane = try Pane(id: PaneId(1), backend: feed, onExit: {})
        pane.onContextChange = { [weak self, weak pane] in self?.titles.append(pane?.title ?? "") }
        return pane
    }

    /// Delivers each read on its own turn of the main actor, as reads apart in time arrive.
    private func play(_ reads: [String], on feed: Feed) {
        for read in reads {
            feed.send(read)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    func testAQuickCommandNeverChangesTheTitle() throws {
        let feed = Feed()
        let pane = try makePane(feed)
        play(Self.prompt, on: feed)
        let before = pane.title
        titles = []
        play(Self.quickCommand + Self.quickCommand, on: feed)
        XCTAssertEqual(titles, [], "the tab's title changed during `ls`")
        XCTAssertEqual(pane.title, before)
    }

    func testAFullScreenProgramShowsItsTitle() throws {
        let feed = Feed()
        let pane = try makePane(feed)
        play(Self.prompt, on: feed)
        titles = []
        play(
            [
                "htop\r\n", "\(Self.esc)]133;C\(Self.bel)", "\(Self.esc)]2;htop\(Self.bel)",
                "\(Self.esc)[?1049h\(Self.esc)[H\(Self.esc)[2J  CPU[||||   12.0%]",
            ], on: feed)
        XCTAssertEqual(pane.title, "htop")
        play(["\(Self.esc)[?1049l"] + Self.prompt, on: feed)
        XCTAssertEqual(titles, ["htop", ""])
    }
}
