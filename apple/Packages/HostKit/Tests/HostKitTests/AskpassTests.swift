import Foundation
import Synchronization
import Testing
import UnnamedCore
@testable import HostKit

/// A daemon client's askpass half: records answers, replays pushes.
nonisolated final class FakeAskpassClient: AskpassClientAPI, @unchecked Sendable {
    struct State {
        var listener: (any AskpassListener)?
        var open: [SecretPrompt] = []
        var answers: [(UInt64, String)] = []
        var cancels: [UInt64] = []
        var typed: [(UInt64, String)] = []
        var answerError: AskpassError?
    }

    let state = Mutex(State())

    func push(_ event: AskpassEvent) {
        state.withLock { $0.listener }?.onAskpassEvent(event: event)
    }

    func setAskpassListener(listener: any AskpassListener) { state.withLock { $0.listener = listener } }
    func openAskpass() -> [SecretPrompt] { state.withLock { $0.open } }
    func detectedPrompt(paneId: UInt64) -> DetectedPrompt? { nil }
    func answerAskpass(id: UInt64, secret: String) async throws {
        if let error = state.withLock({ $0.answerError }) { throw error }
        state.withLock { $0.answers.append((id, secret)) }
    }
    func cancelAskpass(id: UInt64) async throws { state.withLock { $0.cancels.append(id) } }
    func typeSecret(paneId: UInt64, secret: String) async throws { state.withLock { $0.typed.append((paneId, secret)) } }
}

func sudoPrompt(id: UInt64 = 1, pane: UInt64 = 3, retry: Bool = false) -> SecretPrompt {
    SecretPrompt(
        id: id, paneId: pane, source: .sudo, prompt: "[sudo] password for ana:", program: "sudo apt upgrade",
        echo: false, retry: retry, expiresAtMs: 0)
}

@MainActor
@Suite struct AskpassSessionTests {
    /// Lets the session's pump apply what the fake pushed.
    private func settle(_ session: AskpassSession, until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func promptsArriveAndCloseAndAnswersGoToTheDaemon() async throws {
        let client = FakeAskpassClient()
        let session = AskpassSession()
        session.attach(client)

        client.push(.prompt(prompt: sudoPrompt()))
        await settle(session) { !session.prompts.isEmpty }
        #expect(session.prompt(for: 3)?.id == 1)
        #expect(session.prompt(for: 4) == nil)

        try await session.answer(sudoPrompt(), secret: "hunter2")
        #expect(session.prompts.isEmpty)
        #expect(client.state.withLock { $0.answers.map(\.1) } == ["hunter2"])

        // Another device answered the next one first.
        client.push(.prompt(prompt: sudoPrompt(id: 2)))
        await settle(session) { !session.prompts.isEmpty }
        client.push(.closed(id: 2, paneId: 3, reason: .answered(by: "aa")))
        await settle(session) { session.prompts.isEmpty }
        #expect(session.closed[2] == .answered(by: "aa"))

        // Cancel removes it at once and tells the daemon.
        client.push(.prompt(prompt: sudoPrompt(id: 3)))
        await settle(session) { !session.prompts.isEmpty }
        await session.cancel(sudoPrompt(id: 3))
        #expect(session.prompts.isEmpty)
        #expect(client.state.withLock { $0.cancels } == [3])
    }

    @Test func aGoneAnswerClosesThePrompt() async {
        let client = FakeAskpassClient()
        client.state.withLock { $0.open = [sudoPrompt()] }
        let session = AskpassSession()
        session.attach(client)
        // Prompts already open when the session attaches are shown too.
        #expect(session.prompts.count == 1)
        client.state.withLock { $0.answerError = .Gone }
        await #expect(throws: AskpassError.Gone) { try await session.answer(sudoPrompt(), secret: "x") }
        #expect(session.prompts.isEmpty)
    }

    @Test func detectedPromptsComeAndGoAndTakeSecrets() async throws {
        let client = FakeAskpassClient()
        let session = AskpassSession()
        session.attach(client)
        let detected = DetectedPrompt(paneId: 5, prompt: "Password:", atSeq: 10)
        client.push(.detected(prompt: detected))
        await settle(session) { session.detected[5] != nil }
        try await session.typeSecret("s3cret", into: 5)
        #expect(client.state.withLock { $0.typed.map(\.1) } == ["s3cret"])
        #expect(session.detected[5] == nil)

        client.push(.detected(prompt: detected))
        await settle(session) { session.detected[5] != nil }
        client.push(.detectedGone(paneId: 5))
        await settle(session) { session.detected[5] == nil }
        #expect(session.detected.isEmpty)
    }

    @Test func aDroppedConnectionKeepsPromptsBrieflyUntilTheyComeBack() async {
        let client = FakeAskpassClient()
        let session = AskpassSession()
        session.staleGrace = .milliseconds(150)
        session.attach(client)
        client.push(.prompt(prompt: sudoPrompt(id: 7)))
        client.push(.prompt(prompt: sudoPrompt(id: 8, pane: 4)))
        await settle(session) { session.prompts.count == 2 }

        client.push(.reset)
        await settle(session) { !session.stale.isEmpty }
        #expect(session.stale == [7, 8])
        #expect(session.prompts.count == 2)
        // The daemon sends 7 again after reconnecting; 8 is gone for good.
        client.push(.prompt(prompt: sudoPrompt(id: 7)))
        await settle(session) { !session.stale.contains(7) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(session.prompts.map(\.id) == [7])
        #expect(session.stale.isEmpty)
    }
}

@Suite struct AskpassCopyTests {
    @Test func titlesSayWhoAsksForWhat() {
        #expect(AskpassCopy(prompt: sudoPrompt()).title == "sudo needs your password")
        var ssh = sudoPrompt()
        ssh.source = .ssh
        ssh.prompt = "Enter passphrase for key '/home/ana/.ssh/id_ed25519':"
        #expect(AskpassCopy(prompt: ssh).title == "ssh needs a passphrase")
        #expect(AskpassCopy(prompt: ssh).symbol == "key")
        var question = ssh
        question.prompt = "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        question.echo = true
        #expect(AskpassCopy(prompt: question).title == "ssh asks")
        #expect(AskpassCopy(prompt: question).echo)
        var git = sudoPrompt()
        git.source = .git
        git.prompt = "Username for 'https://github.com':"
        git.echo = true
        #expect(AskpassCopy(prompt: git).title == "git needs a username")
        git.prompt = "Password for 'https://ana@github.com':"
        git.echo = false
        #expect(AskpassCopy(prompt: git).title == "git needs a password")
        let detected = AskpassCopy(detected: DetectedPrompt(paneId: 1, prompt: "Password:", atSeq: 0))
        #expect(detected.title == "Password prompt")
        #expect(detected.kind == "terminal")
    }

    @Test func vaultKeysAreHashedPerHostKindAndPrompt() {
        let a = AskpassVaultKey(host: "h1", kind: "sudo", prompt: "[sudo] password for ana:")
        #expect(a == AskpassVaultKey(host: "h1", kind: "sudo", prompt: "[sudo] password for ana:"))
        #expect(a != AskpassVaultKey(host: "h2", kind: "sudo", prompt: "[sudo] password for ana:"))
        #expect(a != AskpassVaultKey(host: "h1", kind: "ssh", prompt: "[sudo] password for ana:"))
        #expect(!a.account.contains("ana"))
        #expect(a.account.hasPrefix("askpass.") && a.account.count == "askpass.".count + 32)
    }

    @Test func memoryVaultSavesReadsAndForgets() async throws {
        let vault = MemoryAskpassVault()
        let key = AskpassVaultKey(host: "h", kind: "sudo", prompt: "Password:")
        #expect(!vault.contains(key))
        try vault.save("pw", for: key)
        #expect(vault.contains(key))
        #expect(try await vault.read(key, reason: "test") == "pw")
        vault.failReads.withLock { $0 = .cancelled }
        await #expect(throws: AskpassVaultError.cancelled) { try await vault.read(key, reason: "test") }
        #expect(try vault.removeAll() == 1)
        #expect(vault.count() == 0)
    }
}
