import Foundation
import Testing
@testable import VoiceKit

/// A recognizer the test drives: `emit` delivers events, `finish()` ends the stream after an
/// optional last event, `fail` throws into it.
@MainActor
final class FakeRecognizer: SpeechRecognizer {
    var startError: VoiceError?
    /// Delivered when `finish()` is called (the recognizer's last words), then the stream ends.
    var lastWords: RecognitionEvent?
    /// Hold `finish()` without ending the stream (a recognizer that never answers).
    var hangOnFinish = false
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var cancelled = 0
    private(set) var locale: Locale?
    private var sink: AsyncThrowingStream<RecognitionEvent, any Error>.Continuation?

    func start(locale: Locale) async throws(VoiceError) -> AsyncThrowingStream<RecognitionEvent, any Error> {
        started += 1
        self.locale = locale
        if let startError { throw startError }
        let (stream, sink) = AsyncThrowingStream.makeStream(of: RecognitionEvent.self)
        self.sink = sink
        return stream
    }

    func finish() async {
        finished += 1
        guard !hangOnFinish else { return }
        if let lastWords { sink?.yield(lastWords) }
        sink?.finish()
    }

    func cancel() {
        cancelled += 1
        sink?.finish()
    }

    func emit(_ event: RecognitionEvent) { sink?.yield(event) }
    func fail(_ error: VoiceError) { sink?.finish(throwing: error) }
}

@MainActor
final class FakeTarget: DictationTarget {
    var route: DictationRoute
    private(set) var previews: [String?] = []
    private(set) var commits: [(String, DictationRoute)] = []
    private(set) var failures: [VoiceError] = []

    init(route: DictationRoute = .paste) { self.route = route }

    var preview: String? { previews.last ?? nil }

    func showPreview(_ text: String?) { previews.append(text) }
    func commit(_ text: String, via route: DictationRoute) { commits.append((text, route)) }
    func dictationFailed(_ error: VoiceError) { failures.append(error) }
}

@MainActor
struct PushToTalkTests {
    let recognizer = FakeRecognizer()
    let target = FakeTarget()
    let settings = VoiceSettings(isEnabled: true, localeIdentifier: "de-DE")

    func makeVoice() -> PushToTalk {
        let recognizer = self.recognizer, target = self.target, settings = self.settings
        return PushToTalk(recognizer: { recognizer }, settings: { settings }, target: { target })
    }

    /// Lets the session task run until `condition` holds.
    func settle(_ condition: () -> Bool = { false }) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func partialAndFinalSegmentsMerge() {
        var transcript = Transcript()
        transcript.apply(.volatile("list"))
        #expect(transcript.text == "list")
        transcript.apply(.volatile("list the files"))
        #expect(transcript.text == "list the files" && transcript.finalized.isEmpty)
        transcript.apply(.finalized("List the files"))
        #expect(transcript.finalized == "List the files" && transcript.volatile.isEmpty)
        transcript.apply(.volatile("in  src\n"))
        #expect(transcript.text == "List the files in src")
        transcript.apply(.finalized(" in source. "))
        #expect(transcript.text == "List the files in source.")
    }

    @Test func previewShowsLiveTextAndNothingIsSentBeforeRelease() async {
        let voice = makeVoice()
        #expect(voice.start())
        await settle { voice.phase == .listening }
        #expect(voice.phase == .listening)
        #expect(recognizer.locale?.identifier == "de-DE")
        recognizer.emit(.volatile("git"))
        recognizer.emit(.volatile("git status"))
        await settle { target.preview == "git status" }
        #expect(target.preview == "git status")
        #expect(voice.transcript.volatile == "git status")
        #expect(target.commits.isEmpty)
    }

    @Test func releaseCommitsExactlyTheFinalTextWithoutNewline() async {
        let voice = makeVoice()
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.finalized("Run the tests"))
        recognizer.emit(.volatile("and"))
        recognizer.lastWords = .finalized("and fix the\nfailures.")
        let outcome = await voice.stop()
        #expect(outcome == .committed("Run the tests and fix the failures.", .paste))
        #expect(target.commits.count == 1)
        #expect(target.commits.first?.0 == "Run the tests and fix the failures.")
        #expect(target.commits.first?.0.contains("\n") == false)
        #expect(target.commits.first?.0.contains("\r") == false)
        #expect(target.preview == nil)
        #expect(voice.phase == .idle)
        #expect(voice.transcript.isEmpty)
        #expect(recognizer.finished == 1)
    }

    @Test func volatileWordsAtReleaseAreKept() async {
        let voice = makeVoice()
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.volatile("npm run build"))
        await settle { voice.transcript.volatile == "npm run build" }
        #expect(await voice.stop() == .committed("npm run build", .paste))
    }

    @Test func cancelCommitsNothing() async {
        let voice = makeVoice()
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.finalized("rm -rf build"))
        await settle { target.preview != nil }
        voice.cancel()
        #expect(voice.phase == .idle)
        #expect(target.commits.isEmpty)
        #expect(target.preview == nil)
        #expect(recognizer.cancelled == 1)
        #expect(await voice.stop() == .nothing)
        #expect(target.commits.isEmpty)
    }

    @Test func emptyTranscriptCommitsNothing() async {
        let voice = makeVoice()
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.volatile("   "))
        #expect(await voice.stop() == .nothing)
        #expect(target.commits.isEmpty)
        #expect(voice.phase == .idle)
    }

    @Test func secondStartWhileListeningIsIgnored() async {
        let voice = makeVoice()
        #expect(voice.start())
        await settle { voice.phase == .listening }
        #expect(!voice.start())
        #expect(recognizer.started == 1)
        recognizer.emit(.finalized("hello"))
        #expect(await voice.stop() == .committed("hello", .paste))
        // A new session after the first ended starts cleanly.
        #expect(voice.start())
        await settle { voice.phase == .listening }
        #expect(recognizer.started == 2)
        #expect(voice.transcript.isEmpty)
        voice.cancel()
    }

    @Test func releaseWhileStartingStillCommits() async {
        let voice = makeVoice()
        voice.start()
        #expect(voice.phase == .starting)
        recognizer.lastWords = .finalized("quick")
        let outcome = await voice.stop()
        #expect(outcome == .committed("quick", .paste))
    }

    @Test func permissionDeniedSurfacesPlainly() async {
        recognizer.startError = .microphoneDenied
        let voice = makeVoice()
        #expect(voice.start())
        await settle { voice.phase != .starting }
        #expect(voice.phase == .failed(.microphoneDenied))
        #expect(VoiceError.microphoneDenied.message.contains("Microphone access is off"))
        #expect(await voice.stop() == .failed(.microphoneDenied))
        #expect(target.commits.isEmpty)
    }

    @Test func recognizerErrorEndsTheSessionWithoutCommitting() async {
        let voice = makeVoice()
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.finalized("half a sentence"))
        recognizer.fail(.failed("the audio device went away"))
        await settle { voice.phase != .listening }
        #expect(voice.phase == .failed(.failed("the audio device went away")))
        #expect(VoiceError.failed("x").message == "Dictation stopped: x")
        #expect(target.preview == nil)
        #expect(await voice.stop() == .failed(.failed("the audio device went away")))
        #expect(target.commits.isEmpty)
    }

    @Test func disabledOrNoTargetDoesNotStart() {
        let off = PushToTalk(recognizer: { recognizer }, settings: { VoiceSettings(isEnabled: false) }, target: { target })
        #expect(!off.start())
        #expect(off.phase == .failed(.disabled))
        let nowhere = PushToTalk(recognizer: { recognizer }, settings: { settings }, target: { nil })
        #expect(!nowhere.start())
        #expect(nowhere.phase == .failed(.noTarget))
        #expect(recognizer.started == 0)
    }

    @Test func slowRecognizerTimesOutAndCommitsWhatItHas() async {
        recognizer.hangOnFinish = true
        let voice = makeVoice()
        voice.finishTimeout = .milliseconds(50)
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.volatile("make test"))
        await settle { voice.transcript.volatile == "make test" }
        #expect(await voice.stop() == .committed("make test", .paste))
        #expect(recognizer.cancelled == 1)
    }

    @Test func agentPromptRouteCommitsIntoThePrompt() async {
        let prompter = FakeTarget(route: .agentPrompt)
        let voice = PushToTalk(recognizer: { recognizer }, settings: { settings }, target: { prompter })
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.finalized("Explain this stack trace"))
        #expect(await voice.stop() == .committed("Explain this stack trace", .agentPrompt))
        #expect(prompter.commits.first?.1 == .agentPrompt)
    }

    @Test func refusedPaneDoesNotListen() {
        let viewer = FakeTarget(route: .refused("You’re viewing. Dictation can’t type here."))
        let voice = PushToTalk(recognizer: { recognizer }, settings: { settings }, target: { viewer })
        #expect(!voice.start())
        #expect(voice.phase == .failed(.refused("You’re viewing. Dictation can’t type here.")))
        #expect(recognizer.started == 0)
    }

    @Test func routing() {
        #expect(DictationRoute.resolve(kind: .shell, canType: true, canPrompt: true) == .paste)
        #expect(DictationRoute.resolve(kind: .agent, canType: true, canPrompt: true) == .paste)
        #expect(DictationRoute.resolve(kind: .agent, canType: false, canPrompt: true) == .agentPrompt)
        #expect(DictationRoute.resolve(kind: .shell, canType: false, canPrompt: true) != .paste)
        if case .refused(let reason) = DictationRoute.resolve(kind: .shell, canType: false, canPrompt: false) {
            #expect(reason.contains("viewing"))
        } else {
            Issue.record("a viewer must be refused")
        }
        if case .refused(let reason) = DictationRoute.resolve(kind: .shell, canType: false, canPrompt: true, drivenBy: "Mira") {
            #expect(reason == "Mira is driving. Take control to dictate.")
        } else {
            Issue.record("a pane driven by someone else must be refused")
        }
    }

    @Test func transcriptStreamFollowsTheSession() async {
        let voice = makeVoice()
        let stream = voice.transcripts()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == Transcript())
        voice.start()
        await settle { voice.phase == .listening }
        recognizer.emit(.volatile("ls"))
        #expect(await iterator.next() == Transcript(volatile: "ls"))
        recognizer.emit(.finalized("ls -la"))
        #expect(await iterator.next() == Transcript(finalized: "ls -la"))
        _ = await voice.stop()
        #expect(await iterator.next() == Transcript())
    }

    @Test func scopedControlCannotFinishOrCancelAnotherTarget() async {
        let voice = makeVoice(), other = FakeTarget()
        voice.start()
        await settle { voice.phase == .listening }
        #expect(voice.isRecording(into: target))
        #expect(!voice.isRecording(into: other))
        #expect(await voice.stop(target: other) == .nothing)
        voice.cancel(target: other)
        #expect(voice.isRecording(into: target))
        #expect(recognizer.finished == 0 && recognizer.cancelled == 0)
        voice.cancel(target: target)
        #expect(!voice.isActive && recognizer.cancelled == 1)
    }

    @Test func endedTargetReceivesItsOwnFailureAndCannotStopAReplacement() async {
        let voice = makeVoice(), replacement = FakeTarget()
        recognizer.startError = .microphoneDenied
        voice.start()
        await settle { voice.phase == .failed(.microphoneDenied) }
        #expect(target.failures == [.microphoneDenied])
        recognizer.startError = nil
        voice.start(target: replacement)
        await settle { voice.phase == .listening }
        #expect(await voice.stop(target: target) == .nothing)
        voice.cancel(target: target)
        #expect(voice.isRecording(into: replacement))
        #expect(replacement.failures.isEmpty)
        voice.cancel(target: replacement)
    }

    @Test func previewFitsTheRowEnd() {
        #expect(DictationPreview.fit("git status", columns: 20) == "git status")
        #expect(DictationPreview.fit("git status", columns: 6) == "…tatus")
        #expect(DictationPreview.fit("abc", columns: 1) == "…")
        #expect(DictationPreview.fit("abc", columns: 0) == "")
        #expect(DictationPreview.fit("日本語", columns: 5) == "…本語")
        #expect(DictationPreview.cells("日本") == 4)
    }

    @Test func holdShortcut() {
        var shortcut = HoldShortcut()
        #expect(shortcut.handle(isTriggerKey: false, chordHeld: true, phase: .press) == .pass)
        #expect(shortcut.handle(isTriggerKey: true, chordHeld: false, phase: .press) == .pass)
        #expect(shortcut.handle(isTriggerKey: true, chordHeld: false, phase: .release) == .pass)
        #expect(shortcut.handle(isTriggerKey: true, chordHeld: true, phase: .press) == .start)
        #expect(shortcut.handle(isTriggerKey: true, chordHeld: true, phase: .repeat) == .swallow)
        #expect(shortcut.handle(isTriggerKey: true, chordHeld: true, phase: .press) == .swallow)
        #expect(shortcut.handle(isTriggerKey: false, chordHeld: false, phase: .press) == .pass)
        // Modifiers let go first: releasing Space still stops.
        #expect(shortcut.handle(isTriggerKey: true, chordHeld: false, phase: .release) == .stop)
        #expect(!shortcut.isHeld)
    }

    @Test func settingsDefaults() {
        let defaults = UserDefaults(suiteName: "voice-tests-\(UUID().uuidString)")!
        #expect(VoiceSettings.load(from: defaults) == VoiceSettings(isEnabled: true, localeIdentifier: nil))
        defaults.set(false, forKey: VoiceSettings.enabledKey)
        defaults.set("fr-FR", forKey: VoiceSettings.localeKey)
        let loaded = VoiceSettings.load(from: defaults)
        #expect(!loaded.isEnabled && loaded.locale.identifier == "fr-FR")
        #expect(VoiceSettings(localeIdentifier: "").locale == Locale.current)
    }
}
