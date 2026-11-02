import DesignSystem
import HostKit
import SwiftUI
import GudoCore

/// The pull request of the focused pane's worktree. Its popover is the one place `gh` problems
/// are reported, with the command that fixes them.
struct PRToolbarButton: View {
    let git: GitUI
    let worktree: WorktreeState

    var body: some View {
        @Bindable var git = git
        HoverPopover(isPresented: $git.isPRPopoverShown) {
            label
        } content: {
            PRPopover(git: git, worktree: worktree)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier("pr-button")
    }

    private var pr: PullRequest? { worktree.visiblePR }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: pr?.kind.systemImage ?? "arrow.triangle.branch")
                .foregroundStyle(pr.map { AnyShapeStyle($0.kind.color) } ?? AnyShapeStyle(DS.Palette.textSecondary))
                .opacity(DS.Opacity.mutedGlyph)
                .overlay(alignment: .bottomTrailing) {
                    if let pr {
                        CheckBadge(pr.checkKinds)
                            .font(.system(size: 8, weight: .black))
                            .offset(x: 2, y: 2)
                    }
                }
            if let pr {
                Text("#\(pr.number)").monospacedDigit()
            } else {
                Text(worktree.displayBranch).lineLimit(1)
            }
        }
        .font(.subheadline)
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, 6)
        .fixedSize()
        .contentShape(.rect)
    }

    private var help: String {
        guard let pr else { return "\(worktree.displayBranch) · no pull request" }
        return "#\(pr.number) \(pr.stateWord) · \(pr.checksSummary.words). Open on GitHub (⌃⌘G)"
    }
}

struct PRPopover: View {
    let git: GitUI
    let worktree: WorktreeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                if let pr = worktree.visiblePR {
                    prBody(pr)
                } else {
                    empty
                }
                if let port = git.port(of: worktree) {
                    Divider()
                    WorktreePortRow(port: port) { git.openPort(of: worktree) }
                }
                if let hint = GhHint(git.gh) {
                    Divider()
                    GhHintView(hint: hint)
                }
            }
            .padding()
            // One width: checks, the port and gh hints change while open and must not widen it.
            .frame(width: DS.Size.popoverWidth, alignment: .leading)
        }
        .frame(maxHeight: DS.Git.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("pr-popover")
    }

    @ViewBuilder
    private func prBody(_ pr: PullRequest) -> some View {
        (Text(pr.stateWord + " ").foregroundStyle(DS.Palette.textSecondary)
            + Text(pr.title)
            + Text(" #\(pr.number)").foregroundStyle(DS.Palette.textSecondary))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        Text(summary(pr))
            .font(.subheadline)
            .foregroundStyle(DS.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
            DiffStat(added: pr.additions, removed: pr.deletions, font: .subheadline)
            if pr.mergeState == .dirty {
                Text("· Merge conflicts").font(.subheadline).foregroundStyle(DS.Palette.error)
            }
        }
        if !pr.checks.isEmpty {
            HStack(spacing: 6) {
                ChecksRing(pr.checkKinds)
                Text(pr.checksSummary.words).font(.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
            }
            Divider()
            ForEach(Array(pr.checks.enumerated()), id: \.offset) { _, check in
                CheckRow(check: check)
            }
        }
        Divider()
        actions(pr)
    }

    private func summary(_ pr: PullRequest) -> String {
        var parts = [pr.headRef]
        switch pr.state {
        case .open:
            parts.append(pr.mergeBlocker ?? (pr.mergeState == .unstable ? "Can merge; an optional check failed" : "Ready to merge"))
        case .merged:
            if let mergedAtMs = worktree.mergedAtMs, worktree.managed {
                let days = GitSettings.autoDeleteDays
                parts.append(days > 0
                    ? "Worktree deleted \(Date(timeIntervalSince1970: Double(mergedAtMs) / 1000 + Double(days) * 86_400).formatted(.relative(presentation: .named)))\(worktree.dirty ? " once its changes are dealt with" : "")"
                    : "Merged")
            }
        case .closed:
            break
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ pr: PullRequest) -> some View {
        HStack(spacing: DS.Space.s) {
            Button("Open on GitHub") { git.openOnGitHub(pr) }
                .help("Open on GitHub (⌃⌘G)")
            Spacer(minLength: DS.Space.s)
            if let busy = git.busy {
                Text(busy).font(.caption).foregroundStyle(DS.Palette.textSecondary)
            } else {
                if pr.state == .open, pr.hasRerunnableFailures {
                    Button("Re-run Failed") { git.rerunFailed(worktree) }
                        .accessibilityIdentifier("pr-rerun")
                }
                if pr.state == .open, pr.mergeBlocker == nil {
                    Button("Merge…") {
                        git.isPRPopoverShown = false
                        git.requestMerge(worktree)
                    }
                    .buttonStyle(.primaryGlass)
                    .accessibilityIdentifier("pr-merge")
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var empty: some View {
        Text("No Pull Request").font(.headline)
        Text(worktree.main
            ? "\(worktree.displayBranch) is the repository's main branch."
            : "\(worktree.displayBranch) has no open pull request.")
            .font(.subheadline)
            .foregroundStyle(DS.Palette.textSecondary)
        if !worktree.main, case .ready = git.gh {
            Divider()
            HStack {
                Spacer()
                if let busy = git.busy {
                    Text(busy).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                } else {
                    Button("Create Pull Request") {
                        git.isPRPopoverShown = false
                        git.createPR(worktree)
                    }
                    .buttonStyle(.primaryGlass)
                    .controlSize(.small)
                    .help("Push \(worktree.displayBranch) and open a pull request (gh pr create --fill)")
                    .accessibilityIdentifier("pr-create")
                }
            }
        }
    }
}

struct WorktreePortRow: View {
    let port: UInt16
    let open: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("PORT").font(.caption.weight(.medium)).foregroundStyle(DS.Palette.textSecondary)
            Text(verbatim: String(port))
                .font(DS.Font.literalSmall)
                .textSelection(.enabled)
                .accessibilityIdentifier("worktree-port")
            Spacer(minLength: DS.Space.s)
            Button("Open localhost:\(String(port))", action: open)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Forward the host's port \(String(port)) here and open it in the browser")
                .accessibilityIdentifier("worktree-open-port")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CheckRow: View {
    let check: PrCheck
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: check.status.kind.systemImage)
                .foregroundStyle(check.status.kind.color)
            if let url = check.url.flatMap(URL.init(string:)), HostLinks.mayOpen(url) {
                Button(check.name) { openURL(url) }
                    .buttonStyle(.plain)
                    .help(check.workflow.map { "\($0) · \(check.name)" } ?? check.name)
            } else {
                Text(check.name)
            }
            Spacer(minLength: DS.Space.s)
            Text(check.status.kind.word).foregroundStyle(DS.Palette.textSecondary)
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

struct GhHintView: View {
    let hint: GhHint
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(hint.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DS.Palette.attention)
            Text(hint.detail).font(.caption).foregroundStyle(DS.Palette.textSecondary)
            if let command = hint.command {
                HStack(spacing: 6) {
                    Text(command)
                        .font(DS.Font.literalSmall)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(DS.Palette.selectedFill, in: .rect(cornerRadius: DS.Radius.chip))
                    Button(copied ? "Copied" : "Copy") {
                        Pasteboard.copy(command)
                        copied = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
        }
        .accessibilityIdentifier("gh-hint")
    }
}

struct RunMenu: View {
    let git: GitUI
    let worktree: WorktreeState?
    @Environment(WindowModel.self) private var model

    var body: some View {
        let scripts = git.scripts(for: worktree)
        let repo = scripts.filter(\.fromRepo)
        let global = scripts.filter { !$0.fromRepo }
        Menu {
            if scripts.isEmpty {
                Text("No scripts yet")
            }
            ForEach(repo) { script in item(script) }
            if !global.isEmpty {
                Section("Global") {
                    ForEach(global) { script in item(script) }
                }
            }
            Divider()
            Button("Edit Scripts…", systemImage: "slider.horizontal.3") { model.sheet = .settings }
        } label: {
            Label("Run", systemImage: git.defaultScript(for: worktree)?.systemImage ?? "play")
        } primaryAction: {
            git.runDefault()
        }
        .menuIndicator(.visible)
        .help(git.defaultScript(for: worktree).map { "Run \($0.name) (⌘R)" } ?? "Run Script (⌘R)")
        .accessibilityIdentifier("run-menu")
    }

    private func item(_ script: ScriptDef) -> some View {
        Button {
            git.run(script, in: worktree)
        } label: {
            Label {
                Text(script.name)
            } icon: {
                Image(systemName: script.systemImage).foregroundStyle(script.color)
            }
        }
        .help(script.command)
    }
}

struct OpenInMenu: View {
    let git: GitUI
    @Environment(WindowModel.self) private var model

    var body: some View {
        Menu {
            Button("VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { model.openEditor() }
            Button("VS Code Beside", systemImage: "rectangle.split.2x1") { model.openEditor(placement: .split) }
            #if os(macOS)
            if DesktopVSCode.isInstalled {
                Button("Desktop VS Code", systemImage: "macwindow") { model.openInDesktopVSCode() }
            }
            #endif
            Button("Files", systemImage: "folder") { model.sheet = .files }
            Button("Diff", systemImage: "plusminus") { model.sheet = .diff }
            if let worktree = git.worktree, let port = git.port(of: worktree) {
                Button("localhost:\(String(port))", systemImage: "globe") { git.openPort(of: worktree) }
                    .help("Open localhost:\(String(port)) in the browser")
            }
            if let pr = git.pr {
                Divider()
                Button("GitHub · #\(pr.number)", systemImage: "arrow.up.right.square") { git.openOnGitHub(pr) }
            }
        } label: {
            Label("Open In", systemImage: "arrow.up.forward.app")
        }
        .menuIndicator(.hidden)
        .help("Open in VS Code, Files or Diff")
        .accessibilityIdentifier("open-in-menu")
    }
}

/// Attached once per window.
struct GitDialogs: ViewModifier {
    let git: GitUI

    func body(content: Content) -> some View {
        @Bindable var git = git
        content
            .confirmationDialog(
                mergeTitle, isPresented: Binding(get: { git.pendingMerge != nil }, set: { if !$0 { git.pendingMerge = nil } }),
                titleVisibility: .visible, presenting: git.pendingMerge
            ) { pending in
                Button(GitSettings.name(pending.strategy)) { git.merge(pending) }
                    .accessibilityIdentifier("confirm-merge")
                Button("Cancel", role: .cancel) { git.pendingMerge = nil }
            } message: { pending in
                Text(pending.unstable
                    ? "\(pending.title). An optional check failed; GitHub allows the merge."
                    : pending.title)
            }
            .confirmationDialog(
                removalTitle, isPresented: Binding(get: { git.pendingRemoval != nil }, set: { if !$0 { git.pendingRemoval = nil } }),
                titleVisibility: .visible, presenting: git.pendingRemoval
            ) { pending in
                Button(pending.kind == .archive ? "Archive with Changes" : "Delete Worktree", role: pending.kind == .delete ? .destructive : nil) {
                    git.pendingRemoval = nil
                    guard let worktree = git.hub(pending.host)?.worktree(pending.path) else { return }
                    if pending.kind == .archive {
                        git.archive(worktree, host: pending.host, confirmed: true)
                    } else {
                        git.delete(worktree, host: pending.host, confirmed: true)
                    }
                }
                Button("Cancel", role: .cancel) { git.pendingRemoval = nil }
            } message: { pending in
                Text(removalMessage(pending))
            }
            .alert("Check Out Pull Request", isPresented: $git.isCheckoutPromptShown) {
                TextField("Number", text: $git.checkoutNumber)
                Button("Check Out") {
                    if let number = UInt32(git.checkoutNumber.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) {
                        git.checkoutPR(number: number)
                    }
                    git.checkoutNumber = ""
                }
                Button("Cancel", role: .cancel) { git.checkoutNumber = "" }
            } message: {
                Text("Into a new worktree, with a tab there.")
            }
    }

    private var mergeTitle: String {
        guard let pending = git.pendingMerge else { return "Merge?" }
        return "Merge #\(pending.number)?"
    }

    private var removalTitle: String {
        guard let pending = git.pendingRemoval else { return "" }
        return pending.kind == .archive ? "Archive \(pending.branch)?" : "Delete \(pending.branch)?"
    }

    private func removalMessage(_ pending: PendingRemoval) -> String {
        let changes = pending.changes == 1 ? "1 uncommitted change" : "\(pending.changes) uncommitted changes"
        switch pending.kind {
        case .archive:
            return "It has \(changes). They are kept with the archive and come back when you restore it."
        case .delete:
            return pending.changes > 0
                ? "It has \(changes), which will be lost. The branch stays."
                : "The worktree's directory is removed. The branch stays."
        }
    }
}
