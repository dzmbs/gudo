import SwiftUI

/// A button at a sheet's edge: Cancel, or the one primary (Start, Connect, Join).
public struct SheetAction {
    public var title: String
    public var isEnabled: Bool
    /// Working: the button gives way to a spinner and `busyTitle`.
    public var isBusy: Bool
    public var busyTitle: String?
    public var identifier: String?
    public var action: () -> Void

    public init(
        _ title: String, isEnabled: Bool = true, isBusy: Bool = false, busyTitle: String? = nil,
        identifier: String? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.busyTitle = busyTitle
        self.identifier = identifier
        self.action = action
    }
}

/// A sheet in each platform's own shape. iOS: a navigation stack, the title inline and the
/// actions in the bar's cancellation and confirmation slots. macOS: no bar at all (a sheet
/// there has no title bar): the title leading over the content, which sizes the sheet, and the
/// buttons trailing at the bottom, Cancel then the default button (Esc and Return), with any
/// accessory leading on the same line.
public struct SheetScaffold<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String?
    let cancel: SheetAction?
    let primary: SheetAction?
    let accessory: Accessory
    let content: Content

    public init(
        _ title: String, subtitle: String? = nil, cancel: SheetAction? = nil, primary: SheetAction? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.cancel = cancel
        self.primary = primary
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        // Opaque from the first frame, whoever presents it.
        layout.chromeSheetBackground()
    }

    @ViewBuilder private var layout: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title, subtitle: subtitle)
            // A sheet taller than its content keeps the title at the top and the buttons at the
            // bottom; the slack goes between them, never above the title.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if cancel != nil || primary != nil || Accessory.self != EmptyView.self {
                HStack(spacing: DS.Space.m) {
                    accessory
                    Spacer(minLength: DS.Space.l)
                    if let cancel {
                        button(cancel)
                            .keyboardShortcut(.cancelAction)
                    }
                    if let primary {
                        if primary.isBusy {
                            busy(primary)
                        } else {
                            button(primary)
                                .buttonStyle(SheetButtonStyle(isDefault: true))
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .background {
                    // A sheet with only Done still closes on Esc.
                    if cancel == nil, let primary, !primary.isBusy {
                        Button("", action: primary.action)
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    // Return types a new line in a multi-line field; ⌘↩ still confirms, as on iPad.
                    if let primary, !primary.isBusy, primary.isEnabled {
                        Button("", action: primary.action)
                            .keyboardShortcut(.return, modifiers: .command)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(SheetButtonStyle())
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.s)
                .padding(.bottom, DS.Space.xl)
            }
        }
        .chromeContent()
        .chromeSheetBackground()
        #else
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let cancel {
                        ToolbarItem(placement: .cancellationAction) { button(cancel) }
                    }
                    if let primary {
                        ToolbarItem(placement: .confirmationAction) {
                            if primary.isBusy {
                                busy(primary)
                            } else {
                                button(primary)
                                    .buttonStyle(.primaryGlass)
                                    .keyboardShortcut(.return, modifiers: .command)
                            }
                        }
                    }
                    if Accessory.self != EmptyView.self {
                        ToolbarItem(placement: .bottomBar) { accessory }
                    }
                }
        }
        .chromeSheetBackground()
        #endif
    }

    private func button(_ action: SheetAction) -> some View {
        Button(action.title, action: action.action)
            .disabled(!action.isEnabled)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier(action.identifier ?? "")
    }

    private func busy(_ action: SheetAction) -> some View {
        HStack(spacing: DS.Space.s) {
            ProgressView().controlSize(.small)
            Text(action.busyTitle ?? action.title)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

#if os(macOS)
/// A Mac sheet's button: a capsule at the large control size on the theme's own fill, the
/// default one on the prominent colour. Disabled, the default button keeps the plain bezel and
/// its label drops to the tertiary ink, quieter than Cancel beside it.
private struct SheetButtonStyle: ButtonStyle {
    var isDefault = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.rowTitle)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.l)
            .frame(minWidth: 72, minHeight: 28)
            .background { fill(isPressed: configuration.isPressed) }
            .contentShape(.capsule)
            .animation(DS.Motion.micro, value: configuration.isPressed)
    }

    private var foreground: ChromeStyle {
        guard isEnabled else { return DS.Palette.textTertiary }
        return isDefault ? DS.Palette.onProminent : DS.Palette.text
    }

    @ViewBuilder private func fill(isPressed: Bool) -> some View {
        if isDefault, isEnabled {
            Capsule().fill(DS.Palette.prominent).brightness(isPressed ? -0.08 : 0)
        } else {
            Capsule().fill(isPressed && isEnabled ? DS.Palette.pressedFill : DS.Palette.selectedFill)
        }
    }
}
#endif

/// A sheet's or tool window's title block on the Mac: the title in the system's headline
/// (13 pt semibold) with an optional line under it, leading, on the 20 pt margin that the
/// grouped form beneath also keeps.
public struct SheetHeader: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.Palette.text)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.xl)
        .padding(.bottom, DS.Space.xs)
    }
}
