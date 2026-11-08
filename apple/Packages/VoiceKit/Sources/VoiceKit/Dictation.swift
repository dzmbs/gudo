import Foundation

@MainActor
public protocol SpeechRecognizer: AnyObject {
    /// Starts listening (asking for permission the first time) and returns the recognition
    /// events. The stream ends after `finish()` once the last words are final, or throws.
    func start(locale: Locale) async throws(VoiceError) -> AsyncThrowingStream<RecognitionEvent, any Error>
    /// The stream delivers what is left, then ends.
    func finish() async
    /// The stream ends without more events.
    func cancel()
}

nonisolated public enum VoiceError: Error, Equatable, Sendable {
    case disabled
    case microphoneDenied
    case speechDenied
    /// The language's display name.
    case languageUnavailable(String)
    case noTarget
    /// The pane does not take this person's input (a viewer, or someone else drives).
    case refused(String)
    case failed(String)

    public var message: String {
        switch self {
        case .disabled:
            "Dictation is off. Turn it on in Settings › Voice."
        case .microphoneDenied:
            #if os(macOS)
            "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            #else
            "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
            #endif
        case .speechDenied:
            #if os(macOS)
            "Speech recognition is off. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            #else
            "Speech recognition is off. Turn it on in Settings › Privacy & Security › Speech Recognition."
            #endif
        case .languageUnavailable(let language):
            "\(language) isn’t available for on-device dictation. Download it in Settings › Voice, or pick another language."
        case .noTarget:
            "Nothing to dictate into. Select a terminal first."
        case .refused(let reason):
            reason
        case .failed(let reason):
            "Dictation stopped: \(reason)"
        }
    }
}

nonisolated public enum DictationRoute: Equatable, Sendable {
    /// Typed into the pane as a paste (bracketed when the program asked for it): a shell prompt,
    /// or an agent's prompt box when this person may type there.
    case paste
    /// An unsubmitted agent prompt: a local Chat draft, or delivered without Return for a guest.
    case agentPrompt
    case refused(String)

    public enum PaneKind: Equatable, Sendable { case shell, agent }

    public static func resolve(kind: PaneKind, canType: Bool, canPrompt: Bool, drivenBy: String? = nil) -> Self {
        if canType { return .paste }
        if kind == .agent, canPrompt { return .agentPrompt }
        if let drivenBy { return .refused("\(drivenBy) is driving. Take control to dictate.") }
        return .refused(canPrompt ? "Dictation works in agent panes only with your role." : "You’re viewing. Dictation can’t type here.")
    }
}

@MainActor
public protocol DictationTarget: AnyObject {
    /// Where committed text goes (checked at start and again at commit).
    var route: DictationRoute { get }
    /// Nil clears it. Nothing reaches the host.
    func showPreview(_ text: String?)
    /// No Return, nothing submitted.
    func commit(_ text: String, via route: DictationRoute)
    /// A failure belongs to this target even after a different recording starts.
    func dictationFailed(_ error: VoiceError)
}

public extension DictationTarget {
    func dictationFailed(_ error: VoiceError) {}
}

/// Hold-to-talk on a hardware keyboard (⌃⌥Space in the app): the trigger chord pressed starts,
/// releasing the trigger key stops. Repeats and the release are swallowed so the shell never sees
/// them; everything else passes through.
nonisolated public struct HoldShortcut: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case pass
        case swallow
        case start
        case stop
    }

    public private(set) var isHeld = false

    public init() {}

    /// - Parameters:
    ///   - isTriggerKey: the key is the trigger key (Space).
    ///   - chordHeld: the trigger's modifiers are held (exactly ⌃⌥) at this event.
    ///   - phase: press, repeat or release.
    public mutating func handle(isTriggerKey: Bool, chordHeld: Bool, phase: Phase) -> Action {
        guard isTriggerKey else { return .pass }
        switch phase {
        case .press:
            if isHeld { return .swallow }
            guard chordHeld else { return .pass }
            isHeld = true
            return .start
        case .repeat:
            return isHeld ? .swallow : .pass
        case .release:
            // The modifiers may be up already: releasing Space ends it either way.
            guard isHeld else { return .pass }
            isHeld = false
            return .stop
        }
    }

    public enum Phase: Equatable, Sendable { case press, `repeat`, release }
}

nonisolated public struct VoiceSettings: Equatable, Sendable {
    public static let enabledKey = "voiceDictationEnabled"
    public static let localeKey = "voiceDictationLocale"

    public var isEnabled: Bool
    /// BCP 47 ("en-US"), or nil for the system language.
    public var localeIdentifier: String?

    public init(isEnabled: Bool = true, localeIdentifier: String? = nil) {
        self.isEnabled = isEnabled
        self.localeIdentifier = localeIdentifier
    }

    public var locale: Locale {
        localeIdentifier.flatMap { $0.isEmpty ? nil : Locale(identifier: $0) } ?? Locale.current
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            localeIdentifier: defaults.string(forKey: localeKey))
    }
}
