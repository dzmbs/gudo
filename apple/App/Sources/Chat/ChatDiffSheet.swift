#if os(iOS)
import DesignSystem
import SwiftUI

struct ChatDiffSheet: View {
    let groups: [ChatToolDiff]
    let openTerminal: () -> Void
    @State private var snapshot: ChatDiffSnapshot?
    @State private var error: String?
    @State private var document: DiffRenderDocument?
    @State private var collapsed: Set<String> = []
    @State private var layout = DiffLayout.automatic
    @State private var width: CGFloat = 800
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.terminalTheme) private var theme
    @Environment(\.chrome) private var chrome
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var summaryHeight: CGFloat = 88
    @ScaledMetric(relativeTo: .body) private var fileHeaderHeight: CGFloat = 44

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot, !snapshot.files.isEmpty { review(snapshot) }
                else if let error { note(error) }
                else if snapshot != nil {
                    note("No changes for this selection are available in Chat. Open Terminal to inspect them.")
                } else { note("Loading diff…") }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(theme.background)
            .navigationTitle("Chat Changes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Terminal", systemImage: "terminal", action: openTerminal)
                        .frame(minHeight: DS.Size.touchTarget)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Layout", systemImage: "rectangle.split.2x1") {
                        Picker("Layout", selection: $layout) {
                            Text("Automatic").tag(DiffLayout.automatic)
                            Text("Unified").tag(DiffLayout.unified)
                            Text("Side by Side").tag(DiffLayout.split)
                        }
                    }.frame(minHeight: DS.Size.touchTarget)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.frame(minHeight: DS.Size.touchTarget)
                }
            }
        }
        .task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) { [groups] in
                    try ChatDiffSnapshot(groups: groups)
                }.value
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? ChatDiffError)?.errorDescription
                    ?? "This diff could not load. Open Terminal to read it."
            }
        }
    }

    private var split: Bool {
        switch layout {
        case .automatic: sizeClass == .regular && width >= 720
        case .unified: false
        case .split: true
        }
    }

    private func review(_ snapshot: ChatDiffSnapshot) -> some View {
        let input = DiffRenderInput(files: snapshot.files, collapsed: collapsed, split: split, notes: [],
            width: width, lineHeight: ceil(lineHeight), characterWidth: lineHeight * 0.45, textSize: lineHeight * 0.7,
            summaryHeight: ceil(summaryHeight), fileHeaderHeight: ceil(fileHeaderHeight),
            hunkHeaderHeight: max(24, ceil(lineHeight)))
        return Group {
            if let document {
                NativeDiffList(document: document) { row in
                    render(row, document: document)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .environment(\.terminalTheme, theme).environment(\.chrome, chrome)
                        .environment(\.dynamicTypeSize, dynamicType).environment(\.colorScheme, colorScheme)
                }
            } else { note("Preparing diff…") }
        }
        .task(id: input) {
            let document = await Task.detached(priority: .userInitiated) { DiffRenderDocument(input: input) }.value
            guard !Task.isCancelled else { return }
            self.document = document
        }
        .accessibilityIdentifier("chat-diff-preview")
    }

    @ViewBuilder private func render(_ row: DiffRenderRow, document: DiffRenderDocument) -> some View {
        switch row.content {
        case .summary:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Chat diff preview").font(DS.Font.title).foregroundStyle(DS.Palette.text)
                Text("Open Terminal for the complete diff.").font(DS.Font.proseSecondary)
                    .foregroundStyle(DS.Palette.textSecondary)
            }.padding(DS.Space.l)
        case .file:
            if let index = row.fileIndex {
                let file = document.input.files[index]
                DiffFileHeader(file: file, isCollapsed: collapsed.contains(file.id), noteCount: 0) {
                    if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
                }
            }
        case .hunk(let header):
            Text(verbatim: header).font(DS.Font.literalSmall).foregroundStyle(DS.Palette.textTertiary)
                .lineLimit(1).padding(.horizontal, DS.Space.l)
        case .line(let left, let right):
            if let index = row.fileIndex {
                DiffLineContent(file: document.input.files[index], left: left, right: right,
                    split: document.input.split, lineHeight: document.input.lineHeight,
                    columnWidth: (document.input.width - 1) / 2)
            }
        case .notice(let message):
            Text(verbatim: message).font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.l)
        case .note, .composer: EmptyView()
        }
    }

    private func note(_ message: String) -> some View {
        Text(verbatim: message).font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(DS.Space.l)
    }
}
#endif
