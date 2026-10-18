import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Review an agent's changes: one scroll with every file, GitHub/Xcode review density. Code stays
/// opaque; color only marks added and removed lines.
struct DiffReviewView: View {
    let source: any DiffSource
    var onApprove: () -> Void = {}
    var onRequestChanges: () -> Void = {}

    @State private var files: [DiffFile]?
    @State private var failure: String?
    @State private var showsProgress = false
    @State private var collapsed: Set<String> = []

    var body: some View {
        content
            .navigationTitle("Changes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Request Changes", systemImage: "text.bubble", action: onRequestChanges)
                        .buttonStyle(.glass)
                    Button("Approve", systemImage: "checkmark", action: onApprove)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let files {
            if files.isEmpty {
                EmptyState("No Changes", systemImage: "checkmark.circle", message: "The working tree matches HEAD.") {}
            } else {
                review(files)
            }
        } else if let failure {
            EmptyState("Couldn't Load Changes", systemImage: "exclamationmark.triangle", message: failure) {
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

    private func review(_ files: [DiffFile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.m, pinnedViews: [.sectionHeaders]) {
                summary(files)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.top, DS.Space.s)
                ForEach(files) { file in
                    Section {
                        if !collapsed.contains(file.id) {
                            FileDiffBody(file: file)
                        }
                    } header: {
                        FileHeader(file: file, isCollapsed: collapsed.contains(file.id)) {
                            withAnimation(DS.Motion.snappy) {
                                if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, DS.Space.xxl)
        }
        .background(.background)
    }

    private func summary(_ files: [DiffFile]) -> some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(source.title)
                .font(DS.Font.title)
            HStack(spacing: DS.Space.xs) {
                Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("+\(additions)").foregroundStyle(DS.Palette.done)
                Text("−\(deletions)").foregroundStyle(DS.Palette.error)
            }
            .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        failure = nil
        do {
            files = try await source.files()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - File header

private struct FileHeader: View {
    let file: DiffFile
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
                StatusLetter(status: file.status)
                pathText
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: DS.Space.s)
                HStack(spacing: DS.Space.xs) {
                    Text("+\(file.additions)").foregroundStyle(DS.Palette.done)
                    Text("−\(file.deletions)").foregroundStyle(DS.Palette.error)
                }
                .font(DS.Font.meta)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { DiffPasteboard.copy(file.path) }
        }
        .accessibilityLabel("\(file.path), \(file.additions) additions, \(file.deletions) deletions")
        .accessibilityHint(isCollapsed ? "Expands the file" : "Collapses the file")
    }

    private var pathText: Text {
        let name = (file.path as NSString).lastPathComponent
        let directory = String(file.path.dropLast(name.count))
        return Text("\(Text(directory).foregroundStyle(.secondary))\(Text(name).foregroundStyle(.primary).fontWeight(.medium))")
            .font(DS.Font.literal)
    }
}

private struct StatusLetter: View {
    let status: FileEntry.GitStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.14), in: .rect(cornerRadius: DS.Radius.chip))
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

// MARK: - Lines

private struct FileDiffBody: View {
    let file: DiffFile

    private static let numberWidth: CGFloat = 36
    private static let lineHeight: CGFloat = 18

    var body: some View {
        // One horizontal scroll per file: long lines never wrap, numbers stay aligned.
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(file.hunks) { hunk in
                    Text(hunk.header)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, Self.numberWidth * 2 + DS.Space.l)
                        .padding(.trailing, DS.Space.l)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                    ForEach(hunk.lines) { line in
                        row(line)
                    }
                }
            }
            .frame(minWidth: 0, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .background(.background)
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Rectangle()
                .fill(markColor(line.kind))
                .frame(width: 2)
                .padding(.trailing, DS.Space.s)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(DS.Font.literal)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, DS.Space.l)
                .textSelection(.enabled)
        }
        .frame(height: Self.lineHeight)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(fill(line.kind))
        .contextMenu {
            Button("Copy Line", systemImage: "doc.on.doc") { DiffPasteboard.copy(line.text) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(line))
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(DS.Font.literalSmall.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: Self.numberWidth, alignment: .trailing)
            .padding(.trailing, DS.Space.xs)
    }

    private func markColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: DS.Palette.done
        case .removed: DS.Palette.error
        }
    }

    private func fill(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: DS.Palette.done.opacity(0.12)
        case .removed: DS.Palette.error.opacity(0.12)
        }
    }

    private func accessibility(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: "Line \(line.newNumber ?? 0): \(line.text)"
        case .added: "Added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "Removed line \(line.oldNumber ?? 0): \(line.text)"
        }
    }
}

private enum DiffPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
