import DesignSystem
import Foundation
import GudoCore
import HostKit
import PaneLayout
import SwiftUI
import TerminalCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Where file paths clicked in a terminal open.
enum FileLinkOpening: String, CaseIterable, Identifiable {
    case gudo, vsCode, defaultApp
    var id: String { rawValue }

    static let key = "fileLinksOpenIn"

    static var current: FileLinkOpening {
        get { UserDefaults.standard.string(forKey: key).flatMap(FileLinkOpening.init) ?? .gudo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static var choices: [FileLinkOpening] {
        #if os(macOS)
        allCases
        #else
        [.gudo, .vsCode]
        #endif
    }

    var title: String {
        switch self {
        case .gudo: Brand.name
        case .vsCode: "VS Code"
        case .defaultApp: "Default App"
        }
    }

    /// ⌥⌘-click opens in VS Code whatever the preference.
    static func forClick(optionHeld: Bool) -> FileLinkOpening {
        optionHeld ? .vsCode : current
    }
}

/// A file a terminal named: on a daemon host, or on this device (`hostId` nil).
struct FileTarget: Hashable, Sendable {
    var hostId: String?
    var path: String
    var line: Int?
    var column: Int?

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var pathWithLine: String {
        guard let line else { return path }
        return "\(path):\(line)" + (column.map { ":\($0)" } ?? "")
    }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isMarkdown: Bool { ["md", "markdown", "mdown", "mdx"].contains(fileExtension) }
}

enum FileLinkKind: Equatable {
    case file, directory, missing, unknown

    init(_ found: PathFound) {
        switch found {
        case .file, .other: self = .file
        case .dir: self = .directory
        case .missing: self = .missing
        case .denied: self = .unknown
        }
    }
}

@MainActor
enum FileLinks {
    /// Resolved where the command that printed it ran, then opened as the user chose.
    static func open(_ link: TerminalLink, from pane: Pane, in workspace: Workspace, window: WindowModel, optionHeld: Bool) {
        let machine = workspace.isRemote ? window.ports.hostName : ProcessInfo.processInfo.hostName
        if let host = link.host, !isThisMachine(host, machineName: machine) {
            guard let url = URL(string: link.text) else { return }
            PaneLinks.confirmOpen(url, from: pane) { PaneLinks.openExternally(url) }
            return
        }
        let block = PaneCommandMarks.of(pane)?.block(atViewportRow: link.row)
        let current = pane.workingDirectory.isEmpty ? pane.foreground()?.directory : pane.workingDirectory
        let directory = block?.mark.cwd ?? current
        let target = FileTarget(
            hostId: workspace.isRemote ? workspace.hostId : nil, path: link.resolvedPath(relativeTo: directory),
            line: link.line, column: link.column)
        let choice = FileLinkOpening.forClick(optionHeld: optionHeld)
        let daemon = workspace.isRemote ? (try? (workspace.host as? DaemonConnection)?.workspace.client()) as? DaemonPathAPI : nil
        Task {
            let (resolved, kind) = await resolve(
                target, printed: link.target, daemon: daemon, pane: pane.id.rawValue, command: block?.mark.commandId)
            window.openFile(resolved, kind: kind, choice: choice)
        }
    }

    /// The daemon's answer where it gives one, else the app's own join.
    static func resolve(
        _ target: FileTarget, printed: String, daemon: (any DaemonPathAPI)?, pane: UInt64, command: UInt64?
    ) async -> (FileTarget, FileLinkKind) {
        if target.hostId == nil {
            return (target, localKind(target.path))
        }
        guard let daemon, daemon.offersResolvePaths(),
              let answer = try? await daemon.resolvePaths(paneId: pane, commandId: command, paths: [printed]).first
        else { return (target, .unknown) }
        var resolved = target
        resolved.path = answer.path
        return (resolved, FileLinkKind(answer.found))
    }

    static func localKind(_ path: String) -> FileLinkKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    /// A `file://` host names this pane's machine: its own name, or one the app cannot check.
    static func isThisMachine(_ host: String, machineName: String) -> Bool {
        guard let own = shortName(machineName) else { return true }
        return shortName(host) == own
    }

    private static func shortName(_ host: String) -> String? {
        host.split(separator: ".").first.map { $0.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// iPhone and iPad: what a long press on a path offers.
    static func actions(
        for target: FileTarget, window: WindowModel, open: @escaping () -> Void
    ) -> [(title: String, systemImage: String, run: () -> Void)] {
        [
            ("Open", "doc.text.magnifyingglass", open),
            ("Open in VS Code", "chevron.left.forwardslash.chevron.right", { window.openFileInVSCode(target) }),
            ("Copy Path", "doc.on.doc", { FileViewerPasteboard.copy(target.path) }),
            ("Insert in Terminal", "text.insert", { window.insertInTerminal(target.path) }),
        ]
    }
}

extension WindowModel {
    /// A file from a terminal: the viewer (a folder opens in Files), VS Code or the default app.
    func openFile(_ target: FileTarget, kind: FileLinkKind, choice: FileLinkOpening) {
        switch choice {
        case .vsCode:
            openFileInVSCode(target)
        case .defaultApp where target.hostId == nil:
            openFileInDefaultApp(target)
        case .gudo, .defaultApp:
            if kind == .directory {
                revealInFiles(target.path, hostId: target.hostId)
            } else {
                showFileViewer(target)
            }
        }
    }

    func showFileViewer(_ target: FileTarget) {
        if opensToolsAsLeaves {
            openToolLeaf(.viewer) { member in
                member.hostId = target.hostId ?? HostGroups.localId
                member.path = target.path
                member.line = target.line
                member.column = target.column
            }
        } else {
            fileViewerTarget = target
            sheet = .fileViewer
        }
    }

    func openFileInVSCode(_ target: FileTarget) {
        if target.hostId != nil || LaunchOptions.mock {
            openEditor(path: target.path, line: target.line, column: target.column)
            return
        }
        #if os(macOS)
        var address = URLComponents()
        address.scheme = "vscode"
        address.host = "file"
        address.path = (target.path as NSString).expandingTildeInPath
            + (target.line.map { ":\($0)" } ?? "") + (target.column.map { ":\($0)" } ?? "")
        guard let url = address.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            toasts.show(Toast("VS Code isn't installed on this Mac.", systemImage: "chevron.left.forwardslash.chevron.right", style: .neutral))
            return
        }
        NSWorkspace.shared.open(url)
        #endif
    }

    // An app, script or `.webloc` would run: those are shown in the Finder instead.
    func openFileInDefaultApp(_ target: FileTarget) {
        #if os(macOS)
        guard target.hostId == nil else { return }
        let url = URL(fileURLWithPath: (target.path as NSString).expandingTildeInPath)
        if LinkSafety.opensInDefaultApp(url) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
    }

    /// Files at `folder`: a leaf where tools are leaves, else the sheet starting there.
    func revealInFiles(_ folder: String, hostId: String?) {
        #if os(macOS)
        if hostId == nil, !(workspace?.isRemote ?? false) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)])
            return
        }
        #endif
        if opensToolsAsLeaves {
            let member = openToolLeaf(.files)
            filesNavigator(for: member.id, root: folder).go(to: folder)
        } else {
            filesStartFolder = folder
            sheet = .files
        }
    }
}

/// Which printed paths exist, per pane, so only those underline. Asked after the pointer rests.
@MainActor
final class PathUnderlines {
    struct Key: Hashable {
        var command: UInt64?
        var printed: String
    }

    private var known: [Key: Bool] = [:]
    private var asking: (key: Key, task: Task<Void, Never>)?
    private let lookup: (Key) async -> Bool?
    private let onLearned: () -> Void

    static let limit = 512
    static let delay = Duration.milliseconds(120)

    init(lookup: @escaping (Key) async -> Bool?, onLearned: @escaping () -> Void) {
        self.lookup = lookup
        self.onLearned = onLearned
    }

    func underlines(_ key: Key) -> Bool {
        if let exists = known[key] { return exists }
        guard asking?.key != key else { return false }
        asking?.task.cancel()
        asking = (key, Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            let exists = await self.lookup(key)
            if self.asking?.key == key { self.asking = nil }
            guard let exists else { return }
            if self.known.count >= Self.limit { self.known.removeAll() }
            self.known[key] = exists
            self.onLearned()
        })
        return false
    }

    static func attach(to pane: Pane, workspace: Workspace) {
        let paneId = pane.id
        let underlines = PathUnderlines(
            lookup: { [weak workspace] key in
                guard let daemon = workspace.flatMap(pathAPI),
                      let answer = try? await daemon.resolvePaths(paneId: paneId.rawValue, commandId: key.command, paths: [key.printed]).first
                else { return nil }
                return FileLinkKind(answer.found) == .file || FileLinkKind(answer.found) == .directory
            },
            onLearned: { [weak pane] in pane?.view.refreshHoverLink() })
        pane.view.underlinesPath = { [weak workspace, weak pane] link in
            guard let workspace, let pane, pathAPI(workspace) != nil else { return true }
            let command = PaneCommandMarks.of(pane)?.block(atViewportRow: link.row)?.mark.commandId
            return underlines.underlines(Key(command: command, printed: link.target))
        }
    }

    private static func pathAPI(_ workspace: Workspace) -> (any DaemonPathAPI)? {
        guard workspace.isRemote, let daemon = (try? (workspace.host as? DaemonConnection)?.workspace.client()) as? DaemonPathAPI,
              daemon.offersResolvePaths()
        else { return nil }
        return daemon
    }
}

/// Settings ▸ Terminal ▸ File links.
struct FileLinksSettingsSection: View {
    @AppStorage(FileLinkOpening.key) private var opening = FileLinkOpening.gudo

    var body: some View {
        Section {
            Picker("Open File Links In", selection: $opening) {
                ForEach(FileLinkOpening.choices) { Text($0.title).tag($0) }
            }
            .settingAnchor("open-file-links")
        } header: {
            Text("File Links")
        } footer: {
            #if os(macOS)
            Text("⌘-click a path to open it. ⌥⌘-click opens it in VS Code.")
            #else
            Text("Tap a path to open it. Touch and hold for more.")
            #endif
        }
    }
}
