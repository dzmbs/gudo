import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI

/// Floating windows for design review (`-screen floating…`, `MacSnapshotTests`,
/// several windows, the tray and a split inside a window. Real panes with written screens.
@MainActor
enum FloatingFixtures {
    /// The panes a fixture made, by role.
    struct Panes {
        var shell: PaneId
        var tests: PaneId
        var htop: PaneId
        var agent: PaneId?
        var logs: PaneId?
    }

    static let screens: Set<String> = ["floating", "floating-tiled", "floating-multi", "floating-tray", "floating-zoom"]

    /// Builds `screen` in the workspace's active tab (one fresh pane).
    @discardableResult
    static func apply(_ screen: String, workspace: Workspace, model: WindowModel) async -> Panes? {
        guard let panes = await base(workspace, floated: screen != "floating-tiled") else { return nil }
        var result = panes
        switch screen {
        case "floating-multi":
            result = await multi(workspace, panes)
        case "floating-tray":
            result = await multi(workspace, panes)
            if let agent = result.agent { workspace.apply(.setFloat(agent, frame: nil, minimized: true, pinned: nil)) }
            if let logs = result.logs { workspace.apply(.setFloat(logs, frame: nil, minimized: true, pinned: nil)) }
            workspace.apply(.focus(panes.htop))
        case "floating-zoom":
            workspace.apply(.focus(panes.tests))
            workspace.apply(.toggleZoom)
        default:
            break
        }
        try? await Task.sleep(for: .milliseconds(900))
        paint(workspace, result)
        return result
    }

    /// A shell beside a test run, htop floating over both (or tiled beside them).
    static func base(_ workspace: Workspace, floated: Bool = true) async -> Panes? {
        guard let shell = workspace.focusedPane, let tab = workspace.session.activeTabId else { return nil }
        workspace.apply(.rename(tab, "~/projects/unnamed"))
        workspace.apply(.split(shell, .horizontal))
        guard let tests = workspace.focusedPane, tests != shell else { return nil }
        workspace.apply(.split(tests, .horizontal))
        guard let htop = workspace.focusedPane, htop != tests else { return nil }
        if floated { workspace.apply(.float(htop, frame: htopFrame)) }
        workspace.apply(.focus(htop))
        MockPaneStatus.fixture = [
            shell.description: ("zsh", nil),
            tests.description: ("cargo", nil),
            htop.description: ("htop", nil),
        ]
        try? await Task.sleep(for: .milliseconds(300))
        return Panes(shell: shell, tests: tests, htop: htop)
    }

    static let htopFrame = FloatFrame(x: 0.2, y: 0.17, width: 0.6, height: 0.62)

    /// Two more windows: Claude at work split with a log tail inside one window, cascaded.
    static func multi(_ workspace: Workspace, _ panes: Panes) async -> Panes {
        var out = panes
        workspace.apply(.setFloat(panes.htop, frame: FloatFrame(x: 0.05, y: 0.08, width: 0.5, height: 0.56), minimized: nil, pinned: nil))
        workspace.apply(.split(panes.tests, .vertical))
        guard let agent = workspace.focusedPane, agent != panes.tests else { return out }
        workspace.apply(.float(agent, frame: FloatFrame(x: 0.42, y: 0.34, width: 0.54, height: 0.6)))
        workspace.apply(.focus(agent))
        workspace.apply(.split(agent, .vertical))
        let logs = workspace.focusedPane
        workspace.apply(.focus(agent))
        out.agent = agent
        out.logs = logs
        var fixture = MockPaneStatus.fixture ?? [:]
        fixture[agent.description] = ("claude", .working)
        if let logs { fixture[logs.description] = ("tail", nil) }
        MockPaneStatus.fixture = fixture
        MockPaneStatus.details = [agent.description: "Docking floats beside a pane · 3m"]
        try? await Task.sleep(for: .milliseconds(300))
        return out
    }

    /// Writes each pane's screen at its current grid.
    static func paint(_ workspace: Workspace, _ panes: Panes) {
        write(shellScreen, to: panes.shell, in: workspace)
        write(testScreen, to: panes.tests, in: workspace)
        let grid = workspace.grids[panes.htop] ?? GridSize(cols: 100, rows: 30)
        write(htop(cols: Int(grid.cols), rows: Int(grid.rows)), to: panes.htop, in: workspace)
        if let agent = panes.agent { write(agentScreen, to: agent, in: workspace) }
        if let logs = panes.logs { write(logScreen, to: logs, in: workspace) }
    }

    static func write(_ text: String, to pane: PaneId, in workspace: Workspace) {
        guard let surface = workspace.panes[pane]?.view.surface else { return }
        surface.terminal.write(Array(("\u{1b}[?25l\u{1b}[2J\u{1b}[H" + text).utf8))
        surface.outputArrived()
    }

    // MARK: Screens

    private static let esc = "\u{1b}["
    private static func sgr(_ codes: String) -> String { "\(esc)\(codes)m" }
    private static let reset = sgr("0")

    static var shellScreen: String {
        let prompt = "\(sgr("36"))~/projects/unnamed\(reset) \(sgr("35"))main\(reset) \(sgr("32"))❯\(reset) "
        let log = [
            ("adaf810", "PTY bound test: raw mode, so input backs up"),
            ("7fb4929", "Merge final polish: layer animations, staged panes"),
            ("dc7c2a6", "Fix leftovers from the iPad and iPhone campaigns"),
            ("0328b4a", "Merge daemon stress fixes: bounded slow clients"),
            ("d90a92c", "Stress: scenario scripts and docs/STRESS.md"),
            ("4d97cb4", "Floating windows on the wire"),
        ]
        var lines = [prompt + "git log --oneline -6"]
        lines += log.map { "\(sgr("33"))\($0.0)\(reset) \($0.1)" }
        lines += ["", prompt + "git status --short", " \(sgr("31"))M\(reset) apple/App/Sources/Views/PaneCanvas.swift", " \(sgr("31"))M\(reset) docs/DESIGN.md", "", prompt]
        return lines.joined(separator: "\r\n")
    }

    static var testScreen: String {
        var lines = [
            "\(sgr("32"))❯\(reset) cargo test -p daemon layout",
            "\(sgr("1;32"))   Compiling\(reset) daemon v0.0.0 (crates/daemon)",
            "\(sgr("1;32"))    Finished\(reset) `test` profile [unoptimized + debuginfo] in 38.4s",
            "\(sgr("1;32"))     Running\(reset) unittests src/lib.rs",
            "",
            "running 14 tests",
        ]
        for name in [
            "floats_dock_in_place", "floats_cascade", "minimized_window_leaves_focus", "restore_raises",
            "dock_beside_a_tiled_pane", "move_pane_to_edge", "resize_stays_in_its_layer", "tab_keeps_a_tiled_pane",
            "pinned_window_over_every_tab", "close_when_done", "nesting_is_capped",
        ] {
            lines.append("test layout::tests::\(name) ... \(sgr("32"))ok\(reset)")
        }
        lines += ["", "test result: \(sgr("32"))ok\(reset). 14 passed; 0 failed; 0 ignored; finished in 0.04s", "", "\(sgr("32"))❯\(reset) "]
        return lines.joined(separator: "\r\n")
    }

    static var agentScreen: String {
        [
            "\(sgr("38;5;209"))✻\(reset) \(sgr("1"))Welcome to Claude Code\(reset)",
            "",
            "\(sgr("2"))>\(reset) dock a floating window beside the pane it is dropped on",
            "",
            "\(sgr("38;5;209"))⏺\(reset) Reading \(sgr("1"))crates/daemon/src/layout.rs\(reset)",
            "\(sgr("38;5;209"))⏺\(reset) The dock op takes the window's subtree and puts it beside",
            "  the target, so its splits come along.",
            "",
            "\(sgr("38;5;209"))⏺\(reset) Update(\(sgr("1"))layout.rs\(reset))",
            "  ⎿  \(sgr("32"))+ self.check_insert(target, &node)?;\(reset)",
            "",
            "\(sgr("38;5;209"))✳ Docking…\(reset) \(sgr("2"))(3m · esc to interrupt)\(reset)",
        ].joined(separator: "\r\n")
    }

    static var logScreen: String {
        [
            "\(sgr("2"))10:42:07\(reset) \(sgr("32"))INFO\(reset)  hostd: layout rev 412 → 3 clients",
            "\(sgr("2"))10:42:07\(reset) \(sgr("32"))INFO\(reset)  floats: window 7 raised",
            "\(sgr("2"))10:42:09\(reset) \(sgr("32"))INFO\(reset)  floats: window 9 minimized",
            "\(sgr("2"))10:42:12\(reset) \(sgr("33"))WARN\(reset)  client 3 slow: 412 KiB queued",
            "\(sgr("2"))10:42:13\(reset) \(sgr("32"))INFO\(reset)  floats: window 9 restored",
        ].joined(separator: "\r\n")
    }

    /// htop at `cols` × `rows`: meters, the process table with its green header and the
    /// selected row, and the function-key bar.
    static func htop(cols: Int, rows: Int) -> String {
        let cols = max(cols, 40)
        func pad(_ s: String, _ width: Int) -> String { s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count) }
        func meter(_ label: String, _ width: Int, _ parts: [(Double, String)], _ text: String) -> String {
            let inner = max(width - label.count - 2, 4)
            var bar = ""
            var used = 0
            for (fraction, color) in parts {
                let n = min(Int(Double(inner) * fraction), inner - used)
                bar += sgr(color) + String(repeating: "|", count: max(n, 0))
                used += max(n, 0)
            }
            let free = max(inner - used - text.count, 0)
            return "\(sgr("36"))\(label)\(reset)\(sgr("1"))[\(reset)\(bar)\(String(repeating: " ", count: free))\(sgr("2"))\(text)\(reset)\(sgr("1"))]\(reset)"
        }
        let half = cols / 2 - 1
        let cpus: [(Double, Double)] = [(0.42, 0.08), (0.18, 0.05), (0.66, 0.12), (0.09, 0.02), (0.31, 0.06), (0.12, 0.03), (0.55, 0.1), (0.07, 0.02)]
        var lines: [String] = []
        for row in 0..<4 {
            let a = cpus[row], b = cpus[row + 4]
            let left = meter(String(format: "%4d", row), half, [(a.0, "32"), (a.1, "31")], String(format: "%.1f%%", (a.0 + a.1) * 100))
            let right = meter(String(format: "%4d", row + 4), half, [(b.0, "32"), (b.1, "31")], String(format: "%.1f%%", (b.0 + b.1) * 100))
            lines.append(left + "  " + right)
        }
        lines.append(meter("  Mem", half, [(0.38, "32"), (0.06, "34"), (0.14, "33")], "9.31G/16.0G") + "  " + "\(sgr("36"))Tasks: \(reset)\(sgr("1"))312\(reset)\(sgr("36")), \(reset)\(sgr("1;32"))1204\(reset)\(sgr("36")) thr; \(reset)\(sgr("1;32"))3\(reset)\(sgr("36")) running\(reset)")
        lines.append(meter("  Swp", half, [(0.04, "31")], "128M/2.00G") + "  " + "\(sgr("36"))Load average: \(reset)\(sgr("1"))2.41 \(reset)\(sgr("1;36"))1.98 \(reset)\(sgr("36"))1.77\(reset)")
        lines.append(String(repeating: " ", count: half + 2) + "\(sgr("36"))Uptime: \(reset)\(sgr("1"))4 days, 03:12:44\(reset)")
        lines.append("")
        let header = "    PID USER       PRI  NI  VIRT   RES   SHR S  CPU% MEM%   TIME+  Command"
        lines.append("\(sgr("30;42"))\(pad(header, cols))\(reset)")
        let procs: [(Int, String, String, String, String, String, Double, Double, String)] = [
            (48213, "me", "1214M", "312M", "98M", "R", 38.2, 1.9, "unnamed-hostd --foreground"),
            (51877, "me", "2104M", "540M", "122M", "S", 21.4, 3.3, "cargo test -p daemon"),
            (902, "root", "412M", "88M", "41M", "S", 9.1, 0.5, "/usr/libexec/WindowServer"),
            (51902, "me", "880M", "201M", "64M", "S", 6.7, 1.2, "claude --resume"),
            (1388, "me", "3.1G", "742M", "210M", "S", 4.3, 4.5, "Xcode"),
            (447, "root", "96M", "12M", "8M", "S", 1.2, 0.1, "/usr/sbin/sshd -D"),
            (51911, "me", "48M", "9M", "5M", "S", 0.8, 0.1, "tail -f /var/log/hostd.log"),
            (1, "root", "64M", "18M", "11M", "S", 0.3, 0.1, "/sbin/launchd"),
            (712, "me", "212M", "44M", "21M", "S", 0.2, 0.3, "zsh -l"),
            (52004, "me", "34M", "6M", "4M", "R", 0.2, 0.0, "htop"),
            (633, "root", "71M", "14M", "9M", "S", 0.1, 0.1, "/usr/libexec/logd"),
            (1502, "me", "520M", "96M", "40M", "S", 0.1, 0.6, "node dev-server.js"),
            (1650, "me", "180M", "31M", "17M", "S", 0.0, 0.2, "ssh-agent"),
            (1702, "me", "95M", "22M", "12M", "S", 0.0, 0.1, "git fsmonitor--daemon"),
        ]
        let room = max(rows - lines.count - 1, 0)
        for (index, p) in procs.prefix(room).enumerated() {
            let time = String(format: "%2d:%02d.%02d", index * 3 % 60, (index * 17) % 60, (index * 29) % 100)
            let base = String(format: "%7d %@ %3d %3d %5@ %5@ %5@ %@ %5.1f %4.1f %@  ", p.0, pad(p.1, 9), 20, 0, p.2, p.3, p.4, p.5, p.6, p.7, time)
            if index == 0 {
                lines.append("\(sgr("30;46"))\(pad(base + p.8, cols))\(reset)")
            } else {
                let user = p.1 == "root" ? sgr("2") : ""
                let cpu = p.6 > 10 ? sgr("1;31") : ""
                let program = p.8.split(separator: " ").first.map(String.init) ?? p.8
                let args = String(p.8.dropFirst(program.count))
                lines.append("\(user)\(cpu)\(base)\(reset)\(sgr("1"))\(program)\(reset)\(sgr("2"))\(args)\(reset)")
            }
        }
        while lines.count < rows - 1 { lines.append("") }
        let keys = [("F1", "Help"), ("F2", "Setup"), ("F3", "Search"), ("F4", "Filter"), ("F5", "Tree"), ("F6", "SortBy"), ("F7", "Nice -"), ("F8", "Nice +"), ("F9", "Kill"), ("F10", "Quit")]
        var bar = ""
        var width = 0
        for (key, label) in keys where width + key.count + 6 <= cols {
            bar += "\(reset)\(key)\(sgr("30;46"))\(pad(label, 6))"
            width += key.count + 6
        }
        lines.append(bar + "\(sgr("30;46"))\(String(repeating: " ", count: max(cols - width, 0)))\(reset)")
        return lines.joined(separator: "\r\n")
    }
}
