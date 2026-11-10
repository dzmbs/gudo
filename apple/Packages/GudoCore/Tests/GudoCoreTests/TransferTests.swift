import Foundation
import Testing
import GudoCore

@Suite(.serialized) struct TransferTests {
    @Test func cancellingTheTaskStopsATransferWaitingForTheHost() async throws {
        let daemon = try LocalDaemon(config: "[files]\nallow = [\"{state}\"]\n")
        let ticket = try await daemon.ticket()
        let events = Recorder()
        let client = try DaemonClient.connect(
            ticket: ticket,
            config: ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: true),
            listener: events)
        try await events.wait("connected") { all in
            all.first { if case .connected = $0 { true } else { false } }
        }
        daemon.process.terminate()
        daemon.process.waitUntilExit()

        let target = WriteTarget(
            path: daemon.stateDir.appending(path: "never.txt").path,
            ifMatch: nil, createNew: false, mkdirs: true, mode: nil)
        let upload = Task { try await client.uploadBytes(data: Data("never".utf8), target: target) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        upload.cancel()
        await #expect(throws: CancellationError.self) { try await upload.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(5))
    }
}
