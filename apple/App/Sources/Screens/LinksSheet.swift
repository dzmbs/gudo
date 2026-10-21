import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Links and paths in the focused pane: on screen and in the output of its recent commands
/// (the daemon's link extraction, paths resolved against the pane's directory). A path opens in
/// VS Code at its line; a URL in the in-app browser (localhost through a forward).
struct LinksSheet: View {
    let source: any LinkSource
    var onOpen: (DetectedLink) -> Void = { _ in }
    var onShowInFiles: ((DetectedLink) -> Void)?
    var onInsert: (DetectedLink) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var links: [DetectedLink]?
    @State private var failure: String?
    @State private var filter = Filter.all
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", urls = "URLs", paths = "Paths"
        var id: String { rawValue }
    }

    private var visible: [DetectedLink] {
        (links ?? [])
            .filter {
                switch filter {
                case .all: true
                case .urls: $0.kind == .url
                case .paths: $0.kind == .path
                }
            }
            .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(visible) { link in
                        Button {
                            onOpen(link)
                            dismiss()
                        } label: {
                            LinkRow(link: link)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("link-\(link.text)")
                        .contextMenu {
                            Button(link.kind == .path ? "Open in VS Code" : "Open", systemImage: "arrow.up.forward.app") {
                                onOpen(link)
                                dismiss()
                            }
                            if link.kind == .path, let onShowInFiles {
                                Button("Show in Files", systemImage: "folder") { onShowInFiles(link) }
                            }
                            Button("Copy", systemImage: "doc.on.doc") { LinksPasteboard.copy(link.resolved) }
                            Button("Insert in Terminal", systemImage: "text.insert") {
                                onInsert(link)
                                dismiss()
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Copy", systemImage: "doc.on.doc") { LinksPasteboard.copy(link.resolved) }
                                .tint(.gray)
                        }
                    }
                } footer: {
                    if links?.isEmpty == false {
                        Text("Found on screen and in the output of the pane's recent commands.")
                    }
                }
                .chromeRows()
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .chromeGrouped()
            .overlay {
                if let failure {
                    EmptyState("Couldn't Read Links", systemImage: "exclamationmark.triangle", message: failure) {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.glass)
                    }
                } else if links != nil, visible.isEmpty {
                    if query.isEmpty {
                        EmptyState(
                            "No Links", systemImage: "link",
                            message: "URLs and file paths printed in this pane show up here.") {}
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
            }
            .searchable(text: $query, prompt: "Filter")
            .navigationTitle("Links & Paths")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
            .task { await load() }
            .accessibilityIdentifier("links-list")
        }
        .phoneDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private func load() async {
        failure = nil
        do {
            let loaded = try await source.links()
            withAnimation(links == nil ? nil : DS.Motion.snappy) { links = loaded }
        } catch {
            failure = ScreenError.describe(error)
        }
    }
}

private struct LinkRow: View {
    let link: DetectedLink

    var body: some View {
        ListRow(text, leading: {
            Image(systemName: link.kind == .url ? "link" : "doc.text")
                .foregroundStyle(DS.Palette.textSecondary)
        }) {
            Text(where_)
        }
        .opacity(link.exists == false ? 0.55 : 1)
        .contentShape(.rect)
    }

    private var text: Text {
        switch link.kind {
        case .url:
            // Fonts on interpolated segments survive ListRow's row font.
            return Text("\(Text(verbatim: link.text).font(DS.Font.literal))")
        case .path:
            let parts = PathParts(link.text)
            let font = DS.Font.literal
            return Text("\(Text(verbatim: parts.directory).font(font).foregroundStyle(DS.Palette.textSecondary))\(Text(verbatim: parts.name).font(font.weight(.medium)))\(Text(verbatim: parts.position).font(font).foregroundStyle(DS.Palette.textSecondary))")
        }
    }

    private var where_: String {
        if link.exists == false { return "not found" }
        if link.fromCommand { return "in output" }
        switch link.line {
        case 0: return "on screen"
        case -1: return "1 line up"
        case ..<0: return "\(-link.line) lines up"
        default: return "line \(link.line)"
        }
    }
}

/// `dir/name.ext:12:7` split into directory, file name and the `:line:col` suffix.
struct PathParts {
    var directory: String
    var name: String
    var position: String

    init(_ text: String) {
        var path = Substring(text)
        var suffix = ""
        // Peel up to two trailing `:number` groups.
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":"), !path[path.index(after: colon)...].isEmpty,
                  path[path.index(after: colon)...].allSatisfy(\.isNumber) else { break }
            suffix = String(path[colon...]) + suffix
            path = path[..<colon]
        }
        if let slash = path.lastIndex(of: "/") {
            directory = String(path[...slash])
            name = String(path[path.index(after: slash)...])
        } else {
            directory = ""
            name = String(path)
        }
        position = suffix
    }

    /// The `:line` and `:col` numbers.
    var numbers: (line: Int?, column: Int?) {
        let parts = position.split(separator: ":").compactMap { Int($0) }
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}

private enum LinksPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension WindowModel {
    /// A link from a pane: a path opens in VS Code at its line (a host pane), a URL in the
    /// in-app browser.
    func open(_ link: DetectedLink) {
        switch link.kind {
        case .url:
            Task { await openURL(link.resolved) }
        case .path:
            let numbers = PathParts(link.text).numbers
            let path = link.target ?? PathParts(link.text).directory + PathParts(link.text).name
            if workspace?.isRemote == true || LaunchOptions.mock {
                openEditor(path: path, line: link.targetLine ?? numbers.line, column: link.targetColumn ?? numbers.column)
            } else {
                #if os(macOS)
                NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                #endif
            }
        }
    }

    /// Types text into the focused pane (as a paste: no newline, nothing runs).
    func insertInTerminal(_ text: String) {
        guard let workspace, let id = workspace.focusedPane, let pane = workspace.panes[id] else { return }
        let quoted = text.contains(" ") ? "'\(text)'" : text
        pane.backend.paste(quoted)
    }

    /// `cd` into a directory in the focused pane.
    func revealInTerminal(_ directory: String) {
        guard let workspace, let id = workspace.focusedPane, let pane = workspace.panes[id] else { return }
        let escaped = directory.replacingOccurrences(of: "'", with: "'\\''")
        Data("cd '\(escaped)'\r".utf8).withUnsafeBytes { pane.backend.write($0) }
        sheet = nil
        destination = .terminal
    }
}
