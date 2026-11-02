import DesignSystem
import Foundation
import HostKit
import Observation
import PaneLayout
import SwiftUI
import GudoCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum GitSettings {
    static let mergeStrategyKey = "git.mergeStrategy"
    static let autoDeleteDaysKey = "git.autoDeleteDays"
    static let globalScriptsKey = "git.globalScripts"
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

    static var autoDeleteDays: Int {
        UserDefaults.standard.object(forKey: autoDeleteDaysKey) as? Int ?? 7
    }

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

/// A repository's script from its `.gudo.json`, or a global one from Settings.
struct ScriptDef: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    var icon: String?
    var tint: String?
    var isDefault = false
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

    /// `tint` is a palette name or `#RRGGBB`.
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

/// One window's focused worktree and pull request, and the git actions on them.
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
    /// The in-flight request's label, such as "Merging…".
    var busy: String?
    var archived: [ArchivedWorktree] = []

    func refreshArchived() {
        guard let api = try? hub?.repoClient() else {
            archived = []
            return
        }
        Task { archived = (try? await api.worktreeArchived(repo: nil)) ?? [] }
    }
    @ObservationIgnored private var sentAutoDelete: [String: Int] = [:]
    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?

    init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: GitSettings.autoDeleteChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAutoDelete() }
        }
    }

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

    var worktree: WorktreeState? {
        guard let pane = window?.workspace?.focusedPane else { return nil }
        return hub?.worktree(ofPane: pane.rawValue)
    }

    var pr: PullRequest? { worktree?.visiblePR }

    var gh: GhStatus { hub?.repos?.gh ?? .unknown }

    func scripts(for worktree: WorktreeState?) -> [ScriptDef] {
        (worktree?.scripts.map(ScriptDef.init) ?? []) + GitSettings.globalScripts
    }

    /// ⌘R's script: the repository's default, else its first, else the first global one.
    func defaultScript(for worktree: WorktreeState?) -> ScriptDef? {
        let all = scripts(for: worktree)
        return all.first(where: \.isDefault) ?? all.first
    }

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

    func openOnGitHub(_ pr: PullRequest? = nil) {
        // The host reports the address: only a web page goes to the system.
        guard let url = URL(string: (pr ?? self.pr)?.url ?? ""), HostLinks.mayOpen(url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func requestMerge(_ worktree: WorktreeState? = nil) {
        guard let worktree = worktree ?? self.worktree, let pr = worktree.visiblePR else { return }
        if let blocker = pr.mergeBlocker {
            toast("Can't merge #\(pr.number): \(blocker)", "arrow.triangle.merge", style: .neutral)
            return
        }
        pendingMerge = PendingMerge(
            path: worktree.path, number: pr.number, title: pr.title, strategy: GitSettings.mergeStrategy,
            unstable: pr.mergeState == .unstable)
    }

    func merge(_ pending: PendingMerge) {
        guard let api = api() else { return }
        pendingMerge = nil
        busy = "Merging…"
        Task {
            defer { busy = nil }
            do {
                let updated = try await api.prMerge(path: pending.path, number: pending.number, strategy: pending.strategy)
                hub?.applyPR(updated, to: pending.path)
                toast("Merged #\(pending.number)", "arrow.triangle.merge", style: .success)
            } catch {
                toast("Couldn't merge #\(pending.number): \(ScreenError.describe(error))")
            }
        }
    }

    func rerunFailed(_ worktree: WorktreeState? = nil) {
        guard let worktree = worktree ?? self.worktree, let api = api() else { return }
        busy = "Re-running…"
        Task {
            defer { busy = nil }
            do {
                let updated = try await api.prRerunFailed(path: worktree.path)
                hub?.applyPR(updated, to: worktree.path)
                toast("Re-running failed checks", "arrow.clockwise", style: .success)
            } catch {
                toast("Couldn't re-run checks: \(ScreenError.describe(error))")
            }
        }
    }

    func createPR(_ worktree: WorktreeState? = nil, draft: Bool = false) {
        guard let worktree = worktree ?? self.worktree, let api = api() else { return }
        busy = "Pushing…"
        Task {
            defer { busy = nil }
            do {
                let pr = try await api.prCreate(path: worktree.path, draft: draft, base: nil)
                hub?.applyPR(pr, to: worktree.path)
                toast(pr.map { "Opened #\($0.number)" } ?? "Pull request opened", "arrow.triangle.pull", style: .success)
            } catch {
                toast("Couldn't open a pull request: \(ScreenError.describe(error))")
            }
        }
    }

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

    func archive(_ worktree: WorktreeState, host: String? = nil, confirmed: Bool = false) {
        if worktree.dirty && !confirmed {
            pendingRemoval = PendingRemoval(kind: .archive, host: host, path: worktree.path, branch: worktree.displayBranch, changes: worktree.changedFiles)
            return
        }
        guard let api = api(host) else { return }
        Task {
            do {
                await confirmTeardown(of: worktree, host: host, api: api)
                try await api.worktreeArchive(path: worktree.path, force: confirmed)
                closeTabs(in: worktree.path, host: host)
                toast("Archived \(worktree.displayBranch)", "archivebox", style: .success)
            } catch {
                toast("Couldn't archive: \(ScreenError.describe(error))")
            }
        }
    }

    func delete(_ worktree: WorktreeState, host: String? = nil, confirmed: Bool = false) {
        if !confirmed {
            pendingRemoval = PendingRemoval(kind: .delete, host: host, path: worktree.path, branch: worktree.displayBranch, changes: worktree.changedFiles)
            return
        }
        guard let api = api(host) else { return }
        Task {
            do {
                await confirmTeardown(of: worktree, host: host, api: api)
                try await api.worktreeRemove(path: worktree.path, force: worktree.dirty, deleteBranch: false)
                closeTabs(in: worktree.path, host: host)
                toast("Deleted \(worktree.name)", "trash", style: .success)
            } catch {
                toast("Couldn't delete: \(ScreenError.describe(error))")
            }
        }
    }

    /// Declining still archives or deletes, only without the repository's teardown.
    private func confirmTeardown(of worktree: WorktreeState, host: String?, api: any DaemonRepoAPI) async {
        guard let trust = api as? any DaemonRepoTrustAPI, !isGuest(host) else { return }
        let ask = try? await trust.repoHooksForWorktree(path: worktree.path)
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

    func run(_ script: ScriptDef, in worktree: WorktreeState? = nil, host: String? = nil) {
        guard let worktree = worktree ?? self.worktree else {
            toast("Scripts run in a repository; open a tab in one first.", "play", style: .neutral)
            return
        }
        guard let daemon = connection(host), let api = api(host), let session = daemon.layout.sessionId else { return }
        Task {
            do {
                let pane = try await api.scriptRun(cwd: worktree.path, sessionId: session, name: script.name, command: script.command)
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

    func port(of worktree: WorktreeState?, host: String? = nil) -> UInt16? {
        guard let worktree, !worktree.main else { return nil }
        return hub(host)?.port(ofWorktree: worktree.path)
    }

    /// A worktree on another host first brings its tab forward: the browser forwards ports from
    /// the window's host.
    func openPort(of worktree: WorktreeState, host: String? = nil, tab: Tab? = nil) {
        guard let window, let port = port(of: worktree, host: host) else { return }
        let fromPopover = isPRPopoverShown
        isPRPopoverShown = false
        Task {
            // A sheet cannot come up while the popover is still going away.
            if fromPopover { try? await Task.sleep(for: .milliseconds(450)) }
            if let host, host != window.workspace?.hostId {
                guard let tab else {
                    toast("Open a tab in \(worktree.displayBranch) first.", "network", style: .neutral)
                    return
                }
                window.focus(TabRef(hostId: host, tab: tab.id))
                try? await Task.sleep(for: .milliseconds(100))
            }
            let detected = window.ports.ports.first { $0.port == port }
                ?? DetectedPort(port: port, process: "", url: nil, isHTTP: true, loopbackOnly: true, pane: worktree.displayBranch)
            await window.openPort(detected)
        }
    }

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
