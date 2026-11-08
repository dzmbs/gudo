#if os(iOS)
import Foundation
import HostKit
import Observation
import PaneLayout

@MainActor
@Observable
final class PaneChatState {
    enum Persistence { case remembered, transient }
    struct ActionContext: Equatable {
        let presentation: UUID
        let session: String?
        let epoch: UInt64?
    }
    enum TerminalNotice: Equatable {
        case unavailableCommand(UInt64)

        var message: String {
            switch self {
            case .unavailableCommand: "This command is not available in this Terminal window."
            }
        }
    }

    private(set) var presentation: PanePresentation {
        get { access(keyPath: \.presentation); return inputPresentation.value }
        set {
            if inputPresentation.value != newValue { actionEpoch = UUID() }
            withMutation(keyPath: \.presentation) { inputPresentation.value = newValue }
        }
    }
    private(set) var agent: AgentKind?
    private(set) var error: String?
    private(set) var terminalNotice: TerminalNotice?
    var draft = ""
    let composer = ChatComposer()
    var model: TimelineModel? { lease?.model }
    @ObservationIgnored weak var controller: ChatViewController?
    @ObservationIgnored private weak var hub: DaemonWorkspace?
    @ObservationIgnored private var actionEpoch = UUID()

    var actionContext: ActionContext {
        ActionContext(presentation: actionEpoch, session: model?.frame.session?.nativeSession,
                      epoch: model?.frame.cursor?.epoch)
    }

    private let member: HostPane
    private let defaultPresentation: PanePresentation
    private let inputPresentation: PaneInputPresentation
    private let owner = UUID()
    private let preferences: UserDefaults
    private let preferenceKey: String
    private let pool: ChatModelPool
    private var lease: ChatModelLease?

    init(
        member: HostPane,
        defaultPresentation: PanePresentation,
        agent: AgentKind? = nil,
        inputPresentation: PaneInputPresentation = .init(),
        preferences: UserDefaults = .standard,
        pool: ChatModelPool = .shared
    ) {
        self.member = member
        self.defaultPresentation = defaultPresentation
        self.inputPresentation = inputPresentation
        self.agent = agent == .other ? nil : agent
        self.preferences = preferences
        self.pool = pool
        preferenceKey = "chat.presentation.\(member.hostId.utf8.count):\(member.hostId):\(member.pane.rawValue)"
        presentation = rememberedPresentation
    }

    isolated deinit {
        deactivate()
        pool.forget(owner)
    }

    private var rememberedPresentation: PanePresentation {
        preferences.string(forKey: preferenceKey).flatMap(PanePresentation.init(rawValue:)) ?? defaultPresentation
    }

    func prepareInitialPresentation(_ prepare: () -> Bool) {
        if presentation == .chat, !prepare() { presentation = .terminal }
    }

    func updateAgent(_ agent: AgentKind?) {
        let supported = agent == .other ? nil : agent
        guard self.agent != supported else { return }
        composer.cancelBeforeSend()
        actionEpoch = UUID()
        self.agent = supported
        terminalNotice = nil
        model?.stop()
        model?.receive(.reset)
        if supported == nil {
            presentation = .terminal
            deactivate()
        } else {
            presentation = rememberedPresentation
        }
    }

    func activate(in hub: DaemonWorkspace) {
        guard agent != nil else { return }
        self.hub = hub
        if lease == nil { lease = pool.acquire(owner, pane: member.pane.rawValue) }
        guard let model else {
            presentation = .terminal
            error = "Close another Chat view to open this one, or use Terminal."
            return
        }
        error = nil
        model.start(in: hub)
    }

    func deactivate() {
        actionEpoch = UUID()
        composer.cancelBeforeSend()
        lease?.close()
        lease = nil
        controller = nil
        hub = nil
    }

    @discardableResult
    func show(_ presentation: PanePresentation, terminal: Pane, persistence: Persistence = .remembered) -> Bool {
        select(presentation, persistence: persistence) {
            switch presentation {
            case .chat:
                if model == nil, let hub { activate(in: hub) }
                guard let model else { return false }
                if model.error != nil { model.retry() }
                return model.error == nil && terminal.prepareToParkTerminal()
            case .terminal:
                return controller?.prepareToPark() ?? true
            }
        }
    }

    @discardableResult
    func showTerminal(commandMark: UInt64?, terminal: Pane) -> Bool {
        guard terminal.view.markedTextRange == nil, show(.terminal, terminal: terminal) else { return false }
        if let commandMark, PaneCommandMarks.of(terminal)?.reveal(command: commandMark) != true {
            terminalNotice = .unavailableCommand(commandMark)
        }
        return true
    }

    @discardableResult
    func select(
        _ presentation: PanePresentation,
        persistence: Persistence = .remembered,
        preparing prepare: () -> Bool
    ) -> Bool {
        guard self.presentation == presentation || prepare() else { return false }
        terminalNotice = nil
        self.presentation = presentation
        if persistence == .remembered { preferences.set(presentation.rawValue, forKey: preferenceKey) }
        return true
    }
}
#endif
