import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Links and paths found in the focused pane's scrollback, newest first.
struct LinksSheet: View {
    let links: [DetectedLink]
    var onOpen: (DetectedLink) -> Void = { _ in }
    var onInsert: (DetectedLink) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var filter = Filter.all
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", urls = "URLs", paths = "Paths"
        var id: String { rawValue }
    }

    private var visible: [DetectedLink] {
        links
            .filter {
                switch filter {
                case .all: true
                case .urls: $0.kind == .url
                case .paths: $0.kind == .path
                }
            }
            .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
            .sorted { $0.line > $1.line }
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
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") {
                                onOpen(link)
                                dismiss()
                            }
                            Button("Copy", systemImage: "doc.on.doc") { LinksPasteboard.copy(link.text) }
                            Button("Insert in Terminal", systemImage: "text.insert") {
                                onInsert(link)
                                dismiss()
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Copy", systemImage: "doc.on.doc") { LinksPasteboard.copy(link.text) }
                                .tint(.gray)
                        }
                    }
                } footer: {
                    Text("Found in the focused pane's scrollback. ⌘-click a link in the terminal to open it directly.")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .overlay {
                if visible.isEmpty {
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
        }
        .phoneDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}

private struct LinkRow: View {
    let link: DetectedLink

    var body: some View {
        ListRow(text, leading: {
            Image(systemName: link.kind == .url ? "link" : "doc.text")
                .foregroundStyle(.secondary)
        }) {
            Text(offset)
        }
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
            return Text("\(Text(verbatim: parts.directory).font(font).foregroundStyle(.secondary))\(Text(verbatim: parts.name).font(font.weight(.medium)))\(Text(verbatim: parts.position).font(font).foregroundStyle(.secondary))")
        }
    }

    private var offset: String {
        switch link.line {
        case 0: "visible"
        case -1: "1 line up"
        case ..<0: "\(-link.line) lines up"
        default: "line \(link.line)"
        }
    }
}

/// `dir/name.ext:12:7` split into directory, file name and the `:line:col` suffix.
private struct PathParts {
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
