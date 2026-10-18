import DesignSystem
import Foundation
import Observation

/// What the detail column (or the iPhone tab) shows.
enum Destination: Hashable {
    case terminal
    case inbox
    case hosts
}

/// Modal surfaces. One at a time, like the system's own sheets.
enum SheetRoute: String, Identifiable {
    case pairing, launchAgent, invite, links, diff, files, browser, editor, settings
    var id: String { rawValue }
}

/// App-wide UI state and the data sources behind the screens. One per window.
@Observable
final class AppModel {
    var destination = Destination.terminal
    var sheet: SheetRoute?
    var isPaletteShown = false
    var isSearchShown = false
    var searchNeedle = ""
    /// The terminal link state the reconnect overlay reflects (live until the daemon link exists).
    var connection = ConnectionState.connected

    let hosts: any HostDirectory
    let agents: any AgentFeed
    let paneStatus: any PaneStatusSource
    let files: any FileSource
    let diffs: any DiffSource
    let toasts = ToastCenter()

    init(
        hosts: any HostDirectory = MockHostDirectory(), agents: any AgentFeed = MockAgentFeed(),
        paneStatus: any PaneStatusSource = LaunchOptions.mock ? MockPaneStatus() : NoPaneStatus(),
        files: any FileSource = MockFileSource(), diffs: any DiffSource = MockDiffSource()
    ) {
        self.hosts = hosts
        self.agents = agents
        self.paneStatus = paneStatus
        self.files = files
        self.diffs = diffs
    }

    var needsYouCount: Int { agents.items.filter(\.state.needsYou).count }
}

/// Launch arguments for design review and screenshots:
/// `-mock` fills panes with agent statuses; `-screen <name>` opens straight to one screen.
enum LaunchOptions {
    static let mock = ProcessInfo.processInfo.arguments.contains("-mock")
    static let screen: String? = UserDefaults.standard.string(forKey: "screen")
}
