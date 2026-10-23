import SwiftUI

/// The dense list row every list uses: a fixed leading slot (icon or status glyph), a title with an
/// optional subtitle, and trailing metadata. Leading slots are fixed width so titles align to one
public struct ListRow<Leading: View, Trailing: View>: View {
    let title: Text
    let subtitle: Text?
    let leading: Leading
    let trailing: Trailing
    var subtitleIsLiteral = false

    public init(
        _ title: Text, subtitle: Text? = nil, literalSubtitle: Bool = false,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsLiteral = literalSubtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DS.Space.m) {
            leading
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                if let subtitle {
                    subtitle
                        .font(subtitleIsLiteral ? DS.Font.literalSmall : DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(subtitleIsLiteral ? .middle : .tail)
                }
            }
            Spacer(minLength: DS.Space.s)
            trailing
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.vertical, DS.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

public extension ListRow where Trailing == EmptyView {
    init(_ title: Text, subtitle: Text? = nil, literalSubtitle: Bool = false, @ViewBuilder leading: () -> Leading) {
        self.init(title, subtitle: subtitle, literalSubtitle: literalSubtitle, leading: leading) { EmptyView() }
    }
}

/// A section header in sentence case, quiet and tight (sidebars and plain lists).
public struct SectionTitle: View {
    let title: String
    let count: Int?
    let small: Bool

    /// `small` for dense lists (the Agents screen), one step under the sidebar's.
    public init(_ title: String, count: Int? = nil, small: Bool = false) {
        self.title = title
        self.count = count
        self.small = small
    }

    public var body: some View {
        HStack(spacing: DS.Space.row) {
            Text(title)
            if let count {
                Text("\(count)").foregroundStyle(DS.Palette.textTertiary).monospacedDigit()
            }
        }
        .font(small ? DS.Font.sectionSmall : DS.Font.section)
        .foregroundStyle(DS.Palette.textSecondary)
        .textCase(nil)
    }
}

/// welcome view: the glyph in `title` at the large scale, 12, then the title (`title3`
/// semibold) and one line (`subheadline`) 4 apart, then the actions. Greys are the theme's
/// (`DS.Palette`), never a fixed opacity of the foreground. Copy names the next step, not the
/// absence; give it an action whenever there is one.
public struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    let actions: Actions

    public init(_ title: String, systemImage: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.title)
                .imageScale(.large)
                .foregroundStyle(DS.Palette.textSecondary)
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Palette.text)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)
            HStack(spacing: DS.Space.s) {
                actions
            }
            .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// default, `.vertical` inside an `HStack`.
public struct Hairline: View {
    public enum Axis: Sendable { case horizontal, vertical }

    let axis: Axis
    let style: ChromeStyle
    @Environment(\.displayScale) private var scale

    public init(_ axis: Axis = .horizontal, style: ChromeStyle = DS.Palette.hairline) {
        self.axis = axis
        self.style = style
    }

    public var body: some View {
        let width = max(DS.Size.hairline(scale: scale), 0.5)
        Rectangle()
            .fill(style)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
            .accessibilityHidden(true)
    }
}
