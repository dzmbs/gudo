import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Browses a host's files. In a leaf and on the Mac it keeps its own back/forward history and
/// draws each place itself; in an iOS sheet it pushes onto the caller's NavigationStack.
struct FilesBrowserView: View {
    let source: any FileSource
    var onOpenInEditor: ((String) -> Void)?
    var onRevealInTerminal: (String) -> Void = { _ in }
    var onInsertPath: (String) -> Void = { _ in }

    @Environment(WindowModel.self) private var model
    @Environment(\.toolLeaf) private var leaf
    /// Where browsing starts instead of `source.root` (Go to Home from a folder that is gone).
    @State private var start: String?
    @State private var ownNavigator = FilesNavigator(root: "~")

    /// A push from a leaf lands in the window's navigation, not the leaf's, and Mac tools have no
    /// back gesture to keep: both draw each place here instead.
    private var navigatesInPlace: Bool {
        #if os(macOS)
        true
        #else
        leaf != nil
        #endif
    }

    var body: some View {
        Group {
            if let reason = source.unavailableReason {
                EmptyState("No Host", systemImage: "server.rack", message: reason) {
                    Button("Show Hosts") { model.showHosts() }
                        .buttonStyle(.glass)
                }
                .toolChrome("Files")
            } else if navigatesInPlace {
                InPlaceFiles(
                    source: source, actions: actions,
                    navigator: leaf.map { model.filesNavigator(for: $0.member.id, root: source.root) } ?? ownNavigator)
            } else {
                let root = start ?? source.root
                DirectoryListing(
                    source: source, directory: root, actions: actions,
                    goHome: root == "~" ? nil : { start = "~" })
                    .id(root)
            }
        }
        .onAppear {
            if let folder = model.filesStartFolder {
                start = folder
                model.filesStartFolder = nil
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
        FileActions(
            openInEditor: onOpenInEditor, revealInTerminal: onRevealInTerminal, insertPath: onInsertPath,
            openDrawing: DrawingDocuments.canCreate(in: model) ? { [model, leaf] path in
                if leaf == nil { model.sheet = nil }
                DrawingDocuments.open(path: path, window: model)
            } : nil)
    }
}

struct FileActions {
    var openInEditor: ((String) -> Void)?
    var revealInTerminal: (String) -> Void
    var insertPath: (String) -> Void
    /// Opens an `.excalidraw` file in a canvas.
    var openDrawing: ((String) -> Void)?
}

/// A pushed directory; wrapped so the destination does not claim every `String` in the stack.
private struct DirectoryRoute: Hashable {
    var path: String
}

private struct FileRoute: Hashable {
    var entry: FileEntry
}

/// Finder's path bar: every folder from the top down to the one shown, each a click away.
private struct PathBar: View {
    let trail: [String]
    /// The file previewed in the last folder.
    let file: String?
    let go: (String) -> Void
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Space.xs) {
                ForEach(Array(trail.enumerated()), id: \.element) { index, folder in
                    if index > 0 { separator }
                    Button { go(folder) } label: {
                        Label(InPlaceFiles.name(folder), systemImage: InPlaceFiles.symbol(folder))
                            .fontWeight(index == trail.count - 1 && file == nil ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("path-\(InPlaceFiles.name(folder))")
                }
                if let file {
                    separator
                    Label(file, systemImage: "doc").fontWeight(.semibold)
                }
            }
            .labelStyle(PathLabelStyle())
            .font(DS.Font.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.s)
        }
        .scrollIndicators(.hidden)
        // The deepest folders stay in view; the top scrolls away first.
        .defaultScrollAnchor(.trailing)
        .frame(height: 24)
        .background(theme.background)
        .overlay(alignment: .top) { theme.splitDivider.frame(height: 1) }
        .accessibilityIdentifier("files-path")
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

private struct PathLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Browsing drawn in place: the place on screen, Finder's back and forward, and the folders
/// enclosing it (the bar's title menu, ⌘↑).
private struct InPlaceFiles: View {
    let source: any FileSource
    let actions: FileActions
    let navigator: FilesNavigator

    var body: some View {
        Group {
            switch navigator.place {
            case .folder(let path):
                DirectoryListing(
                    source: source, directory: path, actions: actions,
                    goHome: navigator.canGoBack || path == "~" ? nil : { navigator.reset(to: "~") },
                    navigator: navigator)
            case .file(let entry):
                FilePreviewScreen(source: source, entry: entry, actions: actions)
            }
        }
        .id(navigator.place)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PathBar(trail: navigator.trail, file: { if case .file(let entry) = navigator.place { entry.name } else { nil } }()) {
                navigator.go(to: $0)
            }
        }
        .environment(\.toolNavigation, navigation)
        .onChange(of: source.root, initial: true) { _, root in
            // Until something is opened, the start follows the focused pane's folder.
            if navigator.isAtStart, navigator.place != .folder(root) { navigator.reset(to: root) }
        }
    }

    private var navigation: ToolNavigation {
        let trail = navigator.trail
        let enclosing = navigator.place == .folder(navigator.folder) ? trail.dropLast() : trail[...]
        return ToolNavigation(
            back: navigator.canGoBack ? { navigator.goBack() } : nil,
            forward: navigator.canGoForward ? { navigator.goForward() } : nil,
            enclosing: enclosing.reversed().map { folder in
                ToolNavigation.Stop(id: folder, title: Self.name(folder), systemImage: Self.symbol(folder)) {
                    navigator.go(to: folder)
                }
            },
            location: "\(source.display(navigator.place.path)) · \(source.hostName)")
    }

    static func name(_ folder: String) -> String {
        switch folder {
        case "~": "Home"
        case "/": "/"
        default: (folder as NSString).lastPathComponent
        }
    }

    static func symbol(_ folder: String) -> String {
        switch folder {
        case "~": "house"
        case "/": "internaldrive"
        default: "folder"
        }
    }
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
    /// Browsing in place: rows open through it, and folders expand beneath their row.
    var navigator: FilesNavigator?

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
    @State private var draftName = ""
    @State private var trashing: FileEntry?
    @State private var transfer: Transfer?
    @State private var shared: SharedFile?
    /// `-screen file-preview`: Cargo.toml opened once the root is listed.
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

    private struct Row: Identifiable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.path }
    }

    private static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The folder's entries, each expanded folder's beneath it (Finder's list view); a filter
    /// matches the folder's own entries.
    private var rows: [Row] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            return Self.sorted(entries ?? []).filter { $0.name.localizedCaseInsensitiveContains(query) }.map { Row(entry: $0, depth: 0) }
        }
        func tree(_ entries: [FileEntry], depth: Int) -> [Row] {
            Self.sorted(entries).flatMap { entry in
                var rows = [Row(entry: entry, depth: depth)]
                if entry.isDirectory, let navigator, navigator.expanded.contains(entry.path) {
                    rows += tree(navigator.listings[entry.path] ?? [], depth: depth + 1)
                }
                return rows
            }
        }
        return tree(entries ?? [], depth: 0)
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
                        draftName = ""
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
                TextField(namingPlaceholder, text: $draftName)
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
                guard let cargo = entries?.first(where: { $0.name == "Cargo.toml" }) else { return }
                if let navigator { navigator.open(.file(cargo)) } else { fixtureFile = cargo }
            }
    }

    private var title: String {
        directory == source.root ? (directory as NSString).lastPathComponent.nonEmpty ?? "Files" : (directory as NSString).lastPathComponent
    }

    @ViewBuilder private var content: some View {
        if entries != nil {
            List {
                ForEach(rows) { row in
                    self.row(row.entry, depth: row.depth)
                        .listRowBackground(theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .refreshable { await load() }
            .overlay {
                if rows.isEmpty {
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

    @ViewBuilder private func row(_ entry: FileEntry, depth: Int) -> some View {
        Group {
            if let navigator {
                HStack(spacing: DS.Space.xs) {
                    disclosure(entry, navigator: navigator)
                    Button {
                        navigator.open(entry.isDirectory ? .folder(entry.path) : .file(entry))
                    } label: {
                        label(entry)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, CGFloat(depth) * Self.indent)
            } else if entry.isDirectory {
                NavigationLink(value: DirectoryRoute(path: entry.path)) { label(entry) }
            } else {
                NavigationLink(value: FileRoute(entry: entry)) { label(entry) }
            }
        }
        // Nested rows by path: names repeat across folders.
        .accessibilityIdentifier(depth == 0 ? "file-\(entry.name)" : "file-\(entry.path)")
        .contextMenu {
            if !entry.isDirectory, DrawingFile.isDrawing(entry.name), let open = actions.openDrawing {
                Button("Open Drawing", systemImage: "scribble.variable") { open(entry.path) }
            }
            if !entry.isDirectory, let open = actions.openInEditor {
                Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { open(entry.path) }
            }
            if !entry.isDirectory {
                Button(downloadTitle, systemImage: "square.and.arrow.down") { download(entry) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { FilesPasteboard.copy(entry.path) }
            Divider()
            Button("Rename…", systemImage: "pencil") {
                draftName = entry.name
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
            // Red, not `.destructive`: that role drops the row before the user confirms, and the
            // list then deletes it twice (a UICollectionView exception).
            Button("Trash", systemImage: "trash") { trashing = entry }
                .tint(.red)
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

    private static let indent: CGFloat = 16

    /// The disclosure triangle: a folder's entries beneath its row. Files keep its width so
    /// names line up.
    @ViewBuilder private func disclosure(_ entry: FileEntry, navigator: FilesNavigator) -> some View {
        if entry.isDirectory {
            let isExpanded = navigator.expanded.contains(entry.path)
            Button(isExpanded ? "Collapse" : "Expand", systemImage: "chevron.right") { toggle(entry, navigator: navigator) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Self.indent, height: Self.indent)
                .contentShape(.rect)
                .accessibilityIdentifier("disclose-\(entry.name)")
        } else {
            Color.clear.frame(width: Self.indent, height: Self.indent)
        }
    }

    private func toggle(_ entry: FileEntry, navigator: FilesNavigator) {
        withAnimation(DS.Motion.snappy) {
            if navigator.expanded.remove(entry.path) == nil { navigator.expanded.insert(entry.path) }
        }
        if navigator.expanded.contains(entry.path), navigator.listings[entry.path] == nil {
            Task { await loadChildren(entry.path) }
        }
    }

    private func loadChildren(_ path: String) async {
        guard let navigator else { return }
        do {
            let loaded = try await source.list(path)
            withAnimation(DS.Motion.snappy) { navigator.listings[path] = loaded }
        } catch {
            navigator.expanded.remove(path)
            model.toasts.show(Toast("Couldn't read \((path as NSString).lastPathComponent): \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
        }
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
        var trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
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
            for path in navigator?.expanded ?? [] where path.hasPrefix(directory + "/") {
                await loadChildren(path)
            }
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

/// A file's preview: text with line numbers, an image, or a card with its size.
struct FilePreviewScreen: View {
    let source: any FileSource
    let entry: FileEntry
    let actions: FileActions

    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var preview: FilePreview?
    @State private var lineCount = 0
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
        if DrawingFile.isDrawing(entry.name), let open = actions.openDrawing {
            Button("Open Drawing", systemImage: "scribble.variable") { open(entry.path) }
                .help("Open Drawing")
                .accessibilityIdentifier("file-open-drawing")
        }
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
        if case .text(_, let truncated)? = preview {
            parts.append(truncated ? "first MiB" : "\(lineCount) line\(lineCount == 1 ? "" : "s")")
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
            let loaded = try await source.preview(entry.path)
            if case .text(let text, _) = loaded {
                lineCount = await Task.detached(priority: .userInitiated) { Self.lineCount(text) }.value
            }
            preview = loaded
        } catch {
            problem = ToolProblem(error, path: entry.path)
        }
    }

    nonisolated private static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(into: 1) { count, byte in if byte == UInt8(ascii: "\n") { count += 1 } }
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
    var body: some View {
        NativeTextPreview(text: text, truncated: truncated)
            .accessibilityIdentifier("file-text-preview")
    }
}

private struct ImagePreview: View {
    let data: Data
    let name: String
    @Environment(\.terminalTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var shownPixels = 0
    @State private var decoded: Decoded?

    nonisolated private enum Decoded: Sendable {
        case image(CGImage)
        case failure(ImageThumbnail.Failure)
    }

    /// Decoding again only when the view outgrows the last decode by a step, not at every
    /// point of a live resize.
    private static let pixelStep = 512

    var body: some View {
        Group {
            switch decoded {
            case .image(let image):
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            case .failure(.tooLarge(let width, let height)):
                EmptyState(name, systemImage: "photo", message: "\(width) × \(height) pixels is too large to preview here.") {}
            case .failure(.unreadable):
                EmptyState(name, systemImage: "photo", message: "This image could not be decoded here.") {}
            case nil:
                Color.clear
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(proxy.size.width, proxy.size.height)
        } action: { longestSide in
            let pixels = (Int((longestSide * displayScale).rounded(.up)) / Self.pixelStep + 1) * Self.pixelStep
            shownPixels = max(shownPixels, pixels)
        }
        .task(id: shownPixels) {
            guard shownPixels > 0 else { return }
            let data = data, pixels = shownPixels
            let result = await Task.detached(priority: .userInitiated) { () -> Decoded in
                do throws(ImageThumbnail.Failure) {
                    return .image(try ImageThumbnail.decode(data, maximumPixelSize: pixels))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            decoded = result
        }
        .background(theme.background)
        .accessibilityLabel(name)
        .accessibilityIdentifier("file-image-preview")
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
