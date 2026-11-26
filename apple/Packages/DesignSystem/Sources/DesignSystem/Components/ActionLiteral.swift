import SwiftUI

/// Whether a card has shown the whole of an action it asks the owner to allow. An action that
/// fits the card's lines is shown at once; one cut there only once it was opened and read to
/// its end.
nonisolated public struct ActionReveal: Equatable, Sendable {
    /// The tallest an opened action grows before it scrolls.
    public static let openedHeight: CGFloat = 168

    public private(set) var isOpen = false
    public private(set) var hasShownAll = false
    private var collapsedHeight: CGFloat?
    private var fullHeight: CGFloat?

    public init() {}

    /// The card's lines hide part of the action.
    public var isCut: Bool {
        guard let collapsedHeight, let fullHeight else { return false }
        return fullHeight > collapsedHeight + 0.5
    }

    public mutating func measured(collapsed height: CGFloat) {
        collapsedHeight = height
        settle()
    }

    public mutating func measured(full height: CGFloat) {
        fullHeight = height
        settle()
    }

    public mutating func open() {
        isOpen = true
    }

    /// The opened action showed its last line.
    public mutating func reachedEnd() {
        if isOpen { hasShownAll = true }
    }

    private mutating func settle() {
        if collapsedHeight != nil, fullHeight != nil, !isCut { hasShownAll = true }
    }
}

/// The exact action an approval card asks about, in the literal face on a raised field. When the
/// card's lines cut it, Show All opens it in place (scrolling past `ActionReveal.openedHeight`),
/// and `isShownWhole` stays false until its last line has been on screen: a card keeps its allow
/// buttons off until then, so nothing past the cut is allowed unseen.
public struct ActionLiteral: View {
    private let text: String
    private let lineLimit: Int
    @Binding private var isShownWhole: Bool
    @State private var reveal = ActionReveal()

    public init(_ text: String, lineLimit: Int, isShownWhole: Binding<Bool>) {
        self.text = text
        self.lineLimit = lineLimit
        _isShownWhole = isShownWhole
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xxs) {
            field
            if reveal.isCut, !reveal.isOpen {
                Button("Show All") { withAnimation(DS.Motion.standard) { reveal.open() } }
                    .buttonStyle(.quiet)
                    .controlSize(.small)
                    .help("Show the whole action before allowing it")
                    .accessibilityIdentifier("action-show-all")
            }
        }
        .onChange(of: reveal.hasShownAll, initial: true) { _, shown in isShownWhole = shown }
        .onChange(of: text) { reveal = ActionReveal() }
    }

    private var literal: some View {
        Text(verbatim: text)
            .font(DS.Font.literalSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var field: some View {
        Group {
            if reveal.isOpen { opened } else { collapsed }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field, style: .continuous))
        .hairlineBorder(RoundedRectangle.rounded(DS.Radius.field), style: DS.Palette.hairline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Action: \(text)")
    }

    private var collapsed: some View {
        literal
            .lineLimit(lineLimit)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reveal.measured(collapsed: $0) }
            .background(alignment: .topLeading) {
                literal
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reveal.measured(full: $0) }
            }
    }

    /// Whole when it fits the opened height; else scrolling, shown once scrolled to its end.
    private var opened: some View {
        ViewThatFits(in: .vertical) {
            literal
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onAppear { reveal.reachedEnd() }
            ScrollView {
                literal.textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 1
            } action: { _, isAtEnd in
                if isAtEnd { reveal.reachedEnd() }
            }
        }
        .frame(maxHeight: ActionReveal.openedHeight)
    }
}
