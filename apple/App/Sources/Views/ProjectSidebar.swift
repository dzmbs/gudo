import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UniformTypeIdentifiers

// The sidebar's tab list is one flat list so a row moving between sections slides instead of
// fading. Dragging shows the drop as a plan applied to the rows (`SidebarDrop`); the drop commits
// that plan in the transaction that clears it, so nothing moves twice.

/// One line of the list. Ids are stable across sections: a tab's row is the same view whether it
/// sits in a project or under its host.
enum SidebarItem: Identifiable, Hashable {
    case projectHeader(ProjectPlace)
    /// An empty project's one line: where its tabs will go.
    case projectEmpty(ProjectPlace)
    case row(TabRef, SidebarContainer)
    /// One pane of a tab opened into its panes, under the tab's row.
    case pane(TabRef, PaneId, SidebarContainer)
    case windowHeader(WindowTabKind)
    case suggestion(ProjectSuggestion)
    /// The one-time line teaching drag-onto-tab grouping, before the first project.
    case projectsIntro
    /// "Restore 6 Tabs": tabs kept out of sight at launch.
    case restoreTabs(Int)
    /// "Close 6 Idle Tabs".
    case idleTabs(Int)
    case hostHeader(String)
    case repoFold(host: String, repo: String)
    case worktree(host: String, repo: String, path: String)
    case hostPlaceholder(String)

    var id: String {
        switch self {
        case .projectHeader(let place): "project/\(place.foldKey)"
        case .projectEmpty(let place): "project-empty/\(place.foldKey)"
        case .row(let ref, _): "tab/\(ref)"
        case .pane(let ref, let pane, _): "pane/\(ref)/\(pane.rawValue)"
        case .windowHeader(let kind): "window/\(kind.rawValue)"
        case .suggestion(let suggestion): "suggestion/\(suggestion.tabs.first?.hostId ?? "")/\(suggestion.key)"
        case .projectsIntro: "projects-intro"
        case .restoreTabs: "restore-tabs"
        case .idleTabs: "idle-tabs"
        case .hostHeader(let id): "host/\(id)"
        case .repoFold(let host, let repo): "repos/\(host)/\(repo)"
        case .worktree(let host, let repo, let path): "worktree/\(host)/\(repo)/\(path)"
        case .hostPlaceholder(let id): "placeholder/\(id)"
        }
    }
}

/// The window's own tabs, by kind.
enum WindowTabKind: String, CaseIterable {
    case editors, browsers, mixed

    var title: String {
        switch self {
        case .editors: "VS Code"
        case .browsers: "Browser"
        case .mixed: "Mixed"
        }
    }

    var systemImage: String {
        switch self {
        case .editors: "chevron.left.forwardslash.chevron.right"
        case .browsers: "globe"
        case .mixed: "rectangle.split.2x1"
        }
    }

    init(_ tab: CompositeTab) {
        self = tab.isEditorOnly ? .editors : tab.isBrowserOnly ? .browsers : .mixed
    }
}

/// What a drag over the sidebar would do, observed by the rows.
@MainActor
@Observable
final class SidebarDragState {
    /// The tab being dragged over the list.
    var dragging: TabRef?
    var plan: SidebarDrop?
    /// A project header being dragged, and where it would land.
    var draggedProject: ProjectPlace?
    var projectMove: (id: String, index: Int)?
    @ObservationIgnored var springTarget: String?
    @ObservationIgnored var springTask: Task<Void, Never>?

    func reset() {
        dragging = nil
        plan = nil
        projectMove = nil
        springTarget = nil
        springTask?.cancel()
    }

    func isGroupTarget(_ ref: TabRef) -> Bool {
        if case .group(_, let target) = plan { return target == ref }
        return false
    }
}

/// A row's frame in the list's space and in the window's.
nonisolated struct SidebarRowPlace: Equatable, Sendable {
    let frame: CGRect
    let frameInWindow: CGRect
}

/// Where each item is, for hit-testing a drag (not observed: frames change every layout).
@MainActor
final class SidebarGeometry {
    var frames: [String: CGRect] = [:]
    /// Where the list's space starts in the window's.
    var listOriginInWindow = CGPoint.zero
    /// The pinned headers' heights, as last drawn.
    var headerHeight: CGFloat = 40
    var hostHeaderHeight: CGFloat = 40
    let scroll = SidebarScroll()
    var items: [String: SidebarItem] = [:]
    /// The items' ids in list order.
    var order: [String] = []
    var sections: [SidebarSection] = []
    /// The list is grouped by host: a host's header pins over its rows too.
    var pinsHosts = false

    func item(at point: CGPoint) -> (SidebarItem, CGRect)? {
        for (id, frame) in frames where frame.contains(point) {
            if let item = items[id] { return (item, frame) }
        }
        return nil
    }

    func section(_ container: SidebarContainer) -> SidebarSection {
        sections.first { $0.container == container } ?? SidebarSection(container, rows: [])
    }
}

extension WindowModel {
    /// The list's items with `drop` and `projectMove` shown as if done.
    func sidebarItems(
        drop: SidebarDrop?, projectMove: (id: String, index: Int)?, showsIntro: Bool = false, opensPanes: Bool = false,
        showsEmptyProjects: Bool = false
    ) -> (items: [SidebarItem], sections: [SidebarSection]) {
        let hostGroups = groups.groups
        var sections = groups.sections
        if let drop {
            // A selection dragged by one of its rows moves together.
            sections = drop.carrying(carriedTabs(dragging: drop.dragged), in: sections).reduce(sections) { $1.applied(to: $0) }
        }
        func rows(_ container: SidebarContainer) -> [TabRef] {
            sections.first { $0.container == container }?.rows ?? []
        }
        // A tab still arriving gets its row with its content.
        let arriving = arrivingTab
        func tabItems(_ refs: [TabRef], in container: SidebarContainer) -> [SidebarItem] {
            refs.filter { $0 != arriving }.flatMap { ref -> [SidebarItem] in
                guard opensPanes, expandedTabs.contains(ref),
                      let panes = groups.group(ref.hostId)?.tabs.first(where: { $0.id == ref.tab })?.root.panes, panes.count > 1
                else { return [.row(ref, container)] }
                return [.row(ref, container)] + panes.map { .pane(ref, $0, container) }
            }
        }
        var projects = self.projects
        if let projectMove, let from = projects.firstIndex(where: { $0.id == projectMove.id }) {
            let moving = projects.remove(at: from)
            projects.insert(moving, at: min(max(projectMove.index, 0), projects.count))
        }
        let byHost = hostGroups.count > 1
        let shownSections = Set(sections.map(\.container))
        func projectItems(_ place: ProjectPlace) -> [SidebarItem] {
            let members = rows(place.container)
            // A host's part of a project goes with its last row there, as the drop leaves it.
            guard place.host == nil || !members.isEmpty else { return [] }
            guard !self.groups.isCollapsed(place) else { return [.projectHeader(place)] }
            let empty: [SidebarItem] = members.isEmpty && showsEmptyProjects ? [.projectEmpty(place)] : []
            return [.projectHeader(place)] + tabItems(members, in: place.container) + empty
        }
        var items: [SidebarItem] = []
        let restorable = groups.restoreDismissed ? 0 : groups.restorableTabs.count
        if restorable > 0 { items.append(.restoreTabs(restorable)) }
        if !idleTabs.isEmpty { items.append(.idleTabs(idleTabs.count)) }
        for project in projects where !byHost || shownSections.contains(.project(project.id)) {
            items += projectItems(ProjectPlace(project.id))
        }
        let suggestions = projectSuggestions.prefix(2)
        if !byHost { items += suggestions.map(SidebarItem.suggestion) }
        // Before the first project, once, while there is something to group.
        if showsIntro, projects.isEmpty, suggestions.isEmpty, groups.tabs.count >= 2 {
            items.append(.projectsIntro)
        }
        let window = rows(.window)
        for kind in WindowTabKind.allCases {
            let refs = window.filter { ref in composites.tab(ref.tab).map(WindowTabKind.init) == kind }
            guard !refs.isEmpty else { continue }
            items.append(.windowHeader(kind))
            items += tabItems(refs, in: .window)
        }
        for group in hostGroups {
            items.append(.hostHeader(group.id))
            guard !self.groups.collapsed.contains(group.id) else { continue }
            items += tabItems(rows(.host(group.id)), in: .host(group.id))
            if byHost {
                items += suggestions.filter { $0.tabs.first?.hostId == group.id }.map(SidebarItem.suggestion)
                for project in projects where shownSections.contains(.hostProject(host: group.id, project: project.id)) {
                    items += projectItems(ProjectPlace(project.id, on: group.id))
                }
            }
            if let sidebar = self.groups.repoSidebar(for: group) {
                for repo in sidebar.repos {
                    let fold = WorktreeFold(repo)
                    guard !fold.folded.isEmpty else { continue }
                    items.append(.repoFold(host: group.id, repo: repo.id))
                    if WorktreeFoldStore.shared.isExpanded(repo: repo.id, host: group.id) {
                        items += fold.folded.map { .worktree(host: group.id, repo: repo.id, path: $0.id) }
                    }
                }
            }
            if group.tabs.isEmpty { items.append(.hostPlaceholder(group.id)) }
        }
        return (items, sections)
    }
}

/// A section of the compact tab switcher: a project's tabs, the window's own, or a host's tabs
/// outside any project.
struct SwitcherSection: Identifiable, Equatable {
    enum Kind: Hashable {
        case project(ProjectPlace)
        case window
        case host(String)
    }

    let kind: Kind
    let tabs: [TabRef]
    var id: Kind { kind }
}

extension WindowModel {
    /// The switcher's sections in the sidebar's order: projects, the window's tabs, then hosts
    /// (grouped by host, each host's projects after its own tabs). Every tab is listed once.
    var switcherSections: [SwitcherSection] {
        groups.sections.compactMap { section in
            switch section.container {
            case .window: section.rows.isEmpty ? nil : SwitcherSection(kind: .window, tabs: section.rows)
            case .host(let id): SwitcherSection(kind: .host(id), tabs: section.rows)
            case .project, .hostProject: section.container.projectPlace.map { SwitcherSection(kind: .project($0), tabs: section.rows) }
            }
        }
    }

    /// Under a project's name in the switcher: where its tabs run and how many there are.
    func switcherSubtitle(of project: Project, in place: ProjectPlace? = nil) -> String {
        let tabs = place.map(groups.rows(of:)) ?? project.tabs
        guard !tabs.isEmpty else { return "No tabs" }
        let count = tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs"
        let hosts = Set(tabs.map(\.hostId))
        let location = hosts.count > 1 ? "\(hosts.count) hosts" : groupName(place?.host ?? tabs[0].hostId)
        return "\(location) · \(count)"
    }
}

/// The list itself, with one drop target over all of it.
struct SidebarTabList: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.sidebarListStyle) private var listStyle
    let geometry: SidebarGeometry
    @AppStorage(ProjectsIntroRow.dismissedKey) private var introDismissed = false
    nonisolated private static let space = "sidebar-list"

    var body: some View {
        #if DEBUG
        let _ = ChromeRenders.note("sidebar-list")
        #endif
        let drag = model.sidebarDrag
        let (items, sections) = model.sidebarItems(
            drop: drag.plan, projectMove: drag.projectMove, showsIntro: !introDismissed, opensPanes: listStyle == .plain,
            showsEmptyProjects: listStyle == .grouped)
        let numbers = Dictionary(model.groups.tabs.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        let byHost = model.groups.groupsByHost
        let _ = geometry.record(items, sections, pinsHosts: byHost)
        Group {
            ForEach(items) { item in
                SidebarItemView(item: item, numbers: numbers)
                    .environment(\.groupedRowPosition, Self.position(of: item, in: items))
                    .environment(\.sidebarIndent, byHost && item.isUnderHost ? SidebarIndent.level : 0)
                    .motionTransition(.row)
                    .onGeometryChange(for: SidebarRowPlace.self) { proxy in
                        SidebarRowPlace(frame: proxy.frame(in: .named(Self.space)), frameInWindow: proxy.frame(in: .global))
                    } action: { place in
                        geometry.place(item.id, place)
                    }
                    // A row the list stops showing keeps no frame: frames are of rows on screen.
                    .onDisappear { geometry.place(item.id, nil) }
            }
        }
        .environment(\.sidebarGroupedByHost, byHost)
        .animation(DS.Motion.standard, value: items)
        // Taught once: the first project, however made, retires the hint for good.
        .onChange(of: model.projects.isEmpty, initial: true) { _, empty in
            if !empty, !introDismissed { introDismissed = true }
        }
    }
}

extension SidebarTabList {
    /// Rows of one section (and a project's empty row) draw as one card in the grouped list.
    static func position(of item: SidebarItem, in items: [SidebarItem]) -> GroupedRowPosition {
        guard let index = items.firstIndex(of: item), let section = item.cardSection else { return .alone }
        let previous = index > items.startIndex ? items[index - 1].cardSection : nil
        let next = index < items.index(before: items.endIndex) ? items[index + 1].cardSection : nil
        return GroupedRowPosition(isFirst: previous != section, isLast: next != section)
    }
}

private extension SidebarItem {
    /// The card a row belongs to: its section's container.
    var cardSection: String? {
        switch self {
        case .row(_, let container), .pane(_, _, let container): "\(container)"
        case .projectEmpty(let place): "\(place.container)"
        default: nil
        }
    }
}

extension SidebarItem {
    /// The host whose section holds this line, in a list grouped by host (its header included).
    var hostSection: String? {
        switch self {
        case .hostHeader(let id), .hostPlaceholder(let id), .repoFold(let id, _), .worktree(let id, _, _): id
        case .projectHeader(let place), .projectEmpty(let place): place.host
        case .row(_, let container), .pane(_, _, let container):
            switch container {
            case .host(let id), .hostProject(let id, _): id
            case .project, .window: nil
            }
        case .suggestion(let suggestion): suggestion.tabs.first?.hostId
        case .windowHeader, .projectsIntro, .restoreTabs, .idleTabs: nil
        }
    }

    /// A line inside a host's section, drawn a level in from the host's header.
    var isUnderHost: Bool {
        if case .hostHeader = self { return false }
        return hostSection != nil
    }
}

/// How far a host's lines sit in from its header, in a list grouped by host.
enum SidebarIndent {
    static let level = DS.Space.m
}

extension SidebarGeometry {
    /// Where a row is, or nil once the list stops showing it, and the pinned header that follows
    /// from it: worked out as the rows report each layout, so the header moves with them.
    func place(_ id: String, _ place: SidebarRowPlace?) {
        frames[id] = place?.frame
        if let place {
            listOriginInWindow = CGPoint(x: place.frameInWindow.minX - place.frame.minX, y: place.frameInWindow.minY - place.frame.minY)
        }
        pin()
    }

    func pin() {
        // Across the rows' own width, inside the list's margins.
        guard let row = frames.values.first else {
            if scroll.pinned != nil { scroll.pinned = nil }
            return
        }
        let edge = listOriginInWindow.y + scroll.top
        func frame(top: CGFloat, offset: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: listOriginInWindow.x + row.minX, y: listOriginInWindow.y + top + offset, width: row.width, height: height)
        }
        let host = pinsHosts ? StickyProjectHeader.pinnedHost(in: self, top: scroll.top, height: hostHeaderHeight) : nil
        // Under the host's pinned header, the project's pins at that header's foot.
        let projectTop = host.map { scroll.top + $0.offset + hostHeaderHeight } ?? scroll.top
        let project = StickyProjectHeader.pinned(in: self, top: projectTop, height: headerHeight)
        let pinned: PinnedHeaders? = host == nil && project == nil ? nil : PinnedHeaders(
            edge: edge,
            host: host.map { ($0.host, frame(top: scroll.top, offset: $0.offset, height: hostHeaderHeight)) },
            project: project.map { ($0.project, frame(top: projectTop, offset: $0.offset, height: headerHeight)) })
        if scroll.pinned != pinned { scroll.pinned = pinned }
    }
}

private extension SidebarGeometry {
    func record(_ items: [SidebarItem], _ sections: [SidebarSection], pinsHosts: Bool) {
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        order = items.map(\.id)
        frames = frames.filter { self.items[$0.key] != nil }
        self.sections = sections
        self.pinsHosts = pinsHosts
    }
}

private struct SidebarItemView: View {
    let item: SidebarItem
    let numbers: [TabRef: Int]
    @Environment(WindowModel.self) private var model
    @Environment(\.chrome) private var chrome

    var body: some View {
        switch item {
        case .projectHeader(let place):
            if let project = model.groups.project(place.project) { ProjectHeader(project: project, place: place) }
        case .projectEmpty(let place):
            if let project = model.groups.project(place.project) { ProjectEmptyRow(project: project, place: place) }
        case .row(let ref, let container):
            SidebarTabRow(ref: ref, container: container, number: numbers[ref] ?? 0)
        case .pane(let ref, let pane, _):
            if let group = model.groups.group(ref.hostId), let tab = group.tabs.first(where: { $0.id == ref.tab }) {
                PaneTreeRow(pane: pane, group: group, isFocusedPane: model.currentTab == ref && tab.focused == pane)
            }
        case .windowHeader(let kind):
            WindowTabsHeader(kind: kind)
        case .suggestion(let suggestion):
            SuggestionRow(suggestion: suggestion)
        case .projectsIntro:
            ProjectsIntroRow()
        case .restoreTabs(let count):
            RestoreTabsRow(count: count)
        case .idleTabs(let count):
            IdleTabsRow(count: count)
        case .hostHeader(let id):
            if let group = model.groups.group(id) { HostGroupHeaderItem(group: group) }
        case .repoFold(let host, let repoID):
            if let group = model.groups.group(host), let repo = model.groups.repoSidebar(for: group)?.repos.first(where: { $0.id == repoID }) {
                let folds = WorktreeFoldStore.shared
                RepoFoldRow(repo: repo, fold: WorktreeFold(repo), host: host, expanded: folds.isExpanded(repo: repoID, host: host)) {
                    withAnimation(DS.Motion.standard) { folds.toggle(repo: repoID, host: host) }
                }
                .padding(.top, DS.Space.xs)
                .opacity(group.showsAsLive ? 1 : chrome.awayOpacity)
            }
        case .worktree(let host, let repoID, let path):
            if let group = model.groups.group(host),
               let repo = model.groups.repoSidebar(for: group)?.repos.first(where: { $0.id == repoID }),
               let worktree = repo.worktrees.first(where: { $0.id == path }) {
                WorktreeRow(worktree: worktree.state, host: host)
                    .opacity(group.showsAsLive ? 1 : chrome.awayOpacity)
            }
        case .hostPlaceholder(let id):
            if let group = model.groups.group(id) { GroupPlaceholder(group: group) }
        }
    }
}

/// A tab's row in any section: a host tab or one of the window's own. Rows in a project name
/// their host when there is more than one.
private struct SidebarTabRow: View {
    let ref: TabRef
    let container: SidebarContainer
    let number: Int
    @Environment(WindowModel.self) private var model
    @Environment(SidebarDragState.self) private var drag

    var body: some View {
        let project: Project? = if case .project(let id) = container { model.groups.project(id) } else { nil }
        let isGroupTarget = drag.isGroupTarget(ref)
        let joined = model.joinedTab == ref
        let tint: ChromeStyle = model.groups.project(of: ref).map { DS.Palette.project($0.color) } ?? DS.Palette.accent
        content(showsHost: project != nil && model.groups.groups.count > 1)
            // What the drop will do, said quietly where the row's trailing glyphs sit.
            .overlay(alignment: .trailing) {
                if isGroupTarget, let dragged = drag.dragging {
                    Text(model.groupLabel(dragged, onto: ref))
                        .font(DS.Font.meta.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, 2)
                        .background(DS.Palette.sidebar, in: .capsule)
                        .overlay(Capsule().fill(DS.Palette.container(tint)))
                        .padding(.trailing, DS.Space.l)
                        .motionTransition(.pill(anchor: .trailing))
                        .accessibilityHidden(true)
                }
            }
            // Selected for bulk actions: the selection tint, under the row's own fills.
            .background {
                if model.isInMultipleSelection(ref) {
                    RoundedRectangle.rounded(DS.Radius.control)
                        .fill(DS.Palette.selection)
                        .padding(.horizontal, DS.Space.s)
                        .motionTransition(.fade)
                }
            }
            .animation(DS.Motion.micro, value: model.isInMultipleSelection(ref))
            // "Will group": the row lights in the project's colour (the accent for a loose one).
            .background {
                RoundedRectangle.rounded(DS.Radius.control)
                    .fill(DS.Palette.container(tint))
                    .overlay(RoundedRectangle.rounded(DS.Radius.control).strokeBorder(tint, lineWidth: 1.5).opacity(isGroupTarget ? 1 : 0))
                    .opacity(isGroupTarget || joined ? 1 : 0)
                    .padding(.horizontal, DS.Space.s)
            }
            .scaleEffect(isGroupTarget ? 1.015 : 1)
            // The dragged row leaves a gap where it will land: it never slides over its
            // neighbours, they make room around it.
            .opacity(drag.dragging == ref ? 0 : 1)
            .animation(DS.Motion.standard, value: isGroupTarget)
            // Gone at once (the lifted preview covers it); back with a short fade on the drop.
            .animation(drag.dragging == ref ? nil : DS.Motion.micro, value: drag.dragging == ref)
            .sidebarTabDrag(ref, model: model, drag: drag, title: dragTitle)
    }

    /// The lifted row's words: the tab, or how many tabs move with it.
    private var dragTitle: String {
        let carried = model.carriedTabs(dragging: ref).count
        return carried > 0 ? "\(carried + 1) Tabs" : model.title(ofTab: ref)
    }

    @ViewBuilder private func content(showsHost: Bool) -> some View {
        if ref.hostId == HostGroups.mixedId {
            if let tab = model.composites.tab(ref.tab) { MixedTabRow(tab: tab, number: number) }
        } else if let group = model.groups.group(ref.hostId), let tab = group.tabs.first(where: { $0.id == ref.tab }) {
            TabRow(tab: tab, ref: ref, number: number, group: group, showsHost: showsHost)
        }
    }
}

extension View {
    /// Drags a tab from the sidebar with a lifted preview of its row.
    func sidebarTabDrag(_ ref: TabRef, model: WindowModel, drag: SidebarDragState, title: String) -> some View {
        onDrag {
            model.draggedTab = ref
            drag.draggedProject = nil
            return TabDrag.provider(for: ref, in: model)
        } preview: {
            DragLiftPreview(title: title, systemImage: nil)
        }
    }
}

/// What follows the pointer or finger: the row lifted off the list, a raised card with a shadow.
private struct DragLiftPreview: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: DS.Space.row) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(DS.Palette.textSecondary) }
            Text(title).font(SidebarFont.title).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minWidth: 160, alignment: .leading)
        // The system draws the preview as an image, which glass would not survive.
        .surface(.card, in: RoundedRectangle.rounded(DS.Radius.control), fill: DS.Palette.raised)
        .chromeContent()
    }
}

/// One drop target over the whole list: the pointer's place picks the row or header under it.
struct SidebarDropDelegate: DropDelegate {
    let model: WindowModel
    let drag: SidebarDragState
    let geometry: SidebarGeometry

    func validateDrop(info: DropInfo) -> Bool { info.isTabDrag && (model.draggedTab != nil || drag.draggedProject != nil) }

    func dropEntered(info: DropInfo) {
        drag.dragging = drag.draggedProject == nil ? model.draggedTab : nil
        update(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(DS.Motion.standard) { drag.reset() }
    }

    func performDrop(info: DropInfo) -> Bool {
        update(info.location)
        let plan = drag.plan, move = drag.projectMove
        // The rows already show the result: commit it in the same transaction that ends the
        // preview, so they stay where they are.
        withAnimation(DS.Motion.standard) {
            if let plan { model.commit(plan) }
            if let move { model.moveProject(move.id, to: move.index) }
            drag.reset()
        }
        model.draggedTab = nil
        drag.draggedProject = nil
        return plan != nil || move != nil
    }

    private func update(_ point: CGPoint) {
        guard let (item, frame) = geometry.item(at: point) else { return }
        if let project = drag.draggedProject {
            updateProjectMove(project, over: item)
            return
        }
        guard let ref = model.draggedTab else { return }
        var next = drag.plan
        var springTarget: String?
        switch item {
        case .pane(let target, _, let container):
            if target != ref {
                next = SidebarDrop.plan(dragging: ref, over: target, at: 1, in: geometry.section(container)) ?? next
            }
        case .row(let target, let container):
            if target == ref {
                if case .group = next { next = nil }
            } else {
                let fraction = frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5
                next = SidebarDrop.plan(dragging: ref, over: target, at: fraction, in: geometry.section(container)) ?? next
            }
        case .projectHeader(let place), .projectEmpty(let place):
            // A tab from another host joins the project where its own host shows it.
            let landing = geometry.pinsHosts && !SidebarDrop.accepts(place.container, ref)
                ? ProjectPlace(place.project, on: model.groups.home(of: ref)) : place
            let rows = geometry.section(landing.container).rows
            if !rows.contains(ref) { next = .insert(ref, into: landing.container, at: rows.count) }
            if model.groups.isCollapsed(place) { springTarget = place.foldKey }
        case .hostHeader(let id), .hostPlaceholder(let id):
            if ref.hostId == id, !geometry.section(.host(id)).rows.contains(ref) {
                next = .insert(ref, into: .host(id), at: 0)
            }
        case .repoFold(let id, _), .worktree(let id, _, _):
            let rows = geometry.section(.host(id)).rows
            if ref.hostId == id, !rows.contains(ref) {
                next = .insert(ref, into: .host(id), at: rows.count)
            }
        case .windowHeader:
            if ref.hostId == HostGroups.mixedId, !geometry.section(.window).rows.contains(ref) {
                next = .insert(ref, into: .window, at: 0)
            }
        case .suggestion, .projectsIntro, .restoreTabs, .idleTabs:
            break
        }
        if next != drag.plan {
            withAnimation(DS.Motion.standard) { drag.plan = next }
        }
        springOpen(springTarget)
    }

    /// A collapsed project opens when a drag rests on its header (spring-loaded folders).
    private func springOpen(_ id: String?) {
        guard id != drag.springTarget else { return }
        drag.springTask?.cancel()
        drag.springTarget = id
        guard let id else { return }
        drag.springTask = Task { @MainActor [drag, model] in
            try? await Task.sleep(for: DS.Motion.springOpenDelay)
            guard !Task.isCancelled, drag.springTarget == id else { return }
            _ = withAnimation(DS.Motion.standard) { model.groups.collapsedProjects.remove(id) }
        }
    }

    /// Projects reorder among their neighbours under the same host.
    private func updateProjectMove(_ dragged: ProjectPlace, over item: SidebarItem) {
        let target: ProjectPlace? = switch item {
        case .projectHeader(let other), .projectEmpty(let other): other
        case .row(_, let container): container.projectPlace
        default: nil
        }
        let order = model.projects.map(\.id)
        guard let target, target.host == dragged.host, let index = order.firstIndex(of: target.project) else { return }
        let id = dragged.project
        let move: (id: String, index: Int)? = index == order.firstIndex(of: id) ? nil : (id, index)
        if move?.id != drag.projectMove?.id || move?.index != drag.projectMove?.index {
            withAnimation(DS.Motion.standard) { drag.projectMove = move }
        }
    }
}

// MARK: - Project header

/// A project's mark: a small rounded square in its colour, lit from above, the head of the
/// thread its rows carry.
struct ProjectMark: View {
    let project: Project

    var body: some View {
        let fill = DS.Palette.project(project.color)
        let size = SidebarFont.projectMark
        let shape = RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        shape
            .fill(fill)
            // Light from above, in the theme's own text colour; the mask only fades it.
            .overlay(shape.fill(DS.Palette.text).opacity(0.3).blendMode(.overlay)
                // style-exempt: a mask, only its alpha counts
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)))
            .hairlineBorder(shape, style: DS.Palette.border)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Where the sidebar list shows its content, and the headers pinned over it: observed only by
/// the pinned headers.
@MainActor
@Observable
final class SidebarScroll {
    /// Where the list's content starts under the window's bars, in the list's own space.
    @ObservationIgnored var top: CGFloat = 0
    /// Where it ends over the footer.
    @ObservationIgnored var bottom: CGFloat = 0
    var pinned: PinnedHeaders?
}

/// The headers pinned over the list, in the window's space: the host's whose section runs
/// under the top edge (in a list grouped by host), and under it the project's. Each sits at
/// its edge, or above it, pushed up by the end of its rows; as wide as the rows.
struct PinnedHeaders: Equatable {
    /// Where the list's content starts under the window's bars.
    let edge: CGFloat
    let host: String?
    let hostFrame: CGRect
    let project: ProjectPlace?
    let projectFrame: CGRect

    init(edge: CGFloat, host: (id: String, frame: CGRect)?, project: (place: ProjectPlace, frame: CGRect)?) {
        self.edge = edge
        self.host = host?.id
        hostFrame = host?.frame ?? .zero
        self.project = project?.place
        projectFrame = project?.frame ?? .zero
    }
}

/// Which way the list scrolls to show a row: not at all while the row shows whole.
enum SidebarReveal: Equatable {
    case none, up, down

    /// `frames` holds only the rows the list has laid out; a row without one lies past the
    /// shown rows on one side, read from `order`.
    static func move(to target: String, in order: [String], frames: [String: CGRect], visible: ClosedRange<CGFloat>) -> SidebarReveal {
        if let frame = frames[target] {
            if frame.minY < visible.lowerBound { return .up }
            if frame.maxY > visible.upperBound { return .down }
            return .none
        }
        guard let index = order.firstIndex(of: target) else { return .none }
        let shown = order.indices.filter { frames[order[$0]].map { $0.maxY > visible.lowerBound && $0.minY < visible.upperBound } ?? false }
        guard let firstShown = shown.first, let lastShown = shown.last else { return .none }
        if index < firstShown { return .up }
        if index > lastShown { return .down }
        return .none
    }

    /// Where the row lands: at the bottom edge going down; going up, at the top just under
    /// what covers it (a pinned project header). An anchor aligns the same point of the row
    /// and of the viewport, so the row's top sits `covered` below the viewport's top.
    static func anchor(for move: SidebarReveal, covered: CGFloat, viewport: CGFloat, rowHeight: CGFloat) -> UnitPoint? {
        switch move {
        case .none: return nil
        case .down: return .bottom
        case .up:
            guard covered > 0, viewport > rowHeight else { return .top }
            return UnitPoint(x: 0.5, y: min(1, covered / (viewport - rowHeight)))
        }
    }
}

extension SidebarGeometry {
    /// Scrolls `proxy` so `ref`'s row shows whole, the least way, when it does not, in `animation`.
    func reveal(_ ref: TabRef, proxy: ScrollViewProxy, animation: Animation?) {
        guard let item = items.values.first(where: { if case .row(let row, _) = $0 { row == ref } else { false } }) else { return }
        let projectHeader = item.projectPlace.map { SidebarItem.projectHeader($0).id }
        let hostHeader = pinsHosts ? item.hostSection.map { SidebarItem.hostHeader($0).id } : nil
        let covered = [projectHeader, hostHeader].compactMap { $0.flatMap { frames[$0]?.height } }.reduce(0, +)
        let visible = scroll.top + covered...max(scroll.top + covered, scroll.bottom)
        let move = SidebarReveal.move(to: item.id, in: order, frames: frames, visible: visible)
        let rowHeight = frames[item.id]?.height ?? frames.values.map(\.height).min() ?? 0
        // The list's own least travel, which leaves a row in view where it is; only a row
        // under the pinned header needs an anchor of ours. Frames of rows the list has
        // scrolled away can be stale, so they never veto the scroll.
        let anchor = move == .up && covered > 0
            ? SidebarReveal.anchor(for: move, covered: covered, viewport: scroll.bottom - scroll.top, rowHeight: rowHeight) : nil
        withAnimation(animation) { proxy.scrollTo(item.id, anchor: anchor) }
    }
}

/// The header of the project whose rows run under the list's top edge, pinned there until the
/// end of its rows pushes it up, as list section headers do. Grouped by host, the host's header
/// pins above it the same way, until the next host's header pushes it up.
struct StickyProjectHeader: View {
    let geometry: SidebarGeometry
    @Environment(WindowModel.self) private var model
    @State private var frameInWindow = CGRect.zero

    var body: some View {
        let pinned = geometry.scroll.pinned
        ZStack(alignment: .top) {
            if let pinned, let place = pinned.project, let project = model.groups.project(place.project) {
                pinnedHeader(frame: pinned.projectFrame) {
                    ProjectHeader(project: project, place: place)
                        .environment(\.sidebarIndent, place.host == nil ? 0 : SidebarIndent.level)
                } height: { geometry.headerHeight = $0 }
            }
            // Over the project's header, which slides under it when pushed up.
            if let pinned, let host = pinned.host, let group = model.groups.group(host) {
                pinnedHeader(frame: pinned.hostFrame, rule: pinned.project == nil) {
                    HostGroupHeaderItem(group: group).environment(\.sidebarGroupedByHost, true)
                } height: { geometry.hostHeaderHeight = $0 }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-pinned-headers")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameInWindow = $0 }
        // A header pushed up leaves under the bars, not over them.
        .mask(alignment: .top) { Rectangle().padding(.top, max(0, (pinned?.edge ?? 0) - frameInWindow.minY)) }
    }

    private func pinnedHeader(
        frame: CGRect, rule: Bool = true, @ViewBuilder _ header: () -> some View, height: @escaping (CGFloat) -> Void
    ) -> some View {
        header()
            .padding(.leading, max(0, frame.minX - frameInWindow.minX))
            .padding(.trailing, max(0, frameInWindow.maxX - frame.maxX))
            .background(DS.Palette.sidebar)
            .overlay(alignment: .bottom) { if rule { Hairline(style: DS.Palette.separator) } }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                height(measured)
                geometry.pin()
            }
            .offset(y: frame.minY - frameInWindow.minY)
            .transition(.identity)
    }

    /// The project whose rows cross the top edge, and how far the end of its rows has pushed its
    /// header up. Read from the items at and below the edge: the list lets go of items as they
    /// pass under the window's bars, the project's own header among them.
    static func pinned(in geometry: SidebarGeometry, top: CGFloat, height: CGFloat) -> (project: ProjectPlace, offset: CGFloat)? {
        pinnedRun(in: geometry, top: top, height: height, of: \.projectPlace).map { ($0.run, $0.offset) }
    }

    /// The host whose section crosses the top edge, and how far the next host's header has
    /// pushed its header up.
    static func pinnedHost(in geometry: SidebarGeometry, top: CGFloat, height: CGFloat) -> (host: String, offset: CGFloat)? {
        pinnedRun(in: geometry, top: top, height: height, of: \.hostSection).map { ($0.run, $0.offset) }
    }

    private static func pinnedRun<Run: Equatable>(
        in geometry: SidebarGeometry, top: CGFloat, height: CGFloat, of run: (SidebarItem) -> Run?
    ) -> (run: Run, offset: CGFloat)? {
        let order = geometry.order
        guard let first = order.indices.first(where: { geometry.frames[order[$0]].map { $0.maxY > top } ?? false }),
              let firstFrame = geometry.frames[order[first]]
        else { return nil }
        let atEdge = firstFrame.minY < top ? first : first - 1
        guard order.indices.contains(atEdge), let item = geometry.items[order[atEdge]], let current = run(item),
              let last = order.lastIndex(where: { id in geometry.items[id].flatMap(run) == current })
        else { return nil }
        // Where the rows end: the next item's top, or the last row's end, once either is laid out.
        let bottom = (order.indices.contains(last + 1) ? geometry.frames[order[last + 1]]?.minY : nil)
            ?? geometry.frames[order[last]]?.maxY ?? .infinity
        guard bottom > top else { return nil }
        return (current, min(0, bottom - top - height))
    }
}

extension SidebarItem {
    /// The project and place a header or line belongs to.
    var projectPlace: ProjectPlace? {
        switch self {
        case .projectHeader(let place), .projectEmpty(let place): place
        case .row(_, let container), .pane(_, _, let container): container.projectPlace
        default: nil
        }
    }
}

/// What VoiceOver says for a project's header: "acme-app, on studio, project, 3 tabs". Grouped
/// by host, it names the host whose part of the project the header heads.
enum ProjectHeaderLabel {
    static func spoken(_ name: String, host: String?, tabs: Int) -> String {
        let count = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        return [name, host.map { "on \($0)" }, "project", count].compactMap(\.self).joined(separator: ", ")
    }
}

/// A project: its mark, name (renamed in place), tab count while collapsed and + New Terminal.
/// A click collapses it; dragging it reorders projects; its menu holds the rest.
private struct ProjectHeader: View {
    let project: Project
    /// Where this header stands: grouped by host, a project has one under each of its hosts.
    let place: ProjectPlace
    @Environment(WindowModel.self) private var model
    @Environment(SidebarDragState.self) private var drag
    @Environment(\.sidebarIndent) private var indent
    @Environment(\.chrome) private var chrome
    @State private var hovered = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let collapsed = model.groups.isCollapsed(place)
        let tabs = model.groups.rows(of: place)
        let host = place.host.flatMap(model.groups.group)
        // A tab joining from elsewhere lights the project it joins.
        let dropping = { if case .insert(let ref, let container, _)? = drag.plan { container == place.container && !tabs.contains(ref) } else { false } }()
        // Lined up with a host's header: its mark where the host's icon sits, its name where the
        // host's name starts, so the rows under both read as indented.
        HStack(spacing: DS.Space.s) {
            ProjectMark(project: project)
                .frame(minWidth: 16)
            if renaming {
                nameField
            } else {
                Text(project.name)
                    .font(SidebarFont.section)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: DS.Space.xs)
            if collapsed, !tabs.isEmpty {
                Text(tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs")
                    .monospacedDigit()
                    .font(SidebarFont.number)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .contentTransition(.numericText())
                if let state = model.mostUrgentState(of: tabs) {
                    StateMark(state).motionTransition(.pill())
                }
            }
            Button("New Terminal in \(project.name)", systemImage: "plus") { model.newTab(inProject: project.id, on: place.host) }
                .labelStyle(.iconOnly)
                .buttonStyle(.bar)
                .font(.callout)
                .opacity(controlsShown && canOpen(host) ? 1 : 0)
                .disabled(!canOpen(host))
                .accessibilityIdentifier(host.map { "project-new-tab-\(project.name)-\($0.name)" } ?? "project-new-tab-\(project.name)")
            // An empty project is its header alone: nothing to fold.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textTertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .opacity(!tabs.isEmpty && (controlsShown || collapsed) ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 28)
        .opacity(host.map { $0.showsAsLive ? 1 : chrome.awayOpacity } ?? 1)
        .padding(.leading, DS.Space.l + indent)
        .padding(.trailing, DS.Space.gap10)
        .padding(.top, DS.Space.m)
        .animation(DS.Motion.micro, value: controlsShown)
        .background {
            RoundedRectangle.rounded(DS.Radius.control)
                .fill(DS.Palette.project(project.color).opacity(dropping ? 0.14 : 0))
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Space.s)
        }
        // The name field of a project just made opens at once, its name selected, in the first
        // place the list shows it.
        .onChange(of: model.namingProject, initial: true) { _, id in
            if id == project.id, model.groups.places(of: project.id).first == place { startRename() }
        }
        .contentShape(.rect)
        // A click acts at once; the second click of a double-click renames instead of folding back.
        .onTapGesture {
            #if os(macOS)
            if NSApp.currentEvent?.clickCount == 2 { return startRename() }
            #endif
            withAnimation(DS.Motion.standard) { model.groups.toggleCollapsed(place) }
        }
        .onHover { hovered = $0 }
        .onDrag {
            drag.draggedProject = place
            model.draggedTab = nil
            return TabDrag.provider(forProject: project.id, in: model)
        } preview: {
            DragLiftPreview(title: project.name, systemImage: "square.fill")
        }
        .opacity(drag.projectMove?.id == project.id ? 0.4 : 1)
        .contextMenu { ProjectMenu(project: project, collapsed: collapsed, place: place) { startRename() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ProjectHeaderLabel.spoken(project.name, host: host?.name, tabs: tabs.count))
        .accessibilityHint(collapsed ? "Shows its tabs" : "Hides its tabs")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(host.map { "project-\(project.name)-\($0.name)" } ?? "project-\(project.name)")
        // Combined, the header's own tap and + are reached as its actions.
        .accessibilityAction { withAnimation(DS.Motion.standard) { model.groups.toggleCollapsed(place) } }
        .accessibilityAction(named: "New Terminal") { model.newTab(inProject: project.id, on: place.host) }
        .accessibilityAction(named: "Rename") { startRename() }
    }

    /// A project's + opens on its host while that host takes new tabs; across hosts, anywhere.
    private func canOpen(_ host: HostGroup?) -> Bool {
        host.map { $0.isLocal || $0.isReady } ?? true
    }

    private var controlsShown: Bool {
        #if os(macOS)
        hovered
        #else
        true
        #endif
    }

    private var nameField: some View {
        TextField("Project Name", text: $draft, selection: $selection)
            .textFieldStyle(.plain)
            .font(SidebarFont.section)
            .foregroundStyle(DS.Palette.text)
            .focused($fieldFocused)
            .onSubmit { finishRename() }
            #if os(macOS)
            .onExitCommand { finishRename(keep: true) }
            #endif
            .onChange(of: fieldFocused) { _, focused in if !focused { finishRename() } }
            // On the theme's own field surface, not the system's black field editor.
            .padding(.horizontal, DS.Space.xs)
            .fieldSurface(isFocused: fieldFocused, cornerRadius: DS.Radius.field)
            .accessibilityIdentifier("project-name-field")
    }

    private func startRename() {
        draft = project.name
        selection = TextSelection(range: draft.startIndex..<draft.endIndex)
        renaming = true
        // Once the field exists.
        Task { @MainActor in fieldFocused = true }
    }

    /// Return or leaving the field keeps what was typed; Escape keeps the name it had.
    private func finishRename(keep: Bool = false) {
        guard renaming else { return }
        renaming = false
        if model.namingProject == project.id { model.namingProject = nil }
        if !keep { model.renameProject(project.id, to: draft) }
    }
}

/// A project's menu: Rename, Colour, New Terminal, Collapse, Ungroup, Close All Tabs. Without
/// `collapsed` (the compact switcher, which has nothing to collapse) there is no Collapse. In a
/// `place` under one host, New Terminal, Ungroup and Close All Tabs act on that host's part.
struct ProjectMenu: View {
    let project: Project
    let collapsed: Bool?
    var place: ProjectPlace?
    let rename: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
        let place = place ?? ProjectPlace(project.id)
        Button("Rename…", systemImage: "pencil", action: rename)
        Menu("Colour") {
            ForEach(ProjectColor.names.indices, id: \.self) { index in
                Button {
                    model.setProjectColor(project.id, index)
                } label: {
                    Label {
                        Text(ProjectColor.names[index])
                    } icon: {
                        Image(systemName: index == project.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                .tint(DS.Palette.project(index))
            }
        }
        Button("New Terminal", systemImage: "terminal") { model.newTab(inProject: project.id, on: place.host) }
        if let collapsed {
            Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "chevron.down" : "chevron.right") {
                withAnimation(DS.Motion.standard) { model.groups.toggleCollapsed(place) }
            }
        }
        Divider()
        if project.tabs.isEmpty {
            Button("Delete Project", systemImage: "trash") {
                withAnimation(DS.Motion.standard) { model.ungroupProject(project.id) }
            }
        } else {
            Button("Ungroup", systemImage: "rectangle.stack.badge.minus") {
                withAnimation(DS.Motion.standard) { model.ungroup(place) }
            }
            Button("Close All Tabs", systemImage: "xmark.square", role: .destructive) { model.closeProject(place) }
        }
    }
}

/// New Project from Tab, Move to Project ▸, Remove from Project: the tab's project items, shared
/// by the row menus, the strip, the compact switcher and the Tab menu.
struct ProjectMenuItems: View {
    let model: WindowModel
    let ref: TabRef

    var body: some View {
        let current = model.groups.project(of: ref)
        let others = model.projects.filter { $0.id != current?.id }
        Button("New Project from Tab", systemImage: "folder.badge.plus") {
            withAnimation(DS.Motion.standard) { model.newProject(from: [ref]) }
        }
        if !others.isEmpty {
            Menu("Move to Project") {
                ForEach(others) { project in
                    Button(project.name) { withAnimation(DS.Motion.standard) { model.move(ref, toProject: project.id) } }
                }
            }
        }
        if let current {
            Button("Remove from \(current.name)", systemImage: "folder.badge.minus") {
                withAnimation(DS.Motion.standard) { model.removeFromProject(ref) }
            }
        }
    }
}

// MARK: - Other items

/// "Group 3 tabs in app": one tap makes the project; never made on its own.
private struct SuggestionRow: View {
    let suggestion: ProjectSuggestion
    @Environment(WindowModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Space.gap10) {
            Button {
                withAnimation(DS.Motion.standard) { model.accept(suggestion) }
            } label: {
                HStack(spacing: DS.Space.gap10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .frame(width: 16)
                    // Tabs of a folder that already has a project join it.
                    let joins = model.existingProject(for: suggestion) != nil
                    Text("\(joins ? "Add" : "Group") \(suggestion.tabs.count) tabs \(joins ? "to" : "in") \(Text(suggestion.name).foregroundStyle(DS.Palette.textSecondary))")
                        .font(SidebarFont.subtitle)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Not Now", systemImage: "xmark") { withAnimation(DS.Motion.standard) { model.dismiss(suggestion) } }
                .labelStyle(.iconOnly)
                .buttonStyle(.sidebarDismiss)
                .font(.caption2)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .sidebarRow(selected: false)
        .padding(.top, DS.Space.xs)
        .accessibilityIdentifier("project-suggestion-\(suggestion.name)")
    }
}

/// An empty project's line under its header: where its tabs go, and a tap makes one.
private struct ProjectEmptyRow: View {
    let project: Project
    let place: ProjectPlace
    @Environment(WindowModel.self) private var model
    @Environment(SidebarDragState.self) private var drag

    var body: some View {
        let dropping = { if case .insert(_, let container, _)? = drag.plan { container == place.container } else { false } }()
        let tint = DS.Palette.project(project.color)
        let size = SidebarFont.icon
        Button {
            model.newTab(inProject: project.id, on: place.host)
        } label: {
            HStack(spacing: DS.Space.gap10) {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(dropping ? AnyShapeStyle(tint) : AnyShapeStyle(DS.Palette.textTertiary))
                    .frame(width: size, height: size)
                Text(dropping ? "Drop to add" : "New Terminal")
                    .font(SidebarFont.title)
                    .foregroundStyle(dropping ? AnyShapeStyle(tint) : AnyShapeStyle(DS.Palette.textTertiary))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            // A drop lights the line in the project's colour.
            .background {
                RoundedRectangle.rounded(DS.Radius.control)
                    .fill(DS.Palette.container(tint))
                    .padding(.horizontal, -DS.Space.m)
                    .padding(.vertical, -DS.Space.row)
                    .opacity(dropping ? 1 : 0)
            }
            .sidebarRow(selected: false)
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.micro, value: dropping)
        .accessibilityLabel("No tabs in \(project.name). New Terminal, or drag a tab here")
        .accessibilityIdentifier("project-empty-\(project.name)")
    }
}

/// Taught once, before the first project: tabs group by dropping one onto another. Gone for
/// good when dismissed or once any project exists.
struct ProjectsIntroRow: View {
    static let dismissedKey = "projects.introDismissed"
    @AppStorage(dismissedKey) private var dismissed = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.gap10) {
            Image(systemName: "square.stack")
                .font(.caption)
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Group tabs into projects")
                    .font(SidebarFont.subtitle.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                Text("Drop a tab onto another tab, from any host.")
                    .font(SidebarFont.subtitle)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark") { withAnimation(DS.Motion.standard) { dismissed = true } }
                .labelStyle(.iconOnly)
                .buttonStyle(.sidebarDismiss)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Palette.textTertiary)
                .help("Don't show again")
                .accessibilityIdentifier("projects-intro-close")
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(DS.Palette.hoverFill, in: RoundedRectangle.rounded(DS.Radius.control))
        .padding(.horizontal, DS.Space.s)
        .padding(.top, DS.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects-intro")
    }
}

/// The header over the window's own tabs of one kind.
private struct WindowTabsHeader: View {
    let kind: WindowTabKind

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: kind.systemImage)
                .font(SidebarFont.section.weight(.regular))
                .imageScale(.small)
                .foregroundStyle(DS.Palette.textSecondary)
                .opacity(DS.Opacity.mutedGlyph)
                .frame(width: 16)
            Text(kind.title)
                .font(SidebarFont.section)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.gap10)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("host-group-\(kind.rawValue)")
    }
}
