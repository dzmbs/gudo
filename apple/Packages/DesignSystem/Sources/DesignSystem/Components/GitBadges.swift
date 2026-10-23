import SwiftUI

// taken): the diff stat, the outline PR pill, the checks ring and per-check glyphs, and a
// popover that opens on pointer hover with a 150 ms grace.

public extension DS.Palette {
    /// Merged pull requests (GitHub's purple): the theme's magenta, like a working agent.
    static let merged = DS.Palette.working
}

public extension DS {
    nonisolated enum Git {
        public static let popoverMaxHeight: CGFloat = 400
    }
}

/// `+12 −3` in the palette's green and red, caption, monospaced digits, 2 pt apart. On a
/// selected row both drop to `.secondary` (selection never competes with state).
public struct DiffStat: View {
    let added: UInt32
    let removed: UInt32
    var selected: Bool
    var font: Font

    public init(added: UInt32, removed: UInt32, selected: Bool = false, font: Font = .caption) {
        self.added = added
        self.removed = removed
        self.selected = selected
        self.font = font
    }

    public var body: some View {
        if added > 0 || removed > 0 {
            HStack(spacing: 2) {
                if added > 0 {
                    Text("+\(added.formatted(.number))")
                        .foregroundStyle(selected ? AnyShapeStyle(DS.Palette.textSecondary) : AnyShapeStyle(DS.Palette.done))
                }
                if removed > 0 {
                    Text("−\(removed.formatted(.number))")
                        .foregroundStyle(selected ? AnyShapeStyle(DS.Palette.textSecondary) : AnyShapeStyle(DS.Palette.error))
                }
            }
            .font(font.monospacedDigit())
            .contentTransition(.numericText())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(added) lines added, \(removed) removed")
        }
    }
}

/// What a pull request is, for its colour and glyph.
public enum PRKind: Sendable, Equatable {
    case open, draft, merged, closed

    public var color: ChromeStyle {
        switch self {
        case .open: DS.Palette.done
        case .draft: DS.Palette.textSecondary
        case .merged: DS.Palette.merged
        case .closed: DS.Palette.error
        }
    }

    /// The branch-row glyph (SF Symbols; GitHub's octicons are not ours to ship).
    public var systemImage: String {
        switch self {
        case .open, .draft: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    public var word: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

/// `#124`: caption2, padding h 6 / v 2, radius 4, a 1 pt stroke in the state colour, no fill
public struct PRNumberBadge: View {
    let number: UInt32
    let kind: PRKind
    var selected: Bool

    public init(number: UInt32, kind: PRKind, selected: Bool = false) {
        self.number = number
        self.kind = kind
        self.selected = selected
    }

    public var body: some View {
        let style = selected ? AnyShapeStyle(DS.Palette.textSecondary) : AnyShapeStyle(kind.color)
        Text("#\(number)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(style)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(style, lineWidth: 1))
            .accessibilityLabel("Pull request \(number), \(kind.word)")
    }
}

/// A check's state, as the ring and the checks list draw it.
public enum CheckKind: Sendable, Equatable {
    case success, failure, pending, skipped, neutral, cancelled

    public var color: ChromeStyle {
        switch self {
        case .success: DS.Palette.done
        case .failure: DS.Palette.error
        case .pending: DS.Palette.attention
        case .skipped, .neutral, .cancelled: DS.Palette.textSecondary
        }
    }

    public var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "arrow.triangle.2.circlepath.circle.fill"
        case .skipped, .cancelled: "minus.circle.fill"
        case .neutral: "circle.fill"
        }
    }

    public var word: String {
        switch self {
        case .success: "Success"
        case .failure: "Failed"
        case .pending: "In progress"
        case .skipped: "Skipped"
        case .neutral: "Neutral"
        case .cancelled: "Cancelled"
        }
    }

    /// Ring segment order: failed, in progress, skipped, passed.
    var order: Int {
        switch self {
        case .failure: 0
        case .pending: 1
        case .skipped, .cancelled, .neutral: 2
        case .success: 3
        }
    }
}

/// The checks ring: 12 pt, 2 pt line (scaled with caption text), one segment per state in the
/// order failed, in progress, skipped, passed; rounded caps, a small gap between segments.
public struct ChecksRing: View {
    let checks: [CheckKind]
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var line: CGFloat = 2

    public init(_ checks: [CheckKind]) {
        self.checks = checks
    }

    public var body: some View {
        let groups = Dictionary(grouping: checks, by: \.order)
            .sorted { $0.key < $1.key }
            .map { (color: $0.value[0].color, count: $0.value.count) }
        let total = Double(max(checks.count, 1))
        let gap = groups.count > 1 ? 0.05 : 0
        ZStack {
            if checks.isEmpty {
                Circle().stroke(DS.Palette.textQuaternary, lineWidth: line)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                let start = groups[..<index].reduce(0.0) { $0 + Double($1.count) } / total
                let end = start + Double(group.count) / total
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, end - gap / 2))
                    .stroke(group.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The CI state of a pull request in one glyph for a row's corner: a filled check, cross or
/// dots (any failure fails; else anything running is pending; else passing).
public struct CheckBadge: View {
    let checks: [CheckKind]
    var selected: Bool

    public init(_ checks: [CheckKind], selected: Bool = false) {
        self.checks = checks
        self.selected = selected
    }

    public var body: some View {
        if let kind {
            Image(systemName: kind == .failure ? "xmark.circle.fill" : kind == .pending ? "ellipsis.circle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(DS.Palette.base, selected ? AnyShapeStyle(DS.Palette.textSecondary) : AnyShapeStyle(kind.color))
                .accessibilityLabel("Checks \(kind == .failure ? "failed" : kind == .pending ? "running" : "passed")")
        }
    }

    private var kind: CheckKind? {
        if checks.isEmpty { return nil }
        if checks.contains(.failure) { return .failure }
        if checks.contains(.pending) { return .pending }
        return .success
    }
}

/// The 6 pt dot of a highlight section header: the colour at 60 % with a hairline stroke.
public struct SectionDot: View {
    let color: AnyShapeStyle
    @Environment(\.displayScale) private var scale

    public init(_ color: some ShapeStyle) {
        self.color = AnyShapeStyle(color)
    }

    public var body: some View {
        Circle()
            .fill(color.opacity(0.6))
            .overlay(Circle().strokeBorder(color, lineWidth: DS.Size.hairline(scale: scale)))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
