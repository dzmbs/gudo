import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Browse a host's files: directories first, git status at the trailing edge, push to descend.
/// Works inside the caller's NavigationStack (it registers its own destination for paths).
struct FilesBrowserView: View {
    let source: any FileSource
    var onOpen: (FileEntry) -> Void = { _ in }
    /// "Reveal in Terminal" (cd into the directory) and "Insert Path in Terminal".
    var onRevealInTerminal: (String) -> Void = { _ in }
    var onInsertPath: (String) -> Void = { _ in }

    var body: some View {
        DirectoryListing(
            source: source, directory: source.root, onOpen: onOpen,
            onRevealInTerminal: onRevealInTerminal, onInsertPath: onInsertPath)
            .navigationDestination(for: DirectoryRoute.self) { route in
                DirectoryListing(
                    source: source, directory: route.path, onOpen: onOpen,
                    onRevealInTerminal: onRevealInTerminal, onInsertPath: onInsertPath)
            }
    }
}

/// A pushed directory; wrapped so the destination does not claim every `String` in the stack.
private struct DirectoryRoute: Hashable {
    var path: String
}

private struct DirectoryListing: View {
    let source: any FileSource
    let directory: String
    let onOpen: (FileEntry) -> Void
    let onRevealInTerminal: (String) -> Void
    let onInsertPath: (String) -> Void

    @State private var entries: [FileEntry]?
    @State private var failure: String?
    @State private var filter = ""
    @State private var showsProgress = false

    private var visible: [FileEntry] {
        let sorted = (entries ?? []).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationSubtitle(directory)
            .searchable(text: $filter, prompt: "Filter")
            .task(id: directory) { await load() }
    }

    private var title: String {
        directory == source.root ? "Files" : (directory as NSString).lastPathComponent
    }

    @ViewBuilder private var content: some View {
        if entries != nil {
            List {
                ForEach(visible) { entry in
                    row(entry)
                }
            }
            .listStyle(.plain)
            .overlay {
                if visible.isEmpty {
                    if filter.isEmpty {
                        EmptyState("Empty Folder", systemImage: "folder", message: "Nothing in \(title) yet.") {}
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
        } else if let failure {
            EmptyState("Couldn't Read Folder", systemImage: "exclamationmark.triangle", message: failure) {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glass)
            }
        } else {
            ProgressView()
                .opacity(showsProgress ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    try? await Task.sleep(for: DS.Motion.feedbackDelay)
                    showsProgress = true
                }
        }
    }

    @ViewBuilder private func row(_ entry: FileEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink(value: DirectoryRoute(path: entry.path)) { label(entry) }
            } else {
                Button { onOpen(entry) } label: { label(entry) }
                    .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button(entry.isDirectory ? "Open Folder" : "Open", systemImage: "arrow.up.forward.app") {
                if !entry.isDirectory { onOpen(entry) }
            }
            .disabled(entry.isDirectory)
            Button("Copy Path", systemImage: "doc.on.doc") { FilesPasteboard.copy(entry.path) }
            Divider()
            Button("Reveal in Terminal", systemImage: "terminal") {
                onRevealInTerminal(entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent)
            }
            Button("Insert Path in Terminal", systemImage: "text.insert") { onInsertPath(entry.path) }
        }
        .swipeActions(edge: .trailing) {
            Button("Copy Path", systemImage: "doc.on.doc") { FilesPasteboard.copy(entry.path) }
                .tint(.gray)
        }
    }

    private func label(_ entry: FileEntry) -> some View {
        ListRow(Text(entry.name), leading: {
            Image(systemName: FileIcon.symbol(for: entry))
                .symbolVariant(entry.isDirectory ? .fill : .none)
                .foregroundStyle(.secondary)
                .imageScale(.medium)
        }) {
            HStack(spacing: DS.Space.s) {
                if let meta = meta(entry) {
                    Text(meta)
                }
                if let git = entry.git {
                    GitLetter(status: git)
                }
            }
        }
        .contentShape(.rect)
    }

    private func meta(_ entry: FileEntry) -> String? {
        var parts: [String] = []
        if let size = entry.size, !entry.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = entry.modified {
            parts.append(modified.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        failure = nil
        do {
            entries = try await source.list(directory)
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct GitLetter: View {
    let status: FileEntry.GitStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(color)
            .frame(width: 14)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .added, .untracked: DS.Palette.done
        case .deleted: DS.Palette.error
        case .modified, .renamed: DS.Palette.working
        }
    }

    private var label: String {
        switch status {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .untracked: "Untracked"
        case .renamed: "Renamed"
        }
    }
}

/// Monochrome SF Symbols by file kind.
enum FileIcon {
    static func symbol(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder" }
        return symbol(forPath: entry.name)
    }

    static func symbol(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": return "swift"
        case "rs", "c", "h", "cpp", "go", "zig", "ts", "tsx", "js", "py", "rb", "java", "kt": return "chevron.left.forwardslash.chevron.right"
        case "json", "toml", "yaml", "yml", "plist", "lock": return "curlybraces"
        case "md", "txt", "rst": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp": return "photo"
        case "sh", "zsh", "bash", "fish": return "terminal"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "xz": return "doc.zipper"
        default: return name.hasPrefix(".") ? "gearshape" : "doc.text"
        }
    }
}

private enum FilesPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
