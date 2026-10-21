import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Review changes: uncommitted, staged, or exactly what one agent turn changed. One scroll with
/// every file, terminal-quiet: monospace on the terminal's background, no syntax colours, the
/// palette's green and red only for added and removed lines. Side by side where there is room
/// (iPad, Mac), unified on iPhone. Tap a line to leave a note; the notes go to the agent as one
/// numbered review prompt.
struct DiffReviewView: View {
    let source: any DiffSource
    var onSent: () -> Void = {}

    @Environment(\.terminalTheme) private var theme
    @Environment(WindowModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @AppStorage("diffLayout") private var layoutPreference = DiffLayout.automatic

    @State private var repository: DiffRepository?
    @State private var scope = DiffScope.workingTree
    @State private var turns: [DiffTurn] = []
    @State private var files: [DiffFile]?
    @State private var failure: String?
    @State private var showsProgress = false
    @State private var collapsed: Set<String> = []
    @State private var notes: [ReviewNote] = []
    @State private var composing: NoteAnchor?
    @State private var isSending = false

    var body: some View {
        content
            .chromeContent()
            .navigationTitle(repository.map { ($0.root as NSString).lastPathComponent } ?? source.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationSubtitle(repository?.branch ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    scopeMenu
                    Menu("Layout", systemImage: isSplit ? "rectangle.split.2x1" : "rectangle") {
                        Picker("Layout", selection: $layoutPreference) {
                            Text("Automatic").tag(DiffLayout.automatic)
                            Text("Unified").tag(DiffLayout.unified)
                            Text("Side by Side").tag(DiffLayout.split)
                        }
                    }
                    .help("Layout: automatic, unified or side by side")
                    .menuIndicator(.hidden)
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                        .help("Reload (⌘R)")
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
            .background(theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { reviewBar }
            .task { await load() }
            .onChange(of: scope) { Task { await loadFiles() } }
    }

    private var isSplit: Bool {
        switch layoutPreference {
        case .unified: return false
        case .split: return true
        case .automatic:
            #if os(iOS)
            return sizeClass == .regular
            #else
            return true
            #endif
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let reason = source.unavailableReason {
            EmptyState("No Host", systemImage: "server.rack", message: reason) {}
        } else if let files {
            if files.isEmpty {
                EmptyState("No Changes", systemImage: "checkmark.circle", message: emptyMessage) {}
            } else {
                review(files)
            }
        } else if let failure {
            EmptyState("Couldn't Load Changes", systemImage: "exclamationmark.triangle", message: failure) {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glass)
            }
        } else {
            VStack(spacing: DS.Space.s) {
                Spinner()
                    .frame(width: 16, height: 16)
                Text("Reading the repository…")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .opacity(showsProgress ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: DS.Motion.feedbackDelay)
                showsProgress = true
            }
        }
    }

    private var emptyMessage: String {
        switch scope {
        case .workingTree: "The working tree matches HEAD."
        case .staged: "Nothing is staged."
        case .turn: "This turn changed no files."
        }
    }

    private func review(_ files: [DiffFile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                summary(files)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.m)
                ForEach(files) { file in
                    Section {
                        if !collapsed.contains(file.id) {
                            FileDiffBody(
                                file: file, split: isSplit, notes: notes.filter { $0.path == file.path },
                                composing: composing?.path == file.path ? composing : nil,
                                onTapLine: { line, oldSide in beginNote(file, line, oldSide: oldSide) },
                                onSaveNote: saveNote, onCancelNote: { withAnimation(DS.Motion.snappy) { composing = nil } },
                                onDeleteNote: { note in withAnimation(DS.Motion.snappy) { notes.removeAll { $0.id == note.id } } })
                        }
                    } header: {
                        FileHeader(file: file, isCollapsed: collapsed.contains(file.id), noteCount: notes.filter { $0.path == file.path }.count) {
                            withAnimation(DS.Motion.snappy) {
                                if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, DS.Space.xxl)
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .accessibilityIdentifier("diff-review")
    }

    private func summary(_ files: [DiffFile]) -> some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(scopeTitle)
                .font(DS.Font.title)
                .foregroundStyle(theme.foreground)
            HStack(spacing: DS.Space.xs) {
                Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                    .foregroundStyle(DS.Palette.textSecondary)
                Text("·").foregroundStyle(DS.Palette.textTertiary)
                Text("+\(additions)").foregroundStyle(theme.ansi(2))
                Text("−\(deletions)").foregroundStyle(theme.ansi(1))
                if let repository, repository.ahead + repository.behind > 0 {
                    Text("·").foregroundStyle(DS.Palette.textTertiary)
                    Text(aheadBehind(repository)).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diff-summary")
    }

    private func aheadBehind(_ repository: DiffRepository) -> String {
        var parts: [String] = []
        if repository.ahead > 0 { parts.append("↑\(repository.ahead)") }
        if repository.behind > 0 { parts.append("↓\(repository.behind)") }
        return parts.joined(separator: " ")
    }

    private var scopeTitle: String {
        switch scope {
        case .workingTree: return "Uncommitted changes"
        case .staged: return "Staged changes"
        case .turn(let pane, let turn):
            guard let match = turns.first(where: { $0.pane == pane && $0.turn == turn }) else { return "Agent turn" }
            return "What \(match.agent) changed · turn \(match.turn)"
        }
    }

    // MARK: Scope

    private var scopeMenu: some View {
        Menu {
            Picker("Compare", selection: $scope) {
                Label("Uncommitted", systemImage: "pencil").tag(DiffScope.workingTree)
                Label("Staged", systemImage: "tray.full").tag(DiffScope.staged)
            }
            if !turns.isEmpty {
                Section("Agent Turns") {
                    Picker("Turn", selection: $scope) {
                        ForEach(turns) { turn in
                            Text(turnLabel(turn)).tag(turn.scope)
                        }
                    }
                }
            }
        } label: {
            Label(scopeShort, systemImage: scopeSymbol)
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .accessibilityIdentifier("diff-scope")
    }

    private var scopeShort: String {
        switch scope {
        case .workingTree: "Uncommitted"
        case .staged: "Staged"
        case .turn(_, let turn): "Turn \(turn)"
        }
    }

    private var scopeSymbol: String {
        switch scope {
        case .workingTree: "pencil"
        case .staged: "tray.full"
        case .turn: "sparkle"
        }
    }

    private func turnLabel(_ turn: DiffTurn) -> String {
        let when = turn.started.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return "\(turn.agent) · turn \(turn.turn) · \(turn.ended == nil ? "running" : when)"
    }

    // MARK: Notes

    private func beginNote(_ file: DiffFile, _ line: DiffLine, oldSide: Bool) {
        withAnimation(DS.Motion.snappy) {
            composing = NoteAnchor(path: file.path, lineId: line.id, number: (oldSide ? line.oldNumber : line.newNumber) ?? line.newNumber ?? line.oldNumber ?? 0, oldSide: oldSide, quote: line.text)
        }
    }

    private func saveNote(_ text: String) {
        guard let anchor = composing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(DS.Motion.snappy) {
            if !trimmed.isEmpty {
                notes.append(ReviewNote(
                    path: anchor.path, startLine: anchor.number, endLine: anchor.number, oldSide: anchor.oldSide,
                    quote: anchor.quote.trimmingCharacters(in: .whitespaces).nonEmpty, note: trimmed))
            }
            composing = nil
        }
    }

    @ViewBuilder private var reviewBar: some View {
        if !notes.isEmpty {
            let reviewer = source.reviewer(for: scope)
            HStack(spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(notes.count) \(notes.count == 1 ? "note" : "notes")")
                        .font(DS.Font.rowTitleEmphasis)
                    Text(reviewer.map { "Goes to \($0) as one prompt" } ?? "No agent runs in this repository")
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { DiffPasteboard.copy(formattedNotes) }
                    .help("Copy the notes")
                    .buttonStyle(.glass)
                Button {
                    send()
                } label: {
                    if isSending {
                        Spinner(color: .white).frame(width: 14, height: 14)
                    } else {
                        Text(reviewer.map { "Send to \($0)" } ?? "Send")
                    }
                }
                .buttonStyle(.primaryGlass)
                .disabled(reviewer == nil || isSending)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("diff-send-review")
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .floatingPanel()
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            .movingTransition(.bottom)
        }
    }

    /// The notes as the agent would read them (for Copy).
    private var formattedNotes: String {
        notes.enumerated().map { index, note in
            var text = "\(index + 1). \(note.path):\(note.startLine)"
            if let quote = note.quote { text += "\n   > \(quote)" }
            return text + "\n   \(note.note)"
        }.joined(separator: "\n")
    }

    private func send() {
        isSending = true
        Task {
            do {
                try await source.sendReview(notes, scope: scope, preamble: nil)
                let reviewer = source.reviewer(for: scope) ?? "the agent"
                model.toasts.show(Toast("Review sent to \(reviewer)", systemImage: "arrow.up.circle.fill", style: .success))
                withAnimation(DS.Motion.snappy) { notes.removeAll() }
                onSent()
            } catch {
                model.toasts.show(Toast("Couldn't send: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
            isSending = false
        }
    }

    // MARK: Loading

    private func load() async {
        failure = nil
        do {
            repository = try await source.repository()
            turns = (try? await source.turns()) ?? []
            await loadFiles()
        } catch {
            failure = ScreenError.describe(error)
        }
    }

    private func loadFiles() async {
        do {
            let loaded = try await source.files(scope)
            withAnimation(DS.Motion.snappy) { files = loaded }
        } catch {
            files = nil
            failure = ScreenError.describe(error)
        }
    }
}

enum DiffLayout: String {
    case automatic, unified, split
}

/// Where a note is being written.
struct NoteAnchor: Hashable {
    var path: String
    var lineId: Int
    var number: Int
    var oldSide: Bool
    var quote: String
}

// MARK: - File header

private struct FileHeader: View {
    let file: DiffFile
    let isCollapsed: Bool
    let noteCount: Int
    let toggle: () -> Void
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
                StatusLetter(status: file.status)
                pathText
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: DS.Space.s)
                if noteCount > 0 {
                    Label("\(noteCount)", systemImage: "text.bubble")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.accent)
                }
                HStack(spacing: DS.Space.xs) {
                    Text("+\(file.additions)").foregroundStyle(theme.ansi(2))
                    Text("−\(file.deletions)").foregroundStyle(theme.ansi(1))
                }
                .font(DS.Font.meta)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(theme.surface(0.10))
        .overlay(alignment: .bottom) { theme.splitDivider.frame(height: 1) }
        .overlay(alignment: .top) { theme.splitDivider.frame(height: 1) }
        .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { DiffPasteboard.copy(file.path) }
        }
        .accessibilityLabel("\(file.path), \(file.additions) additions, \(file.deletions) deletions")
        .accessibilityHint(isCollapsed ? "Expands the file" : "Collapses the file")
        .accessibilityIdentifier("diff-file-\(file.path)")
    }

    private var pathText: Text {
        let name = (file.path as NSString).lastPathComponent
        let directory = String(file.path.dropLast(name.count))
        var text = Text("\(Text(directory).foregroundStyle(DS.Palette.textSecondary))\(Text(name).foregroundStyle(theme.foreground).fontWeight(.medium))")
        if let old = file.oldPath {
            text = Text("\(Text(old + " → ").foregroundStyle(DS.Palette.textTertiary))\(text)")
        }
        return text.font(DS.Font.literal)
    }
}

private struct StatusLetter: View {
    let status: FileEntry.GitStatus
    @Environment(\.terminalTheme) private var theme

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

// MARK: - Lines

/// One row of a side-by-side diff: the old line on the left, the new one on the right.
struct SplitDiffRow: Identifiable, Hashable {
    var id: Int
    var left: DiffLine?
    var right: DiffLine?
}

extension DiffHunk {
    /// Pairs a hunk's lines for side by side: context on both sides; each run of removed lines
    /// beside the run of added lines that follows it.
    var splitRows: [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                rows.append(SplitDiffRow(id: (left ?? right)!.id, left: left, right: right))
            }
            removed.removeAll()
            added.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            case .context:
                flush()
                rows.append(SplitDiffRow(id: line.id, left: line, right: line))
            }
        }
        flush()
        return rows
    }
}

private struct FileDiffBody: View {
    let file: DiffFile
    let split: Bool
    let notes: [ReviewNote]
    let composing: NoteAnchor?
    let onTapLine: (DiffLine, Bool) -> Void
    let onSaveNote: (String) -> Void
    let onCancelNote: () -> Void
    let onDeleteNote: (ReviewNote) -> Void

    @Environment(\.terminalTheme) private var theme
    @State private var viewport: CGFloat = 0

    static let numberWidth: CGFloat = 40
    static let lineHeight: CGFloat = 18

    var body: some View {
        if file.isBinary {
            placeholder("Binary file not shown")
        } else if file.hunks.isEmpty {
            placeholder(file.hunksOmitted ? "This diff is too large to show here." : "No content changes")
        } else if split {
            LazyVStack(alignment: .leading, spacing: 0) {
                // One block per hunk: row ids repeat across hunks and must not meet the
                // hunks' own ids in one lazy stack (a row would vanish).
                ForEach(file.hunks) { hunk in
                    VStack(alignment: .leading, spacing: 0) {
                        hunkHeader(hunk)
                        ForEach(hunk.splitRows) { row in
                            HStack(spacing: 0) {
                                side(row.left, oldSide: true)
                                theme.splitDivider.frame(width: 1)
                                side(row.right, oldSide: false)
                            }
                            annotations(for: row.left, oldSide: true)
                            if row.right?.id != row.left?.id { annotations(for: row.right, oldSide: false) }
                        }
                    }
                }
            }
            .background(theme.background)
        } else {
            // One horizontal scroll per file: long lines never wrap, numbers stay aligned.
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        VStack(alignment: .leading, spacing: 0) {
                            hunkHeader(hunk)
                            ForEach(hunk.lines) { line in
                                unifiedRow(line)
                                annotations(for: line, oldSide: line.kind == .removed)
                            }
                        }
                    }
                }
                .frame(minWidth: viewport, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            // Row fills reach the right edge even when every line is short.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
            .background(theme.background)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.rowSubtitle)
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background)
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        Text(verbatim: hunk.header)
            .font(DS.Font.literalSmall)
            .foregroundStyle(DS.Palette.textTertiary)
            .lineLimit(1)
            .padding(.leading, (split ? Self.numberWidth : Self.numberWidth * 2) + DS.Space.l)
            .padding(.trailing, DS.Space.l)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.hoverFill)
    }

    private func unifiedRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            mark(line.kind)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(DS.Font.literal)
                .foregroundStyle(line.kind == .context ? DS.Palette.textSecondary : DS.Palette.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, DS.Space.l)
        }
        .frame(height: Self.lineHeight)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(fill(line.kind))
        .contentShape(.rect)
        .onTapGesture { onTapLine(line, line.kind == .removed) }
        .contextMenu { lineMenu(line, oldSide: line.kind == .removed) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(line))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Adds a review note")
        .accessibilityIdentifier("diff-line-\(file.path)-\(line.id)")
    }

    @ViewBuilder private func side(_ line: DiffLine?, oldSide: Bool) -> some View {
        if let line {
            let kind: DiffLine.Kind = line.kind == .context ? .context : (oldSide ? .removed : .added)
            HStack(alignment: .top, spacing: 0) {
                number(oldSide ? line.oldNumber : line.newNumber)
                mark(kind)
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .font(DS.Font.literal)
                    .foregroundStyle(kind == .context ? DS.Palette.textSecondary : DS.Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, DS.Space.s)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: Self.lineHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill(kind))
            .contentShape(.rect)
            .onTapGesture { onTapLine(line, oldSide) }
            .contextMenu { lineMenu(line, oldSide: oldSide) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility(line))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("diff-line-\(file.path)-\(line.id)\(oldSide ? "-old" : "")")
        } else {
            Rectangle().fill(DS.Palette.hoverFill.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func lineMenu(_ line: DiffLine, oldSide: Bool) -> some View {
        Button("Add Note", systemImage: "text.bubble") { onTapLine(line, oldSide) }
        Button("Copy Line", systemImage: "doc.on.doc") { DiffPasteboard.copy(line.text) }
        if let number = oldSide ? line.oldNumber : line.newNumber {
            Button("Copy Location", systemImage: "number") { DiffPasteboard.copy("\(file.path):\(number)") }
        }
    }

    /// Notes under a line, and the composer when it is the one being annotated.
    @ViewBuilder private func annotations(for line: DiffLine?, oldSide: Bool) -> some View {
        if let line {
            let number = (oldSide ? line.oldNumber : line.newNumber) ?? -1
            ForEach(notes.filter { $0.startLine == number && $0.oldSide == oldSide }) { note in
                NoteCard(note: note) { onDeleteNote(note) }
            }
            if let composing, composing.lineId == line.id, composing.oldSide == oldSide || line.kind == .context {
                NoteComposer(anchor: composing, onSave: onSaveNote, onCancel: onCancelNote)
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(DS.Font.literalSmall.monospacedDigit())
            .foregroundStyle(DS.Palette.textTertiary)
            .frame(width: Self.numberWidth, alignment: .trailing)
            .padding(.trailing, DS.Space.xs)
            .frame(height: Self.lineHeight)
    }

    private func mark(_ kind: DiffLine.Kind) -> some View {
        Rectangle()
            .fill(markColor(kind))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .padding(.trailing, DS.Space.s)
    }

    private func markColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: theme.ansi(2)
        case .removed: theme.ansi(1)
        }
    }

    private func fill(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: theme.ansi(2).opacity(0.13)
        case .removed: theme.ansi(1).opacity(0.13)
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

private struct NoteCard: View {
    let note: ReviewNote
    let delete: () -> Void
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(DS.Palette.accent)
            Text(note.note)
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete Note", systemImage: "xmark", action: delete)
                .help("Delete Note")
                .buttonStyle(.bar)
                .controlSize(.small)
        }
        .padding(DS.Space.gap10)
        .background(DS.Palette.accent.opacity(0.1), in: .rect(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.accent.opacity(0.35), lineWidth: 0.5))
        .padding(.leading, FileDiffBody.numberWidth + DS.Space.l)
        .padding(.trailing, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
        .accessibilityIdentifier("diff-note")
    }
}

private struct NoteComposer: View {
    let anchor: NoteAnchor
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Note on line \(anchor.number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
            TextField("What should change here?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(DS.Space.s)
                .background(theme.surface(0.10), in: .rect(cornerRadius: DS.Radius.control))
                .focused($focused)
                .onSubmit { onSave(text) }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .accessibilityIdentifier("diff-note-field")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                Button("Add Note") { onSave(text) }
                    .buttonStyle(.primaryGlass)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("diff-note-add")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .background(DS.Palette.hoverFill, in: .rect(cornerRadius: DS.Radius.control))
        .padding(.leading, FileDiffBody.numberWidth + DS.Space.l)
        .padding(.trailing, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
        .onAppear { focused = true }
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
