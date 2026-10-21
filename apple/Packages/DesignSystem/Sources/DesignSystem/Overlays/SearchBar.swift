import SwiftUI

/// Scrollback search (Ghostty `SurfaceSearchOverlay`): a 180 pt field with the match counter inside
/// it, next/previous/close buttons, in a floating panel pinned to a corner. Drag it to another
/// corner; it snaps with a 0.2 s ease-out. Return goes to the next match, ⇧Return to the previous,
/// Esc closes. "Aa" matches case exactly (off: case-insensitive, as Ghostty).
public struct TerminalSearchBar: View {
    @Binding var needle: String
    /// Match case; nil hides the toggle.
    var caseSensitive: Binding<Bool>?
    /// Zero-based index of the selected match, if any.
    let selected: Int?
    /// Total matches; nil while the search is still running.
    let total: Int?
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @State private var corner = Corner.topRight
    @State private var dragOffset = CGSize.zero
    @State private var barSize = CGSize.zero
    @FocusState private var isFocused: Bool

    private let padding: CGFloat = 8

    public init(
        needle: Binding<String>, caseSensitive: Binding<Bool>? = nil, selected: Int?, total: Int?,
        onNext: @escaping () -> Void, onPrevious: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        _needle = needle
        self.caseSensitive = caseSensitive
        self.selected = selected
        self.total = total
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onClose = onClose
    }

    public var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                TextField("Search", text: $needle)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(width: 180)
                    .padding(.leading, 8)
                    .padding(.trailing, 50)
                    .padding(.vertical, 6)
                    .background(DS.Palette.selectedFill, in: .rect(cornerRadius: DS.Radius.field))
                    .focused($isFocused)
                    .overlay(alignment: .trailing) { counter }
                    .onSubmit {
                        onNext()
                        // Return submits and, on iOS, would end editing: stay in the field.
                        isFocused = true
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        onPrevious()
                        return .handled
                    }
                    // ⌘G / ⇧⌘G while typing: the text field would take them for itself.
                    .onKeyPress(keys: ["g", "G"], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        if press.modifiers.contains(.shift) { onPrevious() } else { onNext() }
                        return .handled
                    }
                    // ⌘. is Esc on an iPad keyboard (the Magic Keyboard has none), as in the terminal.
                    .onKeyPress(keys: ["."], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        onClose()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onClose()
                        return .handled
                    }
                    .accessibilityIdentifier("search-field")

                if let caseSensitive {
                    Button {
                        caseSensitive.wrappedValue.toggle()
                    } label: {
                        Text(verbatim: "Aa")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(caseSensitive.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(DS.Palette.textSecondary))
                            .frame(minWidth: 22)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.field)
                                    .fill(Color.accentColor.opacity(caseSensitive.wrappedValue ? 0.18 : 0))
                                    .padding(-3))
                    }
                    .accessibilityLabel("Match Case")
                    .accessibilityValue(caseSensitive.wrappedValue ? "On" : "Off")
                    .accessibilityIdentifier("search-case")
                    .help("Match Case")
                }

                Button("Previous Match", systemImage: "chevron.up", action: onPrevious)
                    .help("Previous Match (⇧⌘G)")
                Button("Next Match", systemImage: "chevron.down", action: onNext)
                    .help("Next Match (⌘G)")
                Button("Close Search", systemImage: "xmark", action: onClose)
                    .help("Close (Esc)")
                    // Esc closes from the field or the terminal (Ghostty's `end_search`): iOS gives the
                    // field's own key handler no Esc from a hardware keyboard.
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .buttonStyle(.bar)
            .chromeContent()
            .padding(8)
            .floatingPanel(cornerRadius: 14)
            // The count lives inside the field, where accessibility does not reach it: the bar
            // carries it ("3/17", "-/17").
            .accessibilityElement(children: .contain)
            .accessibilityValue(countText)
            .accessibilityIdentifier("search-bar")
            .onAppear { isFocused = true }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
            .padding(padding)
            .offset(dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        let center = centerPosition(for: corner, in: geo.size)
                        let dropped = CGPoint(x: center.x + value.translation.width, y: center.y + value.translation.height)
                        withAnimation(DS.Motion.overlay) {
                            corner = closestCorner(to: dropped, in: geo.size)
                            dragOffset = .zero
                        }
                    })
        }
    }

    private var countText: String {
        if let selected { return "\(selected + 1)/\(total.map(String.init) ?? "?")" }
        return total.map { "-/\($0)" } ?? ""
    }

    @ViewBuilder private var counter: some View {
        Group {
            if let selected {
                Text("\(selected + 1)/\(total.map(String.init) ?? "?")")
            } else if let total {
                Text("-/\(total)")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.trailing, 8)
        .accessibilityIdentifier("search-count")
    }

    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

        var alignment: Alignment {
            switch self {
            case .topLeft: .topLeading
            case .topRight: .topTrailing
            case .bottomLeft: .bottomLeading
            case .bottomRight: .bottomTrailing
            }
        }
    }

    private func centerPosition(for corner: Corner, in size: CGSize) -> CGPoint {
        let halfWidth = barSize.width / 2 + padding, halfHeight = barSize.height / 2 + padding
        switch corner {
        case .topLeft: return CGPoint(x: halfWidth, y: halfHeight)
        case .topRight: return CGPoint(x: size.width - halfWidth, y: halfHeight)
        case .bottomLeft: return CGPoint(x: halfWidth, y: size.height - halfHeight)
        case .bottomRight: return CGPoint(x: size.width - halfWidth, y: size.height - halfHeight)
        }
    }

    private func closestCorner(to point: CGPoint, in size: CGSize) -> Corner {
        if point.x < size.width / 2 {
            point.y < size.height / 2 ? .topLeft : .bottomLeft
        } else {
            point.y < size.height / 2 ? .topRight : .bottomRight
        }
    }
}
