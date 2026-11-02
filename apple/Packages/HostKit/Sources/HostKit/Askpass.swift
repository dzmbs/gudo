import Foundation
import Observation
import os
import GudoCore

// Native password prompts (docs/DAEMON.md §9): a program in a pane asks for a secret through
// the daemon's askpass helper (`sudo -A`, ssh, git over HTTPS), or prints a password prompt
// with echo off. Views bind to `AskpassSession` (one per `DaemonConnection`); secrets go
// straight from the field to the daemon and are never logged or kept, unless the user turns on
// "Remember in Keychain" for that host and prompt (`AskpassVault`).

/// The askpass half of `GudoCore.DaemonClient`, so the session can be tested with a fake.
nonisolated public protocol AskpassClientAPI: AnyObject, Sendable {
    func setAskpassListener(listener: any AskpassListener)
    func openAskpass() -> [SecretPrompt]
    func detectedPrompt(paneId: UInt64) -> DetectedPrompt?
    func answerAskpass(id: UInt64, secret: String) async throws
    func cancelAskpass(id: UInt64) async throws
    func typeSecret(paneId: UInt64, secret: String) async throws
}

extension DaemonClient: AskpassClientAPI {}

nonisolated final class AskpassRelay: AskpassListener {
    private let handler: @Sendable (AskpassEvent) -> Void

    init(_ handler: @escaping @Sendable (AskpassEvent) -> Void) {
        self.handler = handler
    }

    func onAskpassEvent(event: AskpassEvent) {
        handler(event)
    }
}

/// Open and detected password prompts on one daemon connection.
@MainActor
@Observable
public final class AskpassSession {
    /// Prompts waiting for an answer, oldest first.
    public private(set) var prompts: [SecretPrompt] = []
    /// Panes showing a password prompt with echo off.
    public private(set) var detected: [UInt64: DetectedPrompt] = [:]
    /// Prompts kept through a dropped connection until the daemon sends them again (same id),
    /// so a sheet being typed into survives a blip.
    public private(set) var stale: Set<UInt64> = []
    /// Why the last prompts closed, by id (the card says "Answered on another device").
    public private(set) var closed: [UInt64: AskpassCloseReason] = [:]

    @ObservationIgnored private var client: (any AskpassClientAPI)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var staleSweep: Task<Void, Never>?
    /// How long stale prompts wait to be sent again (the daemon waits 10 s for an app).
    @ObservationIgnored var staleGrace: Duration = .seconds(15)

    private static let log = Logger(subsystem: Log.subsystem, category: "askpass")

    public init() {}

    /// Starts following a client's askpass pushes (called once per dial; public for tests).
    public func attach(_ client: any AskpassClientAPI) {
        self.client = client
        pump?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: AskpassEvent.self)
        client.setAskpassListener(listener: AskpassRelay { continuation.yield($0) })
        pump = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
        for prompt in client.openAskpass() where !prompts.contains(where: { $0.id == prompt.id }) {
            prompts.append(prompt)
        }
    }

    func detach() {
        pump?.cancel()
        pump = nil
        client = nil
    }

    /// The prompt to show on `pane`: its oldest open one.
    public func prompt(for pane: UInt64) -> SecretPrompt? {
        prompts.first { $0.paneId == pane }
    }

    /// Applies one push (public so previews and tests can drive the session without a daemon).
    public func apply(_ event: AskpassEvent) {
        switch event {
        case .prompt(let prompt):
            stale.remove(prompt.id)
            closed[prompt.id] = nil
            if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
                prompts[index] = prompt
            } else {
                prompts.append(prompt)
            }
            Self.log.info("prompt \(prompt.id) pane=\(prompt.paneId) source=\(String(describing: prompt.source), privacy: .public)")
        case .closed(let id, _, let reason):
            prompts.removeAll { $0.id == id }
            stale.remove(id)
            closed[id] = reason
            Self.log.info("closed \(id) \(String(describing: reason), privacy: .public)")
        case .detected(let prompt):
            detected[prompt.paneId] = prompt
        case .detectedGone(let pane):
            detected[pane] = nil
        case .reset:
            detected = [:]
            stale.formUnion(prompts.map(\.id))
            sweepStale()
        }
    }

    private func sweepStale() {
        staleSweep?.cancel()
        let grace = staleGrace
        staleSweep = Task { [weak self] in
            guard (try? await Task.sleep(for: grace)) != nil, let self else { return }
            prompts.removeAll { stale.contains($0.id) }
            stale = []
        }
    }

    /// Answers `prompt`. The secret is handed to the core and not kept here.
    ///
    /// - Throws: `AskpassError` (`.Gone` when another device answered first).
    public func answer(_ prompt: SecretPrompt, secret: String) async throws {
        guard let client else { throw AskpassError.Disconnected }
        do {
            try await client.answerAskpass(id: prompt.id, secret: secret)
            prompts.removeAll { $0.id == prompt.id }
        } catch AskpassError.Gone {
            prompts.removeAll { $0.id == prompt.id }
            throw AskpassError.Gone
        }
    }

    /// Declines `prompt`: the program gets no answer.
    public func cancel(_ prompt: SecretPrompt) async {
        prompts.removeAll { $0.id == prompt.id }
        do {
            try await client?.cancelAskpass(id: prompt.id)
        } catch {
            Self.log.info("cancel \(prompt.id): \(String(describing: error), privacy: .public)")
        }
    }

    /// Types `secret` and Return into `pane` at its detected prompt (the daemon refuses unless
    /// the terminal still hides input).
    public func typeSecret(_ secret: String, into pane: UInt64) async throws {
        guard let client else { throw AskpassError.Disconnected }
        try await client.typeSecret(paneId: pane, secret: secret)
        detected[pane] = nil
    }
}

/// The words a secure prompt shows: what asks, for what, and the key the Keychain uses.
nonisolated public struct AskpassCopy: Equatable, Sendable {
    /// "sudo needs your password", "ssh needs a passphrase", "Password prompt".
    public var title: String
    /// The field's label: the program's own prompt.
    public var fieldLabel: String
    /// The kind for `AskpassVaultKey` and the icon.
    public var kind: String
    /// An SF Symbol.
    public var symbol: String
    /// The answer is not secret (a yes/no question).
    public var echo: Bool
    /// "Asked while bob is driving": a guest held the pane's lease and may have typed the
    /// command that asks.
    public var guestNotice: String?

    public init(prompt: SecretPrompt) {
        let lower = prompt.prompt.lowercased()
        let what = lower.contains("passphrase") ? "a passphrase" : lower.contains("pin") && !lower.contains("password") ? "a PIN" : "a password"
        let program = prompt.source.programName
        if prompt.echo {
            title = lower.hasPrefix("username") ? "\(program) needs a username" : "\(program) asks"
        } else if prompt.source == .sudo {
            title = "sudo needs your password"
        } else {
            title = "\(program) needs \(what)"
        }
        fieldLabel = prompt.prompt.isEmpty ? "Password:" : prompt.prompt
        kind = program
        echo = prompt.echo
        guestNotice = prompt.guestDriving.map { "Asked while \($0) is driving" }
        symbol = switch prompt.source {
        case .sudo: "lock.shield"
        case .ssh: "key"
        case .git: "arrow.triangle.branch"
        case .gpg: "signature"
        case .other: "key.horizontal"
        }
    }

    public init(detected: DetectedPrompt) {
        title = "Password prompt"
        fieldLabel = detected.prompt
        kind = "terminal"
        symbol = "key.horizontal"
        echo = false
        guestNotice = nil
    }
}

nonisolated public extension SecretSource {
    /// The program's name as the user knows it.
    var programName: String {
        switch self {
        case .sudo: "sudo"
        case .ssh: "ssh"
        case .git: "git"
        case .gpg: "gpg"
        case .other: "A program"
        }
    }
}

/// What to tell the user about a failed askpass request.
nonisolated public func askpassMessage(_ error: any Error) -> String {
    guard let error = error as? AskpassError else { return error.localizedDescription }
    switch error {
    case .Gone: return "The prompt is no longer open."
    case .Denied(let message): return "Not allowed: \(message)"
    case .UnknownPane: return "The pane is gone."
    case .NotHidden: return "The terminal is no longer asking for a password. Nothing was typed."
    case .Failed(let message): return message
    case .Disconnected: return "Not connected."
    }
}
