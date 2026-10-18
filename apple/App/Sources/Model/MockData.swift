import DesignSystem
import Foundation
import Observation

// Stand-ins for the daemon-backed sources until the wiring lands. They hold believable data so
// every screen can be designed, screenshotted and reviewed against real-length content.

private func ago(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceNow: -seconds) }

@Observable
final class MockHostDirectory: HostDirectory {
    var hosts: [HostSummary] = [
        HostSummary(
            id: "studio", name: "studio", address: "me@studio.local", kind: .daemon, connection: .connected,
            sessionCount: 4, agentCounts: [.working: 2, .blocked: 1, .done: 1],
            needsYou: "Claude wants to run cargo test -p apple-ffi --release",
            lastLine: "test layout::tests::split_ratio ... ok", lastSeen: .now, isPinned: true),
        HostSummary(
            id: "devbox", name: "devbox", address: "devbox.tail3f2c.ts.net", kind: .daemon,
            connection: .reconnecting(attempt: 3, since: ago(14)), sessionCount: 2, agentCounts: [.working: 1],
            lastLine: "Compiling quinn-proto v0.11.9", lastSeen: ago(14), isPinned: true),
        HostSummary(
            id: "build-01", name: "build-01", address: "ci@build-01.internal:2222", kind: .ssh, connection: .connected,
            sessionCount: 1, agentCounts: [:], lastLine: "$ journalctl -fu runner", lastSeen: ago(60 * 3), isPinned: false),
        HostSummary(
            id: "garage", name: "garage-pi", address: "pi@192.168.1.40", kind: .ssh,
            connection: .unreachable(reason: "No route to host.", hint: "Check that the Pi is on and on this network."),
            sessionCount: 0, agentCounts: [:], lastSeen: ago(60 * 60 * 26), isPinned: false),
    ]

    func connect(_ id: HostSummary.ID) {}
    func forget(_ id: HostSummary.ID) { hosts.removeAll { $0.id == id } }
    func togglePin(_ id: HostSummary.ID) {
        if let index = hosts.firstIndex(where: { $0.id == id }) { hosts[index].isPinned.toggle() }
    }
    func quickConnect(_ destination: String) {}
    func pair(ticket: String) async throws -> HostSummary {
        try await Task.sleep(for: .milliseconds(900))
        let host = HostSummary(
            id: UUID().uuidString, name: "macbook-air", address: "macbook-air.tail3f2c.ts.net", kind: .daemon,
            connection: .connected, sessionCount: 0, agentCounts: [:], lastSeen: .now, isPinned: false)
        hosts.append(host)
        return host
    }
}

@Observable
final class MockAgentFeed: AgentFeed {
    var items: [AgentItem] = [
        AgentItem(
            id: "a1", agent: .claude, hostName: "studio", sessionTitle: "unnamed · apple-ffi", state: .blocked,
            since: ago(4 * 60), prompt: "Expose the layout store over the FFI boundary and add tests",
            request: .permission(tool: "Bash", detail: "cargo test -p apple-ffi --release")),
        AgentItem(
            id: "a2", agent: .codex, hostName: "devbox", sessionTitle: "api · migrations", state: .blocked,
            since: ago(11 * 60), prompt: "Write the v2 sessions migration",
            request: .question("Should the migration drop the legacy sessions_v1 table, or keep it read-only for one release?")),
        AgentItem(
            id: "a3", agent: .claude, hostName: "studio", sessionTitle: "unnamed · renderer", state: .working,
            since: ago(6 * 60 + 12), prompt: "Batch glyph uploads so a full-screen redraw stays under 2 ms"),
        AgentItem(
            id: "a4", agent: .codex, hostName: "devbox", sessionTitle: "api · reconnect", state: .working,
            since: ago(52), prompt: "Find why the reconnect test flakes on CI"),
        AgentItem(
            id: "a5", agent: .claude, hostName: "studio", sessionTitle: "unnamed · docs", state: .done,
            since: ago(25 * 60), prompt: "Update SSH.md for the new host key flow",
            summary: "Edited 2 files · docs/SSH.md, docs/ROADMAP.md"),
        AgentItem(
            id: "a6", agent: .claude, hostName: "studio", sessionTitle: "unnamed · ghostty bump", state: .error,
            since: ago(48 * 60), prompt: "Bump libghostty-vt to the latest tip",
            summary: "zig build exited 1: no x86_64 simulator slice"),
    ]

    func approve(_ id: AgentItem.ID) { transition(id, to: .working) }
    func deny(_ id: AgentItem.ID) { transition(id, to: .working) }
    func reply(_ id: AgentItem.ID, text: String) { transition(id, to: .working) }
    func markDone(_ id: AgentItem.ID) { items.removeAll { $0.id == id } }
    func launch(_ agent: AgentKind, host: String, prompt: String) {
        items.insert(
            AgentItem(
                id: UUID().uuidString, agent: agent, hostName: host, sessionTitle: "new session", state: .working,
                since: .now, prompt: prompt),
            at: 0)
    }

    private func transition(_ id: AgentItem.ID, to state: AgentState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        items[index].request = nil
        items[index].since = .now
    }
}

/// Pane statuses for the design screenshots (`-mock`): the second pane runs Claude, the third Codex.
@Observable
final class MockPaneStatus: PaneStatusSource {
    func state(of pane: String) -> AgentState? {
        switch pane {
        case "pane-3": .working
        case "pane-4": .blocked
        case "pane-6": .done
        default: nil
        }
    }

    func program(of pane: String) -> String? {
        switch pane {
        case "pane-3": "claude"
        case "pane-4": "codex"
        case "pane-6": "cargo"
        default: "zsh"
        }
    }
}

/// No statuses: a plain shell everywhere (until the daemon reports program status).
@Observable
final class NoPaneStatus: PaneStatusSource {
    func state(of pane: String) -> AgentState? { nil }
    func program(of pane: String) -> String? { nil }
}

enum MockLinks {
    static let links: [DetectedLink] = [
        DetectedLink(kind: .path, text: "crates/apple-ffi/src/layout.rs:142:9", line: -3),
        DetectedLink(kind: .path, text: "apple/Packages/PaneLayout/Sources/PaneLayout/Node.swift:88", line: -12),
        DetectedLink(kind: .url, text: "https://github.com/ghostty-org/ghostty/pull/8497", line: -20),
        DetectedLink(kind: .path, text: "~/projects/unnamed/docs/DESIGN.md", line: -41),
        DetectedLink(kind: .url, text: "http://localhost:5173/", line: -58),
        DetectedLink(kind: .path, text: "target/debug/build/ring-4f1a/output", line: -97),
    ]
}

final class MockFileSource: FileSource {
    let root = "~/projects/unnamed"

    func list(_ directory: String) async throws -> [FileEntry] {
        func dir(_ name: String, _ git: FileEntry.GitStatus? = nil) -> FileEntry {
            FileEntry(path: "\(directory)/\(name)", name: name, isDirectory: true, modified: ago(3600), git: git)
        }
        func file(_ name: String, _ size: Int64, _ age: TimeInterval, _ git: FileEntry.GitStatus? = nil) -> FileEntry {
            FileEntry(path: "\(directory)/\(name)", name: name, isDirectory: false, size: size, modified: ago(age), git: git)
        }
        return [
            dir("apple", .modified), dir("crates", .modified), dir("docs"), dir("scripts"), dir("vendor"),
            file("Cargo.lock", 98_304, 86_400), file("Cargo.toml", 1_412, 7_200, .modified),
            file("README.md", 4_806, 172_800), file("rust-toolchain.toml", 92, 604_800),
            file(".gitignore", 120, 604_800), file("NOTES.md", 2_210, 300, .untracked),
        ]
    }

    func read(_ path: String) async throws -> String {
        """
        [workspace]
        resolver = "3"
        members = ["crates/*"]

        [workspace.package]
        edition = "2024"
        license = "MIT"
        rust-version = "1.90"

        [workspace.dependencies]
        anyhow = "1"
        bytes = "1.10"
        iroh = { version = "0.94", default-features = false }
        serde = { version = "1", features = ["derive"] }
        tokio = { version = "1.47", features = ["rt-multi-thread", "macros", "net", "sync", "time"] }
        tracing = "0.1"

        [profile.release]
        lto = "thin"
        codegen-units = 1
        """
    }
}

final class MockDiffSource: DiffSource {
    let title = "Working tree vs HEAD"

    func files() async throws -> [DiffFile] {
        [
            DiffFile(
                path: "crates/apple-ffi/src/layout.rs", status: .modified, additions: 9, deletions: 3,
                hunks: [
                    DiffHunk(id: 0, header: "@@ -136,10 +136,16 @@ impl LayoutStore {", lines: [
                        DiffLine(id: 0, kind: .context, oldNumber: 136, newNumber: 136, text: "    pub fn apply(&mut self, op: LayoutOp) -> Result<(), LayoutError> {"),
                        DiffLine(id: 1, kind: .context, oldNumber: 137, newNumber: 137, text: "        let before = self.session.clone();"),
                        DiffLine(id: 2, kind: .removed, oldNumber: 138, newNumber: nil, text: "        self.session.apply(op)?;"),
                        DiffLine(id: 3, kind: .removed, oldNumber: 139, newNumber: nil, text: "        self.notify();"),
                        DiffLine(id: 4, kind: .added, oldNumber: nil, newNumber: 138, text: "        self.session.apply(op.clone())?;"),
                        DiffLine(id: 5, kind: .added, oldNumber: nil, newNumber: 139, text: "        let diff = LayoutDiff::between(&before, &self.session);"),
                        DiffLine(id: 6, kind: .added, oldNumber: nil, newNumber: 140, text: "        if !diff.is_empty() {"),
                        DiffLine(id: 7, kind: .added, oldNumber: nil, newNumber: 141, text: "            self.subscribers.retain(|s| s.send(diff.clone()).is_ok());"),
                        DiffLine(id: 8, kind: .added, oldNumber: nil, newNumber: 142, text: "        }"),
                        DiffLine(id: 9, kind: .context, oldNumber: 140, newNumber: 143, text: "        Ok(())"),
                        DiffLine(id: 10, kind: .context, oldNumber: 141, newNumber: 144, text: "    }"),
                    ]),
                ]),
            DiffFile(
                path: "apple/Packages/PaneLayout/Sources/PaneLayout/Node.swift", status: .modified, additions: 4, deletions: 1,
                hunks: [
                    DiffHunk(id: 0, header: "@@ -84,7 +84,10 @@ public indirect enum Node", lines: [
                        DiffLine(id: 0, kind: .context, oldNumber: 84, newNumber: 84, text: "    /// Every pane in this subtree, left to right, top to bottom."),
                        DiffLine(id: 1, kind: .removed, oldNumber: 85, newNumber: nil, text: "    public var panes: [PaneId] {"),
                        DiffLine(id: 2, kind: .added, oldNumber: nil, newNumber: 85, text: "    public var panes: [PaneId] { collectPanes() }"),
                        DiffLine(id: 3, kind: .added, oldNumber: nil, newNumber: 86, text: ""),
                        DiffLine(id: 4, kind: .added, oldNumber: nil, newNumber: 87, text: "    private func collectPanes() -> [PaneId] {"),
                        DiffLine(id: 5, kind: .added, oldNumber: nil, newNumber: 88, text: "        var result: [PaneId] = []"),
                        DiffLine(id: 6, kind: .context, oldNumber: 86, newNumber: 89, text: "        switch self {"),
                    ]),
                ]),
            DiffFile(
                path: "docs/DESIGN.md", status: .added, additions: 412, deletions: 0,
                hunks: [
                    DiffHunk(id: 0, header: "@@ -0,0 +1,412 @@", lines: [
                        DiffLine(id: 0, kind: .added, oldNumber: nil, newNumber: 1, text: "# Design"),
                        DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 2, text: ""),
                        DiffLine(id: 2, kind: .added, oldNumber: nil, newNumber: 3, text: "Native, dense, quiet, precise."),
                    ]),
                ]),
        ]
    }
}

enum MockPresence {
    static let participants = [
        Participant(id: "u1", name: "Alex Kim", role: .owner, isActive: false, hue: 0),
        Participant(id: "u2", name: "Mira Holt", role: .editor, isActive: true, hue: 1),
        Participant(id: "u3", name: "Jon Oyelaran", role: .viewer, isActive: false, hue: 2),
        Participant(id: "u4", name: "Sam Ruiz", role: .viewer, isActive: false, hue: 4),
    ]
}
