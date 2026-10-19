import Foundation

/// A speech recognizer the controller drives: `SystemSpeechRecognizer` in the app, a fake in tests.
@MainActor
public protocol SpeechRecognizer: AnyObject {
    /// Starts listening (asking for permission the first time) and returns the recognition
    /// events. The stream ends after `finish()` once the last words are final, or throws.
    func start(locale: Locale) async throws(VoiceError) -> AsyncThrowingStream<RecognitionEvent, any Error>
    /// Stops the microphone; the stream delivers what is left and ends.
    func finish() async
    /// Stops at once; the stream ends without more events.
    func cancel()
}

/// Why dictation stopped or could not start, in words a person can act on.
nonisolated public enum VoiceError: Error, Equatable, Sendable {
    case disabled
    case microphoneDenied
    case speechDenied
    /// No on-device recognizer for the language (its name).
    case languageUnavailable(String)
    /// Nothing to dictate into (no terminal has the keyboard).
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

/// Where dictated text goes when the user lets go.
nonisolated public enum DictationRoute: Equatable, Sendable {
    /// Typed into the pane as a paste (bracketed when the program asked for it): a shell prompt,
    /// or an agent's prompt box when this person may type there.
    case paste
    /// Sent to the agent as a prompt without submitting it (a guest who may prompt but not type).
    case agentPrompt
    /// The pane takes no input from this person; the reason in words.
    case refused(String)

    /// What runs in a pane, as far as dictation cares.
    public enum PaneKind: Equatable, Sendable { case shell, agent }

    /// The route for a pane: typing (paste) when allowed; an agent pane falls back to an
    /// unsubmitted prompt for people who may prompt but not type.
    public static func resolve(kind: PaneKind, canType: Bool, canPrompt: Bool, drivenBy: String? = nil) -> Self {
        if canType { return .paste }
        if kind == .agent, canPrompt { return .agentPrompt }
        if let drivenBy { return .refused("\(drivenBy) is driving. Take control to dictate.") }
        return .refused(canPrompt ? "Dictation works in agent panes only with your role." : "You’re viewing. Dictation can’t type here.")
    }
}

/// A pane dictation types into. The app implements it over a terminal pane.
@MainActor
public protocol DictationTarget: AnyObject {
    /// Where committed text goes (checked at start and again at commit).
    var route: DictationRoute { get }
    /// Shows the live transcript at the cursor (nil clears it). Nothing reaches the host.
    func showPreview(_ text: String?)
    /// Delivers the final text: no Return, nothing submitted.
    func commit(_ text: String, via route: DictationRoute)
}

/// Hold-to-talk on a hardware keyboard (⌃⌥Space in the app): the trigger chord pressed starts,
/// releasing the trigger key stops. Repeats and the release are swallowed so the shell never sees
/// them; everything else passes through.
nonisolated public struct HoldShortcut: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Not ours: let the terminal encode the key.
        case pass
        /// Ours, nothing to do (a repeat while held).
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

/// The user's choices (Settings › Voice), in user defaults.
nonisolated public struct VoiceSettings: Equatable, Sendable {
    public static let enabledKey = "voiceDictationEnabled"
    public static let localeKey = "voiceDictationLocale"

    public var isEnabled: Bool
    /// A BCP 47 identifier ("en-US"), or nil for the system language.
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
