import DesignSystem
import HostKit
import SwiftUI
import UnnamedCore

/// New Task (git workspace; one flow for New Agent, New Worktree and the inbox's +): pick the
/// host and repository, a friendly generated name, the branch (derived from the name), and
/// what runs: Claude Code, Codex or a shell. With New Worktree on, the host makes a worktree on
/// the new branch, runs the repository's setup command, and opens a tab there; off, the agent
/// starts in a split of the focused pane as before.
struct NewTaskSheet: View {
    let feed: any AgentFeed

    enum Runner: String, CaseIterable, Identifiable {
        case claude, codex, shell
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .shell: "Shell"
            }
        }
        var systemImage: String {
            switch self {
            case .claude: AgentKind.claude.systemImage
            case .codex: AgentKind.codex.systemImage
            case .shell: "terminal"
            }
        }
        var agent: AgentKind? {
            switch self {
            case .claude: .claude
            case .codex: .codex
            case .shell: nil
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(WindowModel.self) private var model
    @State private var runner = Runner.claude
    @State private var hostID: String?
    @State private var repoPath: String?
    @State private var name = FriendlyName.make()
    @State private var branch = ""
    @State private var prompt = ""
    @State private var worktree = true
    @State private var isStarting = false
    @State private var failure: String?
    /// The chosen host's agents, by what launching would find; empty until it answers.
    @State private var installs: [AgentKind: InstallState] = [:]
    @FocusState private var isPromptFocused: Bool

    private var hosts: [LaunchHost] { feed.launchHosts }
    private var host: LaunchHost? { hosts.first { $0.id == hostID } }
    private var daemon: DaemonConnection? { hostID.flatMap { model.app.hosts.connection($0) as? DaemonConnection } }

    /// The chosen agent, when the host says it can't run it.
    private var unavailable: (agent: AgentKind, state: InstallState)? {
        guard let agent = runner.agent, let state = installs[agent] else { return nil }
        if case .installed = state { return nil }
        return (agent, state)
    }

    /// The host's repositories (from its repository snapshot), main worktrees only.
    private var repos: [WorktreeState] {
        guard let hostID, let daemon = model.app.hosts.connection(hostID) as? DaemonConnection,
              let snapshot = daemon.existingWorkspace?.repos else { return [] }
        return snapshot.worktrees.filter(\.main)
    }

    private var repo: WorktreeState? { repos.first { $0.path == repoPath } }

    /// The setup command of the chosen repository.
    private var setup: String? {
        guard let hostID, let daemon = model.app.hosts.connection(hostID) as? DaemonConnection,
              let snapshot = daemon.existingWorkspace?.repos, let repoPath else { return nil }
        return snapshot.worktrees.first { $0.repo == repoPath && $0.main }?.setup
    }

    /// The `PORT`s the chosen repository's worktrees hold now.
    private var portsInUse: [UInt16] {
        guard let hostID, let daemon = model.app.hosts.connection(hostID) as? DaemonConnection,
              let hub = daemon.existingWorkspace, let snapshot = hub.repos, let repoPath else { return [] }
        return snapshot.worktrees.filter { $0.repo == repoPath }.compactMap { hub.port(ofWorktree: $0.path) }.sorted()
    }

    /// The host gives the worktree its `PORT` when it makes it (the lowest free one), so the
    /// sheet says that, and which ones are taken; the toast after Start says the one it got.
    private var portNote: some View {
        let taken = portsInUse.map(String.init).joined(separator: ", ")
        return (Text("Gets its own ") + Text("PORT").font(DS.Font.literalSmall)
            + Text(taken.isEmpty ? " from the host, free for its dev server." : " from the host (in use here: \(taken))."))
            .accessibilityIdentifier("task-port-note")
    }

    /// The branch the host will use when the field is empty (as the daemon derives it).
    private var derivedBranch: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber || "/._".contains($0) ? String($0) : "-" }.joined()
        let collapsed = slug.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "task" : collapsed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Run", selection: $runner) {
                        ForEach(Runner.allCases) { runner in
                            Label(runner.title, systemImage: runner.systemImage).tag(runner)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("task-runner")
                }
                .chromeRows()
                if let unavailable, let host,
                   let guide = AgentInstallGuide(agent: unavailable.agent, os: daemon?.daemonInfo?.os ?? "")
                {
                    AgentInstallSection(
                        agent: unavailable.agent, state: unavailable.state, hostName: host.name, guide: guide,
                        onInstall: install)
                        .chromeRows()
                }
                Section {
                    Picker("Host", selection: $hostID) {
                        ForEach(hosts) { host in
                            Text(host.name).tag(Optional(host.id))
                        }
                    }
                    .disabled(hosts.isEmpty)
                    if !repos.isEmpty {
                        Picker("Repository", selection: $repoPath) {
                            ForEach(repos) { repo in
                                Text(repo.repoName).tag(Optional(repo.path))
                            }
                            Text("Focused pane’s directory").tag(String?.none)
                        }
                        .accessibilityIdentifier("task-repo")
                    } else if let directory = host?.directory {
                        LabeledContent("Directory") {
                            Text(verbatim: directory)
                                .font(DS.Font.literalSmall)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Toggle(isOn: $worktree) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New Worktree")
                            Text("Its own branch, PORT and tab, so it can't trip over your checkout.")
                                .font(.footnote)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .disabled(repo == nil && host?.directory == nil)
                    .accessibilityIdentifier("task-worktree")
                } footer: {
                    if hosts.isEmpty {
                        Text("No host with the helper is connected. Connect one in Hosts first.")
                    }
                }
                .chromeRows()
                if worktree {
                    Section {
                        HStack {
                            TextField("Name", text: $name)
                                .font(DS.Font.literal)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .accessibilityIdentifier("task-name")
                            Button("New Name", systemImage: "shuffle") { name = FriendlyName.make(avoiding: [name]) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Another name")
                        }
                        TextField(derivedBranch, text: $branch, prompt: Text(derivedBranch).foregroundStyle(DS.Palette.textTertiary))
                            .font(DS.Font.literal)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("task-branch")
                    } header: {
                        Text("Name and branch")
                    } footer: {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            if let setup {
                                (Text("Runs setup first: ") + Text(setup).font(DS.Font.literalSmall))
                            }
                            portNote
                        }
                    }
                    .chromeRows()
                }
                if runner != .shell {
                    Section("Prompt") {
                        TextEditor(text: $prompt)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                            .focused($isPromptFocused)
                            .overlay(alignment: .topLeading) {
                                if prompt.isEmpty {
                                    Text("What should \(runner.title) do? (optional)")
                                        .foregroundStyle(DS.Palette.textTertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityIdentifier("launch-prompt")
                    }
                    .chromeRows()
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Palette.error)
                            .font(DS.Font.rowSubtitle)
                    }
                    .chromeRows()
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isStarting {
                        HStack(spacing: DS.Space.s) {
                            Spinner()
                                .frame(width: 14, height: 14)
                            Text("Starting…").foregroundStyle(DS.Palette.textSecondary)
                        }
                    } else {
                        Button("Start", action: start)
                            .disabled(!canStart)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("launch-start")
                    }
                }
            }
            .onAppear {
                hostID = hostID ?? (hosts.first { $0.id == model.workspace?.hostId } ?? hosts.first)?.id
                repoPath = repoPath ?? model.git.worktree?.repo ?? repos.first?.path
                worktree = repo != nil
                if let seeded = model.newTaskPrompt {
                    model.newTaskPrompt = nil
                    prompt = seeded
                }
                isPromptFocused = true
            }
            .onChange(of: hosts.map(\.id)) { _, ids in
                if hostID == nil || !ids.contains(hostID!) { hostID = ids.first }
            }
            .onChange(of: hostID) {
                repoPath = repos.first?.path
                worktree = repo != nil
            }
            // On every opening, so an install made since shows.
            .task(id: hostID) { await checkInstalls() }
            // The host's repositories can arrive after the sheet opened.
            .onChange(of: repos.map(\.path)) { old, paths in
                guard old.isEmpty, repoPath == nil, !paths.isEmpty else { return }
                repoPath = model.git.worktree?.repo ?? paths.first
                worktree = true
            }
        }
        #if os(iOS)
        .phoneDetents([.large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520)
        #endif
    }

    private var canStart: Bool {
        host != nil && !isStarting && unavailable == nil && (!worktree || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Asks the host which agents it has; a helper too old to say leaves every agent startable.
    private func checkInstalls() async {
        installs = [:]
        guard let api = try? daemon?.workspace.client() as? DaemonAgentInstallAPI,
              let list = try? await api.agentInstalls() else { return }
        installs = Dictionary(list.map { (AgentKind($0.program), $0.state) }) { first, _ in first }
    }

    /// Runs the vendor's installer in a new tab on the host, the user's own act.
    private func install(_ command: String) {
        guard let host, let daemon, let session = daemon.layout.sessionId else { return }
        let title = runner.title
        Task {
            do {
                let pane = try await daemon.workspace.repoClient().scriptRun(
                    cwd: "~", sessionId: session, name: "Install \(title)", command: command)
                model.reveal(host: host.id, pane: pane)
            } catch {
                withAnimation(DS.Motion.snappy) { failure = ScreenError.describe(error) }
            }
        }
    }

    private func start() {
        guard let host, canStart else { return }
        isStarting = true
        failure = nil
        let request = AgentLaunchRequest(
            agent: runner == .codex ? .codex : .claude, hostId: host.id,
            prompt: runner == .shell ? "" : prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            worktree: worktree, branch: branch.trimmingCharacters(in: .whitespaces).nonEmpty,
            name: worktree ? name.trimmingCharacters(in: .whitespaces) : nil,
            repo: repoPath, shell: runner == .shell)
        Task {
            do {
                let note = try await feed.launch(request)
                isStarting = false
                if worktree {
                    // "fix-login started on hetzner · PORT 4102 · running setup first: npm i"
                    let text = ["\(name) started on \(host.name)", note].compactMap(\.self).joined(separator: " · ")
                    model.toasts.show(Toast(text, systemImage: "arrow.triangle.branch", style: .success))
                } else if let note {
                    model.toasts.show(Toast(note, systemImage: "hammer", style: .neutral))
                } else {
                    model.toasts.show(Toast("\(worktree ? name : runner.title) started on \(host.name)", systemImage: runner.systemImage, style: .success))
                }
                dismiss()
            } catch {
                isStarting = false
                withAnimation(DS.Motion.snappy) { failure = ScreenError.describe(error) }
            }
        }
    }
}

/// An agent the host can't run yet: why, the vendor's installer to copy or to run in a new tab
/// there, and the vendor's guide.
private struct AgentInstallSection: View {
    let agent: AgentKind
    let state: InstallState
    let hostName: String
    let guide: AgentInstallGuide
    let onInstall: (String) -> Void

    private var offPath: String? {
        if case .notOnPath(let path) = state { path } else { nil }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label(offPath == nil ? "\(agent.title) isn’t installed on \(hostName)" : "\(hostName) can’t find \(agent.title)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.attention)
                Group {
                    if let offPath {
                        Text("It’s at \(Text(verbatim: offPath).font(DS.Font.literalSmall)), but the login shell’s PATH doesn’t include that folder.")
                    } else if guide.command != nil {
                        Text("Install it with the official installer, then start the task.")
                    } else {
                        Text("Follow the official guide to install it on this host.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(DS.Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("task-agent-missing")
            if offPath == nil, let command = guide.command {
                HStack(spacing: DS.Space.s) {
                    Text(verbatim: command)
                        .font(DS.Font.literalSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("task-install-command")
                    Button("Copy", systemImage: "doc.on.doc") { copy(command) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy the command")
                        .accessibilityIdentifier("task-install-copy")
                }
                Button("Install in a New Tab", systemImage: "terminal") { onInstall(command) }
                    .accessibilityIdentifier("task-install-run")
            }
            Link(destination: offPath == nil ? guide.docs : guide.pathHelp) {
                HStack {
                    Label(offPath == nil ? "Installation Guide" : "Fix PATH", systemImage: "book")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .contentShape(.rect)
            }
            .accessibilityIdentifier("task-install-docs")
        }
    }
}
