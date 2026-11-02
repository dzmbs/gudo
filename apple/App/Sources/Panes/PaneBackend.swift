import Foundation
// The pane backend protocols and the remote backends live in HostKit.
@_exported import HostKit
import PaneLayout

/// A login shell on a local PTY on macOS; a local echo on iOS and under `-mock`.
@MainActor
func makeLocalBackend(for pane: PaneId) throws -> any PaneBackend {
    #if os(macOS)
    // Design fixtures and snapshots draw known screens, never this Mac's own shell and prompt.
    LaunchOptions.mock ? EchoBackend(pane: pane) : try LocalPTYBackend()
    #else
    EchoBackend(pane: pane)
    #endif
}
