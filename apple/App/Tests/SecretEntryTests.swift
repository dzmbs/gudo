import Foundation
import HostKit
import Synchronization
import UnnamedCore
import XCTest
@testable import App

/// The secure prompt card's model against a fake daemon client and an in-memory vault: answers
/// go out once and are cleared, "Remember in Keychain" saves per host and prompt, the saved
/// password is used only on request and forgotten when it turns out wrong.
@MainActor
final class SecretEntryTests: XCTestCase {
    nonisolated final class Client: AskpassClientAPI, @unchecked Sendable {
        struct State {
            var answers: [(UInt64, String)] = []
            var typed: [(UInt64, String)] = []
            var cancels: [UInt64] = []
            var error: AskpassError?
        }

        let state = Mutex(State())
        func setAskpassListener(listener: any AskpassListener) {}
        func openAskpass() -> [SecretPrompt] { [] }
        func detectedPrompt(paneId: UInt64) -> DetectedPrompt? { nil }
        func answerAskpass(id: UInt64, secret: String) async throws {
            if let error = state.withLock({ $0.error }) { throw error }
            state.withLock { $0.answers.append((id, secret)) }
        }
        func cancelAskpass(id: UInt64) async throws { state.withLock { $0.cancels.append(id) } }
        func typeSecret(paneId: UInt64, secret: String) async throws {
            if let error = state.withLock({ $0.error }) { throw error }
            state.withLock { $0.typed.append((paneId, secret)) }
        }
    }

    private func prompt(id: UInt64 = 1, retry: Bool = false, echo: Bool = false) -> SecretPrompt {
        SecretPrompt(id: id, paneId: 2, source: .sudo, prompt: "[sudo] password for ana:", program: "sudo -A ls",
                     echo: echo, retry: retry, expiresAtMs: 0)
    }

    private func setUpSession() -> (AskpassSession, Client) {
        let client = Client()
        let session = AskpassSession()
        session.attach(client)
        return (session, client)
    }

    override func setUp() async throws {
        AskpassVaultStore.recentlyUsed = [:]
    }

    func testSendsOnceClearsTheFieldAndRemembersOnlyWhenAsked() async {
        let (session, client) = setUpSession()
        let vault = MemoryAskpassVault()
        let entry = SecretEntry(target: .askpass(prompt()), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        XCTAssertFalse(entry.canSend, "nothing typed yet")
        entry.secret = "hunter2"
        let closed = await entry.send()
        XCTAssertTrue(closed)
        XCTAssertEqual(entry.secret, "", "the field forgets what was typed")
        XCTAssertEqual(client.state.withLock { $0.answers.map(\.1) }, ["hunter2"])
        XCTAssertEqual(vault.count(), 0, "not remembered unless asked")

        let second = SecretEntry(target: .askpass(prompt(id: 2)), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        second.secret = "hunter2"
        second.remember = true
        _ = await second.send()
        XCTAssertTrue(vault.contains(second.key))
        // Another host's same prompt does not see it.
        let other = SecretEntry(target: .askpass(prompt(id: 3)), hostId: "other", session: session, vault: vault, vaultAvailable: true)
        XCTAssertFalse(other.hasSaved)
    }

    func testSavedPasswordIsUsedOnRequestAndForgottenWhenWrong() async {
        let (session, client) = setUpSession()
        let vault = MemoryAskpassVault()
        let key = AskpassVaultKey(host: "h", kind: "sudo", prompt: "[sudo] password for ana:")
        try? vault.save("old-pw", for: key)

        let entry = SecretEntry(target: .askpass(prompt()), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        XCTAssertTrue(entry.hasSaved)
        let closed = await entry.sendSaved()
        XCTAssertTrue(closed)
        XCTAssertEqual(client.state.withLock { $0.answers.map(\.1) }, ["old-pw"])

        // sudo asks again at once: the saved password was wrong.
        let retry = SecretEntry(target: .askpass(prompt(id: 2, retry: true)), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        XCTAssertTrue(retry.forgotSaved)
        XCTAssertFalse(retry.hasSaved)
        XCTAssertFalse(vault.contains(key))
    }

    func testCancelledFaceIDSendsNothing() async {
        let (session, client) = setUpSession()
        let vault = MemoryAskpassVault()
        let entry = SecretEntry(target: .askpass(prompt()), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        try? vault.save("pw", for: entry.key)
        vault.failReads.withLock { $0 = .cancelled }
        let closed = await entry.sendSaved()
        XCTAssertFalse(closed)
        XCTAssertTrue(client.state.withLock { $0.answers.isEmpty })
    }

    /// A guest held the pane's lease when the program asked: the card says who is driving, and
    /// the saved password is not one tap away (the guest's command may be what asks).
    func testAPromptAskedWhileAGuestDrivesSaysSoAndOffersNoSavedPassword() {
        let (session, _) = setUpSession()
        let vault = MemoryAskpassVault()
        var asked = prompt()
        asked.guestDriving = "bob"
        let entry = SecretEntry(target: .askpass(asked), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        try? vault.save("pw", for: entry.key)
        let again = SecretEntry(target: .askpass(asked), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        XCTAssertEqual(again.copy.guestNotice, "Asked while bob is driving")
        XCTAssertFalse(again.hasSaved)
        let owner = SecretEntry(target: .askpass(prompt()), hostId: "h", session: session, vault: vault, vaultAvailable: true)
        XCTAssertNil(owner.copy.guestNotice)
        XCTAssertTrue(owner.hasSaved)
    }

    func testQuestionsAreNotSecretAndNeverRemembered() {
        let (session, _) = setUpSession()
        let entry = SecretEntry(target: .askpass(prompt(echo: true)), hostId: "h", session: session,
                                vault: MemoryAskpassVault(), vaultAvailable: true)
        XCTAssertTrue(entry.copy.echo)
        XCTAssertFalse(entry.canRemember)
        XCTAssertTrue(entry.canSend, "an empty answer is an answer to a question")
    }

    func testDetectedPromptsTypeIntoThePaneAndReportAnEchoingTerminal() async {
        let (session, client) = setUpSession()
        let detected = DetectedPrompt(paneId: 9, prompt: "Password:", atSeq: 1)
        let entry = SecretEntry(target: .detected(detected), hostId: "h", session: session,
                                vault: MemoryAskpassVault(isAvailable: false), vaultAvailable: false)
        XCTAssertFalse(entry.canRemember, "no Keychain in this build")
        entry.secret = "s3cret"
        let closed = await entry.send()
        XCTAssertTrue(closed)
        XCTAssertEqual(client.state.withLock { $0.typed.map(\.0) }, [9])

        client.state.withLock { $0.error = .NotHidden }
        let late = SecretEntry(target: .detected(detected), hostId: "h", session: session,
                               vault: MemoryAskpassVault(), vaultAvailable: true)
        late.secret = "s3cret"
        let lateClosed = await late.send()
        XCTAssertFalse(lateClosed)
        XCTAssertEqual(late.failure, "The terminal is no longer asking for a password. Nothing was typed.")
    }

    func testCancelDeclinesTheAskpassPrompt() async {
        let (session, client) = setUpSession()
        let entry = SecretEntry(target: .askpass(prompt(id: 4)), hostId: "h", session: session,
                                vault: MemoryAskpassVault(), vaultAvailable: true)
        entry.secret = "typed"
        await entry.cancel()
        XCTAssertEqual(entry.secret, "")
        XCTAssertEqual(client.state.withLock { $0.cancels }, [4])
    }
}
