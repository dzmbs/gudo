import os

nonisolated enum PanePresentation: String, CaseIterable, Sendable {
    case chat, terminal
}

/// Shared by the main-actor presentation and terminal paste callbacks, which may run off actor.
/// This only blocks hidden UI input; it is not an agent-consumption acknowledgement.
nonisolated final class PaneInputPresentation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: PanePresentation.terminal)

    var value: PanePresentation {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    var allowsTerminalInput: Bool { value == .terminal }
}
