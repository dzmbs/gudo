import Foundation
import HostKit
import PaneLayout

/// Two shells for reviewing layout motion (`-screen transitions-columns|transitions-rows`,
/// `MacSnapshotTests.testTransitions`): side by side or stacked, each at a zsh-like prompt with
/// a clock right-aligned (RPROMPT) that the stand-in shell redraws at each new width, as zsh does.
@MainActor
enum TransitionFixtures {
    static let screens: Set<String> = ["transitions-columns", "transitions-rows"]

    /// The two panes, first (left or top) and second.
    static var last: (first: PaneId, second: PaneId)?

    static func apply(_ screen: String, workspace: Workspace) async {
        guard let first = workspace.focusedPane, let tab = workspace.session.activeTabId else { return }
        workspace.apply(.rename(tab, "~/projects/gudo"))
        workspace.apply(.split(first, screen == "transitions-rows" ? .vertical : .horizontal))
        guard let second = workspace.focusedPane, second != first else { return }
        MockPaneStatus.fixture = [first.description: ("zsh", nil), second.description: ("zsh", nil)]
        workspace.layoutChangeUntil = .now + .seconds(4)
        for _ in 0..<60 where ![first, second].allSatisfy({ workspace.panes[$0]?.view.surface.grid != nil }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(600))
        paint(workspace, first: first, second: second)
        last = (first, second)
    }

    static func paint(_ workspace: Workspace, first: PaneId, second: PaneId) {
        show(logScreen, in: first, of: workspace, clock: "19:44")
        show(buildScreen, in: second, of: workspace, clock: "19:44")
    }

    private static func show(_ text: String, in pane: PaneId, of workspace: Workspace, clock: String) {
        let backend = workspace.panes[pane]?.backend
        guard let echo = (backend.flatMap(SharedPaneBackend.underlying) ?? backend) as? EchoBackend else { return }
        echo.show("\u{1b}[2J\u{1b}[H" + text + "\r\n")
        echo.showPrompt(prompt, width: promptWidth, right: "\u{1b}[2m\(clock)\u{1b}[0m", width: clock.count)
    }

    private static let esc = "\u{1b}["
    private static func sgr(_ codes: String) -> String { "\(esc)\(codes)m" }
    private static let reset = sgr("0")
    private static let prompt = "\(sgr("36"))~/projects/gudo\(reset) \(sgr("35"))main\(reset) \(sgr("32"))❯\(reset) "
    private static let promptWidth = 26

    private static var logScreen: String {
        let log = [
            ("adaf810", "PTY bound test: raw mode, so input backs up"),
            ("7fb4929", "Merge final polish: layer animations, staged panes"),
            ("dc7c2a6", "Fix leftovers from the iPad and iPhone campaigns"),
            ("0328b4a", "Merge daemon stress fixes: bounded slow clients"),
            ("d90a92c", "Stress: scenario scripts and docs/STRESS.md"),
        ]
        var lines = [prompt + "git log --oneline -5"]
        lines += log.map { "\(sgr("33"))\($0.0)\(reset) \($0.1)" }
        lines += ["", prompt + "git status --short", " \(sgr("31"))M\(reset) apple/App/Sources/Views/SplitTreeView.swift"]
        return lines.joined(separator: "\r\n")
    }

    private static var buildScreen: String {
        [
            prompt + "cargo build -p gudo-hostd",
            "\(sgr("1;32"))   Compiling\(reset) daemon v0.0.0 (/Users/me/projects/gudo/crates/daemon)",
            "\(sgr("1;32"))   Compiling\(reset) hostd v0.0.0 (/Users/me/projects/gudo/crates/hostd)",
            "\(sgr("1;32"))    Finished\(reset) `dev` profile [unoptimized + debuginfo] target(s) in 41.27s",
        ].joined(separator: "\r\n")
    }
}
