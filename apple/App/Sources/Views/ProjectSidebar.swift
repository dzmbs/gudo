import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UniformTypeIdentifiers

// The sidebar's tab list (docs/APP-ARCHITECTURE.md §23): projects, the window's own tabs, then
// each host with its loose tabs, drawn as one flat list so a row moving between sections slides
// instead of fading. Dragging shows the drop as a plan applied to the rows (`SidebarDrop`); the
// drop commits that plan in the transaction that clears it, so nothing moves twice.

/// One line of the list. Ids are stable across sections: a tab's row is the same view whether it
/// sits in a project or under its host.
enum SidebarItem: Identifiable, Hashable {
    case projectHeader(String)
    case row(TabRef, SidebarContainer)
    case windowHeader(WindowTabKind)
    case suggestion(ProjectSuggestion)
    case hostHeader(String)
    /// A daemon's loose tabs grouped by repository (drawn as one block).
    case hostRepos(String)
    case hostPlaceholder(String)
    case hostAgents(String)

    var id: String {
        switch self {
        case .projectHeader(let id): "project/\(id)"
        case .row(let ref, _): "tab/\(ref)"
        case .windowHeader(let kind): "window/\(kind.rawValue)"
        case .suggestion(let suggestion): "suggestion/\(suggestion.key)"
        case .hostHeader(let id): "host/\(id)"
        case .hostRepos(let id): "repos/\(id)"
        case .hostPlaceholder(let id): "placeholder/\(id)"
        case .hostAgents(let id): "agents/\(id)"
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
    var draggedProject: String?
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

/// Where each item is, for hit-testing a drag (not observed: frames change every layout).
@MainActor
final class SidebarGeometry {
    var frames: [String: CGRect] = [:]
    var items: [String: SidebarItem] = [:]
    var sections: [SidebarSection] = []

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
    func sidebarItems(drop: SidebarDrop?, projectMove: (id: String, index: Int)?) -> (items: [SidebarItem], sections: [SidebarSection]) {
        let hostGroups = groups.groups
        var sections = groups.sections
        if let drop { sections = drop.applied(to: sections) }
        func rows(_ container: SidebarContainer) -> [TabRef] {
            sections.first { $0.container == container }?.rows ?? []
        }
        var projects = self.projects
        if let projectMove, let from = projects.firstIndex(where: { $0.id == projectMove.id }) {
            let moving = projects.remove(at: from)
            projects.insert(moving, at: min(max(projectMove.index, 0), projects.count))
        }
        var items: [SidebarItem] = []
        for project in projects {
            items.append(.projectHeader(project.id))
            if !self.groups.collapsedProjects.contains(project.id) {
                items += rows(.project(project.id)).map { .row($0, .project(project.id)) }
            }
        }
        items += projectSuggestions.prefix(2).map(SidebarItem.suggestion)
        let window = rows(.window)
        for kind in WindowTabKind.allCases {
            let refs = window.filter { ref in composites.tab(ref.tab).map(WindowTabKind.init) == kind }
            guard !refs.isEmpty else { continue }
            items.append(.windowHeader(kind))
            items += refs.map { .row($0, .window) }
        }
        let grouped = Set(self.projects.flatMap(\.tabs))
        for group in hostGroups {
            items.append(.hostHeader(group.id))
            guard !self.groups.collapsed.contains(group.id) else { continue }
            let loose = rows(.host(group.id))
            let looseTabs = group.tabs.filter { !grouped.contains(group.ref($0.id)) }
            if self.groups.repoSidebar(for: group, tabs: looseTabs).map({ !$0.repos.isEmpty }) == true {
                items.append(.hostRepos(group.id))
            } else {
                items += loose.map { .row($0, .host(group.id)) }
            }
            if group.tabs.isEmpty { items.append(.hostPlaceholder(group.id)) }
            items.append(.hostAgents(group.id))
        }
        return (items, sections)
    }
}

/// The list itself, with one drop target over all of it.
struct SidebarTabList: View {
    @Environment(WindowModel.self) private var model
    @State private var geometry = SidebarGeometry()
    private static let space = "sidebar-list"

    var body: some View {
        let drag = model.sidebarDrag
        let (items, sections) = model.sidebarItems(drop: drag.plan, projectMove: drag.projectMove)
        let numbers = Dictionary(model.groups.tabs.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let _ = geometry.record(items, sections)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                SidebarItemView(item: item, numbers: numbers)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { geometry.frames[item.id] = $0 }
            }
        }
        .coordinateSpace(.named(Self.space))
        .animation(DS.Motion.reorder, value: items)
        .onDrop(of: [.text], delegate: SidebarDropDelegate(model: model, drag: drag, geometry: geometry))
        .environment(drag)
    }
}

private extension SidebarGeometry {
    func record(_ items: [SidebarItem], _ sections: [SidebarSection]) {
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        frames = frames.filter { self.items[$0.key] != nil }
        self.sections = sections
    }
}

private struct SidebarItemView: View {
    let item: SidebarItem
    let numbers: [TabRef: Int]
    @Environment(WindowModel.self) private var model

    var body: some View {
        switch item {
        case .projectHeader(let id):
            if let project = model.groups.project(id) { ProjectHeader(project: project) }
        case .row(let ref, let container):
            SidebarTabRow(ref: ref, container: container, number: numbers[ref] ?? 0)
        case .windowHeader(let kind):
            WindowTabsHeader(kind: kind)
        case .suggestion(let suggestion):
            SuggestionRow(suggestion: suggestion)
        case .hostHeader(let id):
            if let group = model.groups.group(id) { HostGroupHeaderItem(group: group) }
        case .hostRepos(let id):
            if let group = model.groups.group(id) { HostReposItem(group: group, numbers: numbers) }
        case .hostPlaceholder(let id):
            if let group = model.groups.group(id) { GroupPlaceholder(group: group) }
        case .hostAgents(let id):
            if let group = model.groups.group(id) { GroupAgents(group: group, numbers: numbers) }
        }
    }
}

/// A tab's row in any section: a host tab or one of the window's own. Rows in a project carry
/// its colour as a thread down their leading edge and name their host.
private struct SidebarTabRow: View {
    let ref: TabRef
    let container: SidebarContainer
    let number: Int
    @Environment(WindowModel.self) private var model
    @Environment(SidebarDragState.self) private var drag

    var body: some View {
        let project: Project? = if case .project(let id) = container { model.groups.project(id) } else { nil }
        let isGroupTarget = drag.isGroupTarget(ref)
        let tint: ChromeStyle = model.groups.project(of: ref).map { DS.Palette.project($0.color) } ?? DS.Palette.accent
        content(showsHost: project != nil && model.groups.groups.count > 1)
            .overlay(alignment: .leading) {
                if let project {
                    // Rows touch, so the threads of a project's rows read as one line.
                    Rectangle()
                        .fill(DS.Palette.project(project.color))
                        .frame(width: 2)
                        .padding(.leading, DS.Space.s + 2)
                        .accessibilityHidden(true)
                }
            }
            // "Will group": the row lights in the project's colour (the accent for a loose one).
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(tint.opacity(isGroupTarget ? 0.16 : 0))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(tint.opacity(isGroupTarget ? 0.7 : 0), lineWidth: 1.5))
                    .padding(.horizontal, DS.Space.s)
            }
            .scaleEffect(isGroupTarget ? 1.015 : 1)
            // The dragged row leaves a gap where it will land (Finder, Safari): it never slides
            // over its neighbours, they make room around it.
            .opacity(drag.dragging == ref ? 0 : 1)
            .animation(DS.Motion.reorder, value: isGroupTarget)
            // Gone at once (the lifted preview covers it); back with a short fade on the drop.
            .animation(drag.dragging == ref ? nil : DS.Motion.quick, value: drag.dragging == ref)
            .sidebarTabDrag(ref, model: model, drag: drag, title: model.title(ofTab: ref))
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
            Text(title).font(DS.Font.sidebarTitle).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minWidth: 160, alignment: .leading)
        .background(DS.Palette.raised, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.border, lineWidth: 0.5))
        .shadow(DS.Shadow.float)
        .chromeContent()
    }
}

/// One drop target over the whole list: the pointer's place picks the row or header under it.
private struct SidebarDropDelegate: DropDelegate {
    let model: WindowModel
    let drag: SidebarDragState
    let geometry: SidebarGeometry

    func validateDrop(info: DropInfo) -> Bool { model.draggedTab != nil || drag.draggedProject != nil }

    func dropEntered(info: DropInfo) {
        drag.dragging = drag.draggedProject == nil ? model.draggedTab : nil
        update(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(DS.Motion.reorder) { drag.reset() }
    }

    func performDrop(info: DropInfo) -> Bool {
        update(info.location)
        let plan = drag.plan, move = drag.projectMove
        // The rows already show the result: commit it in the same transaction that ends the
        // preview, so they stay where they are.
        withAnimation(DS.Motion.reorder) {
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
        case .row(let target, let container):
            if target == ref {
                if case .group = next { next = nil }
            } else {
                let fraction = frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5
                next = SidebarDrop.plan(dragging: ref, over: target, at: fraction, in: geometry.section(container)) ?? next
            }
        case .projectHeader(let id):
            let rows = geometry.section(.project(id)).rows
            if !rows.contains(ref) { next = .insert(ref, into: .project(id), at: rows.count) }
            if model.groups.collapsedProjects.contains(id) { springTarget = id }
        case .hostHeader(let id), .hostRepos(let id), .hostPlaceholder(let id):
            if ref.hostId == id, !geometry.section(.host(id)).rows.contains(ref) {
                next = .insert(ref, into: .host(id), at: 0)
            }
        case .windowHeader:
            if ref.hostId == HostGroups.mixedId, !geometry.section(.window).rows.contains(ref) {
                next = .insert(ref, into: .window, at: 0)
            }
        case .suggestion, .hostAgents:
            break
        }
        if next != drag.plan {
            withAnimation(DS.Motion.reorder) { drag.plan = next }
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
            _ = withAnimation(DS.Motion.reorder) { model.groups.collapsedProjects.remove(id) }
        }
    }

    private func updateProjectMove(_ id: String, over item: SidebarItem) {
        let target: String? = switch item {
        case .projectHeader(let other): other
        case .row(_, .project(let other)): other
        default: nil
        }
        let order = model.projects.map(\.id)
        guard let target, let index = order.firstIndex(of: target) else { return }
        let move: (id: String, index: Int)? = index == order.firstIndex(of: id) ? nil : (id, index)
        if move?.id != drag.projectMove?.id || move?.index != drag.projectMove?.index {
            withAnimation(DS.Motion.reorder) { drag.projectMove = move }
        }
    }
}

// MARK: - Project header

/// A project: its colour, name (renamed in place), tab count while collapsed and + New Terminal.
/// A tap collapses it; dragging it reorders projects; its menu holds the rest.
private struct ProjectHeader: View {
    let project: Project
    @Environment(WindowModel.self) private var model
    @Environment(SidebarDragState.self) private var drag
    @State private var hovered = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let collapsed = model.groups.collapsedProjects.contains(project.id)
        // A tab joining from elsewhere lights the project it joins.
        let dropping = { if case .insert(let ref, .project(let id), _)? = drag.plan { id == project.id && !project.tabs.contains(ref) } else { false } }()
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill(DS.Palette.project(project.color))
                .frame(width: 8, height: 8)
                .frame(minWidth: 16)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(DS.Font.section)
                    .focused($fieldFocused)
                    .onSubmit(finishRename)
                    #if os(macOS)
                    .onExitCommand { renaming = false }
                    #endif
                    .onChange(of: fieldFocused) { _, focused in if !focused { finishRename() } }
            } else {
                Text(project.name)
                    .font(DS.Font.section)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: DS.Space.xs)
            if collapsed {
                Text("\(project.tabs.count)")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .contentTransition(.numericText())
            }
            Button("New Terminal in \(project.name)", systemImage: "plus") { model.newTab(inProject: project.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.bar)
                .font(.callout)
                .opacity(plusEmphasized ? 1 : 0.45)
                .accessibilityIdentifier("project-new-tab-\(project.name)")
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.gap10)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Palette.project(project.color).opacity(dropping ? 0.14 : 0))
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Space.s)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(DS.Motion.snappy) { model.groups.toggleCollapsed(project: project.id) } }
        .onHover { hovered = $0 }
        .onDrag {
            drag.draggedProject = project.id
            model.draggedTab = nil
            return NSItemProvider(object: "project:\(project.id)" as NSString)
        } preview: {
            DragLiftPreview(title: project.name, systemImage: "circle.fill")
        }
        .opacity(drag.projectMove?.id == project.id ? 0.4 : 1)
        .contextMenu { ProjectMenu(project: project, collapsed: collapsed) { startRename() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), project, \(project.tabs.count) tabs")
        .accessibilityHint(collapsed ? "Shows its tabs" : "Hides its tabs")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("project-\(project.name)")
        .accessibilityAction(named: "Rename") { startRename() }
    }

    private var plusEmphasized: Bool {
        #if os(macOS)
        hovered
        #else
        true
        #endif
    }

    private func startRename() {
        draft = project.name
        renaming = true
        fieldFocused = true
    }

    private func finishRename() {
        guard renaming else { return }
        renaming = false
        model.renameProject(project.id, to: draft)
    }
}

/// A project's menu: Rename, Colour, New Terminal, Collapse, Ungroup, Close All Tabs. Without
/// `collapsed` (the compact switcher, which has nothing to collapse) there is no Collapse.
struct ProjectMenu: View {
    let project: Project
    let collapsed: Bool?
    let rename: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
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
        Button("New Terminal", systemImage: "terminal") { model.newTab(inProject: project.id) }
        if let collapsed {
            Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "chevron.down" : "chevron.right") {
                withAnimation(DS.Motion.snappy) { model.groups.toggleCollapsed(project: project.id) }
            }
        }
        Divider()
        Button("Ungroup", systemImage: "rectangle.stack.badge.minus") {
            withAnimation(DS.Motion.reorder) { model.ungroupProject(project.id) }
        }
        Button("Close All Tabs", systemImage: "xmark.square", role: .destructive) { model.closeProject(project.id) }
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
            withAnimation(DS.Motion.reorder) { model.newProject(from: [ref]) }
        }
        if !others.isEmpty {
            Menu("Move to Project") {
                ForEach(others) { project in
                    Button(project.name) { withAnimation(DS.Motion.reorder) { model.move(ref, toProject: project.id) } }
                }
            }
        }
        if let current {
            Button("Remove from \(current.name)", systemImage: "folder.badge.minus") {
                withAnimation(DS.Motion.reorder) { model.removeFromProject(ref) }
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
                withAnimation(DS.Motion.reorder) { model.accept(suggestion) }
            } label: {
                HStack(spacing: DS.Space.gap10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .frame(width: 16)
                    Text("Group \(suggestion.tabs.count) tabs in \(Text(suggestion.name).foregroundStyle(DS.Palette.textSecondary))")
                        .font(DS.Font.sidebarSubtitle)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Not Now", systemImage: "xmark") { withAnimation(DS.Motion.snappy) { model.dismiss(suggestion) } }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .sidebarRow(selected: false)
        .padding(.top, DS.Space.xs)
        .accessibilityIdentifier("project-suggestion-\(suggestion.name)")
    }
}

/// The header over the window's own tabs of one kind.
private struct WindowTabsHeader: View {
    let kind: WindowTabKind

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: kind.systemImage)
                .font(DS.Font.section.weight(.regular))
                .imageScale(.small)
                .foregroundStyle(DS.Palette.textSecondary)
                .opacity(DS.Opacity.mutedGlyph)
                .frame(width: 16)
            Text(kind.title)
                .font(DS.Font.section)
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

/// A daemon's loose tabs grouped by repository and worktree.
private struct HostReposItem: View {
    let group: HostGroup
    let numbers: [TabRef: Int]
    @Environment(WindowModel.self) private var model
    @Environment(SidebarDragState.self) private var drag

    var body: some View {
        let grouped = Set(model.projects.flatMap(\.tabs))
        let loose = group.tabs.filter { !grouped.contains(group.ref($0.id)) }
        if let sidebar = model.groups.repoSidebar(for: group, tabs: loose) {
            RepoGroupsView(group: group, sidebar: sidebar, numbers: numbers) { tab in
                let ref = group.ref(tab.id)
                TabRow(tab: tab, ref: ref, number: numbers[ref] ?? 0, group: group, showsHost: false)
                    .sidebarTabDrag(ref, model: model, drag: drag, title: model.title(ofTab: ref))
            }
        }
    }
}
