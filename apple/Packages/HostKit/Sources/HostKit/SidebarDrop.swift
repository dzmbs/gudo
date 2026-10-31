import PaneLayout

/// A run of rows in the sidebar that tabs can be dragged within or into.
nonisolated public enum SidebarContainer: Hashable, Sendable {
    case project(String)
    /// The window's own tabs that are in no project.
    case window
    /// A host's loose tabs.
    case host(String)
}

/// A container and its rows, top to bottom.
nonisolated public struct SidebarSection: Hashable, Sendable, Identifiable {
    public var container: SidebarContainer
    public var rows: [TabRef]
    public var id: SidebarContainer { container }

    public init(_ container: SidebarContainer, rows: [TabRef]) {
        self.container = container
        self.rows = rows
    }
}

/// Where a dragged tab would land: in a gap of a container, or onto a row to group with it.
nonisolated public enum SidebarDrop: Hashable, Sendable {
    /// Into `container` at `index` among its rows without the dragged one.
    case insert(TabRef, into: SidebarContainer, at: Int)
    /// Onto `target`: into its project, or a new project of the two.
    case group(TabRef, onto: TabRef)

    public var dragged: TabRef {
        switch self {
        case .insert(let ref, _, _), .group(let ref, _): ref
        }
    }

    /// Whether a tab may land in `container` at all: a host's section takes only its own tabs
    /// (tabs live on their host), the window's only window tabs.
    public static func accepts(_ container: SidebarContainer, _ ref: TabRef) -> Bool {
        switch container {
        case .project: true
        case .window: ref.hostId == HostGroups.mixedId
        case .host(let id): ref.hostId == id
        }
    }

    /// The plan for a pointer at `fraction` (0 top … 1 bottom) of `target`'s row in `section`:
    /// the middle groups (unless both are already in that project), the edges open a gap
    /// before or after the row. Nil when the drop would change nothing.
    public static func plan(dragging ref: TabRef, over target: TabRef, at fraction: Double, in section: SidebarSection) -> SidebarDrop? {
        guard ref != target, let index = section.rows.firstIndex(of: target) else { return nil }
        let sameProject = section.rows.contains(ref) && { if case .project = section.container { true } else { false } }()
        let canInsert = accepts(section.container, ref)
        let middle = fraction > 0.3 && fraction < 0.7
        if (middle && !sameProject) || !canInsert {
            return .group(ref, onto: target)
        }
        let rows = section.rows.filter { $0 != ref }
        let targetIndex = rows.firstIndex(of: target) ?? index
        let insertAt = fraction < 0.5 ? targetIndex : targetIndex + 1
        let drop = SidebarDrop.insert(ref, into: section.container, at: insertAt)
        return drop.changes(section) ? drop : nil
    }

    /// Whether an insert moves `ref` within `section` (or into it).
    func changes(_ section: SidebarSection) -> Bool {
        guard case .insert(let ref, _, let index) = self, let from = section.rows.firstIndex(of: ref) else { return true }
        return from != index
    }

    /// The sections as they look after this drop: the dragged row out of its section and in
    /// the target's. A group drop leaves the rows where they are (the target only lights up).
    public func applied(to sections: [SidebarSection]) -> [SidebarSection] {
        guard case .insert(let ref, let container, let index) = self else { return sections }
        var result = sections.map { section in
            var section = section
            section.rows.removeAll { $0 == ref }
            return section
        }
        if let i = result.firstIndex(where: { $0.container == container }) {
            result[i].rows.insert(ref, at: min(max(index, 0), result[i].rows.count))
        } else {
            result.append(SidebarSection(container, rows: [ref]))
        }
        return result
    }

    /// The position to give `ref` in its host's session so its loose rows read `loose`
    /// (`ref` included, in the new order): just before the row after it, else just after the
    /// row before it. Indices are those `Session.moveTab` takes. Nil when nothing moves.
    public static func sessionIndex(for ref: TabId, loose: [TabId], session: [TabId]) -> Int? {
        guard let position = loose.firstIndex(of: ref), session.contains(ref) else { return nil }
        let others = session.filter { $0 != ref }
        let target: Int
        if position + 1 < loose.count, let next = others.firstIndex(of: loose[position + 1]) {
            target = next
        } else if position > 0, let previous = others.firstIndex(of: loose[position - 1]) {
            target = previous + 1
        } else {
            return nil
        }
        return session.firstIndex(of: ref) == target ? nil : target
    }
}
