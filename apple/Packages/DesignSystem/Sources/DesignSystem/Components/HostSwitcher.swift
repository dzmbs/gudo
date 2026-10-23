import SwiftUI

/// One host in the switcher: its device symbol, name, a word about its link when that is news,
/// whether it is the window's, and its ⌃⌘ number.
public struct HostSwitcherHost: Identifiable, Hashable, Sendable {
    public enum Link: Hashable, Sendable { case live, connecting, down, closed }

    public var id: String
    public var name: String
    public var systemImage: String
    /// "Reconnecting", "Offline", "2 need you": only what is worth a glance.
    public var detail: String?
    public var link: Link
    public var needsYou: Bool
    public var isCurrent: Bool
    /// ⌃⌘1…⌃⌘9.
    public var shortcut: Int?

    public init(
        id: String, name: String, systemImage: String, detail: String? = nil, link: Link = .live,
        needsYou: Bool = false, isCurrent: Bool = false, shortcut: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.detail = detail
        self.link = link
        self.needsYou = needsYou
        self.isCurrent = isCurrent
        self.shortcut = shortcut
    }
}

/// A fixed row under the hosts: New Tab, New Agent, Add Remote Host….
public struct HostSwitcherCommand: Identifiable {
    public var id: String
    public var title: String
    public var systemImage: String
    /// The shortcut as glyphs, e.g. ["⇧", "⌘", "N"].
    public var shortcut: [String]
    public var perform: () -> Void

    public init(id: String, title: String, systemImage: String, shortcut: [String] = [], perform: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.perform = perform
    }
}

/// window's and its ⌃⌘ number, then the commands. ↑/↓ move the highlight, ↩ chooses, Esc closes.
public struct HostSwitcher: View {
    let hosts: [HostSwitcherHost]
    let commands: [HostSwitcherCommand]
    let onSelect: (HostSwitcherHost) -> Void
    let onCreate: ((String) -> Void)?
    let onDismiss: () -> Void
    /// Type-to-filter at once; off on touch, where focusing would raise the software keyboard
    /// over a menu that is mostly tapped.
    let focusesFilter: Bool

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var isFieldFocused: Bool
    @Namespace private var highlight

    public init(
        hosts: [HostSwitcherHost], commands: [HostSwitcherCommand],
        onSelect: @escaping (HostSwitcherHost) -> Void, onCreate: ((String) -> Void)? = nil,
        focusesFilter: Bool = true, onDismiss: @escaping () -> Void
    ) {
        self.focusesFilter = focusesFilter
        self.hosts = hosts
        self.commands = commands
        self.onSelect = onSelect
        self.onCreate = onCreate
        self.onDismiss = onDismiss
    }

    private enum Row: Identifiable {
        case host(HostSwitcherHost)
        case create(String)
        case command(HostSwitcherCommand)

        var id: String {
            switch self {
            case .host(let host): "host-\(host.id)"
            case .create: "create"
            case .command(let command): "command-\(command.id)"
            }
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var shownHosts: [HostSwitcherHost] {
        guard !trimmed.isEmpty else { return hosts }
        return hosts.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var shownCommands: [HostSwitcherCommand] {
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var rows: [Row] {
        var rows = shownHosts.map(Row.host)
        if onCreate != nil, !trimmed.isEmpty, shownHosts.isEmpty { rows.append(.create(trimmed)) }
        return rows + shownCommands.map(Row.command)
    }

    public var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            field
            Hairline()
            ScrollView {
                VStack(spacing: 1) {
                    let hostRows = rows.filter { if case .command = $0 { false } else { true } }
                    let commandRows = rows.filter { if case .command = $0 { true } else { false } }
                    ForEach(hostRows) { rowView($0) }
                    if !hostRows.isEmpty, !commandRows.isEmpty {
                        Hairline()
                            .padding(.vertical, DS.Space.xs)
                            .padding(.horizontal, DS.Space.s)
                    }
                    ForEach(commandRows) { rowView($0) }
                }
                .padding(DS.Space.row)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: DS.Size.switcherWidth)
        .chromeContent()
        .onAppear {
            highlighted = hosts.first(where: \.isCurrent).map { "host-\($0.id)" } ?? rows.first?.id
            if focusesFilter { isFieldFocused = true }
        }
        .onChange(of: query) {
            highlighted = self.rows.first?.id
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host-switcher")
    }

    private var field: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(DS.Palette.textTertiary)
            TextField(onCreate == nil ? "Filter…" : "Filter or connect…", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .focused($isFieldFocused)
                .onSubmit { choose(highlighted) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
                .accessibilityIdentifier("host-switcher-filter")
        }
        .font(.body)
        .padding(.horizontal, DS.Space.m)
        .frame(height: 44)
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        let isHighlighted = highlighted == row.id
        Button {
            choose(row.id)
        } label: {
            HStack(spacing: DS.Space.gap10) {
                switch row {
                case .host(let host):
                    Image(systemName: host.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 20)
                        .overlay(alignment: .topTrailing) {
                            if host.needsYou {
                                Circle().fill(DS.Palette.attention).frame(width: 7, height: 7).offset(x: 3, y: -2)
                            }
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(host.name)
                            .font(.body)
                            .foregroundStyle(host.link == .down ? DS.Palette.textSecondary : DS.Palette.text)
                            .lineLimit(1)
                        if let detail = host.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(host.link == .down ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(DS.Palette.textTertiary))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Space.s)
                    if host.link == .connecting {
                        Spinner(color: DS.Palette.textTertiary)
                            .frame(width: 12, height: 12)
                    }
                    if let shortcut = host.shortcut {
                        shortcutText(["⌃", "⌘", "\(shortcut)"])
                    }
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Palette.accent)
                        .opacity(host.isCurrent ? 1 : 0)
                        .frame(width: 16)
                        .accessibilityHidden(!host.isCurrent)
                case .create(let destination):
                    Image(systemName: "arrow.right.circle")
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 20)
                    (Text("Connect to ") + Text(destination).font(DS.Font.literal))
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                case .command(let command):
                    Image(systemName: command.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 20)
                    Text(command.title)
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    shortcutText(command.shortcut)
                    Color.clear.frame(width: 16, height: 1)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: 36)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(DS.Palette.selectedFill)
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .contentShape(.rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { withAnimation(DS.Motion.menu) { highlighted = row.id } } }
        #if os(iOS)
        .contentShape(.hoverEffect, .rect(cornerRadius: DS.Radius.control))
        .hoverEffect(.highlight)
        #endif
        .accessibilityAddTraits(isCurrent(row) ? .isSelected : [])
        .accessibilityIdentifier("host-switcher-\(row.id)")
    }

    private func isCurrent(_ row: Row) -> Bool {
        if case .host(let host) = row { return host.isCurrent }
        return false
    }

    private func shortcutText(_ glyphs: [String]) -> some View {
        ShortcutLabel(glyphs)
            .font(DS.Font.menuShortcut)
            .accessibilityHidden(true)
    }

    private func move(_ step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        withAnimation(DS.Motion.menu) { highlighted = ids[min(max(index + step, 0), ids.count - 1)] }
    }

    private func choose(_ id: String?) {
        guard let row = rows.first(where: { $0.id == id }) ?? rows.first else { return }
        onDismiss()
        switch row {
        case .host(let host): onSelect(host)
        case .create(let destination): onCreate?(destination)
        case .command(let command): command.perform()
        }
    }
}

/// symbol, its name and a small chevron; the symbol gives way to a link glyph when the link is
/// not healthy.
public struct HostSwitcherLabel<Glyph: View>: View {
    let name: String
    let glyph: Glyph

    public init(_ name: String, @ViewBuilder glyph: () -> Glyph) {
        self.name = name
        self.glyph = glyph()
    }

    public var body: some View {
        HStack(spacing: DS.Space.row) {
            glyph
            Text(name).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, DS.Space.row)
        .contentShape(.rect)
    }
}
