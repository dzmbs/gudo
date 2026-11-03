import DesignSystem
import SwiftUI

/// A new browser tab's page. Dev servers come and go with the host's scans, so they sit last,
/// where appearing or leaving never moves the history above them.
struct BrowserStartPage: View {
    var hostName: String
    var devServers: [DetectedPort]
    var focusOnAppear: Bool
    var open: (URL) -> Void
    var openDevServer: (DetectedPort) -> Void

    @Environment(\.terminalTheme) private var theme
    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @State private var text = ""
    /// -1 when no suggestion is picked: Return goes where the text says.
    @State private var selection = -1
    @FocusState private var isFocused: Bool
    private var history: BrowserHistory { .shared }

    private var suggestions: [AddressSuggestion] {
        AddressSuggestion.make(for: text, history: history.entries, devServers: devServers, engine: engine, locale: .current)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxxl) {
                field
                if text.isEmpty {
                    if !history.frequent.isEmpty { frequentSection }
                    if !history.recent.isEmpty { recentSection }
                    if !devServers.isEmpty { devServerSection }
                    if devServers.isEmpty && history.entries.isEmpty {
                        Text("Dev servers you start in a terminal show up here.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, 72)
            .padding(.bottom, DS.Space.xxxl)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background)
        .animation(DS.Motion.snappy, value: text.isEmpty)
        .animation(DS.Motion.snappy, value: devServers)
        .onAppear { if focusOnAppear { isFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("start-page")
    }

    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DS.Palette.textSecondary)
                TextField("Search \(engine.title) or enter address", text: $text)
                    .font(.title3)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    #endif
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onChange(of: text) { selection = -1 }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .accessibilityIdentifier("start-address")
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 52)
            if !suggestions.isEmpty {
                Hairline()
                AddressSuggestionList(suggestions: suggestions, selection: selection) { open($0.url) }
                    .padding(DS.Space.xs)
            }
        }
        .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Palette.border))
        .shadow(color: .black.opacity(isFocused ? 0.12 : 0.05), radius: isFocused ? 16 : 6, y: 4)
        .animation(DS.Motion.snappy, value: isFocused)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        selection = AddressSuggestion.step(selection, by: step, count: suggestions.count)
        return .handled
    }

    private func submit() {
        if suggestions.indices.contains(selection) {
            open(suggestions[selection].url)
        } else if let url = BrowserAddress.url(for: text, engine: engine, locale: .current) {
            open(url)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: DS.Space.m)]

    private var devServerSection: some View {
        section(hostName.isEmpty ? "Dev Servers" : "Dev Servers on \(hostName)") {
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(devServers) { port in
                    Button { openDevServer(port) } label: {
                        Tile(title: "localhost:\(port.port)", subtitle: port.pane.map { "\(port.process) · \($0)" } ?? port.process) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(DS.Palette.done)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("start-dev-\(port.port)")
                }
            }
        }
    }

    private var frequentSection: some View {
        section("Frequently Visited") {
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(history.frequent, id: \.url) { entry in
                    Button { URL(string: entry.url).map(open) } label: {
                        Tile(title: entry.title.isEmpty ? host(entry.url) : entry.title, subtitle: host(entry.url)) {
                            Monogram(text: host(entry.url))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("start-frequent")
                }
            }
        }
    }

    private var recentSection: some View {
        section("Recently Visited") {
            VStack(spacing: 0) {
                ForEach(history.recent, id: \.url) { entry in
                    Button { URL(string: entry.url).map(open) } label: {
                        HStack(spacing: DS.Space.m) {
                            Image(systemName: "clock")
                                .foregroundStyle(DS.Palette.textTertiary)
                            Text(entry.title.isEmpty ? AddressSuggestion.bare(entry.url) : entry.title)
                                .lineLimit(1)
                            Spacer(minLength: DS.Space.s)
                            Text(entry.lastVisit, format: .relative(presentation: .named))
                                .font(DS.Font.meta)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                        .padding(.horizontal, DS.Space.m)
                        .frame(height: 36)
                    }
                    .buttonStyle(.row)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(title)
                .font(DS.Font.section)
                .foregroundStyle(DS.Palette.textSecondary)
            content()
        }
    }

    private func host(_ url: String) -> String {
        AddressSuggestion.bare(URL(string: url)?.host() ?? url)
    }
}

private struct Tile<Mark: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let mark: Mark
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            mark
                .frame(width: 32, height: 32)
                .background(DS.Palette.hoverFill, in: .rect(cornerRadius: DS.Radius.control))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.rowTitleEmphasis)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .background(isHovered ? DS.Palette.hoverFill : DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.pane))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.pane).strokeBorder(DS.Palette.hairline))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
    }
}

/// A site's first letter, for pages without an icon of their own.
private struct Monogram: View {
    let text: String

    var body: some View {
        Text(text.first.map { String($0).uppercased() } ?? "·")
            .font(.headline.weight(.semibold))
            .foregroundStyle(DS.Palette.accent)
    }
}

/// Settings ▸ Browser.
struct BrowserSettingsSection: View {
    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @AppStorage(WebsiteLanguage.key) private var language = WebsiteLanguage.defaultTag
    @AppStorage(SearchRegion.key) private var region = ""
    @AppStorage(BrowserAppearance.key) private var appearance = BrowserAppearance.matchTheme

    var body: some View {
        Section {
            Picker("Search Engine", selection: $engine) {
                ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
            }
            .settingAnchor("search-engine")
            .accessibilityIdentifier("settings-search-engine")
            Picker("Language for Websites", selection: $language) {
                Text("System").tag("")
                ForEach(WebsiteLanguage.tags, id: \.self) { Text(WebsiteLanguage.name($0)).tag($0) }
            }
            .settingAnchor("website-language")
            .accessibilityIdentifier("settings-website-language")
            Picker("Search Region", selection: $region) {
                Text("Automatic").tag("")
                ForEach(SearchRegion.codes, id: \.self) { Text(SearchRegion.name($0)).tag($0) }
            }
            .settingAnchor("search-region")
            Picker("Browser Appearance", selection: $appearance) {
                ForEach(BrowserAppearance.allCases) { Text($0.title).tag($0) }
            }
            .settingAnchor("website-appearance")
            Button("Clear Browsing History", role: .destructive) { BrowserHistory.shared.clear() }
                .disabled(BrowserHistory.shared.entries.isEmpty)
                .settingAnchor("browser-history")
        } header: {
            Text("Browser")
        } footer: {
            Text("What you type in a browser tab's address field that isn't an address searches here. Websites are asked for pages in the language chosen; the region sets where Google and Bing results are for, which they otherwise guess from your network. Websites that have a dark style use it when the appearance is dark. Visited pages stay on this device.")
        }
    }
}

/// Suggestions under an address field; `selection` is the highlighted index.
struct AddressSuggestionList: View {
    let suggestions: [AddressSuggestion]
    let selection: Int
    let pick: (AddressSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: suggestion.systemImage)
                            .foregroundStyle(suggestion.kind == .devServer ? AnyShapeStyle(DS.Palette.done) : AnyShapeStyle(DS.Palette.textSecondary))
                            .frame(width: 20)
                        Text(suggestion.title)
                            .lineLimit(1)
                        Text(suggestion.detail)
                            .font(DS.Font.rowDetail)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.row)
                    .frame(minHeight: 32)
                }
                .buttonStyle(.row(selected: index == selection))
                .accessibilityIdentifier("address-suggestion-\(index)")
            }
        }
    }
}
