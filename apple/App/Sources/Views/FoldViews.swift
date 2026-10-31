import DesignSystem
import SwiftUI

/// The band over a fold: the window's base, nothing on it. A partly open fold reserves the
/// division's margins; a flat one a thin band, so no text or control sits in the crease.
struct FoldGutter: View {
    /// A flat fold shows no crease: a split divider down the middle parts the pages. Partly
    /// open, the crease itself does.
    var showsLine = false
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(DS.Palette.base)
            .overlay {
                if showsLine { Rectangle().fill(theme.splitDivider).frame(width: DS.Size.dividerVisible) }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Two views, one each side of a fold running top to bottom (`FoldLayout.pages`); without one,
/// side by side at `fallbackDivider` apart. Measures where it sits in the window, so the fold
/// lands between its children wherever the container starts.
struct FoldPages<Leading: View, Trailing: View, Divider: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var divider: Divider
    @ViewBuilder var trailing: Trailing
    @Environment(WindowModel.self) private var model

    var body: some View {
        // The container's own frame, which its children cannot move: where the fold falls in it.
        GeometryReader { proxy in
            let layout = model.foldLayout
            let frame = proxy.frame(in: .global)
            let page = layout.leadingPage(from: frame.minX)
            let gutter = page == nil ? 0 : layout.gutter
            let fits = page.map { $0 >= FoldLayout.minimumPage && frame.width - $0 - gutter >= FoldLayout.minimumPage } ?? false
            // The children keep their places whether or not there is a fold: unfolding resizes
            // them, never rebuilds them.
            HStack(spacing: 0) {
                leading
                    .frame(width: fits ? page : nil)
                    .frame(maxWidth: fits ? nil : .infinity)
                ZStack {
                    if fits {
                        FoldGutter(showsLine: !model.fold.isDivisionActive).frame(width: gutter)
                    } else {
                        divider
                    }
                }
                trailing.frame(maxWidth: .infinity)
            }
        }
    }
}

#if os(iOS)
/// The lower screen of a half-folded inner display (laptop or tabletop): the agents, with
/// approve, deny and reply inline, under thumbs while the terminal stays readable above. The
/// keyboard rises over this screen only, so the terminal above never reflows for it.
struct TabletopDeck: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        NavigationStack {
            InboxView(feed: model.agents, onLaunch: { model.newAgent() }, onNewTerminal: { model.newTab() })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Keyboard", systemImage: "keyboard") { typeInTerminal() }
                            .help("Type in the Terminal")
                            .disabled(workspace.focusedPane == nil)
                            .accessibilityIdentifier("deck-keyboard")
                    }
                }
        }
        .chromeBackground(DS.Palette.base)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabletop-deck")
    }

    /// The focused pane takes the keyboard, which comes up over the deck.
    private func typeInTerminal() {
        guard let id = workspace.focusedPane else { return }
        _ = workspace.panes[id]?.view.becomeFirstResponder()
    }
}
#endif
