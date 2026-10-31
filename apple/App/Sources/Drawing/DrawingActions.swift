import DesignSystem
import Foundation
import HostKit
import PaneLayout
import UniformTypeIdentifiers
import UnnamedCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Where a finished drawing can go (the overlay's Send menu and a placement's menu): an agent
/// pane on any host this window shows, a new agent started with it, the pasteboard, a file, or
/// just the terminal. Every destination keeps the drawing in the pane's output too, so it can be
/// sent again, copied or edited later.
nonisolated struct AgentDestination: Identifiable, Equatable, Sendable {
    /// `host/pane`.
    var id: String { "\(hostId)/\(pane)" }
    var hostId: String
    var hostName: String
    var pane: UInt64
    var agent: AgentKind
    /// The tab (or pane) title, to tell two Claude Codes apart.
    var title: String
    /// On the drawing's own host (the image is already there; elsewhere it is uploaded).
    var sameHost: Bool

    /// "Claude Code" or "Claude Code · fix-login" when the title says more than the agent.
    var label: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == agent.title || t.lowercased() == agent.rawValue { return agent.title }
        return "\(agent.title) · \(t)"
    }
}

/// What to do with a finished drawing.
nonisolated enum DrawingAction: Equatable, Sendable {
    case send(AgentDestination)
    /// Starts Claude Code or Codex next to the pane, then attaches the drawing once it is ready.
    case start(AgentKind)
    /// The image, with the `.excalidraw` scene alongside (apps that understand it take it).
    case copy
    /// The drawing as box-glyph text, for chats, commit messages and agents that read text.
    case copyText
    /// iOS: the share sheet (Save Image, AirDrop, Messages…). Mac: the sharing picker.
    case share
    /// A file in one format: a save panel on the Mac, the share sheet on iOS.
    case export(DrawingExportFormat)
    /// Nothing else: the drawing stays in the terminal output.
    case keep

    /// Takes a copy away (pasteboard, file, share sheet); changes nothing on the host.
    var isTakeaway: Bool {
        switch self {
        case .copy, .copyText, .share, .export: true
        case .send, .start, .keep: false
        }
    }

    var id: String {
        switch self {
        case .send(let d): "send-\(d.id)"
        case .start(let kind): "start-\(kind.rawValue)"
        case .copy: "copy"
        case .copyText: "copyText"
        case .share: "share"
        case .export(let format): "export-\(format.rawValue)"
        case .keep: "keep"
        }
    }
}

/// The file formats a drawing exports to.
nonisolated enum DrawingExportFormat: String, CaseIterable, Sendable {
    case png, svg, excalidraw, ascii

    var title: String {
        switch self {
        case .png: "PNG Image…"
        case .svg: "SVG…"
        case .excalidraw: "Excalidraw File…"
        case .ascii: "Text (ASCII)…"
        }
    }

    var systemImage: String {
        switch self {
        case .png: "photo"
        case .svg: "point.topleft.down.to.point.bottomright.curvepath"
        case .excalidraw: "scribble.variable"
        case .ascii: "text.alignleft"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .svg: "svg"
        case .excalidraw: "excalidraw"
        case .ascii: "txt"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .svg: .svg
        case .excalidraw: .excalidraw
        case .ascii: .plainText
        }
    }
}

extension UTType {
    /// `.excalidraw` scenes (imported in Info.plist: Excalidraw declares no type of its own).
    nonisolated static let excalidraw = UTType(importedAs: "com.excalidraw.json", conformingTo: .json)
}

/// The menu both surfaces show, as data (SwiftUI in the overlay, UIMenu / NSMenu on a
/// placement), so the two never drift apart.
struct DrawingMenu {
    struct Item: Identifiable {
        var title: String
        var subtitle: String?
        var systemImage: String
        var action: DrawingAction?
        /// Placement-only entries.
        var placementAction: PlacementAction?
        var destructive = false
        var id: String { action?.id ?? placementAction.map { "placement-\($0)" } ?? title }
    }

    enum PlacementAction: String { case edit, delete, history }

    struct Section: Identifiable {
        var title: String?
        var items: [Item]
        /// Shown as a submenu titled `title` (with `systemImage`) instead of inline.
        var submenu = false
        var systemImage: String?
        var id: String { title ?? items.first?.id ?? "" }
    }

    var sections: [Section]

    /// `primary` is left out of the list when the surface shows it as its own button.
    /// `history`: the placement's drawing has a version history (Version History submenu,
    /// filled when it opens).
    static func make(destinations: [AgentDestination], primary: AgentDestination?, canStart: Bool, includeKeep: Bool, placement: Bool, history: Bool = false) -> DrawingMenu {
        var sections: [Section] = []
        let others = destinations.filter { $0 != primary || placement }
        if !others.isEmpty {
            sections.append(Section(title: "Send to", items: others.map { d in
                Item(title: d.label, subtitle: d.sameHost ? nil : d.hostName, systemImage: d.agent.systemImage, action: .send(d))
            }))
        }
        if canStart {
            sections.append(Section(title: nil, items: [AgentKind.claude, .codex].map { kind in
                Item(title: "Start \(kind.title) with This Drawing", systemImage: "plus.bubble", action: .start(kind))
            }))
        }
        sections.append(Section(title: nil, items: [
            Item(title: "Copy Image", systemImage: "doc.on.doc", action: .copy),
            Item(title: "Copy as Text", systemImage: "text.quote", action: .copyText),
            Item(title: "Share…", systemImage: "square.and.arrow.up", action: .share),
        ]))
        sections.append(Section(
            title: "Export", items: DrawingExportFormat.allCases.map { format in
                Item(title: format.title, systemImage: format.systemImage, action: .export(format))
            }, submenu: true, systemImage: "square.and.arrow.down"))
        if includeKeep {
            sections.append(Section(title: nil, items: [Item(title: "Keep in Terminal", systemImage: "pin", action: .keep)]))
        }
        if placement {
            var items: [Item] = []
            if history {
                items.append(Item(title: "Version History", systemImage: "clock.arrow.circlepath", placementAction: .history))
            }
            sections.append(Section(title: nil, items: items + [
                Item(title: "Edit Drawing", systemImage: "pencil.tip", placementAction: .edit),
                Item(title: "Delete Drawing", systemImage: "trash", placementAction: .delete, destructive: true),
            ]))
        }
        return DrawingMenu(sections: sections)
    }
}

extension PaneDrawing {
    /// The window this pane is shown in.
    var window: WindowModel? {
        workspace.flatMap { ActiveWindow.model(for: $0) } ?? ActiveWindow.model
    }

    /// Every agent pane on every daemon host this window shows: the default target
    /// (`agentTarget`) first, then this host's, then other hosts'.
    func agentDestinations() -> [AgentDestination] {
        guard let window else { return [] }
        let myHost = workspace?.hostId
        var result: [AgentDestination] = []
        for group in window.groups.groups where !group.isLocal {
            guard let daemon = window.app.hosts.connection(group.id) as? DaemonConnection, daemon.status.isLive else { continue }
            let tabs = daemon.layout.session.tabs
            for (pane, meta) in daemon.meta.all {
                guard let agent = meta.agent, meta.exit == nil else { continue }
                guard let tab = tabs.first(where: { $0.root.panes.contains(pane) }) else { continue }
                result.append(AgentDestination(
                    hostId: group.id, hostName: group.name, pane: pane.rawValue, agent: AgentKind(agent.kind),
                    title: tab.title ?? meta.title, sameHost: group.id == myHost))
            }
        }
        let preferred = agentTarget()?.pane
        return result.sorted { a, b in
            let ka = (a.sameHost && a.pane == preferred ? 0 : a.sameHost ? 1 : 2, a.hostName, a.pane)
            let kb = (b.sameHost && b.pane == preferred ? 0 : b.sameHost ? 1 : 2, b.hostName, b.pane)
            return ka < kb
        }
    }

    /// The destination the primary button sends to: an agent in this pane or its tab.
    func primaryDestination(in list: [AgentDestination]) -> AgentDestination? {
        guard let target = agentTarget() else { return nil }
        return list.first { $0.sameHost && $0.pane == target.pane }
    }

    /// New agents can start next to this pane (a writer on a live daemon).
    var canStartAgent: Bool {
        !isReadOnly && (workspace?.host as? DaemonConnection)?.status.isLive == true
    }

    /// Does `action` with a drawing already placed in this pane; returns what to tell the user.
    /// `anchor` is where a share sheet or picker points (pane coordinates).
    func perform(_ action: DrawingAction, artifactId: UInt64?, png: Data, anchor: CGRect) async throws -> PlacedOutcome {
        switch action {
        case .keep:
            return .kept
        case .send(let destination):
            if destination.sameHost {
                _ = try await hub.client.sendToAgent(paneId: destination.pane, artifactId: artifactId, version: nil, png: png)
            } else {
                guard let daemon = window?.app.hosts.connection(destination.hostId) as? DaemonConnection,
                      let client = daemon.workspace.api as? DaemonClient
                else { throw ArtifactError.Disconnected }
                _ = try await client.sendToAgent(paneId: destination.pane, artifactId: nil, version: nil, png: png)
            }
            window?.reveal(host: destination.hostId, pane: destination.pane)
            CanvasWebView.log.info("drawing sent to \(destination.agent.rawValue, privacy: .public) pane \(destination.pane) on \(destination.hostName, privacy: .private)")
            return .sent(destination.agent.title)
        case .start(let kind):
            try await startAgent(kind, artifactId: artifactId, png: png)
            return .sent(kind.title)
        case .copy:
            // The scene rides along so apps that understand it (Excalidraw, this app on another
            // device through Universal Clipboard) get the editable drawing, not just pixels.
            let scene = try? await artifactId.asyncMap { try await hub.client.excalidrawFile(artifactId: $0) }
            Self.copy(png: png, scene: scene)
            return .copied
        case .copyText:
            guard let artifactId else { throw ArtifactError.Invalid(message: "the drawing is not saved yet") }
            let text = try await hub.client.artifactExport(artifactId: artifactId, version: nil, format: .ascii).data
            #if os(iOS)
            UIPasteboard.general.string = String(decoding: text, as: UTF8.self)
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: text, as: UTF8.self), forType: .string)
            #endif
            return .copiedText
        case .share:
            let file = try Self.exportFile(png, format: .png)
            return share(file, anchor: anchor) ? .shared : .kept
        case .export(let format):
            let data = try await exportData(format, artifactId: artifactId, png: png)
            #if os(iOS)
            return share(try Self.exportFile(data, format: format), anchor: anchor) ? .shared : .kept
            #else
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = Self.fileName(format)
            panel.canCreateDirectories = true
            let response: NSApplication.ModalResponse
            if let window = pane?.view.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return .kept }
            try data.write(to: url, options: .atomic)
            return .saved(url.lastPathComponent)
            #endif
        }
    }

    /// The drawing in `format`: the device's PNG, the daemon's SVG or ASCII, or the scene.
    func exportData(_ format: DrawingExportFormat, artifactId: UInt64?, png: Data) async throws -> Data {
        if format == .png { return png }
        guard let artifactId else { throw ArtifactError.Invalid(message: "the drawing is not saved yet") }
        switch format {
        case .png: return png
        case .svg: return try await hub.client.artifactExport(artifactId: artifactId, version: nil, format: .svg).data
        case .ascii: return try await hub.client.artifactExport(artifactId: artifactId, version: nil, format: .ascii).data
        case .excalidraw: return try await hub.client.excalidrawFile(artifactId: artifactId)
        }
    }

    /// Puts the image (and the `.excalidraw` scene, when there is one) on the pasteboard.
    static func copy(png: Data, scene: Data?) {
        #if os(iOS)
        var item: [String: Any] = [UTType.png.identifier: png]
        if let scene { item[UTType.excalidraw.identifier] = scene }
        UIPasteboard.general.setItems([item])
        #else
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let scene { item.setData(scene, forType: NSPasteboard.PasteboardType(UTType.excalidraw.identifier)) }
        board.writeObjects([item])
        #endif
    }

    /// The share sheet (iOS) or sharing picker (Mac) for `file`, pointing at `anchor`.
    private func share(_ file: URL, anchor: CGRect) -> Bool {
        #if os(iOS)
        guard let view = pane?.view, var presenter = view.window?.rootViewController else { return false }
        while let next = presenter.presentedViewController { presenter = next }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = anchor
        presenter.present(sheet, animated: true)
        #else
        guard let view = pane?.view else { return false }
        NSSharingServicePicker(items: [file]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
        #endif
        return true
    }

    static func fileName(_ format: DrawingExportFormat) -> String {
        "Drawing \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())).\(format.fileExtension)"
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
    }

    /// A file in the temporary directory, named for people (share sheets and drops show the
    /// name).
    static func exportFile(_ data: Data, format: DrawingExportFormat) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Drawings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(format))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Starts Claude Code or Codex in a split next to this pane and attaches the drawing once
    private func startAgent(_ kind: AgentKind, artifactId: UInt64?, png: Data) async throws {
        guard let daemon = workspace?.host as? DaemonConnection, let hostId = workspace?.hostId else { throw ArtifactError.Disconnected }
        let api = try daemon.workspace.client()
        let launched = try await api.launchAgentPane(launch: AgentLaunch(
            splitFrom: paneId, agent: kind == .codex ? .codex : .claude, axis: .horizontal,
            worktree: nil, cwd: nil, resume: nil, prompt: nil, submit: false, readyTimeoutMs: 30_000))
        let pane = launched.paneId
        window?.reveal(host: hostId, pane: pane)
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let agent = daemon.meta[PaneId(pane)]?.agent, case .idle = agent.state { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let agent = daemon.meta[PaneId(pane)]?.agent, case .idle = agent.state else {
            throw ArtifactError.Failed(message: "\(kind.title) did not become ready in time")
        }
        _ = try await hub.client.sendToAgent(paneId: pane, artifactId: artifactId, version: nil, png: png)
        CanvasWebView.log.info("drawing attached to a new \(kind.rawValue, privacy: .public) in pane \(pane)")
    }
}

extension Optional {
    /// `map` with an async throwing transform.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

/// What a finished drawing did, for the notice after it.
enum PlacedOutcome: Equatable {
    case kept
    case sent(String)
    case copied
    case copiedText
    case shared
    case saved(String)
}
