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
    case copy
    /// iOS: the share sheet (Save Image, AirDrop, Messages…). Mac: the sharing picker.
    case share
    /// Mac: a save panel.
    case save
    /// Nothing else: the drawing stays in the terminal output.
    case keep

    var id: String {
        switch self {
        case .send(let d): "send-\(d.id)"
        case .start(let kind): "start-\(kind.rawValue)"
        case .copy: "copy"
        case .share: "share"
        case .save: "save"
        case .keep: "keep"
        }
    }
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

    enum PlacementAction: String { case edit, delete }

    struct Section: Identifiable {
        var title: String?
        var items: [Item]
        var id: String { title ?? items.first?.id ?? "" }
    }

    var sections: [Section]

    /// `primary` is left out of the list when the surface shows it as its own button.
    static func make(destinations: [AgentDestination], primary: AgentDestination?, canStart: Bool, includeKeep: Bool, placement: Bool) -> DrawingMenu {
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
        var export: [Item] = [Item(title: "Copy Image", systemImage: "doc.on.doc", action: .copy)]
        #if os(iOS)
        export.append(Item(title: "Share…", systemImage: "square.and.arrow.up", action: .share))
        #else
        export.append(Item(title: "Save Image…", systemImage: "square.and.arrow.down", action: .save))
        export.append(Item(title: "Share…", systemImage: "square.and.arrow.up", action: .share))
        #endif
        sections.append(Section(title: nil, items: export))
        if includeKeep {
            sections.append(Section(title: nil, items: [Item(title: "Keep in Terminal", systemImage: "pin", action: .keep)]))
        }
        if placement {
            sections.append(Section(title: nil, items: [
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
            for (pane, meta) in daemon.meta {
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
            CanvasWebView.log.info("drawing sent to \(destination.agent.rawValue, privacy: .public) pane \(destination.pane) on \(destination.hostName, privacy: .public)")
            return .sent(destination.agent.title)
        case .start(let kind):
            try await startAgent(kind, artifactId: artifactId, png: png)
            return .sent(kind.title)
        case .copy:
            #if os(iOS)
            UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
            #else
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(png, forType: .png)
            #endif
            return .copied
        case .share:
            let file = try Self.exportFile(png)
            #if os(iOS)
            guard let view = pane?.view, var presenter = view.window?.rootViewController else { return .kept }
            while let next = presenter.presentedViewController { presenter = next }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = anchor
            presenter.present(sheet, animated: true)
            #else
            guard let view = pane?.view else { return .kept }
            NSSharingServicePicker(items: [file]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
            #endif
            return .shared
        case .save:
            #if os(macOS)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = Self.fileName
            panel.canCreateDirectories = true
            let response: NSApplication.ModalResponse
            if let window = pane?.view.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return .kept }
            try png.write(to: url)
            return .saved(url.lastPathComponent)
            #else
            return try await perform(.share, artifactId: artifactId, png: png, anchor: anchor)
            #endif
        }
    }

    private static var fileName: String {
        "Drawing \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())).png"
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
    }

    /// A PNG in the temporary directory, named for people (share sheets show the name).
    private static func exportFile(_ png: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Drawings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try png.write(to: url, options: .atomic)
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

/// What a finished drawing did, for the notice after it.
enum PlacedOutcome: Equatable {
    case kept
    case sent(String)
    case copied
    case shared
    case saved(String)
}
