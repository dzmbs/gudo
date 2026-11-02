@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import Speech

/// Apple's on-device speech: `SpeechAnalyzer` + `SpeechTranscriber` when the language's model is
/// installed, else `SFSpeechRecognizer` with `requiresOnDeviceRecognition`. Audio never leaves the
/// device and no paid entitlement is needed. Models are downloaded only when the user asks
/// (Settings › Voice → `download(_:)`), never during dictation.
@MainActor
public final class SystemSpeechRecognizer: SpeechRecognizer {
    private var session: (any RecognitionSession)?
    nonisolated static let log = Logger(subsystem: "dev.gudo.voice", category: "voice")

    public init() {}

    public func start(locale: Locale) async throws(VoiceError) -> AsyncThrowingStream<RecognitionEvent, any Error> {
        try await Self.requestMicrophone()
        let name = Self.displayName(locale)
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = Self.transcriber(supported)
            if await AssetInventory.status(forModules: [transcriber]) == .installed {
                let session = AnalyzerSession(transcriber: transcriber)
                self.session = session
                do {
                    return try await session.start()
                } catch {
                    Self.log.error("SpeechAnalyzer failed to start, using SFSpeechRecognizer: \(String(describing: error), privacy: .public)")
                    self.session = nil
                }
            }
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw .languageUnavailable(name)
        }
        try await Self.requestSpeech()
        guard recognizer.isAvailable else { throw .languageUnavailable(name) }
        let session = LegacySession(recognizer: recognizer)
        self.session = session
        do {
            return try session.start()
        } catch {
            self.session = nil
            throw .failed(error.localizedDescription)
        }
    }

    public func finish() async {
        await session?.finish()
    }

    public func cancel() {
        session?.cancel()
        session = nil
    }

    // MARK: Languages (Settings › Voice)

    /// Whether dictation in a language works now, and how.
    public enum Availability: Equatable, Sendable {
        /// SpeechAnalyzer's model is on the device.
        case installed
        /// SpeechAnalyzer supports it; the model can be downloaded (Apple's on-device model).
        /// Until then the older on-device recognizer is used when `fallback` is true.
        case downloadable(fallback: Bool)
        case downloading
        /// Only the older on-device recognizer (SFSpeechRecognizer) has it.
        case legacyOnly
        case unavailable
    }

    public static func availability(of locale: Locale) async -> Availability {
        let legacy = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return legacy ? .legacyOnly : .unavailable
        }
        switch await AssetInventory.status(forModules: [transcriber(supported)]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .downloadable(fallback: legacy)
        case .unsupported: return legacy ? .legacyOnly : .unavailable
        @unknown default: return legacy ? .legacyOnly : .unavailable
        }
    }

    /// Downloads and installs SpeechAnalyzer's model for `locale` (the system does it; recognition
    /// stays on device). `progress` is updated as it goes.
    public static func download(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(supported)]) else { return }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// Every language some on-device recognizer here can dictate in, by identifier.
    public static func supportedLocales() async -> [Locale] {
        var byId: [String: Locale] = [:]
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales { byId[locale.identifier(.bcp47)] = locale }
        }
        for locale in SFSpeechRecognizer.supportedLocales() where byId[locale.identifier(.bcp47)] == nil {
            if SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true { byId[locale.identifier(.bcp47)] = locale }
        }
        return byId.values.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
    }

    public nonisolated static func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    nonisolated static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    // MARK: Permissions

    static func requestMicrophone() async throws(VoiceError) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return
        case .denied: throw .microphoneDenied
        default:
            guard await AVAudioApplication.requestRecordPermission() else { throw .microphoneDenied }
        }
    }

    static func requestSpeech() async throws(VoiceError) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .denied, .restricted: throw .speechDenied
        default:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw .speechDenied }
        }
    }
}

/// One dictation: microphone in, recognition events out.
@MainActor
protocol RecognitionSession: AnyObject {
    func finish() async
    func cancel()
}

// MARK: SpeechAnalyzer

@MainActor
final class AnalyzerSession: RecognitionSession {
    private let transcriber: SpeechTranscriber
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var sink: AsyncThrowingStream<RecognitionEvent, any Error>.Continuation?
    private let microphone = Microphone()

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    func start() async throws -> AsyncThrowingStream<RecognitionEvent, any Error> {
        let transcriber = self.transcriber
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.failed("no audio format for the speech model")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        let (inputs, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.input = input
        let (events, sink) = AsyncThrowingStream.makeStream(of: RecognitionEvent.self)
        self.sink = sink
        results = Task.detached {
            do {
                for try await result in transcriber.results {
                    let words = String(result.text.characters)
                    sink.yield(result.isFinal ? .finalized(words) : .volatile(words))
                }
                sink.finish()
            } catch {
                sink.finish(throwing: error)
            }
        }
        try await analyzer.start(inputSequence: inputs)
        try microphone.start(converting: format) { buffer in
            input.yield(AnalyzerInput(buffer: buffer))
        }
        return events
    }

    func finish() async {
        microphone.stop()
        input?.finish()
        input = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            SystemSpeechRecognizer.log.error("finalizing: \(String(describing: error), privacy: .public)")
            await analyzer?.cancelAndFinishNow()
        }
    }

    func cancel() {
        microphone.stop()
        input?.finish()
        input = nil
        // End the events first, so the cancellation below is not reported as an error.
        sink?.finish()
        results?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

// MARK: SFSpeechRecognizer (on device)

@MainActor
final class LegacySession: RecognitionSession {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let microphone = Microphone()

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func start() throws -> AsyncThrowingStream<RecognitionEvent, any Error> {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request
        let (events, sink) = AsyncThrowingStream.makeStream(of: RecognitionEvent.self)
        // The legacy recognizer reports the whole utterance each time: it is the volatile segment
        // until it is final.
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let words = result.bestTranscription.formattedString
                if result.isFinal {
                    sink.yield(.finalized(words))
                    sink.finish()
                } else {
                    sink.yield(.volatile(words))
                }
            } else if let error {
                // "No speech detected" after the user let go is not an error: nothing was said.
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && [1110, 216, 301].contains(nsError.code) {
                    sink.finish()
                } else {
                    sink.finish(throwing: VoiceError.failed(error.localizedDescription))
                }
            }
        }
        try microphone.start(converting: nil) { buffer in request.append(buffer) }
        return events
    }

    func finish() async {
        microphone.stop()
        request?.endAudio()
    }

    func cancel() {
        microphone.stop()
        request?.endAudio()
        task?.cancel()
    }
}

// MARK: Microphone

/// The input node's audio, converted to the recognizer's format, delivered on the audio thread.
nonisolated final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false

    func start(converting format: AVAudioFormat?, deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else {
            throw VoiceError.failed("no microphone input")
        }
        let converter = format.flatMap { $0 == natural ? nil : AVAudioConverter(from: natural, to: $0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in
            guard let converter, let format else { return deliver(buffer) }
            let ratio = format.sampleRate / natural.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { deliver(out) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
