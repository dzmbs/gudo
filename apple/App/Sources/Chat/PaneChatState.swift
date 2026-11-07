#if os(iOS)
import Foundation
import HostKit
import Observation
import PaneLayout

@MainActor
@Observable
final class PaneChatState {
    enum Persistence { case remembered, transient }

    private(set) var presentation: PanePresentation {
        get { access(keyPath: \.presentation); return inputPresentation.value }
        set { withMutation(keyPath: \.presentation) { inputPresentation.value = newValue } }
    }
    private(set) var agent: AgentKind?
    private(set) var error: String?
    var draft = ""
    var model: TimelineModel? { lease?.model }
    @ObservationIgnored weak var controller: ChatViewController?
    @ObservationIgnored private weak var hub: DaemonWorkspace?

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
        self.agent = supported
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
    func select(
        _ presentation: PanePresentation,
        persistence: Persistence = .remembered,
        preparing prepare: () -> Bool
    ) -> Bool {
        guard self.presentation == presentation || prepare() else { return false }
        self.presentation = presentation
        if persistence == .remembered { preferences.set(presentation.rawValue, forKey: preferenceKey) }
        return true
    }
}
#endif
