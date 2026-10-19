import SwiftUI

/// One command palette entry (Ghostty `CommandOption`, plus a section for the empty-query view).
public struct PaletteCommand: Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var section: String?
    public var systemImage: String?
    /// Status dot for entries that are sessions or agents.
    public var state: AgentState?
    public var shortcut: [String]?
    public var badge: String?
    public var action: () -> Void

    public init(
        id: String, title: String, subtitle: String? = nil, section: String? = nil, systemImage: String? = nil,
        state: AgentState? = nil, shortcut: [String]? = nil, badge: String? = nil, action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.section = section
        self.systemImage = systemImage
        self.state = state
        self.shortcut = shortcut
        self.badge = badge
        self.action = action
    }
}

/// query field, a divider and a fixed-height list. One row is always selected, in solid accent;
/// ↑/↓ and ⌃P/⌃N move, Return runs, ⌘1–⌘5 run the first five matches, Esc or clicking outside
/// closes. Matched characters are bold. With an empty query, entries are grouped by section
/// (Raycast); with a query, they are ranked flat.
public struct CommandPalette: View {
    @Binding var isPresented: Bool
    let commands: [PaletteCommand]
    var placeholder: String

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>, commands: [PaletteCommand], placeholder: String = "Execute a command…") {
        _isPresented = isPresented
        self.commands = commands
        self.placeholder = placeholder
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var results: [PaletteCommand] {
        guard !trimmed.isEmpty else { return commands }
        return commands
            .compactMap { command -> (PaletteCommand, Int)? in
                if let score = FuzzyMatch.score(trimmed, in: command.title) { return (command, score) }
                if let subtitle = command.subtitle, let score = FuzzyMatch.score(trimmed, in: subtitle) { return (command, score - 50) }
                return nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    public var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.paletteQuery)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, DS.Space.l)
                .frame(height: 48)
                .focused($isFocused)
                .onSubmit { run(results.first { $0.id == selection } ?? results.first) }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                .onKeyPress(keys: ["p", "n"], phases: .down) { press in
                    guard press.modifiers == .control else { return .ignored }
                    move(press.characters == "p" ? -1 : 1, in: results)
                    return .handled
                }
                // ⌘1–⌘5 run the first five results.
                .onKeyPress(keys: ["1", "2", "3", "4", "5"], phases: .down) { press in
                    guard press.modifiers == .command, let n = Int(press.characters), results.indices.contains(n - 1) else { return .ignored }
                    run(results[n - 1])
                    return .handled
                }
                .accessibilityIdentifier("palette-field")

            Divider()

            if results.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(DS.Space.l)
                    .frame(height: Self.listHeight, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                if trimmed.isEmpty, let section = command.section,
                                   index == 0 || results[index - 1].section != section {
                                    SectionTitle(section)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, DS.Space.s)
                                        .padding(.top, index == 0 ? 2 : DS.Space.s)
                                        .padding(.bottom, 2)
                                }
                                // Always one selected row, so Return always does something.
                                row(command, index: index, selected: command.id == (selection ?? results.first?.id))
                                    .id(command.id)
                            }
                        }
                        .padding(DS.Space.s)
                    }
                    // A fixed height: the panel does not jump as the matches change.
                    .frame(height: Self.listHeight)
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: DS.Size.paletteWidth)
        .floatingPanel(cornerRadius: DS.Radius.panel)
        .padding()
        .onAppear { Task { isFocused = true } }
        .onChange(of: query) { selection = nil }
        .accessibilityIdentifier("command-palette")
    }

    /// Mac: five and a half rows; touch: seven and a half.
    #if os(macOS)
    static let listHeight: CGFloat = 230
    #else
    static let listHeight: CGFloat = 380
    #endif

    private func row(_ command: PaletteCommand, index: Int, selected: Bool) -> some View {
        Button { run(command) } label: {
            HStack(spacing: DS.Space.s) {
                if let state = command.state {
                    StatusIndicator(state, size: 12).frame(width: 16)
                } else if let image = command.systemImage {
                    Image(systemName: image)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    highlighted(command.title, selected: selected)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    if let subtitle = command.subtitle {
                        Text(subtitle).font(.caption)
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.s)
                if let badge = command.badge {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
                // The first five results run with ⌘1–⌘5 while a query narrows them.
                if !trimmed.isEmpty, index < 5 {
                    ShortcutLabel(["⌘", "\(index + 1)"])
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                } else if let shortcut = command.shortcut {
                    ShortcutLabel(shortcut)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.row)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.paletteRow(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Matched characters in bold (white on the selected row, never the accent colour).
    private func highlighted(_ title: String, selected: Bool) -> Text {
        guard !trimmed.isEmpty, let indices = FuzzyMatch.indices(trimmed, in: title) else { return Text(title) }
        var attributed = AttributedString(title)
        for offset in indices {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    private func move(_ delta: Int, in results: [PaletteCommand]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : results.count)
        selection = results[(current + delta + results.count) % results.count].id
    }

    private func run(_ command: PaletteCommand?) {
        guard let command else { return }
        close()
        command.action()
    }

    private func close() {
        isPresented = false
        query = ""
        selection = nil
    }
}

/// Subsequence matching with a preference for word starts and contiguous runs.
nonisolated public enum FuzzyMatch {
    public static func indices(_ query: String, in text: String) -> [Int]? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var result: [Int] = [], qi = 0
        for (ti, c) in t.enumerated() where qi < q.count && c == q[qi] {
            result.append(ti)
            qi += 1
        }
        return qi == q.count ? result : nil
    }

    public static func score(_ query: String, in text: String) -> Int? {
        guard let indices = indices(query, in: text) else { return nil }
        let chars = Array(text)
        var score = 100 - (indices.first ?? 0)
        for (n, index) in indices.enumerated() {
            if n > 0, indices[n - 1] == index - 1 { score += 8 }
            if index == 0 || chars[index - 1] == " " || chars[index - 1] == "-" { score += 10 }
        }
        if text.lowercased().hasPrefix(query.lowercased()) { score += 40 }
        return score
    }
}
