import DesignSystem
import HostKit
import SwiftUI
import UnnamedCore

/// New Agent (⇧⌘N, every + and the palette; one flow for agents and worktree tasks): pick the
/// host and repository, a friendly generated name, the branch (derived from the name), and
/// what runs: Claude Code, Codex or a shell. With New Worktree on, the host makes a worktree on
/// the new branch, runs the repository's setup command, and opens a tab there; off, the agent
/// starts in a tab of its own in the focused pane's directory.
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
    /// The chosen host's agents, by what launching would find; nil until it answers.
    @State private var installs: [AgentKind: InstallState]?
    @FocusState private var isPromptFocused: Bool

    private var hosts: [LaunchHost] { feed.launchHosts }
    private var host: LaunchHost? { hosts.first { $0.id == hostID } }
    private var daemon: DaemonConnection? { hostID.flatMap { model.app.hosts.connection($0) as? DaemonConnection } }

    private var status: LaunchStatus {
        guard host != nil else { return .noHost }
        guard let agent = runner.agent else { return .shell }
        guard let installs else { return .checking(agent) }
        return switch installs[agent] {
        case .installed(let path): .ready(agent, path: path)
        case .notOnPath(let path): .offPath(agent, path: path)
        case .missing: .missing(agent)
        // A helper too old to say: every agent is startable.
        case nil: .ready(agent, path: nil)
        }
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
        SheetScaffold(
            "New Agent",
            cancel: SheetAction("Cancel") { dismiss() },
            primary: SheetAction(
                "Start", isEnabled: canStart, isBusy: isStarting, busyTitle: "Starting…",
                identifier: "launch-start", action: start)
        ) {
            Form {
                // On the page, not in a card: a segmented control is a control, not a row.
                #if os(iOS)
                Section {
                    RunnerPicker(selection: $runner)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                #endif
                // Always present and one size in every state: the check's answer changes the
                // row, never the sheet.
                Section {
                    LaunchStatusRow(
                        status: status, hostName: host?.name ?? "",
                        guide: runner.agent.flatMap { AgentInstallGuide(agent: $0, os: daemon?.daemonInfo?.os ?? "") },
                        onInstall: install)
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
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .disabled(repo == nil && host?.directory == nil)
                    .accessibilityIdentifier("task-worktree")
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
                        TextField("Branch", text: $branch, prompt: Text(derivedBranch).foregroundStyle(DS.Palette.textTertiary))
                            .font(DS.Font.literal)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("task-branch")
                    } header: {
                        SectionTitle("Name and Branch")
                    } footer: {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            if let setup {
                                (Text("Runs setup first: ") + Text(setup).font(DS.Font.literalSmall))
                            }
                            portNote
                        }
                        .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .chromeRows()
                }
                if runner != .shell {
                    Section {
                        // The field's own placeholder, not an overlay on a TextEditor: it sits
                        // exactly where the caret does on every platform.
                        TextField("Prompt", text: $prompt, prompt: Text("What should \(runner.title) do? (optional)"), axis: .vertical)
                            .lineLimit(4...10)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .focused($isPromptFocused)
                            .accessibilityIdentifier("launch-prompt")
                    } header: {
                        SectionTitle("Prompt")
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
            #if os(macOS)
            // A Mac form draws a card behind every section: the picker sits on the page above it.
            .safeAreaInset(edge: .top, spacing: 0) {
                RunnerPicker(selection: $runner)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.m)
            }
            #endif
            .macFittedForm(maxHeight: 560)
            .onAppear {
                let seed = model.newAgentSeed
                model.newAgentSeed = NewAgentSeed()
                hostID = hostID ?? (hosts.first { $0.id == seed.host } ?? hosts.first { $0.id == model.workspace?.hostId } ?? hosts.first)?.id
                let preferred = [seed.repo, model.git.worktree?.repo].compactMap(\.self)
                repoPath = repoPath ?? (repos.first { preferred.contains($0.path) } ?? repos.first)?.path
                worktree = repo != nil
                if let seeded = seed.prompt { prompt = seeded }
                // Not on a phone: its keyboard would scroll the runner and host out of view as
                // the sheet opens.
                isPromptFocused = model.widthBucket != .compact
            }
            .onChange(of: hosts.map(\.id)) { _, ids in
                if hostID == nil || !ids.contains(hostID!) { hostID = ids.first }
            }
            .onChange(of: hostID) { old, _ in
                // The first pick (on appearing) keeps the seeded repository.
                guard old != nil else { return }
                installs = nil
                repoPath = repos.first?.path
                worktree = repo != nil
            }
            // On every opening, so an install made since shows.
            .task(id: hostID) { await checkInstalls() }
            // The host's repositories can arrive after the sheet opened: one is picked, but
            // New Worktree stays as it opened rather than adding a section under the pointer.
            .onChange(of: repos.map(\.path)) { old, paths in
                guard old.isEmpty, repoPath == nil, !paths.isEmpty else { return }
                repoPath = model.git.worktree?.repo ?? paths.first
            }
        }
        #if os(iOS)
        .phoneDetents([.large])
        #else
        // As tall as the form (its status row is one size in every state); a longer form scrolls.
        .frame(width: 520)
        #endif
    }

    private var canStart: Bool {
        host != nil && !isStarting && status.canStart && (!worktree || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Asks the host which agents it has; a helper too old to say leaves every agent startable.
    private func checkInstalls() async {
        guard let hostID else { return }
        let answer = await feed.installs(on: hostID) ?? [:]
        guard !Task.isCancelled else { return }
        withAnimation(DS.Motion.snappy) { installs = answer }
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

/// What runs, as one segmented row drawn here rather than a `UISegmentedControl`: that one
/// lays its labels out against the sheet's presentation (and the keyboard rising under it), so
/// they overlapped for a moment before settling.
private struct RunnerPicker: View {
    @Binding var selection: NewTaskSheet.Runner
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NewTaskSheet.Runner.allCases) { runner in
                let selected = runner == selection
                Button {
                    withAnimation(DS.Motion.snappy) { selection = runner }
                } label: {
                    HStack(spacing: DS.Space.row) {
                        // The agent's own mark (Claude's, Codex's), as in the Agents screen.
                        if let agent = runner.agent {
                            ProgramMark(agent.identity, size: 14)
                        } else {
                            Image(systemName: runner.systemImage).imageScale(.small)
                        }
                        Text(runner.title)
                    }
                        // One weight: the raised pill shows the choice; a weight change would
                        // make the words jump.
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? DS.Palette.text : DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selected {
                                // The system segmented control's thumb: the raised surface, an
                                // edge and a contact shadow.
                                Capsule()
                                    .fill(DS.Palette.overlay)
                                    .overlay(Capsule().strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Palette.hoverFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run")
        .accessibilityIdentifier("task-runner")
    }
}

/// What Start would do on the chosen host, as the host's own check says.
private enum LaunchStatus: Equatable {
    case noHost
    case shell
    case checking(AgentKind)
    /// `path` is nil when the host's helper is too old to say.
    case ready(AgentKind, path: String?)
    case offPath(AgentKind, path: String)
    case missing(AgentKind)

    var canStart: Bool {
        switch self {
        case .noHost, .offPath, .missing: false
        case .shell, .checking, .ready: true
        }
    }
}

/// One row, the same height in every state (a title line and two reserved detail lines), so
/// the check's answer never moves the form: checking, ready, or why the agent can't start
/// with the vendor's fix beside it.
private struct LaunchStatusRow: View {
    let status: LaunchStatus
    let hostName: String
    let guide: AgentInstallGuide?
    let onInstall: (String) -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            icon
                .frame(width: 20, height: 20)
            ZStack(alignment: .topLeading) {
                // The tallest the text gets (two detail lines, each in both fonts), so a path or a
                // shorter state never changes the height.
                lines(Text(verbatim: " ") + Text(verbatim: " ").font(DS.Font.literalSmall) + Text(verbatim: "\n ") + Text(verbatim: " ").font(DS.Font.literalSmall))
                    .hidden()
                    .accessibilityHidden(true)
                lines(detail)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task-agent-status")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
                .controlSize(.small)
                .fixedSize()
        }
    }

    private func lines(_ detail: some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            detail
                .font(.footnote)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(2, reservesSpace: true)
        }
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let agent, _):
            ProgramMark(agent.identity, size: 18)
        case .offPath, .missing:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.attention)
        case .shell:
            Image(systemName: "terminal").foregroundStyle(DS.Palette.textSecondary)
        case .noHost:
            Image(systemName: "server.rack").foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private var title: String {
        switch status {
        case .noHost: "No host connected"
        case .shell: "A shell on \(hostName)"
        case .checking(let agent): "Checking \(agent.title) on \(hostName)…"
        case .ready(let agent, _): "\(agent.title) is ready on \(hostName)"
        case .offPath(let agent, _): "\(hostName) can’t find \(agent.title)"
        case .missing(let agent): "\(agent.title) isn’t installed on \(hostName)"
        }
    }

    @ViewBuilder private var detail: some View {
        switch status {
        case .noHost:
            Text("Connect a host with the helper in Hosts first.")
        case .shell:
            Text("Your login shell, in a tab of its own.")
        case .checking:
            Text("Looking where the host’s terminal looks.")
        case .ready(_, let path?):
            Text(verbatim: path).font(DS.Font.literalSmall).truncationMode(.middle)
        case .ready:
            Text("Starts in a tab of its own.")
        case .offPath(_, let path):
            Text("It’s at \(Text(verbatim: path).font(DS.Font.literalSmall)), but the shell’s PATH doesn’t include that folder.")
        case .missing:
            if let command = guide?.command {
                Text(verbatim: command)
                    .font(DS.Font.literalSmall)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("task-install-command")
            } else {
                Text("Follow the official guide to install it on this host.")
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch status {
        case .offPath:
            if let guide {
                Link("Fix PATH", destination: guide.pathHelp)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("task-install-docs")
            }
        case .missing:
            if let guide {
                Menu("Install") {
                    if let command = guide.command {
                        Button("Install in a New Tab", systemImage: "terminal") { onInstall(command) }
                            .accessibilityIdentifier("task-install-run")
                        Button("Copy Command", systemImage: "doc.on.doc") { copy(command) }
                            .accessibilityIdentifier("task-install-copy")
                    }
                    Link(destination: guide.docs) { Label("Installation Guide", systemImage: "book") }
                        .accessibilityIdentifier("task-install-docs")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("task-install-menu")
            }
        default:
            EmptyView()
        }
    }
}
