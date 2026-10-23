import Foundation
@testable import HostKit
import Testing
import UnnamedCore

/// The other device on a canvas pane, for `apple/scripts/canvas-peers-ui-test.sh`: paired with
/// `CANVAS_PEER_TICKET` as a second device of the owner, it waits for the app's canvas pane and
/// the rectangle drawn in it, then adds an ellipse the app must show. Skipped without a ticket.
@MainActor
@Suite struct CanvasPeerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANVAS_PEER_TICKET"] != nil))
    func peerSeesTheAppsRectangleAndAddsAnEllipse() async throws {
        let ticket = try PairingTicket(try #require(ProcessInfo.processInfo.environment["CANVAS_PEER_TICKET"]))
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
        let hostId = try await model.pair(ticket, name: "peer")
        let connection = try #require(model.connection(hostId) as? DaemonConnection)
        let client = try #require(connection.client as? DaemonClient)
        try await eventually("attached", timeout: .seconds(30)) { model.record(hostId)?.sessionId != nil }
        let session = try #require(model.record(hostId)?.sessionId)

        // The app's New Canvas Split, then a rectangle drawn with Excalidraw's tool.
        try await eventually("the app's canvas pane", timeout: .seconds(240)) { !client.canvasPanes(sessionId: session).isEmpty }
        let artifact = try #require(client.canvasPanes(sessionId: session).first).artifactId
        let deadline = ContinuousClock.now + .seconds(120)
        var sawRectangle = false
        while !sawRectangle, ContinuousClock.now < deadline {
            let scene = try await client.excalidrawGet(artifactId: artifact, since: 0)
            sawRectangle = scene.elements.contains { !$0.deleted && $0.json.contains("\"type\":\"rectangle\"") }
            if !sawRectangle { try await Task.sleep(for: .milliseconds(200)) }
        }
        #expect(sawRectangle, "the app's rectangle reached this device")

        let ellipse: [String: Any] = [
            "id": "peer-ellipse", "type": "ellipse", "x": 40, "y": 40, "width": 160, "height": 90, "angle": 0,
            "strokeColor": "#e03131", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2,
            "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [], "frameId": NSNull(),
            "roundness": ["type": 2], "seed": 1_968_410_351, "version": 1, "versionNonce": 7, "isDeleted": false,
            "boundElements": NSNull(), "updated": 1_729_000_000_000, "link": NSNull(), "locked": false,
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ellipse), as: UTF8.self)
        let applied = try await client.excalidrawPut(
            artifactId: artifact, elements: [ExElement(id: "peer-ellipse", version: 1, versionNonce: 7, deleted: false, json: json)],
            appState: nil, files: [])
        #expect(applied.rejected.isEmpty)
        print("canvas peer: rectangle seen, ellipse put at revision \(applied.version)")
        // Stay connected while the app shows it.
        try await Task.sleep(for: .seconds(20))
    }
}
