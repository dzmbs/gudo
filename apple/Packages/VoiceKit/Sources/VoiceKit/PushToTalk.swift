import Foundation
import Observation

/// Push-to-talk dictation into a terminal pane or an agent's prompt.
///
/// The API the key bar's mic button (and the ⌃⌥Space hold shortcut) calls:
///
/// ```swift
/// let voice = PushToTalk.shared            // the app's instance (VoiceDictation wires it)
/// voice.start()                            // finger down: listen; the transcript shows at the cursor
/// await voice.stop()                       // finger up: commit the words (no Return), then idle
/// voice.cancel()                           // dragged off / Escape: drop everything, commit nothing
/// for await t in voice.transcripts() { … } // live `Transcript` updates (empty when a session ends)
/// ```
///
/// Observable state: `phase` (`idle`, `starting`, `listening`, `finishing`, `failed(VoiceError)`),
/// `transcript`, `isActive`, `settings`. Nothing reaches the host before `stop()`: while
/// listening the target only draws a preview (marked text at the cursor). `stop()` commits
/// `Transcript.text` exactly, on one line, without a newline, through the target's route
/// (`DictationRoute`: a paste into the pane, or an unsubmitted agent prompt). An empty transcript
/// commits nothing. A second `start()` while a session runs is ignored. Errors (permission,
/// language, recognizer) end the session, commit nothing and stay in `phase` until the next start.
@MainActor
@Observable
public final class PushToTalk {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Asking for permission / starting the microphone.
        case starting
        case listening
        /// Released: waiting for the last words.
        case finishing
        case failed(VoiceError)
    }

    /// What `stop()` did.
    public enum Outcome: Equatable, Sendable {
        case committed(String, DictationRoute)
        /// Nothing was heard, or no session was running.
        case nothing
        case failed(VoiceError)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var transcript = Transcript()
    /// The settings read at the last start (on/off, language).
    public private(set) var settings: VoiceSettings

    /// Listening, or about to, or finishing: the mic button shows as held.
    public var isActive: Bool {
        switch phase {
        case .starting, .listening, .finishing: true
        case .idle, .failed: false
        }
    }

    /// How long `stop()` waits for the recognizer's last words before committing what it has.
    public var finishTimeout: Duration = .seconds(2)

    @ObservationIgnored private let makeRecognizer: () -> any SpeechRecognizer
    @ObservationIgnored private let loadSettings: () -> VoiceSettings
    @ObservationIgnored public var targetProvider: () -> (any DictationTarget)?
    @ObservationIgnored private var recognizer: (any SpeechRecognizer)?
    @ObservationIgnored private weak var target: (any DictationTarget)?
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var listeners: [UUID: AsyncStream<Transcript>.Continuation] = [:]

    public init(
        recognizer: @escaping () -> any SpeechRecognizer,
        settings: @escaping () -> VoiceSettings = { VoiceSettings.load() },
        target: @escaping () -> (any DictationTarget)? = { nil }
    ) {
        makeRecognizer = recognizer
        loadSettings = settings
        targetProvider = target
        self.settings = settings()
    }

    /// Live transcript updates for as long as the caller iterates. Every change while listening,
    /// and an empty transcript when a session ends (committed, cancelled or failed).
    public func transcripts() -> AsyncStream<Transcript> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Transcript.self, bufferingPolicy: .bufferingNewest(8))
        listeners[id] = continuation
        continuation.yield(transcript)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return stream
    }

    /// Starts listening into `target` (default: the focused pane from `targetProvider`). Returns
    /// false when it could not start (off, nothing to type into, refused) or a session is already
    /// running; the reason is in `phase`.
    @discardableResult
    public func start(target explicit: (any DictationTarget)? = nil) -> Bool {
        guard !isActive else { return false }
        settings = loadSettings()
        guard settings.isEnabled else {
            phase = .failed(.disabled)
            return false
        }
        guard let target = explicit ?? targetProvider() else {
            phase = .failed(.noTarget)
            return false
        }
        if case .refused(let reason) = target.route {
            phase = .failed(.refused(reason))
            return false
        }
        session += 1
        let id = session
        stopRequested = false
        self.target = target
        transcript = Transcript()
        phase = .starting
        let recognizer = makeRecognizer()
        self.recognizer = recognizer
        let locale = settings.locale
        sessionTask = Task { [weak self] in
            await self?.run(recognizer, locale: locale, session: id)
        }
        return true
    }

    /// Stops listening and commits what was heard (no Return). Waits for the last words up to
    /// `finishTimeout`.
    @discardableResult
    public func stop() async -> Outcome {
        guard isActive, let task = sessionTask else {
            if case .failed(let error) = phase { return .failed(error) }
            return .nothing
        }
        let id = session
        stopRequested = true
        if phase == .listening {
            phase = .finishing
            await recognizer?.finish()
        }
        // A session still starting finishes the recognizer itself once it is up (`run`). A
        // recognizer that does not deliver its last words in time is cancelled, which ends its
        // stream: what was heard so far is committed.
        let recognizer = self.recognizer
        let timeout = finishTimeout
        let watchdog = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            recognizer?.cancel()
        }
        await task.value
        watchdog.cancel()
        guard id == session else {
            // The session ended while finishing: a recognizer error (in `phase`) or a cancel.
            if case .failed(let error) = phase { return .failed(error) }
            return .nothing
        }
        return commit(session: id)
    }

    /// Stops at once; nothing is committed.
    public func cancel() {
        guard isActive else {
            if case .failed = phase { phase = .idle }
            return
        }
        recognizer?.cancel()
        end(session: session, phase: .idle)
    }

    // MARK: Session

    private func run(_ recognizer: any SpeechRecognizer, locale: Locale, session id: Int) async {
        let events: AsyncThrowingStream<RecognitionEvent, any Error>
        do {
            events = try await recognizer.start(locale: locale)
        } catch {
            if id == session { end(session: id, phase: .failed(error)) }
            return
        }
        guard id == session else {
            recognizer.cancel()
            return
        }
        if stopRequested {
            phase = .finishing
            await recognizer.finish()
        } else {
            phase = .listening
        }
        do {
            for try await event in events {
                guard id == session else { return }
                transcript.apply(event)
                target?.showPreview(transcript.isEmpty ? nil : transcript.text)
                broadcast(transcript)
            }
        } catch {
            guard id == session else { return }
            let reason = (error as? VoiceError) ?? .failed(error.localizedDescription)
            end(session: id, phase: .failed(reason))
        }
        // The stream may end on its own (a recognizer's time limit): keep the words until the
        // user lets go.
    }

    private func commit(session id: Int) -> Outcome {
        let text = Transcript.normalize(transcript.text)
        let target = self.target
        let route = target?.route ?? .refused(VoiceError.noTarget.message)
        target?.showPreview(nil)
        if text.isEmpty {
            end(session: id, phase: .idle)
            return .nothing
        }
        if case .refused(let reason) = route {
            end(session: id, phase: .failed(.refused(reason)))
            return .failed(.refused(reason))
        }
        target?.commit(text, via: route)
        end(session: id, phase: .idle)
        return .committed(text, route)
    }

    private func end(session id: Int, phase: Phase) {
        guard id == session else { return }
        session += 1
        target?.showPreview(nil)
        target = nil
        recognizer = nil
        sessionTask = nil
        stopRequested = false
        transcript = Transcript()
        self.phase = phase
        broadcast(transcript)
    }

    private func broadcast(_ transcript: Transcript) {
        for continuation in listeners.values { continuation.yield(transcript) }
    }
}
