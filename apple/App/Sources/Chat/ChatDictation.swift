#if os(iOS)
import Foundation
import Observation
import VoiceKit

/// The shared recognizer gets an explicit local-draft target, never its focused-Terminal fallback.
@MainActor
@Observable
final class ChatDictation {
    private(set) var preview: String?
    private(set) var message: String?
    private let voice: PushToTalk
    private var target: ChatDictationTarget?

    init(voice: PushToTalk = VoiceDictation.shared.voice) { self.voice = voice }
    isolated deinit { cancel() }

    var isActive: Bool { target.map { voice.isRecording(into: $0) } ?? false }
    var isStarting: Bool { isActive && voice.phase == .starting }
    var canFinish: Bool { isActive && voice.phase == .listening }

    var status: String? {
        guard isActive else { return message }
        switch voice.phase {
        case .starting: return "Starting dictation…"
        case .listening: return preview.map { "Listening… \($0)" } ?? "Listening…"
        case .finishing: return "Finishing dictation…"
        default: return message
        }
    }

    func start(in state: PaneChatState) {
        guard !voice.isActive else { message = "Dictation is already in use."; return }
        message = nil
        preview = nil
        let id = UUID()
        let target = ChatDictationTarget(id: id, state: state, preview: { [weak self] text in
            guard self?.target?.id == id else { return }
            self?.preview = text
        }, failed: { [weak self] error in
            guard self?.target?.id == id else { return }
            self?.message = error.message
        })
        self.target = target
        if !voice.start(target: target) {
            if case .failed(let error) = voice.phase { message = error.message }
            self.target = nil
        }
    }

    /// Capture the target before deferring; a queued finish cannot commit a replacement recording.
    func finish() {
        guard canFinish, let target else { return }
        Task { [weak self, voice] in
            _ = await voice.stop(target: target)
            guard let self, self.target === target else { return }
            self.target = nil
            preview = nil
        }
    }

    func cancel() {
        let previous = target
        target = nil
        preview = nil
        message = nil
        if let previous { voice.cancel(target: previous) }
    }

    func cancelIfStale() {
        if let target, !target.hasCurrentContext { cancel() }
    }
}

@MainActor
private final class ChatDictationTarget: DictationTarget {
    let id: UUID
    private weak var state: PaneChatState?
    private let context: PaneChatState.ActionContext
    private let original: String
    private let originalBytes: Int
    private let separator: String
    private var voiceBytes = 0
    private let preview: (String?) -> Void
    private let failed: (VoiceError) -> Void

    init(id: UUID, state: PaneChatState, preview: @escaping (String?) -> Void, failed: @escaping (VoiceError) -> Void) {
        self.id = id
        self.state = state
        context = state.actionContext
        original = state.draft
        originalBytes = original.utf8.prefix(ChatComposer.maximumDraftBytes + 1).count
        separator = original.isEmpty || original.last?.isWhitespace == true ? "" : " "
        self.preview = preview
        self.failed = failed
    }

    var hasCurrentContext: Bool { state?.actionContext == context && state?.presentation == .chat }

    var route: DictationRoute {
        guard hasCurrentContext, let state else { return .refused("This Chat draft is no longer active.") }
        guard state.draft == original else { return .refused("The draft changed. Dictate again to add more text.") }
        guard !state.composer.isBusy, !state.interrupt.isBusy else { return .refused("Wait for the current Chat action.") }
        guard originalBytes + separator.utf8.count + voiceBytes <= ChatComposer.maximumDraftBytes else {
            return .refused("The message is too long. Shorten the draft before dictating.")
        }
        return .agentPrompt
    }

    func showPreview(_ text: String?) {
        if let text {
            voiceBytes = text.utf8.prefix(ChatComposer.maximumDraftBytes + 1).count
            preview(String(decoding: text.utf8.prefix(1_024), as: UTF8.self))
        } else { preview(nil) }
    }

    func commit(_ text: String, via route: DictationRoute) {
        guard route == .agentPrompt, self.route == .agentPrompt, let state else { return }
        let combined = original + separator + text
        guard combined.utf8.count <= ChatComposer.maximumDraftBytes else {
            failed(.refused("The message is too long. Shorten the draft before dictating."))
            return
        }
        state.draft = combined
    }

    func dictationFailed(_ error: VoiceError) { failed(error) }
}
#endif
