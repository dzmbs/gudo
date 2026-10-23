import DesignSystem
import Foundation
import Observation
import enum UnnamedCore.InstallState

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
            lastLine: "Compiling quinn-proto v0.11.9", lastSeen: ago(14), isPinned: true,
            helper: HelperOffer(message: "A newer helper is available.", required: false, canUpdate: true)),
        HostSummary(
            id: "build-01", name: "build-01", address: "ci@build-01.internal:2222", kind: .ssh, connection: .connected,
            sessionCount: 1, agentCounts: [:], lastLine: "$ journalctl -fu runner", lastSeen: ago(60 * 3), isPinned: false,
            canInstallHelper: true),
        HostSummary(
            id: "garage", name: "garage-pi", address: "pi@192.168.1.40", kind: .ssh,
            connection: .unreachable(reason: "No route to host.", hint: "Check that the Pi is on and on this network."),
            sessionCount: 0, agentCounts: [:], lastSeen: ago(60 * 60 * 26), isPinned: false),
        HostSummary(
            id: "nas", name: "nas", address: "admin@nas.tail3f2c.ts.net", kind: .ssh,
            connection: .reconnecting(attempt: 2, since: ago(30)), sessionCount: 0, agentCounts: [:],
            lastSeen: ago(60 * 60 * 3), isPinned: false, isTailscale: true, needsTailscale: true),
    ]

    var isOffline: Bool { false }
    func connect(_ id: HostSummary.ID) {}
    func rename(_ id: HostSummary.ID, to name: String) {
        if let index = hosts.firstIndex(where: { $0.id == id }) { hosts[index].name = name }
    }
    func retry(_ id: HostSummary.ID) {}
    func disconnect(_ id: HostSummary.ID) {}
    func installHelper(_ id: HostSummary.ID) async throws {}
    func updateHelper(_ id: HostSummary.ID) async throws {
        if let index = hosts.firstIndex(where: { $0.id == id }) { hosts[index].helper = nil }
    }
    func forget(_ id: HostSummary.ID) { hosts.removeAll { $0.id == id } }
    func togglePin(_ id: HostSummary.ID) {
        if let index = hosts.firstIndex(where: { $0.id == id }) { hosts[index].isPinned.toggle() }
    }
    func quickConnect(_ destination: String) {}
    func pair(ticket: String, name: String?) async throws -> HostSummary.ID {
        try await Task.sleep(for: .milliseconds(900))
        let host = HostSummary(
            id: UUID().uuidString, name: "macbook-air", address: "macbook-air.tail3f2c.ts.net", kind: .daemon,
            connection: .connected, sessionCount: 0, agentCounts: [:], lastSeen: .now, isPinned: false)
        hosts.append(host)
        return host.id
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
            summary: "Edited 2 files · docs/SSH.md, docs/ROADMAP.md", unseen: true, canReply: true),
        AgentItem(
            id: "a7", agent: .other, hostName: "studio", sessionTitle: "unnamed", state: .done,
            since: ago(31 * 60), prompt: "cargo test --workspace --release", summary: "Exited 0 · 4m 12s",
            unseen: true, isCommand: true),
        AgentItem(
            id: "a6", agent: .claude, hostName: "studio", sessionTitle: "unnamed · ghostty bump", state: .error,
            since: ago(48 * 60), prompt: "Bump libghostty-vt to the latest tip",
            summary: "zig build exited 1: no x86_64 simulator slice"),
    ]

    func approve(_ id: AgentItem.ID) { transition(id, to: .working) }
    func deny(_ id: AgentItem.ID) { transition(id, to: .working) }
    func reply(_ id: AgentItem.ID, text: String) async throws { transition(id, to: .working) }
    func markDone(_ id: AgentItem.ID) { items.removeAll { $0.id == id } }
    var unseenByHost: [String: Int] { ["studio": 2, "devbox": 1] }
    var launchHosts: [LaunchHost] {
        [LaunchHost(id: "studio", name: "studio", directory: "~/projects/unnamed"),
         LaunchHost(id: "devbox", name: "devbox", directory: "~/src/api")]
    }
    func markSeen() {
        for index in items.indices { items[index].unseen = false }
    }
    func open(_ id: AgentItem.ID) {}
    func launch(_ request: AgentLaunchRequest) async throws -> String? {
        items.insert(
            AgentItem(
                id: UUID().uuidString, agent: request.agent, hostName: request.hostId, sessionTitle: "new session",
                state: .working, since: .now, prompt: request.prompt, canReply: true),
            at: 0)
        return nil
    }

    /// Answers after a moment (`-mockAgentInstallDelay` seconds), as a host does;
    /// `-mockAgentInstall notOnPath` or `missing` for Claude Code's other states.
    func installs(on host: LaunchHost.ID) async -> [AgentKind: InstallState]? {
        let delay = UserDefaults.standard.double(forKey: "mockAgentInstallDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 1.5))
        let claude: InstallState = switch UserDefaults.standard.string(forKey: "mockAgentInstall") {
        case "notOnPath": .notOnPath(path: "/Users/you/.local/bin/claude")
        case "missing": .missing
        default: .installed(path: "/Users/you/.local/bin/claude")
        }
        return [.claude: claude, .codex: .installed(path: "/opt/homebrew/bin/codex")]
    }

    /// Standing approvals per item (the renderer agent has one in the screenshots).
    var rules: [AgentItem.ID: [AgentAutoApproval]] = [
        "a3": [AgentAutoApproval(id: "r1", label: "cargo bench …", expiresAt: .now + 42 * 60, turnsLeft: 7, uses: 3, grantedBy: "iPad")],
    ]

    func approvalOptions(_ id: AgentItem.ID) -> AgentApprovalOptions? {
        guard case .permission(_, let detail)? = items.first(where: { $0.id == id })?.request else { return nil }
        let words = detail.split(separator: " ").prefix(2).joined(separator: " ")
        return AgentApprovalOptions(editableInput: detail, likeThis: "\(words) …")
    }

    func autoApprovals(_ id: AgentItem.ID) -> [AgentAutoApproval] { rules[id] ?? [] }

    func approveEdited(_ id: AgentItem.ID, input: String) async throws { transition(id, to: .working) }

    func approveAllLikeThis(_ id: AgentItem.ID) async throws {
        guard let label = approvalOptions(id)?.likeThis else { return }
        rules[id, default: []].append(AgentAutoApproval(
            id: UUID().uuidString, label: label, expiresAt: .now + Double(AgentAutoApproval.minutes * 60),
            turnsLeft: AgentAutoApproval.turns, uses: 1, grantedBy: "This device"))
        transition(id, to: .working)
    }

    func revokeAutoApproval(_ id: AgentItem.ID, rule: AgentAutoApproval.ID) async throws {
        rules[id]?.removeAll { $0.id == rule }
    }

    /// Design fixtures: an agent changes state as a live one would (on a host, in a pane).
    func simulate(_ id: AgentItem.ID, state: AgentState, request: AgentItem.Request? = nil, summary: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        items[index].request = request
        items[index].summary = summary
        items[index].since = .now
        items[index].hostId = items[index].hostName
        items[index].paneId = 90 + UInt64(index)
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
    /// A fixture's own programs and states by pane (the `programs` screen); replaces the defaults.
    /// Static: every window model reads it (iPad launches make two).
    static var fixture: [String: (program: String, state: AgentState?)]?

    func state(of pane: String) -> AgentState? {
        if let fixture = Self.fixture { return fixture[pane]?.state }
        return switch pane {
        case "pane-3": .working
        case "pane-4": .blocked
        case "pane-6": .done
        default: nil
        }
    }

    func program(of pane: String) -> String? {
        if let fixture = Self.fixture { return fixture[pane]?.program ?? "zsh" }
        return switch pane {
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

    var hostName: String { "studio" }
    var unavailableReason: String? { nil }
    func preview(_ path: String) async throws -> FilePreview { .text(try await read(path), truncated: false) }
    func mkdir(_ path: String) async throws {}
    func rename(_ path: String, to name: String) async throws {}
    func trash(_ path: String) async throws {}
    func upload(_ local: URL, to directory: String, progress: @escaping @MainActor (Double) -> Void) async throws { progress(1) }
    func download(_ path: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: (path as NSString).lastPathComponent)
        try Data(try await read(path).utf8).write(to: url)
        return url
    }
    func watch(_ directory: String, onChange: @escaping @MainActor () -> Void) async -> FileWatch? { nil }
}

/// The editor as the first run shows it (`-screen editor -mock`): VS Code being set up.
@Observable
final class MockEditorSource: EditorSource {
    var phase = EditorPhase.installing
    var folder: String { "~/projects/unnamed" }
    var hostName: String { "studio" }
    var unavailableReason: String? { nil }
    var pendingURL: URL?
    func open() async {}
    func open(path: String, line: Int?, column: Int?) async {}
    func didLoad() {}
    func close(stopServer: Bool) async {}
    var mode: EditorMode { .server }
    var tunnelDesktopURI: URL? { nil }
    func acceptLicence() async {}
    func declineLicence() {}
    func resumeIfAccepted() async {}
    func openTunnel(account: EditorTunnelAccount) async {}
}

@Observable
final class MockPortSource: PortSource {
    var ports: [DetectedPort] = [
        DetectedPort(port: 5173, process: "node", url: "http://localhost:5173/", isHTTP: true, loopbackOnly: true, pane: "pnpm dev"),
        DetectedPort(port: 8000, process: "python3", url: nil, isHTTP: true, loopbackOnly: false, pane: "http.server"),
        DetectedPort(port: 5432, process: "postgres", url: nil, isHTTP: false, loopbackOnly: true, pane: nil),
    ]
    var hostName: String { "studio" }
    var hostId: String? { nil }
    var unavailableReason: String? { nil }
    var offer: DetectedPort?
    func dismissOffer() { offer = nil }
    func open(_ port: DetectedPort) async throws -> URL { URL(string: "https://ghostty.org/docs")! }
}

final class MockLinkSource: LinkSource {
    var isAvailable: Bool { true }
    func links() async throws -> [DetectedLink] { MockLinks.links }
    func lastCommandOutput() async throws -> (command: String?, output: String) { ("cargo test", "test result: ok. 42 passed") }
    func countMatches(_ needle: String, caseSensitive: Bool) async throws -> Int? { 14 }
}

final class MockDiffSource: DiffSource {
    let title = "Working tree vs HEAD"
    var unavailableReason: String? { nil }

    func repository() async throws -> DiffRepository {
        DiffRepository(root: "~/projects/unnamed", branch: "w3-screens", ahead: 2, behind: 0, changedFiles: 3)
    }

    func turns() async throws -> [DiffTurn] {
        [
            DiffTurn(pane: 3, turn: 4, agent: "Claude Code", started: ago(6 * 60), ended: nil),
            DiffTurn(pane: 3, turn: 3, agent: "Claude Code", started: ago(22 * 60), ended: ago(19 * 60)),
            DiffTurn(pane: 4, turn: 1, agent: "Codex", started: ago(50 * 60), ended: ago(41 * 60)),
        ]
    }

    func reviewer(for scope: DiffScope) -> String? { "Claude Code" }
    func sendReview(_ notes: [ReviewNote], scope: DiffScope, preamble: String?) async throws {}

    func files(_ scope: DiffScope) async throws -> [DiffFile] {
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
