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

/// A tab row's second line: its worktree's branch, which stands for its folder, or else its context;
/// then a shell command running for a few seconds and for how long ("cargo build · 1m 12s").
struct TabSubtitle: View {
    let context: String?
    let running: CommandMark?
    var worktree: WorktreeState?
    /// Leads the line in a project, whose header does not name the host.
    var host: String?
    /// The agent's kind, state and how long, in place of `context`.
    var status: AgentStatusLine?
    /// Names a running command the shell did not report, by the program running it.
    var program: String?

    /// Quick commands never show: the line would flicker on every `ls`.
    static let threshold = 3

    var body: some View {
        HStack(spacing: 0) {
            if let host {
                Text(host).layoutPriority(1)
            }
            if let worktree {
                if host != nil { Text(" · ").fixedSize() }
                TabBranchLabel(worktree: worktree)
                    .layoutPriority(2)
            }
            if let running {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let seconds = Int(timeline.date.timeIntervalSince1970 - Double(running.startedAtMs) / 1000)
                    if seconds >= Self.threshold {
                        HStack(spacing: 0) {
                            separator
                            Text(running.command ?? program ?? "running")
                                .truncationMode(.tail)
                            Text(" · \(CommandBlocks.elapsed(seconds: seconds))")
                                .monospacedDigit()
                                .fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(running.command ?? program ?? "A command") running for \(CommandBlocks.elapsed(seconds: seconds))")
                    } else {
                        contextLine
                    }
                }
            } else {
                contextLine
            }
        }
        .font(SidebarFont.subtitle)
        .foregroundStyle(DS.Palette.textTertiary)
        .lineLimit(1)
    }

    @ViewBuilder private var separator: some View {
        if worktree != nil || host != nil { Text(" · ").fixedSize() }
    }

    /// Always one line, so a row keeps its height while its context comes and goes.
    @ViewBuilder private var contextLine: some View {
        if let status {
            HStack(spacing: 0) {
                separator
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    // The kind gives way first: the state and its age always show.
                    ViewThatFits(in: .horizontal) {
                        Text(status.text(at: timeline.date))
                        Text(status.stateWords(at: timeline.date)).truncationMode(.tail)
                    }
                }
            }
        } else if let context, worktree == nil {
            HStack(spacing: 0) {
                separator
                // "Claude Code · working" that does not fit keeps its state, whole.
                if let state = context.components(separatedBy: " · ").last, state != context {
                    ViewThatFits(in: .horizontal) {
                        Text(context)
                        Text(state)
                    }
                } else {
                    Text(context).truncationMode(.head)
                }
            }
        } else if worktree == nil && host == nil {
            Text(verbatim: " ").accessibilityHidden(true)
        }
    }
}
