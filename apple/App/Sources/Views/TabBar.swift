import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Horizontal tabs, every host's tabs in sidebar order, each as wide as its title within
/// `DS.Size.tabMinWidth...tabMaxWidth`; more than fit scroll, faded at the edge they run past.
struct TabBar: View {
    let workspace: Workspace
    /// In the title bar's own row (the Mac with the sidebar hidden): the band's height, on what
    /// is under it, with no rule of its own.
    var inTitleBar = false
    @Environment(WindowModel.self) private var model
    @Environment(\.showsContentCard) private var showsContentCard
    @Environment(\.chromeAccessibility) private var accessibility
    @State private var edges = StripEdges()
    @State private var spans = StripSpans()

    var body: some View {
        #if DEBUG
        let _ = ChromeRenders.note("tab-bar")
        #endif
        let active = model.destination == .terminal ? model.shownTab : nil
        let refs = chipRefs
        HStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    chips(refs, active: active)
                        .coordinateSpace(name: StripSpans.space)
                        .animation(DS.Motion.standard, value: refs)
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: StripEdges.self) { geometry in
                    StripEdges(offset: geometry.contentOffset.x, content: geometry.contentSize.width, container: geometry.containerSize.width)
                } action: { _, next in
                    withAnimation(DS.Motion.micro) { edges = next }
                }
                .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                    geometry.contentOffset.x...geometry.contentOffset.x + geometry.containerSize.width
                } action: { old, visible in
                    spans.visible = visible
                    // A resized window can leave the selection past an edge: brought back at once,
                    // as the strip follows the window's edge.
                    if StripSpans.isResize(from: old, to: visible) { reveal(active, with: scroller, animated: false) }
                }
                .stripEdgeFade(edges)
                .onChange(of: refs) { old, new in
                    if new.count > old.count { TabTimeline.mark(.chipInserted) }
                    reveal(active, with: scroller)
                }
                .onChange(of: active, initial: true) { _, ref in reveal(ref, with: scroller) }
            }
            NewTabButton(workspace: workspace)
                .padding(.leading, DS.Space.xs)
        }
        .buttonStyle(.bar)
        .padding(.horizontal, inTitleBar ? 0 : DS.Space.row)
        .frame(height: stripHeight)
        .environment(\.tabStripHeight, stripHeight)
        .background { if !inTitleBar { Rectangle().fill(showsContentCard ? DS.Palette.sidebar : DS.Palette.base) } }
        .overlay(alignment: .bottom) { if !inTitleBar { Hairline(style: DS.Palette.separator) } }
        // A 34 pt strip: titles grow with Dynamic Type only as far as it holds them.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-bar")
    }

    private var stripHeight: CGFloat { inTitleBar ? DS.Size.tab : DS.Size.tabStrip }

    /// Brings the selected chip whole into view by the least travel, once a chip just added has
    /// been laid out.
    private func reveal(_ ref: TabRef?, with scroller: ScrollViewProxy, animated: Bool = true) {
        guard let ref else { return }
        Task { @MainActor in
            // Where the spans know no better (a chip not yet measured), the scroll's own least
            // travel, which leaves a chip in view where it is.
            let anchor = spans.anchor(revealing: ref)
            if animated {
                withAnimation(accessibility.travel(DS.Motion.standard)) { scroller.scrollTo(StripSpans.ChipID(ref: ref), anchor: anchor) }
                TabTimeline.mark(.scrolledIntoView)
            } else if anchor != nil {
                scroller.scrollTo(StripSpans.ChipID(ref: ref), anchor: anchor)
            }
        }
    }

    /// Every chip in strip order: the unified order the sidebar lists and ⌘1…⌘9 number. A tab
    /// still arriving joins with its content.
    private var chipRefs: [TabRef] {
        let arriving = model.arrivingTab
        return model.groups.tabs.filter { $0 != arriving }
    }

    private func chips(_ refs: [TabRef], active: TabRef?) -> some View {
        let groups = Dictionary(model.groups.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activeIndex = active.flatMap { refs.firstIndex(of: $0) }
        // Tabs name their host only while the window holds more than one host.
        let isMultiHost = Set(refs.map(\.hostId)).count > 1
        return HStack(spacing: 0) {
            ForEach(Array(refs.enumerated()), id: \.element) { index, ref in
                if index > 0 {
                    Hairline(.vertical, style: DS.Palette.separator)
                        .frame(height: 16)
                        .opacity(Self.showsSeparator(before: index, active: activeIndex) ? 1 : 0)
                }
                Group {
                    if ref.hostId == HostGroups.mixedId {
                        if let mixed = model.composites.tab(ref.tab) { MixedTabChip(tab: mixed, isActive: ref == active) }
                    } else if let group = groups[ref.hostId], let tab = group.tabs.first(where: { $0.id == ref.tab }) {
                        TabChip(tab: tab, ref: ref, group: group, isActive: ref == active, showsHost: isMultiHost)
                    }
                }
                .id(StripSpans.ChipID(ref: ref))
                .tabChipWidth()
                .modifier(ChipSpanReport(ref: ref, spans: spans))
                .modifier(ChipFrameReport(ref: ref))
                .motionTransition(.tab)
            }
        }
    }

    /// Whether the line before the chip at `index` shows: Ghostty and AppKit draw none next to
    /// the selected tab.
    static func showsSeparator(before index: Int, active: Int?) -> Bool {
        index > 0 && index != active && index - 1 != active
    }
}

/// Where each chip sits along the strip's content and which part of it shows; read when the
/// selection changes, never observed.
@MainActor
final class StripSpans {
    nonisolated static let space = "strip-content"
    /// A chip's own id: the ref alone also names its separator, which the scroll would find first.
    struct ChipID: Hashable {
        let ref: TabRef
    }

    var chips: [TabRef: ClosedRange<CGFloat>] = [:]
    var visible: ClosedRange<CGFloat> = 0...0

    /// Where to scroll `ref` to: by the nearer edge, clear of its fade; nil while it shows whole
    /// or is not measured.
    func anchor(revealing ref: TabRef) -> UnitPoint? {
        guard let chip = chips[ref] else { return nil }
        return Self.anchor(chip: chip, visible: visible, clear: DS.Size.tabStripFade)
    }

    /// The strip's own width changed (the window was resized), not only where it is scrolled.
    static func isResize(from old: ClosedRange<CGFloat>, to new: ClosedRange<CGFloat>) -> Bool {
        abs((old.upperBound - old.lowerBound) - (new.upperBound - new.lowerBound)) > 0.5
    }

    /// The anchor that brings `chip` `clear` inside the nearer edge of `visible`, or to the edge
    /// itself where the strip has no room for that. A scroll anchor lines up the same unit point
    /// of the chip and of the strip, so the chip lands `x` of the way across the room it leaves.
    static func anchor(chip: ClosedRange<CGFloat>, visible: ClosedRange<CGFloat>, clear: CGFloat = 0) -> UnitPoint? {
        let room = (visible.upperBound - visible.lowerBound) - (chip.upperBound - chip.lowerBound)
        let inset = room > 2 * clear ? clear : 0
        if chip.lowerBound < visible.lowerBound + inset - 0.5 { return UnitPoint(x: room > 0 ? inset / room : 0, y: 0.5) }
        if chip.upperBound > visible.upperBound - inset + 0.5 { return UnitPoint(x: room > 0 ? 1 - inset / room : 1, y: 0.5) }
        return nil
    }
}

private struct ChipSpanReport: ViewModifier {
    let ref: TabRef
    let spans: StripSpans

    func body(content: Content) -> some View {
        content.onGeometryChange(for: ClosedRange<CGFloat>.self) { proxy in
            let frame = proxy.frame(in: .named(StripSpans.space))
            return frame.minX...frame.maxX
        } action: { span in
            spans.chips[ref] = span
        }
    }
}

/// Which edges of the strip have chips running past them.
struct StripEdges: Equatable {
    var leading = false
    var trailing = false

    init() {}

    init(offset: CGFloat, content: CGFloat, container: CGFloat) {
        leading = offset > 0.5
        trailing = offset + container < content - 0.5
    }
}

private extension View {
    /// A soft fade where chips run past an edge, so a cut chip reads as more to scroll to; clear
    /// at the edge itself, so no sliver of a chip shows against what stands beside the strip.
    func stripEdgeFade(_ edges: StripEdges) -> some View {
        mask {
            HStack(spacing: 0) {
                StripEdgeFade(isFading: edges.leading, towards: .leading)
                Rectangle()
                StripEdgeFade(isFading: edges.trailing, towards: .trailing)
            }
        }
    }

    func tabChipWidth() -> some View {
        TabChipWidth(range: DS.Size.tabMinWidth...DS.Size.tabMaxWidth).callAsFunction { self }
    }
}

/// One edge of the strip's mask: opaque, or clear for `DS.Space.s` at the edge, then fading in.
private struct StripEdgeFade: View {
    let isFading: Bool
    let towards: HorizontalEdge

    var body: some View {
        // style-exempt: a mask, only its alpha counts
        let opaque = Color.black
        let edge = isFading ? Color.clear : opaque
        LinearGradient(
            stops: [
                .init(color: edge, location: 0),
                .init(color: edge, location: DS.Space.s / DS.Size.tabStripFade),
                .init(color: opaque, location: 1),
            ],
            startPoint: towards == .leading ? .leading : .trailing,
            endPoint: towards == .leading ? .trailing : .leading)
            .frame(width: DS.Size.tabStripFade)
    }
}

/// Lays a chip out at its own width, held within `range`: as wide as its title, never a
/// sliver and never the whole strip.
struct TabChipWidth: Layout {
    let range: ClosedRange<CGFloat>

    static func width(ideal: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(ideal.rounded(.up), range.lowerBound), range.upperBound)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let chip = subviews.first else { return .zero }
        let width = Self.width(ideal: chip.sizeThatFits(.unspecified).width, in: range)
        return CGSize(width: width, height: chip.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension EnvironmentValues {
    /// The strip's height, which each chip fills: its own band, or the title bar's row.
    @Entry var tabStripHeight = DS.Size.tabStrip
}

#if DEBUG
extension EnvironmentValues {
    /// Tests: each strip chip's frame in the window, whenever its layout changes.
    @Entry var tabChipFrames: (@MainActor (TabRef, CGRect) -> Void)?
}
#endif

private struct ChipFrameReport: ViewModifier {
    let ref: TabRef
    #if DEBUG
    @Environment(\.tabChipFrames) private var report
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if let report {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in report(ref, frame) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct TabChip: View {
    let tab: Tab
    let ref: TabRef
    let group: HostGroup
    let isActive: Bool
    /// The window holds tabs from more than one host: name the host under the title.
    let showsHost: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.tabStripHeight) private var stripHeight
    @Environment(\.chrome) private var chrome
    @State private var isHovered = false

    /// Inactive and away tabs dim by opacity rather than colour, so glyph colours survive; as far
    /// as the theme lets their titles still read at 4.5:1.
    private var opacity: Double {
        let inactive = isActive ? 1 : isHovered ? max(chrome.inactiveOpacity, DS.Opacity.inactiveHover) : chrome.inactiveOpacity
        return group.showsAsLive ? inactive : min(inactive, chrome.awayOpacity)
    }

    var body: some View {
        #if DEBUG
        let _ = ChromeRenders.note("tab-chip")
        #endif
        let workspace = model.workspace(ofGroup: group.id)
        let state = AgentState.mostUrgent(tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) })
        let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
        let program = model.programIdentity(of: tab, onGroup: group.id)
        HStack(spacing: DS.Space.row) {
            TabLeadingMark(program: program, state: state, isSelected: isActive)
                .attentionCue(trigger: model.attention.beat(of: ref))
            VStack(spacing: 0) {
                Text(title)
                    .lineLimit(1)
                    // A path keeps its end: the directory you are in.
                    .truncationMode(title.hasPrefix("/") || title.hasPrefix("~") ? .head : .tail)
                if showsHost {
                    Text(group.name)
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            if let state, state.statusMark == .pill {
                // The words where the title leaves room for them, else the symbol.
                ViewThatFits(in: .horizontal) {
                    StatePill(state)
                    StatePill(state, isCompact: true)
                }
                .motionTransition(.pill(anchor: .leading))
            } else if model.attention.contains(ref) {
                AttentionDot().motionTransition(.pill(anchor: .leading))
            }
            TabPresence(workspace: workspace, panes: tab.root.panes)
        }
        .font(DS.Font.tabTitle)
        .foregroundStyle(.primary)
        .opacity(opacity)
        // Room for the close button and the ⌘ hint, which sit over the edges.
        .padding(.horizontal, DS.Space.xxxl)
        .frame(maxWidth: .infinity)
        .frame(height: stripHeight)
        .background {
            if isActive {
                Color.clear
                    .surface(.selection, in: RoundedRectangle.rounded(DS.Radius.field))
                    .padding(.vertical, 3)
                    .motionTransition(.fade)
            } else if isHovered {
                RoundedRectangle.rounded(DS.Radius.field)
                    .fill(DS.Palette.hoverFill)
                    .padding(.vertical, 3)
            }
        }
        .overlay {
            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { model.closeTab(ref, undoable: false) }
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                    .help("Close Tab (⌘W)")
                Spacer(minLength: 0)
                if CommandKeyState.shared.held, let number = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(number)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.trailing, DS.Space.s)
                        .motionTransition(.fade)
                }
            }
            .padding(.leading, 3)
            .animation(DS.Motion.micro, value: CommandKeyState.shared.held)
        }
        .animation(DS.Motion.micro, value: isActive)
        .contentShape(.rect)
        .onTapGesture { model.focus(ref) }
        .onHover { hovering in withAnimation(DS.Motion.micro) { isHovered = hovering } }
        .contextMenu {
            if let workspace {
                Button("Rename…", systemImage: "pencil") {
                    model.focus(ref)
                    workspace.renamingTab = tab.id
                }
                if WindowRequest.isSupported {
                    Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openInNewWindow(ref) }
                }
                MergeIntoTabMenu(workspace: workspace, tab: tab.id)
                ProjectMenuItems(model: model, ref: ref)
                Button("Close Tab", systemImage: "xmark", role: .destructive) { model.closeTab(ref, undoable: false) }
            }
        }
        .tabDrag(ref, model: model)
        .dropDestination(for: String.self) { items, _ in
            // Takes the dragged tab's place in this tab's section (its project or host); only
            // that tab's own drag, not text that happens to arrive while it is remembered.
            guard let dragged = model.draggedTab, dragged != ref, items == [dragged.description],
                  let section = model.groups.sections.first(where: { $0.rows.contains(ref) }),
                  SidebarDrop.accepts(section.container, dragged),
                  let index = section.rows.firstIndex(of: ref)
            else { return false }
            model.draggedTab = nil
            withAnimation(DS.Motion.standard) { model.commit(.insert(dragged, into: section.container, at: index)) }
            return true
        }
        .help(Self.tooltip(
            title: title, host: group.isLocal ? nil : group.name, directory: workspace?.directory(of: tab), context: workspace?.context(of: tab),
            project: model.groups.project(of: ref)?.name))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TabLeadingMark.label(title: title, program: program, state: state, host: nil))
        .accessibilityValue(TabPresence.value(workspace, tab.root.panes))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tabbar-\(ref)")
    }

    /// The title, then where the tab is (project, host, directory) and what it is on (branch,
    /// program or task), each once.
    static func tooltip(title: String, host: String?, directory: String?, context: String?, project: String? = nil) -> String {
        var lines = [title]
        let place = [project, host, directory].compactMap(\.self).joined(separator: " · ")
        if !place.isEmpty, place != title { lines.append(place) }
        if let context, !context.isEmpty, context != title, context != directory, context != "~" { lines.append(context) }
        return lines.joined(separator: "\n")
    }
}

/// A tab's panes into another tab of its host, as a split on the right (a tab dragged onto a
/// pane's edge does the same, on that edge).
struct MergeIntoTabMenu: View {
    let workspace: Workspace
    let tab: TabId
    @Environment(WindowModel.self) private var model

    var body: some View {
        let targets = model.moveTargets(in: workspace, besides: tab)
        if !targets.isEmpty {
            Menu("Merge Into Tab", systemImage: "rectangle.split.2x1") {
                ForEach(targets) { target in
                    Button(workspace.title(of: target)) { model.mergeTab(tab, in: workspace, into: target) }
                }
            }
            .accessibilityIdentifier("tab-merge-into")
        }
    }
}
