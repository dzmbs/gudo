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
        var capabilityGeneration: UUID? = nil
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
            if inputPresentation.value != newValue { invalidateActions() }
            withMutation(keyPath: \.presentation) { inputPresentation.value = newValue }
        }
    }
    private(set) var agent: AgentKind?
    var offersChat: Bool
    private(set) var error: String?
    private(set) var terminalNotice: TerminalNotice?
    var draft = ""
    let composer = ChatComposer()
    let interrupt = ChatInterrupt()
    let dictation: ChatDictation
    let photos = ChatPhotos()
    let queue = ChatQueue()
    /// The queued message the composer is sending, to put back if it does not go.
    var queueInFlight: ChatQueuedMessage?
    let autocomplete = ChatAutocomplete()
    let images = ChatImageLoader()
    /// The agent session's own title, kept after the timeline model is released, for the tab.
    var sessionTitle: String?
    var detail: ChatDetail?
    var model: TimelineModel? { lease?.model }
    var capabilities: AgentCapabilities {
        guard let model, model.error == nil else { return [] }
        return model.outline.capabilities
    }
    @ObservationIgnored weak var controller: ChatTranscriptViewController?
    @ObservationIgnored private weak var hub: DaemonWorkspace?
    @ObservationIgnored private var actionEpoch = UUID()

    var actionContext: ActionContext {
        ActionContext(presentation: actionEpoch, session: model?.outline.session?.nativeSession,
                      epoch: model?.outline.epoch, capabilityGeneration: model?.outline.capabilityGeneration)
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
        offersChat: Bool = true,
        inputPresentation: PaneInputPresentation = .init(),
        preferences: UserDefaults = .standard,
        pool: ChatModelPool = .shared,
        dictation: ChatDictation = .init()
    ) {
        self.member = member
        self.defaultPresentation = defaultPresentation
        self.inputPresentation = inputPresentation
        self.agent = agent
        self.offersChat = offersChat
        self.preferences = preferences
        self.pool = pool
        self.dictation = dictation
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
        if presentation == .chat, !offersChat || !prepare() { presentation = .terminal }
    }

    func updateAgent(_ agent: AgentKind?) {
        let supported = agent
        guard self.agent != supported else { return }
        invalidateActions()
        self.agent = supported
        terminalNotice = nil
        queue.clear()
        photos.discardAttachments()
        sessionTitle = nil
        model?.stop()
        model?.receive(.reset)
        if supported == nil {
            presentation = .terminal
            deactivate()
        } else {
            presentation = rememberedPresentation
        }
    }

    /// The transcript for `model`: the one kept from the last time this pane showed it, when
    /// it is free.
    func transcriptController(for model: TimelineModel) -> ChatTranscriptViewController {
        guard let lease, lease.model === model else { return ChatTranscriptViewController(model: model) }
        return lease.transcript { ChatTranscriptViewController(model: model) }
    }

    /// How long a Chat started ahead of its view waits for the view before letting its model go.
    static let prewarmGrace: Duration = .seconds(2)
    @ObservationIgnored private var prewarmRelease: Task<Void, Never>?

    /// Starts this pane's Chat before its view appears (the pointer resting on its tab), so its
    /// rows are on their way when it shows. It never takes another pane's warm model, and lets go
    /// after `grace` unless the view shows.
    func prewarm(in hub: DaemonWorkspace, grace: Duration = PaneChatState.prewarmGrace) {
        guard agent != nil, offersChat, presentation == .chat, lease == nil,
              let lease = pool.acquireWithoutEvicting(owner, pane: member.pane.rawValue) else { return }
        self.lease = lease
        self.hub = hub
        lease.model.start(in: hub)
        prewarmRelease = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, !Task.isCancelled, prewarmRelease != nil else { return }
            prewarmRelease = nil
            deactivate()
        }
    }

    func activate(in hub: DaemonWorkspace) {
        prewarmRelease?.cancel()
        prewarmRelease = nil
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

    func cancelPreparedActions() {
        composer.cancelBeforeSend()
        interrupt.reset()
    }

    func presentDetail(_ make: (PaneChatState) -> ChatDetail.Content) {
        invalidateActions()
        detail = ChatDetail(content: make(self))
    }

    func invalidateActions() {
        actionEpoch = UUID()
        dictation.cancel()
        photos.cancel()
        autocomplete.close()
        detail = nil
        cancelPreparedActions()
    }

    func deactivate() {
        prewarmRelease?.cancel()
        prewarmRelease = nil
        invalidateActions()
        lease?.close()
        lease = nil
        controller = nil
        hub = nil
    }

    @discardableResult
    func show(_ presentation: PanePresentation, terminal: Pane, persistence: Persistence = .remembered) -> Bool {
        let leavesChat = self.presentation == .chat && presentation == .terminal
        let shown = select(presentation, persistence: persistence) {
            switch presentation {
            case .chat:
                guard offersChat else {
                    error = "Update the helper to use Chat."
                    return false
                }
                if model == nil, let hub { activate(in: hub) }
                guard let model else { return false }
                if model.error != nil { model.retry() }
                return model.error == nil && terminal.prepareToParkTerminal()
            case .terminal:
                return controller?.prepareToPark() ?? true
            }
        }
        // The terminal is on screen now: it takes the phone's grid, as opening it does.
        if shown, leavesChat { terminal.claimSize() }
        return shown
    }

    @discardableResult
    func showTerminal(commandMark: UInt64?, terminal: Pane) -> Bool {
        guard !terminal.isComposingText, show(.terminal, terminal: terminal) else { return false }
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
