import Foundation
@testable import HostKit
import Synchronization
import Testing
import GudoCore

/// Starts `work` on the main actor, then queues a second main-actor job behind it: work that
/// keeps the main actor until it finishes is done before that job runs.
@MainActor
private func finishesBeforeTheNextMainActorJob<Value: Sendable>(
    _ work: @escaping @MainActor () async throws -> Value
) async throws -> (value: Value, heldTheMainActor: Bool) {
    let finished = Mutex(false)
    let started = Task { @MainActor in
        let value = try await work()
        finished.withLock { $0 = true }
        return value
    }
    let next = Task { @MainActor in finished.withLock { $0 } }
    let heldTheMainActor = await next.value
    return (try await started.value, heldTheMainActor)
}

@MainActor
@Suite struct KeyWorkOffMainTests {
    @Test func generatingAnRSAKeyKeepsTheMainActorFree() async throws {
        let keys = KeyStore(secrets: MemorySecretStore(), directory: temporaryDirectory())
        let (key, heldTheMainActor) = try await finishesBeforeTheNextMainActorJob {
            try await keys.generate(label: "old server", type: .rsa4096, passphrase: "secret")
        }
        #expect(key.typeName == "RSA")
        #expect(key.encrypted == true)
        #expect(!heldTheMainActor)
    }

    @Test func importingAnEncryptedKeyKeepsTheMainActorFree() async throws {
        let generated = try await Task.detached {
            try generateSshKey(keyType: .rsa4096, comment: "laptop", passphrase: "secret")
        }.value
        let keys = KeyStore(secrets: MemorySecretStore(), directory: temporaryDirectory())
        let (imported, heldTheMainActor) = try await finishesBeforeTheNextMainActorJob {
            try await keys.importKey(pem: generated.privateKey, passphrase: "secret", label: "laptop")
        }
        #expect(imported.fingerprint == generated.fingerprint)
        #expect(!heldTheMainActor)
        await #expect(throws: (any Error).self) {
            try await keys.importKey(pem: generated.privateKey, passphrase: "wrong", label: "laptop")
        }
    }
}
