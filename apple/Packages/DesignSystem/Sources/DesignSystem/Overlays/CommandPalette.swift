import SwiftUI

/// One command palette entry (Ghostty `CommandOption`, plus a section for the empty-query view).
public struct PaletteCommand: Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var section: String?
    public var systemImage: String?
    /// The program's mark (a tab's shell, agent, editor or browser), in place of the symbol.
    public var program: ProgramIdentity?
    /// Status dot for entries that are sessions or agents.
    public var state: AgentState?
    public var shortcut: [String]?
    public var badge: String?
    public var action: () -> Void

    public init(
        id: String, title: String, subtitle: String? = nil, section: String? = nil, systemImage: String? = nil,
        program: ProgramIdentity? = nil, state: AgentState? = nil, shortcut: [String]? = nil, badge: String? = nil, action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.section = section
        self.systemImage = systemImage
        self.program = program
        self.state = state
        self.shortcut = shortcut
        self.badge = badge
        self.action = action
    }
}

/// The command palette (Ghostty `CommandPaletteView`, Spotlight's and Raycast's shape): a search
/// field, a hairline and a list of compact one-line rows. One row is always selected, as a soft
/// accent tint; ↑/↓ and ⌃P/⌃N move, Return runs, ⌘1–⌘5 run the first five matches, Esc or
/// clicking outside closes. Matched characters are bold. With an empty query, entries are grouped
/// by section (Raycast); with a query, they are ranked flat. Present it with `spotlightOverlay`.
public struct CommandPalette: View {
    @Binding var isPresented: Bool
    let commands: [PaletteCommand]
    var placeholder: String
    /// it switched the palette to that scope (the query is then dropped).
    var onScope: ((String) -> Bool)?
    /// ⌫ on an empty query (a scoped palette goes back to all commands).
    var onDeleteEmpty: (() -> Void)?

    @State private var query = ""
    @State private var selection: String?
    @State private var contentHeight: CGFloat = .infinity
    @FocusState private var isFocused: Bool

    public init(
        isPresented: Binding<Bool>, commands: [PaletteCommand], placeholder: String = "Execute a command…",
        onScope: ((String) -> Bool)? = nil, onDeleteEmpty: (() -> Void)? = nil
    ) {
        _isPresented = isPresented
        self.commands = commands
        self.placeholder = placeholder
        self.onScope = onScope
        self.onDeleteEmpty = onDeleteEmpty
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
            HStack(spacing: DS.Space.gap10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Self.queryGlyph, weight: .medium))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                field(results)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: Self.fieldHeight)

            Hairline()

            if results.isEmpty {
                Text("No matches")
                    .font(Self.subtitleFont)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xl)
            } else {
                list(results)
            }
        }
        .chromeContent()
        .frame(maxWidth: DS.Size.paletteWidth)
        .floatingPanel(cornerRadius: DS.Radius.panel, elevated: true)
        .padding(.horizontal, DS.Space.l)
        .onAppear { Task { isFocused = true } }
        .onChange(of: query) {
            selection = nil
            if let onScope, onScope(query) { query = "" }
        }
        .accessibilityIdentifier("command-palette")
    }

    private func field(_ results: [PaletteCommand]) -> some View {
        TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .font(DS.Font.paletteQuery)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($isFocused)
            .onSubmit { run(results.first { $0.id == selection } ?? results.first) }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.delete) {
                guard query.isEmpty, let onDeleteEmpty else { return .ignored }
                onDeleteEmpty()
                return .handled
            }
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
    }

    private func list(_ results: [PaletteCommand]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        if trimmed.isEmpty, let section = command.section,
                           index == 0 || results[index - 1].section != section {
                            Text(section)
                                .font(Self.sectionFont)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .padding(.horizontal, DS.Space.s)
                                .padding(.top, index == 0 ? DS.Space.xs : DS.Space.m)
                                .padding(.bottom, DS.Space.xs)
                                .accessibilityAddTraits(.isHeader)
                        }
                        // Always one selected row, so Return always does something.
                        row(command, index: index, selected: command.id == (selection ?? results.first?.id))
                            .id(command.id)
                    }
                }
                .padding(Self.listInset)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            // Fits a short list; a long one scrolls at a fixed height (less in a short window).
            .frame(maxHeight: min(contentHeight, Self.listHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    #if os(macOS)
    static let listHeight: CGFloat = 320
    static let fieldHeight: CGFloat = 48
    static let queryGlyph: CGFloat = 15
    static let rowHeight: CGFloat = 32
    static let titleFont = SwiftUI.Font.body
    static let subtitleFont = SwiftUI.Font.callout
    static let iconSize: CGFloat = 16
    #else
    static let listHeight: CGFloat = 400
    static let fieldHeight: CGFloat = 54
    static let queryGlyph: CGFloat = 17
    static let rowHeight: CGFloat = 40
    static let titleFont = SwiftUI.Font.callout
    static let subtitleFont = SwiftUI.Font.footnote
    static let iconSize: CGFloat = 18
    #endif
    static let sectionFont = SwiftUI.Font.caption.weight(.medium)
    /// Rows sit this far inside the panel, so their corners are concentric with its own.
    static let listInset: CGFloat = DS.Radius.panel - DS.Radius.paletteRow

    private func row(_ command: PaletteCommand, index: Int, selected: Bool) -> some View {
        Button { run(command) } label: {
            HStack(spacing: DS.Space.gap10) {
                icon(command)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    highlighted(command.title)
                        .font(Self.titleFont)
                        .foregroundStyle(DS.Palette.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let subtitle = command.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Self.subtitleFont)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.s)
                if let badge = command.badge {
                    Text(badge)
                        .font(DS.Font.badge)
                        .padding(.horizontal, DS.Space.badgeH)
                        .padding(.vertical, DS.Space.badgeV)
                        .background(DS.Palette.selectedFill, in: .capsule)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                // The first five results run with ⌘1–⌘5 while a query narrows them.
                if !trimmed.isEmpty, index < 5 {
                    PaletteKeys(["⌘", "\(index + 1)"])
                } else if let shortcut = command.shortcut {
                    PaletteKeys(shortcut)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.paletteRow(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The program's mark (its agent's state as a badge), a status glyph, or a symbol.
    @ViewBuilder private func icon(_ command: PaletteCommand) -> some View {
        if let program = command.program {
            ProgramMark(program, size: Self.iconSize)
                .foregroundStyle(DS.Palette.text)
                .overlay(alignment: .bottomTrailing) {
                    if let state = command.state, state != .idle, state != .unknown {
                        StatusIndicator(state, size: 8)
                            .padding(1.5)
                            .background(DS.Palette.raised, in: .circle)
                            .offset(x: 4, y: 4)
                    }
                }
        } else if let state = command.state {
            StatusIndicator(state, size: 12)
        } else if let image = command.systemImage {
            Image(systemName: image)
                .font(.system(size: Self.iconSize * 0.78, weight: .regular))
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    /// Matched characters in bold, in the row's own colour (never the accent).
    private func highlighted(_ title: String) -> Text {
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

/// A shortcut right-aligned in palette rows as plain glyphs, the way system menus, Ghostty's
/// palette and the host switcher show them: grey boxes behind every key read as clutter.
struct PaletteKeys: View {
    let symbols: [String]

    init(_ symbols: [String]) {
        self.symbols = symbols
    }

    var body: some View {
        ShortcutLabel(symbols)
            .font(DS.Font.menuShortcut)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(symbols.joined())
    }
}

public extension View {
    /// A Spotlight-style panel over the whole window: centred, its top at a sixth of the height,
    /// over a light scrim that dims and blocks whatever is beneath (the find bar too). A tap on
    /// the scrim calls `onDismiss`.
    func spotlightOverlay<Panel: View>(
        isPresented: Bool, onDismiss: @escaping () -> Void, @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        overlay {
            if isPresented {
                SpotlightLayer(onDismiss: onDismiss, panel: panel)
                    .transition(.opacity)
            }
        }
    }
}

private struct SpotlightLayer<Panel: View>: View {
    let onDismiss: () -> Void
    let panel: () -> Panel
    @Environment(\.chrome) private var chrome

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(chrome.scheme == .dark ? 0.28 : 0.10)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                panel()
                    .frame(maxWidth: .infinity)
                    .padding(.top, min(max(geometry.size.height * 0.16, DS.Space.l), 180))
                    .padding(.bottom, DS.Space.l)
            }
        }
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
