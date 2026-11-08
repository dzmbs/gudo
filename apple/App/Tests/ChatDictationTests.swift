#if os(iOS)
import GudoCore
import HostKit
import PaneLayout
import VoiceKit
import XCTest
@testable import App

@MainActor
final class ChatDictationTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    func testExplicitTargetPreviewsLocallyThenAppendsWithoutSendingOrUsingTerminalFallback() async throws {
        let (state, recognizer, voice, fallback) = try fixture()
        defer { state.deactivate() }
        state.draft = "Existing draft"
        state.dictation.start(in: state)
        try await wait { voice.phase == .listening }
        recognizer.emit(.volatile("more words"))
        try await wait { state.dictation.preview == "more words" }
        XCTAssertEqual(state.draft, "Existing draft")
        state.dictation.finish()
        try await wait { !state.dictation.isActive }
        XCTAssertEqual(state.draft, "Existing draft more words")
        XCTAssertTrue(fallback.commits.isEmpty)
        XCTAssertEqual(state.composer.phase, .idle)
        XCTAssertEqual(state.interrupt.phase, .idle)
    }

    func testChangedDraftIsPreservedRatherThanOverwrittenByDelayedSpeech() async throws {
        let (state, recognizer, voice, _) = try fixture()
        defer { state.deactivate() }
        state.draft = "Original"
        state.dictation.start(in: state)
        try await wait { voice.phase == .listening }
        recognizer.emit(.finalized("spoken words"))
        try await wait { state.dictation.preview != nil }
        state.draft = "New manually edited draft"
        state.dictation.finish()
        try await wait { !state.dictation.isActive }
        XCTAssertEqual(state.draft, "New manually edited draft")
        XCTAssertTrue(state.dictation.message?.contains("draft changed") == true)
    }

    func testQueuedFinishAndCancelCannotCommitOrStopAReplacementTarget() async throws {
        let (state, recognizer, voice, fallback) = try fixture()
        defer { state.deactivate(); voice.cancel() }
        state.dictation.start(in: state)
        try await wait { voice.phase == .listening }
        recognizer.emit(.finalized("old speech"))
        try await wait { state.dictation.preview != nil }
        state.dictation.finish()
        state.dictation.cancel()
        XCTAssertTrue(voice.start(target: fallback))
        try await wait { voice.phase == .listening }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(voice.isRecording(into: fallback))
        XCTAssertTrue(fallback.commits.isEmpty)
        XCTAssertEqual(state.draft, "")
    }

    func testPresentationRoundTripAgentChangeAndDeactivationCancelOnlyThisRecording() async throws {
        for change in 0..<3 {
            let (state, _, voice, _) = try fixture()
            defer { state.deactivate() }
            state.draft = "Retain this draft"
            state.dictation.start(in: state)
            try await wait { voice.phase == .listening }
            switch change {
            case 0:
                XCTAssertTrue(state.select(.terminal, preparing: { true }))
                XCTAssertTrue(state.select(.chat, preparing: { true }))
            case 1: state.updateAgent(.codex)
            default: state.deactivate()
            }
            XCTAssertFalse(voice.isActive)
            XCTAssertEqual(state.draft, "Retain this draft")
            XCTAssertNil(state.dictation.preview)
        }
    }

    func testOversizeSpeechHasBoundedPreviewAndCannotExceedTheDraftBudget() async throws {
        let (state, recognizer, voice, _) = try fixture()
        defer { state.deactivate() }
        state.draft = "Retain"
        state.dictation.start(in: state)
        try await wait { voice.phase == .listening }
        recognizer.emit(.finalized(String(repeating: "漢", count: ChatComposer.maximumDraftBytes)))
        try await wait { state.dictation.preview != nil }
        XCTAssertLessThanOrEqual(state.dictation.preview?.utf8.count ?? 0, 1_026)
        state.dictation.finish()
        try await wait { !state.dictation.isActive }
        XCTAssertEqual(state.draft, "Retain")
        XCTAssertTrue(state.dictation.message?.contains("too long") == true)
    }

    func testPermissionFailureBelongsToThisDraftAndDoesNotChangeIt() async throws {
        let (state, recognizer, voice, _) = try fixture()
        defer { state.deactivate() }
        state.draft = "Retain"
        recognizer.startError = .microphoneDenied
        state.dictation.start(in: state)
        try await wait { voice.phase == .failed(.microphoneDenied) }
        XCTAssertEqual(state.dictation.message, VoiceError.microphoneDenied.message)
        XCTAssertEqual(state.draft, "Retain")
    }

    private func fixture() throws -> (PaneChatState, ChatSpeechFixture, PushToTalk, ChatVoiceFallback) {
        let recognizer = ChatSpeechFixture(), fallback = ChatVoiceFallback()
        let voice = PushToTalk(recognizer: { recognizer }, settings: { VoiceSettings(isEnabled: true) }, target: { fallback })
        let suite = "chat-dictation-tests-" + UUID().uuidString
        suites.append(suite)
        let state = PaneChatState(member: HostPane(hostId: "fixture", pane: PaneId(7)), defaultPresentation: .chat,
                                  agent: .claude, preferences: try XCTUnwrap(UserDefaults(suiteName: suite)),
                                  pool: ChatModelPool(), dictation: ChatDictation(voice: voice))
        return (state, recognizer, voice, fallback)
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Dictation condition did not arrive", file: file, line: line)
    }
}

@MainActor
final class ChatSpeechFixture: SpeechRecognizer {
    var startError: VoiceError?
    private var sink: AsyncThrowingStream<RecognitionEvent, any Error>.Continuation?

    func start(locale: Locale) async throws(VoiceError) -> AsyncThrowingStream<RecognitionEvent, any Error> {
        if let startError { throw startError }
        let (stream, sink) = AsyncThrowingStream.makeStream(of: RecognitionEvent.self)
        self.sink = sink
        return stream
    }
    func finish() async { sink?.finish() }
    func cancel() { sink?.finish() }
    func emit(_ event: RecognitionEvent) { sink?.yield(event) }
}

@MainActor
final class ChatVoiceFallback: DictationTarget {
    var route: DictationRoute { .paste }
    private(set) var commits: [String] = []
    func showPreview(_ text: String?) {}
    func commit(_ text: String, via route: DictationRoute) { commits.append(text) }
}
#endif
