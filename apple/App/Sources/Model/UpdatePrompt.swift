#if os(macOS)
import Foundation
import Observation

/// An update as the sidebar shows it.
struct UpdateOffer: Equatable {
    /// The build number the feed compares (`sparkle:version`).
    var version: String
    var displayVersion: String
    var notes: String?
    var notesURL: URL?
    var isInformationOnly = false
    var infoURL: URL?
}

enum UpdateChoice: Equatable {
    case install, dismiss, skip
}

enum UpdateStage: Equatable {
    case notDownloaded, downloaded, installing
}

/// The sidebar's update control: what the updater reports, and the choices made in the control,
/// replied to the updater. Every check, signature and install step stays the updater's own.
@MainActor
@Observable
final class UpdatePrompt {
    enum Phase: Equatable {
        case hidden
        case checking
        case available
        /// The fraction downloaded, in whole percent steps; nil until the size is known.
        case downloading(Double?)
        case preparing(Double?)
        case ready
        case installing
        case upToDate
        case failed(String)
    }

    static let minimizedKey = "updates.minimized"
    static let dismissedVersionKey = "updates.dismissedVersion"

    private(set) var phase: Phase = .hidden
    private(set) var offer: UpdateOffer?
    var showsNotes = false
    var isMinimized: Bool {
        didSet { defaults.set(isMinimized, forKey: Self.minimizedKey) }
    }
    /// The restart was asked for and the app is still running (it may have kept itself open).
    private(set) var canRetryRestart = false

    @ObservationIgnored var openURL: (URL) -> Void = { _ in }
    /// Brings a window with the sidebar forward.
    @ObservationIgnored var reveal: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let upToDateDuration: Duration
    @ObservationIgnored private var pendingChoice: ((UpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var retryRestart: (() -> Void)?
    @ObservationIgnored private var installsWhenReady = false
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, upToDateDuration: Duration = .seconds(4)) {
        self.defaults = defaults
        self.upToDateDuration = upToDateDuration
        isMinimized = defaults.bool(forKey: Self.minimizedKey)
    }

    var dismissedVersion: String? {
        get { defaults.string(forKey: Self.dismissedVersionKey) }
        set { defaults.set(newValue, forKey: Self.dismissedVersionKey) }
    }

    /// An update is on offer or on its way in: the phases the control can fold to an indicator.
    var holdsUpdate: Bool {
        switch phase {
        case .available, .downloading, .preparing, .ready, .installing: true
        case .hidden, .checking, .upToDate, .failed: false
        }
    }

    var showsIndicator: Bool { isMinimized && holdsUpdate }
    var showsCard: Bool { phase != .hidden && !showsIndicator }

    // MARK: From the updater

    func checkStarted(cancellation: @escaping () -> Void) {
        hideTask?.cancel()
        userInitiated = true
        self.cancellation = cancellation
        offer = nil
        phase = .checking
    }

    func found(_ offer: UpdateOffer, stage: UpdateStage, userInitiated: Bool, reply: @escaping (UpdateChoice) -> Void) {
        hideTask?.cancel()
        if !userInitiated, offer.version == dismissedVersion {
            // Downloaded or installing: still installed when the app quits.
            reply(.dismiss)
            return
        }
        if userInitiated {
            dismissedVersion = nil
            isMinimized = false
        }
        self.userInitiated = self.userInitiated || userInitiated
        self.offer = offer
        cancellation = nil
        pendingChoice = reply
        showsNotes = false
        phase = stage == .notDownloaded ? .available : .ready
    }

    func releaseNotesLoaded(_ notes: String) {
        guard offer != nil, offer?.notes == nil else { return }
        offer?.notes = notes
    }

    func downloadStarted(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        phase = .downloading(nil)
    }

    func downloadExpects(_ length: UInt64) {
        expectedLength = length
        receivedLength = 0
        showDownloadProgress()
    }

    func downloadReceived(_ length: UInt64) {
        receivedLength += length
        showDownloadProgress()
    }

    func extractionStarted() {
        cancellation = nil
        phase = .preparing(nil)
    }

    func extractionProgressed(_ fraction: Double) {
        let stepped = Self.step(fraction)
        if phase != .preparing(stepped) { phase = .preparing(stepped) }
    }

    func readyToInstall(reply: @escaping (UpdateChoice) -> Void) {
        if installsWhenReady {
            installsWhenReady = false
            phase = .installing
            reply(.install)
            return
        }
        if !userInitiated, let version = offer?.version, version == dismissedVersion {
            reply(.dismiss)
            return
        }
        pendingChoice = reply
        phase = .ready
    }

    func installing(applicationTerminated: Bool, retry: @escaping () -> Void) {
        pendingChoice = nil
        cancellation = nil
        retryRestart = applicationTerminated ? nil : retry
        canRetryRestart = false
        phase = .installing
    }

    /// The app is still open a while after the restart was asked for.
    func restartStalled() {
        if phase == .installing, retryRestart != nil { canRetryRestart = true }
    }

    func notFound(upToDate: Bool, message: String) {
        guard phase == .checking else { return }
        cancellation = nil
        guard upToDate else {
            phase = .failed(message)
            return
        }
        phase = .upToDate
        let duration = upToDateDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.phase == .upToDate else { return }
            self.phase = .hidden
        }
    }

    func failed(_ message: String) {
        pendingChoice = nil
        cancellation = nil
        installsWhenReady = false
        guard phase != .hidden || userInitiated else { return }
        phase = .failed(message)
    }

    /// The updater ended the session.
    func finished() {
        pendingChoice = nil
        cancellation = nil
        retryRestart = nil
        canRetryRestart = false
        installsWhenReady = false
        userInitiated = false
        switch phase {
        case .upToDate, .failed: break
        default: clear()
        }
    }

    /// The updater was asked to show what it is doing again.
    func focus() {
        isMinimized = false
        reveal()
    }

    // MARK: From the control

    /// The control's one action: download, restart to update, or open an information-only
    /// update's page.
    func accept() {
        switch phase {
        case .available:
            if offer?.isInformationOnly == true {
                if let url = offer?.infoURL ?? offer?.notesURL { openURL(url) }
                respond(.dismiss)
                clear()
                return
            }
            phase = .downloading(nil)
            respond(.install)
        case .ready:
            // A downloaded update unpacks first, then asks again: the answer is already given.
            installsWhenReady = true
            phase = .installing
            respond(.install)
        case .installing:
            canRetryRestart = false
            retryRestart?()
        default:
            break
        }
    }

    /// Hides the control. An offered update is skipped (until a newer version), a downloaded one
    /// waits and installs when the app quits, a download is cancelled.
    func dismiss() {
        switch phase {
        case .checking, .downloading:
            let cancel = cancellation
            cancellation = nil
            clear()
            cancel?()
        case .available:
            dismissedVersion = offer?.version
            let informationOnly = offer?.isInformationOnly == true
            clear()
            respond(informationOnly ? .dismiss : .skip)
        case .ready:
            dismissedVersion = offer?.version
            clear()
            respond(.dismiss)
        case .upToDate, .failed:
            hideTask?.cancel()
            clear()
        case .hidden, .preparing, .installing:
            break
        }
    }

    func toggleMinimized() {
        isMinimized.toggle()
    }

    func toggleNotes() {
        showsNotes.toggle()
    }

    // MARK: -

    private func respond(_ choice: UpdateChoice) {
        let reply = pendingChoice
        pendingChoice = nil
        reply?(choice)
    }

    private func clear() {
        phase = .hidden
        offer = nil
        showsNotes = false
    }

    private func showDownloadProgress() {
        guard expectedLength > 0 else { return }
        let stepped = Self.step(Double(receivedLength) / Double(expectedLength))
        if phase != .downloading(stepped) { phase = .downloading(stepped) }
    }

    /// Whole percents: a download reports every few kilobytes, the control redraws at most a
    /// hundred times.
    private static func step(_ fraction: Double) -> Double {
        (min(max(fraction, 0), 1) * 100).rounded(.down) / 100
    }
}

/// Release notes as plain text for the control: the feed item's description (plain, Markdown
/// or HTML), or a small linked notes file. A linked web page is opened in the browser instead.
enum ReleaseNotes {
    static let largestInlinePage = 32 * 1024

    static func text(_ source: String, format: String?) -> String? {
        let text: String
        switch format?.lowercased() {
        case "markdown":
            text = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                .map { String($0.characters) } ?? source
        case "plain-text":
            text = source
        default:
            text = source.contains("<") ? plainText(html: source) : source
        }
        let tidy = tidied(text)
        return tidy.isEmpty ? nil : tidy
    }

    static func text(data: Data, mimeType: String?) -> String? {
        guard data.count <= largestInlinePage, let source = String(data: data, encoding: .utf8) else { return nil }
        let type = mimeType?.lowercased() ?? ""
        if type.contains("markdown") { return text(source, format: "markdown") }
        if type.contains("plain") { return text(source, format: "plain-text") }
        if type.contains("html") { return text(source, format: "html") }
        return nil
    }

    static func plainText(html: String) -> String {
        var text = html
        let rules: [(Regex<Substring>, String)] = [
            (/(?is)<(?:script|style|head)\b.*?<\/(?:script|style|head)>/, ""),
            (/(?i)<li\b[^>]*>/, "\n• "),
            (/(?i)<br\s*\/?>/, "\n"),
            (/(?i)<\/(?:p|div|h[1-6]|ul|ol|tr)>/, "\n"),
            (/<[^>]*>/, ""),
        ]
        for (pattern, replacement) in rules {
            text = text.replacing(pattern, with: replacement)
        }
        return decodedEntities(text)
    }

    private static func decodedEntities(_ text: String) -> String {
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}"]
        var decoded = text.replacing(/&#(\d+);/) { match in
            UInt32(match.output.1).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        for (entity, character) in named {
            decoded = decoded.replacingOccurrences(of: entity, with: character)
        }
        return decoded.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Lines trimmed, runs of blank lines folded to one.
    private static func tidied(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.replacing(/[ \t]+/, with: " ").trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
#endif
