import DesignSystem
import SwiftUI

/// Ghostty's bundled themes as a grid of small terminal windows, each in its own colours and
/// framed on the chrome (the sheet itself wears the current theme, so a pick restyles it at once).
/// Dark and light themes are sections of their own; the grid is lazy for the ~460 themes.
struct ThemePicker: View {
    @Binding var selection: String
    @State private var query = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", dark = "Dark", light = "Light"
        var id: String { rawValue }
    }

    private static let all = [TerminalTheme.ghosttyDefault] + ThemeCatalog.all
    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 240), spacing: DS.Space.l, alignment: .top)]

    private var sections: [(title: String, themes: [TerminalTheme])] {
        let matches = query.isEmpty ? Self.all : Self.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let dark = matches.filter { !$0.isLight }, light = matches.filter(\.isLight)
        return switch filter {
        case .all: [("Dark", dark), ("Light", light)].filter { !$0.themes.isEmpty }
        case .dark: [("Dark", dark)]
        case .light: [("Light", light)]
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    Picker("Appearance", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            HStack(spacing: DS.Space.s) {
                                Text(section.title).foregroundStyle(.secondary)
                                Text("\(section.themes.count)").foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.footnote.weight(.semibold))
                            LazyVGrid(columns: columns, spacing: DS.Space.xl) {
                                ForEach(section.themes) { theme in
                                    Button {
                                        withAnimation(DS.Motion.quick) { selection = theme.name }
                                    } label: {
                                        ThemeTile(theme: theme, isSelected: theme.name == selection)
                                    }
                                    .buttonStyle(.plain)
                                    .id(theme.name)
                                    .accessibilityIdentifier("theme-\(theme.name)")
                                }
                            }
                        }
                    }
                    if sections.allSatisfy(\.themes.isEmpty) {
                        Text("No themes match \u{201C}\(query)\u{201D}")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, DS.Space.xxxl)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.m)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .chromeGrouped()
        .sensoryFeedback(.selection, trigger: selection)
        .searchable(text: $query, prompt: "\(Self.all.count) themes")
        .navigationTitle("Theme")
    }
}

/// A theme as a small terminal window in its own colours, framed so that a dark window sits on a
/// light page as well as a light one on a dark page: a hairline in the chrome's ink and a soft
/// shadow. The selected one has the accent ring, set off by a gap, and its name in full ink.
private struct ThemeTile: View {
    let theme: TerminalTheme
    let isSelected: Bool
    @Environment(\.chrome) private var chrome

    private static let radius: CGFloat = 10
    private static let ringGap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ThemePreview(theme: theme)
                .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .strokeBorder(DS.Palette.border, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(chrome.scheme == .light ? 0.10 : 0.35), radius: 6, y: 2)
                .padding(Self.ringGap)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius + Self.ringGap, style: .continuous)
                        .strokeBorder(DS.Palette.accent, lineWidth: 2)
                        .opacity(isSelected ? 1 : 0)
                }
            HStack(spacing: DS.Space.xs) {
                Text(theme.name)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.accent)
                }
            }
            .padding(.horizontal, Self.ringGap + DS.Space.xxs)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A few lines of a session in the theme's colours (a prompt, `git status`, the cursor) over its
/// six ANSI hues.
private struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            prompt { Text("git status").foregroundStyle(theme.foreground) }
            line(" M ", theme.ansi(1), "src/main.rs")
            line("?? ", theme.ansi(2), "notes.md")
            prompt { Rectangle().fill(theme.cursorColor).frame(width: 6, height: 11) }
            Spacer(minLength: DS.Space.s)
            HStack(spacing: 3) {
                ForEach(1...6, id: \.self) { index in
                    Capsule().fill(theme.ansi(index)).frame(height: 4)
                }
            }
        }
        .font(TerminalFont.font(size: 10, relativeTo: .caption2))
        .lineLimit(1)
        .padding(DS.Space.gap10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(theme.background)
    }

    private func line(_ status: String, _ color: Color, _ path: String) -> some View {
        HStack(spacing: 0) {
            Text(status).foregroundStyle(color)
            Text(path).foregroundStyle(theme.foreground)
        }
    }

    private func prompt(@ViewBuilder _ rest: () -> some View) -> some View {
        HStack(spacing: 0) {
            Text("~/app ").foregroundStyle(theme.ansi(4))
            Text("❯ ").foregroundStyle(theme.ansi(2))
            rest()
        }
    }
}
