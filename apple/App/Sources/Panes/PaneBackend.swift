import Foundation
// `PaneBackend`, `PredictionFeed`, `ForegroundProgramReporting`, `PaneEvent` and the remote
// backends live in HostKit (docs/APP-ARCHITECTURE.md); the app sees them everywhere.
@_exported import HostKit
import PaneLayout

/// The backend for new panes in the local workspace: a login shell on a local PTY on macOS (a
/// local echo under `-mock`), a local echo on iOS (the scratch workspace; remote hosts use HostKit's backends).
@MainActor
func makeLocalBackend(for pane: PaneId) throws -> any PaneBackend {
    #if os(macOS)
    // Design fixtures and snapshots draw known screens, never this Mac's own shell and prompt.
    LaunchOptions.mock ? EchoBackend(pane: pane) : try LocalPTYBackend()
    #else
    EchoBackend(pane: pane)
    #endif
}
