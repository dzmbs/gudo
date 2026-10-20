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
    @FocusState private var isPromptFocused: Bool

    private var hosts: [LaunchHost] { feed.launchHosts }
    private var host: LaunchHost? { hosts.first { $0.id == hostID } }

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
                                .foregroundStyle(.secondary)
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
                        TextField(derivedBranch, text: $branch, prompt: Text(derivedBranch).foregroundStyle(.tertiary))
                            .font(DS.Font.literal)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("task-branch")
                    } header: {
                        Text("Name and branch")
                    } footer: {
                        if let setup {
                            (Text("Runs setup first: ") + Text(setup).font(DS.Font.literalSmall))
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
                                        .foregroundStyle(.tertiary)
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
                            Text("Starting…").foregroundStyle(.secondary)
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

    private var canStart: Bool { host != nil && !isStarting && (!worktree || !name.trimmingCharacters(in: .whitespaces).isEmpty) }

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
                if let note {
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
