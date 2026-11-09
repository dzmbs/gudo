import DesignSystem
import HostKit
import SwiftUI
import GudoCore

extension UsageTone {
    /// The meter's colour; nil keeps the surface's own quiet style.
    var color: ChromeStyle? {
        switch self {
        case .quiet: nil
        case .attention: DS.Palette.attention
        case .limited: DS.Palette.error
        }
    }
}

/// One meter's text, tinted only when it needs the user.
struct UsageMeterLine: View {
    let meter: UsageMeter
    var quiet: ChromeStyle = DS.Palette.textTertiary

    var body: some View {
        HStack(spacing: 4) {
            if meter.tone == .limited {
                Image(systemName: "exclamationmark.circle.fill")
                    .imageScale(.small)
            }
            Text(meter.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(DS.Font.meta)
        .monospacedDigit()
        .foregroundStyle(meter.tone.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(quiet))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meter.tone == .limited ? "\(meter.text), limited" : meter.text)
    }
}

/// A host's meters under its name in the sidebar. Watches the host's usage while on screen;
/// tapping opens the detail. Absent when nothing is known.
struct HostUsageMeters: View {
    let hostId: String
    let hostName: String
    @Environment(WindowModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let meters = UsageMeter.compact(model.usage.usage(forHost: hostId), now: context.date)
            if !meters.isEmpty {
                Button {
                    model.usageDetailHost = hostId
                } label: {
                    HStack(spacing: 0) {
                        ForEach(Array(meters.enumerated()), id: \.element.id) { index, meter in
                            if index > 0 { Text(" · ").foregroundStyle(DS.Palette.textTertiary) }
                            Text(meter.short)
                                .foregroundStyle(meter.tone.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(DS.Palette.textTertiary))
                        }
                    }
                    .font(DS.Font.meta)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(meters.map(\.text).joined(separator: "\n"))
                .accessibilityLabel(meters.map(\.text).joined(separator: ", "))
                .accessibilityHint("Shows plan usage on \(hostName)")
                .accessibilityIdentifier("usage-meters-\(hostName)")
            }
        }
        .onAppear { model.usage.watch(host: hostId) }
        .onDisappear { model.usage.unwatch(host: hostId) }
    }
}

/// Every agent's windows on one host, where the numbers come from, and why some are missing.
struct UsageDetailView: View {
    let hostName: String
    let report: AgentUsageReport?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let details = (report?.agents ?? []).map { UsageDetail($0, now: context.date) }
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Plan Usage on \(hostName)")
                    .font(.headline)
                if details.isEmpty {
                    Text(report == nil
                        ? "This host hasn't reported agent usage. Usage needs the latest helper and a connection as the host's owner."
                        : "No Claude Code or Codex on this host.")
                        .font(.callout)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(details) { detail in
                    AgentUsageSection(detail: detail)
                }
            }
            .padding(DS.Space.xl)
            .frame(width: 320, alignment: .leading)
        }
        .chromeContent()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-detail")
    }
}

private struct AgentUsageSection: View {
    let detail: UsageDetail

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(detail.title)
                .font(.subheadline.weight(.semibold))
            ForEach(detail.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name)
                        Spacer()
                        Text(row.percent)
                            .monospacedDigit()
                            .foregroundStyle(row.tone.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    }
                    .font(.callout)
                    ProgressView(value: row.fraction)
                        .progressViewStyle(.linear)
                        .tint(row.tone.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(DS.Palette.textSecondary))
                        .opacity(row.isPast ? 0.4 : 1)
                    if let reset = row.reset {
                        Text(reset)
                            .font(.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usage-row-\(detail.agent == .claude ? "claude" : "codex")-\(row.name)")
            }
            if let note = detail.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = detail.source {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }
}

/// The Inbox's plan usage strip. Watches the reporting hosts while on screen.
struct InboxUsageStrip: View {
    @Environment(WindowModel.self) private var model
    @State private var watching: Set<String> = []
    @State private var detailRow: String?

    private struct Row: Identifiable {
        var host: UsageHost
        var meter: UsageMeter
        var id: String { "\(host.id)/\(meter.id)" }
    }

    var body: some View {
        let hosts = model.usage.reportingHosts
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let rows = hosts.flatMap { host in
                UsageMeter.compact(model.usage.usage(forHost: host.id), now: context.date).map { Row(host: host, meter: $0) }
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        Button {
                            detailRow = row.id
                        } label: {
                            HStack(spacing: DS.Space.s) {
                                UsageMeterLine(meter: row.meter, quiet: DS.Palette.textSecondary)
                                Spacer(minLength: DS.Space.s)
                                // The host's name once, on its first line.
                                if rows.first(where: { $0.host.id == row.host.id })?.id == row.id {
                                    Text(row.host.name)
                                        .font(DS.Font.meta)
                                        .foregroundStyle(DS.Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(
                            get: { detailRow == row.id },
                            set: { if !$0 { detailRow = nil } })
                        ) {
                            UsageDetailView(hostName: row.host.name, report: model.usage.usage(forHost: row.host.id))
                                .chromePopover()
                        }
                        .accessibilityIdentifier("inbox-usage-\(row.host.name)-\(row.meter.id.lowercased())")
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.base)
                .overlay(alignment: .top) { Hairline() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inbox-usage")
            }
        }
        .onChange(of: hosts.map(\.id), initial: true) { _, ids in sync(Set(ids)) }
        .onDisappear { sync([]) }
    }

    private func sync(_ ids: Set<String>) {
        for id in ids.subtracting(watching) { model.usage.watch(host: id) }
        for id in watching.subtracting(ids) { model.usage.unwatch(host: id) }
        watching = ids
    }
}
