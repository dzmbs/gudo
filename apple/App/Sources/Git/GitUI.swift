import DesignSystem
import Foundation
import HostKit
import Observation
import PaneLayout
import SwiftUI
import UnnamedCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings of the git-native workspace, kept on this device (Settings ▸ Git).
enum GitSettings {
    static let mergeStrategyKey = "git.mergeStrategy"
    static let autoDeleteDaysKey = "git.autoDeleteDays"
    static let globalScriptsKey = "git.globalScripts"
    /// Posted when the auto-delete setting changes, so every window sends it to its host.
    static let autoDeleteChanged = Notification.Name("git.autoDeleteChanged")

    static var mergeStrategy: MergeStrategy {
        switch UserDefaults.standard.string(forKey: mergeStrategyKey) {
        case "squash": .squash
        case "rebase": .rebase
        default: .merge
        }
    }

    static func name(_ strategy: MergeStrategy) -> String {
        switch strategy {
        case .merge: "Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }

    /// Days after a merge before a host deletes the worktrees it made (sent to each host).
    static var autoDeleteDays: Int {
        UserDefaults.standard.object(forKey: autoDeleteDaysKey) as? Int ?? 7
    }

    /// Scripts for every repository, kept on this device.
    static var globalScripts: [ScriptDef] {
        get {
            guard let data = UserDefaults.standard.data(forKey: globalScriptsKey),
                  let scripts = try? JSONDecoder().decode([ScriptDef].self, from: data)
            else { return [] }
            return scripts
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: globalScriptsKey)
        }
    }
}

/// A named command with an SF Symbol and a tint (a repository's from `.<product>.json`, or a
/// global one from Settings).
struct ScriptDef: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    var icon: String?
    var tint: String?
    var isDefault = false
    /// From the repository (else global).
    var fromRepo = false

    init(name: String, command: String, icon: String? = nil, tint: String? = nil, isDefault: Bool = false, fromRepo: Bool = false) {
        self.name = name
        self.command = command
        self.icon = icon
        self.tint = tint
        self.isDefault = isDefault
        self.fromRepo = fromRepo
    }

    init(_ script: RepoScript) {
        self.init(name: script.name, command: script.command, icon: script.icon, tint: script.tint, isDefault: script.isDefault, fromRepo: true)
    }

    var systemImage: String { icon?.nonEmpty ?? "play" }

    /// The script's tint: a palette name or `#RRGGBB`.
    var color: AnyShapeStyle {
        switch tint?.lowercased() {
        case "green": AnyShapeStyle(DS.Palette.done)
        case "red": AnyShapeStyle(DS.Palette.error)
        case "yellow", "orange", "amber": AnyShapeStyle(DS.Palette.attention)
        case "blue": AnyShapeStyle(DS.Palette.info)
        case "purple", "magenta": AnyShapeStyle(DS.Palette.merged)
        case let hex? where hex.hasPrefix("#") && hex.count == 7: AnyShapeStyle(Color(hex: hex))
        default: AnyShapeStyle(DS.Palette.textSecondary)
        }
    }
}

/// A merge the user is asked to confirm.
struct PendingMerge: Identifiable, Equatable {
    var path: String
    var number: UInt32
    var title: String
    var strategy: MergeStrategy
    var unstable: Bool
    var id: String { "\(path)#\(number)" }
}

/// An archive or delete that needs a yes because the worktree has changes.
struct PendingRemoval: Identifiable, Equatable {
    enum Kind { case archive, delete }
    var kind: Kind
    var host: String?
    var path: String
    var branch: String
    var changes: UInt32
    var id: String { "\(kind)-\(path)" }
}

/// One window's git-native workspace: the focused pane's worktree and pull request on the
/// window's host, and the actions on them (toolbar, palette, sidebar context menus).
@MainActor
@Observable
final class GitUI {
    @ObservationIgnored weak var window: WindowModel?
    var pendingMerge: PendingMerge?
    var pendingRemoval: PendingRemoval?
    var isPRPopoverShown = false
    var isCheckoutPromptShown = false
    var checkoutNumber = ""
    var isArchivedShown = false
    /// A request in flight, for the popover's buttons ("Merging…").
    var busy: String?
    /// Archived worktrees on the window's host (loaded when the palette opens).
    var archived: [ArchivedWorktree] = []

    func refreshArchived() {
        guard let api = try? hub?.repoClient() else {
            archived = []
            return
        }
        Task { archived = (try? await api.worktreeArchived(repo: nil)) ?? [] }
    }
    /// Hosts whose auto-delete setting this device has sent.
    @ObservationIgnored private var sentAutoDelete: [String: Int] = [:]
    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?

    init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: GitSettings.autoDeleteChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAutoDelete() }
        }
    }

    /// The repository hub of the window's host, when it is a daemon.
    var hub: DaemonWorkspace? {
        guard let daemon = window?.workspace?.host as? DaemonConnection else { return nil }
        return daemon.existingWorkspace ?? daemon.workspace
    }

    var daemon: DaemonConnection? { window?.workspace?.host as? DaemonConnection }

    /// A host's daemon connection (the window's when nil).
    func connection(_ host: String?) -> DaemonConnection? {
        guard let host else { return daemon }
        return window?.app.hosts.connection(host) as? DaemonConnection
    }

    /// Whether a host (the window's when nil) is someone else's, joined as a guest.
    func isGuest(_ host: String?) -> Bool {
        guard let id = host ?? window?.workspace?.hostId else { return false }
        return window?.app.hosts.record(id)?.isGuest == true
    }

    /// A host's repository hub (the window's when nil).
    func hub(_ host: String?) -> DaemonWorkspace? {
        guard let daemon = connection(host) else { return nil }
        return daemon.existingWorkspace ?? daemon.workspace
    }

    /// The worktree of the focused pane.
    var worktree: WorktreeState? {
        guard let pane = window?.workspace?.focusedPane else { return nil }
        return hub?.worktree(ofPane: pane.rawValue)
    }

    var pr: PullRequest? { worktree?.visiblePR }

    var gh: GhStatus { hub?.repos?.gh ?? .unknown }

    /// The scripts for a worktree: the repository's, then the global ones.
    func scripts(for worktree: WorktreeState?) -> [ScriptDef] {
        (worktree?.scripts.map(ScriptDef.init) ?? []) + GitSettings.globalScripts
    }

    /// ⌘R's script: the repository's default, else its first, else the first global one.
    func defaultScript(for worktree: WorktreeState?) -> ScriptDef? {
        let all = scripts(for: worktree)
        return all.first(where: \.isDefault) ?? all.first
    }

    // MARK: Actions

    private func toast(_ text: String, _ image: String = "exclamationmark.triangle.fill", style: Toast.Style = .failure) {
        window?.toasts.show(Toast(text, systemImage: image, style: style))
    }

    private func api(_ host: String? = nil) -> (any DaemonRepoAPI)? {
        do {
            guard let hub = hub(host) else { throw HostError.notConnected }
            return try hub.repoClient()
        } catch {
            toast("Not connected to \(window?.hostName ?? "the host").", "network.slash", style: .neutral)
            return nil
        }
    }

    /// Opens the pull request's page in the browser.
    func openOnGitHub(_ pr: PullRequest? = nil) {
        // The host reports the address: only a web page goes to the system.
        guard let url = URL(string: (pr ?? self.pr)?.url ?? ""), HostLinks.mayOpen(url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Asks to merge (Merge PR): refused in words when GitHub says it cannot be merged.
    func requestMerge(_ worktree: WorktreeState? = nil) {
        guard let wt = worktree ?? self.worktree, let pr = wt.visiblePR else { return }
        if let blocker = pr.mergeBlocker {
            toast("Can't merge #\(pr.number): \(blocker)", "arrow.triangle.merge", style: .neutral)
            return
        }
        pendingMerge = PendingMerge(
            path: wt.path, number: pr.number, title: pr.title, strategy: GitSettings.mergeStrategy,
            unstable: pr.mergeState == .unstable)
    }

    func merge(_ pending: PendingMerge) {
        guard let api = api() else { return }
        pendingMerge = nil
        busy = "Merging…"
        Task {
            defer { busy = nil }
            do {
                let after = try await api.prMerge(path: pending.path, number: pending.number, strategy: pending.strategy)
                hub?.applyPR(after, to: pending.path)
                toast("Merged #\(pending.number)", "arrow.triangle.merge", style: .success)
            } catch {
                toast("Couldn't merge #\(pending.number): \(ScreenError.describe(error))")
            }
        }
    }

    func rerunFailed(_ worktree: WorktreeState? = nil) {
        guard let wt = worktree ?? self.worktree, let api = api() else { return }
        busy = "Re-running…"
        Task {
            defer { busy = nil }
            do {
                let after = try await api.prRerunFailed(path: wt.path)
                hub?.applyPR(after, to: wt.path)
                toast("Re-running failed checks", "arrow.clockwise", style: .success)
            } catch {
                toast("Couldn't re-run checks: \(ScreenError.describe(error))")
            }
        }
    }

    func createPR(_ worktree: WorktreeState? = nil, draft: Bool = false) {
        guard let wt = worktree ?? self.worktree, let api = api() else { return }
        busy = "Pushing…"
        Task {
            defer { busy = nil }
            do {
                let pr = try await api.prCreate(path: wt.path, draft: draft, base: nil)
                hub?.applyPR(pr, to: wt.path)
                toast(pr.map { "Opened #\($0.number)" } ?? "Pull request opened", "arrow.triangle.pull", style: .success)
            } catch {
                toast("Couldn't open a pull request: \(ScreenError.describe(error))")
            }
        }
    }

    /// Checks a pull request out into a new worktree and opens a tab there.
    func checkoutPR(number: UInt32) {
        guard let api = api(), let repo = worktree?.repo ?? hub?.repos?.worktrees.first?.repo else {
            toast("Open a tab in the repository first.", "arrow.triangle.pull", style: .neutral)
            return
        }
        busy = "Checking out…"
        Task {
            defer { busy = nil }
            do {
                let info = try await api.prCheckout(repo: repo, number: number)
                hub?.notePort(info.port, worktree: info.path)
                openTab(in: info.path, name: "pr-\(number)")
                toast("#\(number) is in \((info.path as NSString).lastPathComponent)", "arrow.triangle.pull", style: .success)
            } catch {
                toast("Couldn't check out #\(number): \(ScreenError.describe(error))")
            }
        }
    }

    /// Archive: asks first when the worktree has changes (they are kept with it).
    func archive(_ wt: WorktreeState, host: String? = nil, confirmed: Bool = false) {
        if wt.dirty && !confirmed {
            pendingRemoval = PendingRemoval(kind: .archive, host: host, path: wt.path, branch: wt.displayBranch, changes: wt.changedFiles)
            return
        }
        guard let api = api(host) else { return }
        Task {
            do {
                await confirmTeardown(of: wt, host: host, api: api)
                try await api.worktreeArchive(path: wt.path, force: confirmed)
                closeTabs(in: wt.path, host: host)
                toast("Archived \(wt.displayBranch)", "archivebox", style: .success)
            } catch {
                toast("Couldn't archive: \(ScreenError.describe(error))")
            }
        }
    }

    /// Delete: never with changes without asking.
    func delete(_ wt: WorktreeState, host: String? = nil, confirmed: Bool = false) {
        if !confirmed {
            pendingRemoval = PendingRemoval(kind: .delete, host: host, path: wt.path, branch: wt.displayBranch, changes: wt.changedFiles)
            return
        }
        guard let api = api(host) else { return }
        Task {
            do {
                await confirmTeardown(of: wt, host: host, api: api)
                try await api.worktreeRemove(path: wt.path, force: wt.dirty, deleteBranch: false)
                closeTabs(in: wt.path, host: host)
                toast("Deleted \(wt.name)", "trash", style: .success)
            } catch {
                toast("Couldn't delete: \(ScreenError.describe(error))")
            }
        }
    }

    /// The repository's own teardown runs only once the owner trusts it; declining archives or
    /// deletes without it.
    private func confirmTeardown(of wt: WorktreeState, host: String?, api: any DaemonRepoAPI) async {
        guard let trust = api as? any DaemonRepoTrustAPI, !isGuest(host) else { return }
        let ask = try? await trust.repoHooksForWorktree(path: wt.path)
        await RepoTrustPrompt.confirm(ask, moment: .teardown, api: trust)
    }

    func restore(_ archived: ArchivedWorktree) {
        guard let api = api() else { return }
        Task {
            do {
                let info = try await api.worktreeRestore(id: archived.id)
                hub?.notePort(info.port, worktree: info.path)
                openTab(in: info.path, name: (info.path as NSString).lastPathComponent)
                toast("Restored \(archived.branch ?? archived.path)", "tray.and.arrow.up", style: .success)
            } catch {
                toast("Couldn't restore: \(ScreenError.describe(error))")
            }
        }
    }

    /// Runs a script in its own tab in the worktree.
    func run(_ script: ScriptDef, in worktree: WorktreeState? = nil, host: String? = nil) {
        guard let wt = worktree ?? self.worktree else {
            toast("Scripts run in a repository; open a tab in one first.", "play", style: .neutral)
            return
        }
        guard let daemon = connection(host), let api = api(host), let session = daemon.layout.sessionId else { return }
        Task {
            do {
                let pane = try await api.scriptRun(cwd: wt.path, sessionId: session, name: script.name, command: script.command)
                window?.reveal(host: daemon.hostId, pane: pane)
            } catch {
                toast("Couldn't run \(script.name): \(ScreenError.describe(error))")
            }
        }
    }

    func runDefault() {
        guard let script = defaultScript(for: worktree) else {
            toast("No scripts yet: add one in Settings ▸ Git, or in the repository's .\(Brand.name.lowercased()).json.", "play", style: .neutral)
            return
        }
        run(script)
    }

    /// The worktree's `PORT` on its host (the window's when nil), if the daemon gave it one.
    func port(of wt: WorktreeState?, host: String? = nil) -> UInt16? {
        guard let wt, !wt.main else { return nil }
        return hub(host)?.port(ofWorktree: wt.path)
    }

    /// Opens the worktree's `localhost:PORT` in the in-app browser: the host's port forwarded
    /// to the same port here. A worktree on another host first brings its tab forward (the
    /// browser forwards from the window's host).
    func openPort(of wt: WorktreeState, host: String? = nil, tab: Tab? = nil) {
        guard let window, let port = port(of: wt, host: host) else { return }
        let fromPopover = isPRPopoverShown
        isPRPopoverShown = false
        Task {
            // A sheet cannot come up while the popover is still going away.
            if fromPopover { try? await Task.sleep(for: .milliseconds(450)) }
            if let host, host != window.workspace?.hostId {
                guard let tab else {
                    toast("Open a tab in \(wt.displayBranch) first.", "network", style: .neutral)
                    return
                }
                window.focus(TabRef(hostId: host, tab: tab.id))
                try? await Task.sleep(for: .milliseconds(100))
            }
            let detected = window.ports.ports.first { $0.port == port }
                ?? DetectedPort(port: port, process: "", url: nil, isHTTP: true, loopbackOnly: true, pane: wt.displayBranch)
            await window.openPort(detected)
        }
    }

    /// A new tab with a shell in `path`.
    func openTab(in path: String, name: String, host: String? = nil) {
        guard let daemon = connection(host), let session = daemon.layout.sessionId, let api = api(host) else { return }
        Task {
            // An empty command is a plain shell tab in the directory.
            if let pane = try? await api.scriptRun(cwd: path, sessionId: session, name: name, command: "") {
                window?.reveal(host: daemon.hostId, pane: pane)
            }
        }
    }

    private func closeTabs(in path: String, host: String?) {
        guard let workspace = host.flatMap({ window?.workspace(ofGroup: $0) }) ?? window?.workspace,
              let snapshot = hub(host)?.repos else { return }
        let panes = Set(snapshot.panes.filter { $0.worktree == path }.map(\.paneId))
        for tab in workspace.session.tabs where tab.root.panes.allSatisfy({ panes.contains($0.rawValue) }) && !panes.isEmpty {
            workspace.apply(.closeTab(tab.id))
        }
    }

    /// Sends this device's auto-delete setting to the window's host once per change.
    func syncAutoDelete() {
        guard let daemon, let api = try? hub?.repoClient() else { return }
        let days = GitSettings.autoDeleteDays
        guard sentAutoDelete[daemon.hostId] != days else { return }
        sentAutoDelete[daemon.hostId] = days
        Task { _ = try? await api.worktreeAutoDeleteDays(set: UInt32(days)) }
    }
}

extension PullRequest {
    var kind: PRKind {
        switch state {
        case .merged: .merged
        case .closed: .closed
        case .open: draft ? .draft : .open
        }
    }

    var checkKinds: [CheckKind] { checks.map(\.status.kind) }
}

extension CheckStatus {
    var kind: CheckKind {
        switch self {
        case .pending: .pending
        case .success: .success
        case .failure: .failure
        case .neutral: .neutral
        case .skipped: .skipped
        case .cancelled: .cancelled
        }
    }
}
