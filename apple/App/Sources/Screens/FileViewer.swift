import DesignSystem
import GudoCore
import HostKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Reads a file for the viewer: through a host's daemon, or from this device's disk.
@MainActor
protocol FileReading {
    func stat(_ path: String) async throws -> FileFacts
    func read(_ path: String, offset: UInt64, length: UInt32) async throws -> FileBytes
    /// The repository holding `folder`, nil outside one.
    func repositoryRoot(of folder: String) async -> String?
}

extension FileReading {
    func repositoryRoot(of folder: String) async -> String? { nil }
}

struct FileFacts: Equatable {
    var isDirectory: Bool
    var size: UInt64
    /// The path as the host spells it (`~` expanded), when it says.
    var path: String?
}

struct FileBytes: Equatable {
    var data: Data
    var isEnd: Bool
}

struct DaemonFileReader: FileReading {
    let api: () throws -> any DaemonWorkspaceAPI

    func stat(_ path: String) async throws -> FileFacts {
        let stat = try await api().fsStat(path: path)
        return FileFacts(isDirectory: stat.kind == .dir || stat.targetKind == .dir, size: stat.size, path: stat.path)
    }

    func read(_ path: String, offset: UInt64, length: UInt32) async throws -> FileBytes {
        let chunk = try await api().fsRead(path: path, offset: offset, len: length)
        return FileBytes(data: chunk.data, isEnd: chunk.eof)
    }

    func repositoryRoot(of folder: String) async -> String? {
        guard let api = try? api() else { return nil }
        return await api.repositoryRoot(of: folder)
    }
}

struct LocalFileReader: FileReading {
    func stat(_ path: String) async throws -> FileFacts {
        let expanded = (path as NSString).expandingTildeInPath
        let attributes = try FileManager.default.attributesOfItem(atPath: expanded)
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        return FileFacts(isDirectory: isDirectory, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, path: expanded)
    }

    func repositoryRoot(of folder: String) async -> String? {
        await Task.detached(priority: .userInitiated) { RepositoryPath.localRoot(of: folder) }.value
    }

    func read(_ path: String, offset: UInt64, length: UInt32) async throws -> FileBytes {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        return FileBytes(data: data, isEnd: data.count < Int(length))
    }
}

/// A run of a file's lines: all of it, or the part around the line asked for.
struct FileWindow: Equatable {
    var lines: [String]
    var firstLine: Int
    var hasEarlier: Bool
    var hasLater: Bool

    var lastLine: Int { firstLine + lines.count - 1 }
}

enum FileViewerContent: Equatable {
    case loading
    case text(FileWindow)
    case binary(size: UInt64)
    case directory
    case missing
    case failed(ToolProblem)
}

@MainActor
@Observable
final class FileViewerModel {
    let target: FileTarget
    private let reader: any FileReading
    private(set) var content = FileViewerContent.loading
    private(set) var resolvedPath: String?
    private(set) var repositoryRoot: String?

    static let chunkSize: UInt32 = 1 << 20
    /// Chunks read, at most, looking for a line.
    static let searchLimit = 64

    init(target: FileTarget, reader: any FileReading) {
        self.target = target
        self.reader = reader
    }

    func load() async {
        do {
            let facts = try await reader.stat(target.path)
            resolvedPath = facts.path
            if facts.isDirectory {
                content = .directory
                return
            }
            content = try await window(size: facts.size)
            repositoryRoot = await reader.repositoryRoot(of: ((facts.path ?? target.path) as NSString).deletingLastPathComponent)
        } catch let error as WorkspaceError {
            if case .NotFound = error { content = .missing } else { content = .failed(ToolProblem(error, path: target.path)) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            content = .missing
        } catch {
            content = .failed(ToolProblem(error, path: target.path))
        }
    }

    /// What the menu copies. The contents only when the whole file is shown.
    var copyActions: [FileCopyAction] {
        var contents: String?
        if case .text(let window) = content, !window.hasEarlier, !window.hasLater {
            contents = window.lines.joined(separator: "\n")
        }
        return FileCopyAction.actions(
            path: target.path, resolvedPath: resolvedPath, line: target.line, column: target.column,
            contents: contents, repositoryRoot: repositoryRoot)
    }

    private func window(size: UInt64) async throws -> FileViewerContent {
        var offset: UInt64 = 0
        var lineAtOffset = 1
        for round in 0..<Self.searchLimit {
            let bytes = try await reader.read(target.path, offset: offset, length: Self.chunkSize)
            if round == 0, bytes.data.prefix(8192).contains(0) { return .binary(size: size) }
            let lastNewline = bytes.data.lastIndex(of: UInt8(ascii: "\n"))
            let cut = bytes.isEnd ? bytes.data.endIndex : (lastNewline.map { $0 + 1 } ?? bytes.data.endIndex)
            let text = String(decoding: bytes.data[..<cut], as: UTF8.self)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "", lines.count > 1 { lines.removeLast() }
            let reachesTarget = target.line.map { $0 < lineAtOffset + lines.count } ?? true
            let isLast = bytes.isEnd || bytes.data.isEmpty || round == Self.searchLimit - 1
            if reachesTarget || isLast {
                return .text(FileWindow(
                    lines: lines, firstLine: lineAtOffset, hasEarlier: offset > 0, hasLater: !bytes.isEnd || cut < bytes.data.endIndex))
            }
            offset += UInt64(cut)
            lineAtOffset += lines.count
        }
        return .text(FileWindow(lines: [], firstLine: lineAtOffset, hasEarlier: true, hasLater: true))
    }
}

enum FileViewerMode: String, CaseIterable, Identifiable {
    case raw, rendered
    var id: String { rawValue }
    var title: String { self == .raw ? "Raw" : "Rendered" }
    static let markdownKey = "fileViewerMarkdownMode"
}

extension WindowModel {
    enum ViewerFind {
        case open, next, previous
    }

    /// Find, Find Next and Find Previous in a focused file viewer search its text with the text
    /// view's own find bar, not the terminal's scrollback. Whether a viewer took it.
    func findInFocusedViewer(_ find: ViewerFind) -> Bool {
        #if os(macOS)
        guard let member = focusedToolLeaf, member.tool == .viewer, let textView = LeafTextViews.textView(for: member.id),
              let window = textView.window else { return false }
        window.makeFirstResponder(textView)
        let action: NSTextFinder.Action = switch find {
        case .open: .showFindInterface
        case .next: .nextMatch
        case .previous: .previousMatch
        }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
        return true
        #else
        return false
        #endif
    }

    func fileReader(for target: FileTarget) -> any FileReading {
        if LaunchOptions.mock, !hasLiveTools { return MockFileReader() }
        guard let hostId = target.hostId else { return LocalFileReader() }
        let app = app
        return DaemonFileReader {
            guard let context = HostContext.host(hostId, app: app) else { throw HostError.notConnected }
            return try context.api()
        }
    }
}

/// A file's text with line numbers and the asked-for line marked, or its Markdown rendered.
struct FileViewerScreen: View {
    let target: FileTarget
    @Environment(WindowModel.self) private var window
    @State private var model: FileViewerModel?

    var body: some View {
        Group {
            if let model, model.target == target {
                FileViewerBody(model: model)
            } else {
                Color.clear
            }
        }
        .task(id: target) {
            let made = FileViewerModel(target: target, reader: window.fileReader(for: target))
            model = made
            await made.load()
        }
    }
}

private struct FileViewerBody: View {
    let model: FileViewerModel
    @Environment(WindowModel.self) private var window
    @Environment(\.terminalTheme) private var theme
    @AppStorage(FileViewerMode.markdownKey) private var markdownMode = FileViewerMode.rendered

    private var target: FileTarget { model.target }
    private var mode: FileViewerMode { target.isMarkdown ? markdownMode : .raw }

    var body: some View {
        content
            .chromeContent()
            .background(theme.background.ignoresSafeArea())
            .toolChrome(target.name, subtitle: subtitle) { actions }
            .accessibilityIdentifier("file-viewer")
    }

    private var subtitle: String {
        var parts = [target.folder]
        if let line = target.line { parts.append("line \(line)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .loading:
            Color.clear
        case .text(let window):
            if mode == .rendered {
                MarkdownDocumentView(source: window.lines.joined(separator: "\n"))
            } else {
                FileLinesView(window: window, target: target)
            }
        case .binary(let size):
            EmptyState(
                target.name, systemImage: "doc",
                message: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · no preview for this kind of file."
            ) {
                Button("Open in VS Code") { window.openFileInVSCode(target) }
                    .buttonStyle(.glass)
            }
        case .directory:
            EmptyState(target.name, systemImage: "folder", message: "This is a folder.") {
                Button("Show in Files") { window.revealInFiles(target.path, hostId: target.hostId) }
                    .buttonStyle(.glass)
            }
        case .missing:
            EmptyState(
                "No Such File", systemImage: "questionmark.folder",
                message: "\(target.name) isn't there. It may have moved, or the path was printed from another folder.",
                detail: target.path
            ) {
                Button("Show Folder in Files") { window.revealInFiles(target.folder, hostId: target.hostId) }
                    .buttonStyle(.glass)
            }
        case .failed(let problem):
            EmptyState(
                problem.title ?? "Couldn't Open \(target.name)", systemImage: problem.systemImage, message: problem.message,
                detail: problem.detail
            ) {
                if problem.canRetry {
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var offersModes: Bool {
        guard target.isMarkdown, case .text = model.content else { return false }
        return true
    }

    private var modePicker: some View {
        Picker("View", selection: $markdownMode) {
            ForEach(FileViewerMode.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("file-viewer-mode")
    }

    @ViewBuilder private var actions: some View {
        #if os(macOS)
        if offersModes {
            modePicker
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
        }
        #endif
        Menu("More", systemImage: "ellipsis") {
            #if os(iOS)
            if offersModes {
                modePicker.pickerStyle(.inline)
                Divider()
            }
            #endif
            ForEach(model.copyActions) { action in
                Button(action.title, systemImage: action.systemImage) { FileViewerPasteboard.copy(action.text) }
            }
            Divider()
            Button("Show in Files", systemImage: "folder") { window.revealInFiles(target.folder, hostId: target.hostId) }
            Button("Insert in Terminal", systemImage: "text.insert") { window.insertInTerminal(target.path) }
            Divider()
            Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { window.openFileInVSCode(target) }
            #if os(macOS)
            if target.hostId == nil {
                Button("Open in Default App", systemImage: "arrow.up.forward.app") { window.openFileInDefaultApp(target) }
            }
            #endif
        }
        .menuIndicator(.hidden)
        .help("More")
        .accessibilityIdentifier("file-viewer-more")
    }
}

/// The file's lines with their numbers, the asked-for line marked and scrolled to.
struct FileLinesView: View {
    let window: FileWindow
    let target: FileTarget
    @Environment(\.terminalTheme) private var theme
    @Environment(\.toolLeaf) private var leaf

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if window.hasEarlier { notice("Earlier lines aren't shown.") }
            CodeTextView(window.lines.joined(separator: "\n"), firstLine: window.firstLine, markedLine: target.line, leaf: leaf?.member.id)
            if window.hasLater { notice("Showing part of the file. Open it in VS Code for the rest.") }
        }
        .background(theme.background)
        .accessibilityIdentifier("file-viewer-lines")
    }

    private func notice(_ words: String) -> some View {
        Text(words)
            .font(DS.Font.rowSubtitle)
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.vertical, DS.Space.m)
            .padding(.leading, DS.Space.l)
    }
}

/// iPhone and compact iPad: the viewer as a sheet.
struct FileViewerSheet: View {
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let target = window.fileViewerTarget {
                    FileViewerScreen(target: target)
                } else {
                    Color.clear
                }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .macMinimumSize(width: 640, height: 520)
        .presentationSizing(.page)
    }
}

enum FileViewerPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

/// Screenshots and UI tests (`-mock`): a Markdown file and a source file.
struct MockFileReader: FileReading {
    static let files: [String: String] = [
        "~/projects/gudo/README.md": """
        # Gudo

        A terminal and coding-agent manager for **iPhone**, **iPad** and **Mac**.

        ## Install

        1. Pair a host.
        2. Open a terminal.

        ```
        gudo-hostd pair
        ```

        > Sessions live on the host.
        """,
        "~/projects/gudo/src/main.rs": (1...40).map { "    let value_\($0) = compute(\($0));" }.joined(separator: "\n"),
    ]

    func stat(_ path: String) async throws -> FileFacts {
        guard let text = Self.files[path] else { throw WorkspaceError.NotFound(message: path) }
        return FileFacts(isDirectory: false, size: UInt64(text.utf8.count), path: path)
    }

    func repositoryRoot(of folder: String) async -> String? {
        PathMatch.isInside(folder, Self.repositoryRoot) ? Self.repositoryRoot : nil
    }

    static let repositoryRoot = "~/projects/gudo"

    func read(_ path: String, offset: UInt64, length: UInt32) async throws -> FileBytes {
        guard let text = Self.files[path] else { throw WorkspaceError.NotFound(message: path) }
        let bytes = Data(text.utf8).dropFirst(Int(offset)).prefix(Int(length))
        return FileBytes(data: Data(bytes), isEnd: Int(offset) + bytes.count >= text.utf8.count)
    }
}
