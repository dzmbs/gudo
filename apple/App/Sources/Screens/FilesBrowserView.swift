import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Browse a host's files: directories first, git status at the trailing edge, push to descend,
/// tap a file to preview it (text, images). Upload from Files or by dropping, download to share
/// or save, new folder, rename, move to the host's trash. The directory is watched, so changes
/// made in the terminal or by an agent show up by themselves.
/// Works inside the caller's NavigationStack (it registers its own destinations).
struct FilesBrowserView: View {
    let source: any FileSource
    /// Opens a file in the editor (VS Code on the host).
    var onOpenInEditor: ((String) -> Void)?
    /// "Reveal in Terminal" (cd into the directory) and "Insert Path in Terminal".
    var onRevealInTerminal: (String) -> Void = { _ in }
    var onInsertPath: (String) -> Void = { _ in }

    @Environment(WindowModel.self) private var model
    /// Where browsing starts instead of `source.root` (Go to Home from a folder that is gone).
    @State private var start: String?

    var body: some View {
        Group {
            if let reason = source.unavailableReason {
                EmptyState("No Host", systemImage: "server.rack", message: reason) {
                    Button("Show Hosts") { model.showHosts() }
                        .buttonStyle(.glass)
                }
                .toolChrome("Files")
            } else {
                let root = start ?? source.root
                DirectoryListing(
                    source: source, directory: root, actions: actions,
                    goHome: root == "~" ? nil : { start = "~" })
                    .id(root)
            }
        }
        .navigationDestination(for: DirectoryRoute.self) { route in
            DirectoryListing(source: source, directory: route.path, actions: actions)
        }
        .navigationDestination(for: FileRoute.self) { route in
            FilePreviewScreen(source: source, entry: route.entry, actions: actions)
        }
    }

    private var actions: FileActions {
        FileActions(openInEditor: onOpenInEditor, revealInTerminal: onRevealInTerminal, insertPath: onInsertPath)
    }
}

struct FileActions {
    var openInEditor: ((String) -> Void)?
    var revealInTerminal: (String) -> Void
    var insertPath: (String) -> Void
}

/// A pushed directory; wrapped so the destination does not claim every `String` in the stack.
private struct DirectoryRoute: Hashable {
    var path: String
}

private struct FileRoute: Hashable {
    var entry: FileEntry
}

/// The listing's filter: the system search field in a sheet or window, a field under the bar
/// in a leaf (the window's search field belongs to the whole window there).
private struct ListingFilter: ViewModifier {
    @Binding var filter: String
    let isShown: Bool
    @Environment(\.toolLeaf) private var leaf

    func body(content: Content) -> some View {
        if leaf == nil {
            content.searchable(text: $filter, prompt: "Filter")
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                if isShown {
                    FilterField(text: $filter)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, DS.Space.xs)
                        .transition(.opacity)
                }
            }
        }
    }
}

private struct DirectoryListing: View {
    let source: any FileSource
    let directory: String
    let actions: FileActions
    /// Where to go when the folder is gone (the start of browsing only).
    var goHome: (() -> Void)?

    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var entries: [FileEntry]?
    @State private var problem: ToolProblem?
    @State private var filter = ""
    @State private var isFiltering = false
    @Environment(\.toolLeaf) private var leaf
    @State private var showsProgress = false
    @State private var watch: FileWatch?
    @State private var reload = 0
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var naming: Naming?
    @State private var name = ""
    @State private var trashing: FileEntry?
    @State private var transfer: Transfer?
    @State private var shared: SharedFile?
    /// `-screen file-preview`: Cargo.toml opened once the root is listed (design review).
    @State private var fixtureFile: FileEntry?

    enum Naming: Identifiable {
        case newFolder
        case rename(FileEntry)
        var id: String {
            switch self {
            case .newFolder: "new"
            case .rename(let entry): entry.path
            }
        }
    }

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
            .chromeContent()
            .modifier(ListingFilter(filter: $filter, isShown: isFiltering))
            .toolChrome(title, subtitle: "\(source.display(directory)) · \(source.hostName)") {
                if leaf != nil {
                    Button("Filter", systemImage: "line.3.horizontal.decrease") {
                        withAnimation(DS.Motion.snappy) {
                            isFiltering.toggle()
                            if !isFiltering { filter = "" }
                        }
                    }
                    .help("Filter")
                }
                Menu("Add", systemImage: "plus") {
                    Button("Upload Files…", systemImage: "square.and.arrow.up") { isImporting = true }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        name = ""
                        naming = .newFolder
                    }
                }
                .menuIndicator(.hidden)
                .accessibilityIdentifier("files-add")
            }
            .task(id: "\(directory)#\(reload)") { await load() }
            .task(id: directory) { await startWatching() }
            .onDisappear {
                watch?.cancel()
                watch = nil
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { upload(urls) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                upload(urls.filter(\.isFileURL))
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: DS.Radius.pane)
                        .strokeBorder(DS.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(DS.Space.s)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { transferBar }
            .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField(namingPlaceholder, text: $name)
                    .autocorrectionDisabled()
                Button(namingAction) { commitName() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Move “\(trashing?.name ?? "")” to the Trash on \(source.hostName)?",
                isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { if let trashing { trash(trashing) } }
            }
            .sheet(item: $shared) { file in
                ShareFileSheet(url: file.url)
            }
            .navigationDestination(item: $fixtureFile) { entry in
                FilePreviewScreen(source: source, entry: entry, actions: actions)
            }
            .onChange(of: entries) { _, entries in
                guard LaunchOptions.screen == "file-preview", directory == source.root, fixtureFile == nil else { return }
                fixtureFile = entries?.first { $0.name == "Cargo.toml" }
            }
    }

    private var title: String {
        directory == source.root ? (directory as NSString).lastPathComponent.nonEmpty ?? "Files" : (directory as NSString).lastPathComponent
    }

    @ViewBuilder private var content: some View {
        if entries != nil {
            List {
                ForEach(visible) { entry in
                    row(entry)
                        .listRowBackground(theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .refreshable { await load() }
            .overlay {
                if visible.isEmpty {
                    if filter.isEmpty {
                        EmptyState("Empty Folder", systemImage: "folder", message: "Drop files here, or upload some from this device.") {
                            Button("Upload Files…", systemImage: "square.and.arrow.up") { isImporting = true }
                                .buttonStyle(.glass)
                        }
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
            .accessibilityIdentifier("files-list")
        } else if let problem {
            EmptyState(
                problem.title ?? "Couldn't Read Folder", systemImage: problem.systemImage, message: problem.message,
                detail: problem.detail.map(source.display)
            ) {
                if case .folderNotFound = problem, let goHome {
                    Button("Go to Home", systemImage: "house") { goHome() }
                        .buttonStyle(.glass)
                }
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glass)
            }
        } else {
            // The design's spinner (a TimelineView), not a looping UIActivityIndicator.
            Spinner()
                .frame(width: 16, height: 16)
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
                NavigationLink(value: FileRoute(entry: entry)) { label(entry) }
            }
        }
        .accessibilityIdentifier("file-\(entry.name)")
        .contextMenu {
            if !entry.isDirectory, let open = actions.openInEditor {
                Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { open(entry.path) }
            }
            if !entry.isDirectory {
                Button(downloadTitle, systemImage: "square.and.arrow.down") { download(entry) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { FilesPasteboard.copy(entry.path) }
            Divider()
            Button("Rename…", systemImage: "pencil") {
                name = entry.name
                naming = .rename(entry)
            }
            Button("Reveal in Terminal", systemImage: "terminal") {
                actions.revealInTerminal(entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent)
            }
            Button("Insert Path in Terminal", systemImage: "text.insert") { actions.insertPath(entry.path) }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { trashing = entry }
        }
        .swipeActions(edge: .trailing) {
            Button("Trash", systemImage: "trash", role: .destructive) { trashing = entry }
            Button("Copy Path", systemImage: "doc.on.doc") { FilesPasteboard.copy(entry.path) }
                .tint(.gray)
        }
    }

    private var downloadTitle: String {
        #if os(macOS)
        "Download"
        #else
        "Share…"
        #endif
    }

    private func label(_ entry: FileEntry) -> some View {
        ListRow(Text(entry.name).foregroundStyle(entry.isHidden ? .secondary : .primary), leading: {
            Image(systemName: FileIcon.symbol(for: entry))
                .symbolVariant(entry.isDirectory ? .fill : .none)
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(DS.Palette.info) : AnyShapeStyle(.secondary))
                .imageScale(.medium)
                .overlay(alignment: .bottomTrailing) {
                    if entry.isSymlink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
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

    // MARK: Transfers

    @ViewBuilder private var transferBar: some View {
        if let transfer {
            HStack(spacing: DS.Space.m) {
                Image(systemName: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.title)
                        .font(DS.Font.rowSubtitle)
                        .lineLimit(1)
                    ProgressView(value: transfer.fraction)
                        .tint(DS.Palette.accent)
                }
                Text(transfer.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .floatingPanel()
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            .movingTransition(.bottom)
            .accessibilityIdentifier("files-transfer")
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            for (index, url) in urls.enumerated() {
                let label = urls.count > 1 ? "Uploading \(url.lastPathComponent) (\(index + 1) of \(urls.count))" : "Uploading \(url.lastPathComponent)"
                withAnimation(DS.Motion.snappy) { transfer = Transfer(title: label, fraction: 0, isUpload: true) }
                do {
                    try await source.upload(url, to: directory) { fraction in transfer?.fraction = fraction }
                } catch {
                    model.toasts.show(Toast("Couldn't upload \(url.lastPathComponent): \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
                }
            }
            withAnimation(DS.Motion.snappy) { transfer = nil }
            model.toasts.show(Toast(urls.count == 1 ? "Uploaded \(urls[0].lastPathComponent)" : "Uploaded \(urls.count) files", systemImage: "checkmark.circle.fill", style: .success))
            await load()
        }
    }

    private func download(_ entry: FileEntry) {
        Task {
            withAnimation(DS.Motion.snappy) { transfer = Transfer(title: "Downloading \(entry.name)", fraction: 0, isUpload: false) }
            defer { withAnimation(DS.Motion.snappy) { transfer = nil } }
            do {
                let url = try await source.download(entry.path) { fraction in transfer?.fraction = fraction }
                deliver(url)
            } catch {
                model.toasts.show(Toast("Couldn't download \(entry.name): \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    private func deliver(_ url: URL) {
        #if os(macOS)
        if let saved = FileDelivery.saveToDownloads(url) {
            NSWorkspace.shared.activateFileViewerSelecting([saved])
            model.toasts.show(Toast("Saved to Downloads", systemImage: "checkmark.circle.fill", style: .success))
        }
        #else
        shared = SharedFile(url: url)
        #endif
    }

    // MARK: Changes

    private var namingTitle: String {
        switch naming {
        case .newFolder?: "New Folder"
        case .rename?: "Rename"
        case nil: ""
        }
    }

    private var namingPlaceholder: String {
        if case .newFolder? = naming { return "untitled folder" }
        return "Name"
    }

    private var namingAction: String {
        if case .rename? = naming { return "Rename" }
        return "Create"
    }

    private func commitName() {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, case .newFolder? = naming { trimmed = "untitled folder" }
        guard !trimmed.isEmpty, !trimmed.contains("/"), let naming else { return }
        Task {
            do {
                switch naming {
                case .newFolder:
                    try await source.mkdir((directory as NSString).appendingPathComponent(trimmed))
                case .rename(let entry):
                    guard trimmed != entry.name else { return }
                    try await source.rename(entry.path, to: trimmed)
                }
                await load()
            } catch {
                model.toasts.show(Toast(ScreenError.describe(error), systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    private func trash(_ entry: FileEntry) {
        withAnimation(DS.Motion.snappy) { entries?.removeAll { $0.path == entry.path } }
        Task {
            do {
                try await source.trash(entry.path)
                model.toasts.show(Toast("Moved \(entry.name) to the Trash", systemImage: "trash", style: .neutral))
            } catch {
                model.toasts.show(Toast("Couldn't move \(entry.name) to the Trash: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
                await load()
            }
        }
    }

    private func load() async {
        problem = nil
        do {
            let loaded = try await source.list(directory)
            withAnimation(entries == nil ? nil : DS.Motion.snappy) { entries = loaded }
        } catch {
            problem = ToolProblem(error, path: directory)
        }
    }

    private func startWatching() async {
        watch?.cancel()
        watch = await source.watch(directory) {
            // Many changes arrive together (an agent writing files): one reload per burst.
            reload += 1
        }
    }
}

private struct Transfer: Equatable {
    var title: String
    var fraction: Double
    var isUpload: Bool
}

struct SharedFile: Identifiable {
    var id: URL { url }
    var url: URL
}

// MARK: - Preview

/// A file's preview: text in the terminal's monospace with line numbers, images fit to the
/// width, anything else as a card with its size. Share / download, open in VS Code.
struct FilePreviewScreen: View {
    let source: any FileSource
    let entry: FileEntry
    let actions: FileActions

    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var preview: FilePreview?
    @State private var problem: ToolProblem?
    @State private var shared: SharedFile?
    @State private var downloading: Double?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.toolLeaf) private var leaf

    var body: some View {
        Group {
            if leaf != nil {
                content
                    .chromeContent()
                    .toolChrome(entry.name, subtitle: [folder, meta].compactMap(\.self).joined(separator: " · ")) { actionButtons }
            } else {
                presented
            }
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: entry.path) { await load() }
        .sheet(item: $shared) { file in ShareFileSheet(url: file.url) }
    }

    private var presented: some View {
        content
            #if os(iOS)
            // Touch: the strip is the whole header (the way back, the file, its folder and its
            // actions) instead of a tall bar with a second row under it.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            #endif
            .chromeContent()
            .navigationTitle(entry.name)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            // The Mac: the window's own titlebar is the header (Xcode's editor title).
            .navigationSubtitle([folder, meta].compactMap(\.self).joined(separator: " · "))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) { actionButtons }
            }
            #endif
    }

    private var folder: String { source.display((entry.path as NSString).deletingLastPathComponent) }

    @ViewBuilder private var actionButtons: some View {
        if let open = actions.openInEditor {
            Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { open(entry.path) }
                .help("Open in VS Code")
                .accessibilityIdentifier("file-open-editor")
        }
        Button(downloading == nil ? "Download" : "Downloading", systemImage: "square.and.arrow.down", action: download)
            .help("Download")
            .disabled(downloading != nil)
            .accessibilityIdentifier("file-download")
        Menu("More", systemImage: "ellipsis") {
            Button("Copy Path", systemImage: "doc.on.doc") { FilesPasteboard.copy(entry.path) }
            Button("Insert Path in Terminal", systemImage: "text.insert") { actions.insertPath(entry.path) }
            if case .text(let text, _)? = preview {
                Button("Copy Contents", systemImage: "doc.on.clipboard") { FilesPasteboard.copy(text) }
            }
        }
        .menuIndicator(.hidden)
        .help("More")
        .accessibilityIdentifier("file-more")
    }

    /// The editor pane's strip, for a file: its kind, name, folder and what is shown of it,
    /// then quiet icon actions.
    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Button("Back", systemImage: "chevron.left") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bar)
                .accessibilityIdentifier("file-back")
            Image(systemName: FileIcon.symbol(for: entry))
                .font(.callout)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.text)
                Text(verbatim: [folder, meta].compactMap(\.self).joined(separator: " · "))
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: DS.Space.s)
            HStack(spacing: DS.Space.xs) { actionButtons }
                .labelStyle(.iconOnly)
                .buttonStyle(.bar)
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.l)
        .frame(height: Self.headerHeight)
        .background(theme.background)
        .overlay(alignment: .bottom) { theme.splitDivider.frame(height: 1) }
        .accessibilityIdentifier("file-header")
    }

    private static let headerHeight: CGFloat = 52

    /// "2 KB · 48 lines", and when only the start is shown, says so.
    private var meta: String? {
        var parts: [String] = []
        if let size = entry.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if case .text(let text, let truncated)? = preview {
            let lines = text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
            parts.append(truncated ? "first MiB" : "\(lines) line\(lines == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        switch preview {
        case .text(let text, let truncated)?:
            TextPreview(text: text, truncated: truncated)
        case .image(let data)?:
            ImagePreview(data: data, name: entry.name)
        case .binary(let size)?:
            EmptyState(entry.name, systemImage: FileIcon.symbol(for: entry), message: "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · no preview for this kind of file.") {
                Button("Download", action: download)
                    .buttonStyle(.primaryGlass)
            }
        case nil:
            if let problem {
                EmptyState(
                    "Couldn't Open \(entry.name)", systemImage: problem.systemImage, message: problem.message,
                    detail: problem.detail.map(source.display)
                ) {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.glass)
                }
            } else {
                Color.clear
            }
        }
    }

    private func load() async {
        problem = nil
        do {
            preview = try await source.preview(entry.path)
        } catch {
            problem = ToolProblem(error, path: entry.path)
        }
    }

    private func download() {
        Task {
            downloading = 0
            defer { downloading = nil }
            do {
                let url = try await source.download(entry.path) { downloading = $0 }
                #if os(macOS)
                if let saved = FileDelivery.saveToDownloads(url) {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                    model.toasts.show(Toast("Saved to Downloads", systemImage: "checkmark.circle.fill", style: .success))
                }
                #else
                shared = SharedFile(url: url)
                #endif
            } catch {
                model.toasts.show(Toast("Couldn't download: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }
}

private struct TextPreview: View {
    let text: String
    let truncated: Bool
    @Environment(\.terminalTheme) private var theme

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 0) {
                LazyVStack(alignment: .trailing, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(verbatim: "\(index + 1)")
                            .font(DS.Font.literal.monospacedDigit())
                            .foregroundStyle(DS.Palette.textQuaternary)
                            .frame(height: 18)
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .frame(minWidth: CGFloat(max(3, String(lines.count).count)) * 9 + DS.Space.l, alignment: .trailing)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(verbatim: lines[index].isEmpty ? " " : String(lines[index]))
                            .font(DS.Font.literal)
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(height: 18, alignment: .leading)
                    }
                    if truncated {
                        Text("Showing the first MiB. Download the file or open it in VS Code for the rest.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, DS.Space.m)
                    }
                }
                .padding(.trailing, DS.Space.l)
                .textSelection(.enabled)
            }
            .padding(.vertical, DS.Space.s)
        }
        // A short file starts at the top left, not centred in the view.
        .defaultScrollAnchor(.topLeading)
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .background(theme.background)
        .accessibilityIdentifier("file-text-preview")
    }
}

private struct ImagePreview: View {
    let data: Data
    let name: String
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                unreadable
            }
            #else
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                unreadable
            }
            #endif
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .accessibilityLabel(name)
        .accessibilityIdentifier("file-image-preview")
    }

    private var unreadable: some View {
        EmptyState(name, systemImage: "photo", message: "This image could not be decoded here.") {}
    }
}

// MARK: - Delivery

enum FileDelivery {
    #if os(macOS)
    /// Moves a downloaded file into ~/Downloads (a free name), returning where it went.
    static func saveToDownloads(_ url: URL) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        var target = downloads.appending(path: url.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appending(path: LiveFileSource.numbered(url.lastPathComponent, number))
            number += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
    #endif
}

#if canImport(UIKit)
/// The system share sheet for a downloaded file (Save to Files, AirDrop, open in…).
struct ShareFileSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
struct ShareFileSheet: View {
    let url: URL
    var body: some View {
        ShareLink(item: url).padding()
    }
}
#endif

private struct GitLetter: View {
    let status: FileEntry.GitStatus
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(color)
            .frame(width: 14)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .added, .untracked: theme.ansi(2)
        case .deleted: theme.ansi(1)
        case .modified, .renamed: theme.ansi(3)
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

enum FilesPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
