import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A file open in the editor container: a quiet header, a line-number gutter beside SF Mono text,
/// and an Xcode-style status bar.
struct EditorView: View {
    let source: any FileSource
    let path: String
    var onSave: (String) -> Void = { _ in }
    var onRevealInFiles: () -> Void = {}
    var onOpenInTerminal: () -> Void = {}

    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var failure: String?

    private var isDirty: Bool { loaded && text != saved }
    private var name: String { (path as NSString).lastPathComponent }
    private var directory: String { (path as NSString).deletingLastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .background(.background)
        .task(id: path) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: FileIcon.symbol(forPath: path))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text(directory)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Edited")
                    .help("Edited")
                    .transition(.opacity)
            }
            Spacer(minLength: DS.Space.s)
            Button("Save", systemImage: "square.and.arrow.down", action: save)
                .keyboardShortcut("s")
                .disabled(!isDirty)
                .buttonStyle(.bar)
                .help("Save (⌘S)")
            Menu("More", systemImage: "ellipsis") {
                Button("Reveal in Files", systemImage: "folder", action: onRevealInFiles)
                Button("Copy Path", systemImage: "doc.on.doc") { EditorPasteboard.copy(path) }
                Button("Open in Terminal", systemImage: "terminal", action: onOpenInTerminal)
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .buttonStyle(.bar)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Size.tabBar)
        .animation(DS.Motion.overlay, value: isDirty)
    }

    // MARK: Text

    @ViewBuilder private var content: some View {
        if let failure {
            EmptyState("Couldn't Open \(name)", systemImage: "exclamationmark.triangle", message: failure) {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glass)
            }
        } else {
            ScrollView([.vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    gutter
                    TextEditor(text: $text)
                        .font(DS.Font.literal)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                        .accessibilityLabel(name)
                        .accessibilityIdentifier("editor-text")
                }
            }
            .opacity(loaded ? 1 : 0)
        }
    }

    private var gutter: some View {
        let count = max(1, text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } })
        let digits = max(3, String(count).count)
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(1...count, id: \.self) { number in
                Text(verbatim: "\(number)")
                    .font(DS.Font.literal.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.top, gutterTopInset)
        .padding(.horizontal, DS.Space.s)
        .frame(minWidth: CGFloat(digits) * 9 + DS.Space.l, alignment: .trailing)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
        .accessibilityHidden(true)
    }

    /// TextEditor's own top text inset, so numbers line up with their lines.
    private var gutterTopInset: CGFloat {
        #if os(iOS)
        8
        #else
        0
        #endif
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: DS.Space.xs) {
            Text("Ln 1, Col 1")
            Text("·").foregroundStyle(.tertiary)
            Text("UTF-8")
            Text("·").foregroundStyle(.tertiary)
            Text("LF")
            Text("·").foregroundStyle(.tertiary)
            Text(language)
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.m)
        .frame(height: 22)
        .background(.bar)
    }

    private var language: String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "Swift"
        case "rs": "Rust"
        case "toml": "TOML"
        case "json": "JSON"
        case "md": "Markdown"
        case "yml", "yaml": "YAML"
        case "ts", "tsx": "TypeScript"
        case "js": "JavaScript"
        case "py": "Python"
        case "go": "Go"
        case "zig": "Zig"
        case "sh", "zsh", "bash": "Shell"
        case "lock": "Lockfile"
        default: "Plain Text"
        }
    }

    // MARK: Actions

    private func load() async {
        failure = nil
        do {
            let contents = try await source.read(path)
            text = contents
            saved = contents
            loaded = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func save() {
        guard isDirty else { return }
        onSave(text)
        saved = text
    }
}

private enum EditorPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
