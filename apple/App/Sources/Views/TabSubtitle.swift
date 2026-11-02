import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import GudoCore

extension Workspace {
    /// The longest-running shell command in a tab's panes (daemon hosts, shell integration);
    /// none in a pane where an agent works (its own status says more).
    func runningCommand(of tab: Tab) -> CommandMark? {
        guard let daemon = host as? DaemonConnection, let hub = daemon.existingWorkspace else { return nil }
        return tab.root.panes
            .compactMap { pane in daemon.meta[pane]?.agent == nil ? hub.runningCommands[pane.rawValue] : nil }
            .min { $0.startedAtMs < $1.startedAtMs }
    }
}

/// A tab row's second line: its context, or a shell command running for a few seconds and for
/// how long ("cargo build · 1m 12s").
struct TabSubtitle: View {
    let context: String?
    let running: CommandMark?

    /// Quick commands never show: the line would flicker on every `ls`.
    static let threshold = 3

    var body: some View {
        if let running {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let seconds = Int(timeline.date.timeIntervalSince1970 - Double(running.startedAtMs) / 1000)
                if seconds >= Self.threshold {
                    HStack(spacing: 0) {
                        Text(running.command ?? "command")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(" · \(CommandBlocks.elapsed(seconds: seconds))")
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(DS.Font.sidebarSubtitle)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(running.command ?? "A command") running for \(CommandBlocks.elapsed(seconds: seconds))")
                } else {
                    contextLine
                }
            }
        } else {
            contextLine
        }
    }

    /// Always one line, so a row keeps its height while its context comes and goes.
    private var contextLine: some View {
        Text(context ?? " ")
            .font(DS.Font.sidebarSubtitle)
            .foregroundStyle(DS.Palette.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityHidden(context == nil)
    }
}
