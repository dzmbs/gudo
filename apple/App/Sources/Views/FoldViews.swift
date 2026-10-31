import DesignSystem
import SwiftUI

/// The band over a fold: the window's base, nothing on it. A partly open fold reserves the
/// division's margins; a flat one a thin band, so no text or control sits in the crease.
struct FoldGutter: View {
    var body: some View {
        Rectangle()
            .fill(DS.Palette.base)
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
    @State private var originX: CGFloat = 0

    var body: some View {
        let layout = model.foldLayout
        let page = layout.leadingPage(from: originX)
        // The children keep their places whether or not there is a fold: unfolding resizes
        // them, never rebuilds them.
        HStack(spacing: 0) {
            leading
                .frame(width: page)
                .frame(maxWidth: page == nil ? .infinity : nil)
            ZStack {
                if case .pages(_, let gutter) = layout, page != nil {
                    FoldGutter().frame(width: gutter)
                } else {
                    divider
                }
            }
            trailing.frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { originX = $0 }
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
