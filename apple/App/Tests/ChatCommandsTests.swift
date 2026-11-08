#if os(iOS)
import GudoCore
import DesignSystem
import SwiftUI
import UIKit
import HostKit
import PaneLayout
import XCTest
@testable import App

@MainActor
final class ChatCommandsTests: XCTestCase {
    func testQueriesDoNotReplaceOrdinaryTextArgumentsOrControlCharacters() throws {
        let commands = try commands(["review:tests", "compact", "cost", "bad\nname", "compact"])
        XCTAssertEqual(ChatCommands.matches("/CO", commands: commands).map(\.name), ["compact", "cost"])
        for draft in ["Existing draft", "/compact keep this", "/cost\n", "/bad/command"] {
            XCTAssertNil(ChatCommands.query(draft))
            XCTAssertTrue(ChatCommands.matches(draft, commands: commands).isEmpty)
        }
        XCTAssertEqual(ChatCommands.matches("/review:", commands: commands).map(\.name), ["review:tests"])
        XCTAssertEqual(ChatCommands.matches("/", commands: commands).count, 3)
        XCTAssertEqual(ChatCommands.matches("", commands: try self.commands((0..<300).map { "test\($0)" })).count, 256)
    }

    func testSelectingACommandOnlyEditsThisDraftAndNeverSubmitsIt() async throws {
        let (state, hub, preferences, client) = try await fixture()
        defer { state.deactivate(); preferences.removePersistentDomain(forName: preferencesSuite) }
        withExtendedLifetime(hub) {
            state.draft = "/rev"
            let offer = ChatCommandOffer(state: state)
            XCTAssertEqual(offer.commands.map(\.name), ["review:tests"])
            XCTAssertTrue(ChatCommands.apply(offer.commands[0], offer: offer, to: state))
            XCTAssertEqual(state.draft, "/review:tests ")
            XCTAssertFalse(ChatCommands.apply(offer.commands[0], offer: offer, to: state))
            XCTAssertEqual(state.composer.phase, .idle)
            XCTAssertFalse(client.calls.contains { $0.hasPrefix("send ") || $0.hasPrefix("interrupt") })
        }
    }

    func testChangedDraftAndPresentationRoundTripInvalidateOfferedCommands() async throws {
        let (state, hub, preferences, _) = try await fixture()
        defer { state.deactivate(); preferences.removePersistentDomain(forName: preferencesSuite) }
        withExtendedLifetime(hub) {
            let offer = ChatCommandOffer(state: state)
            state.draft = "New unsent text"
            XCTAssertFalse(ChatCommands.apply(offer.commands[0], offer: offer, to: state))
            state.draft = ""
            XCTAssertTrue(state.select(.terminal, preparing: { true }))
            XCTAssertTrue(state.select(.chat, preparing: { true }))
            XCTAssertFalse(ChatCommands.apply(offer.commands[0], offer: offer, to: state))
            XCTAssertEqual(state.draft, "")
        }
    }

    func testCommandDetailBuildsItsOfferAfterRotatingTheActionScope() async throws {
        let (state, hub, preferences, _) = try await fixture()
        defer {
            state.deactivate()
            withExtendedLifetime(hub) {}
            preferences.removePersistentDomain(forName: preferencesSuite)
        }
        let previous = state.actionContext
        state.presentDetail { .commands(ChatCommandOffer(state: $0)) }
        XCTAssertNotEqual(state.actionContext, previous)
        guard case .commands(let offer) = state.detail?.content else { return XCTFail("Command detail missing") }
        XCTAssertEqual(offer.context, state.actionContext)
        XCTAssertTrue(ChatCommands.apply(offer.commands[0], offer: offer, to: state))
        XCTAssertNil(state.detail)
    }

    func testCommandSheetRendersBothSchemesWithoutSubmitting() async throws {
        let (state, hub, preferences, client) = try await fixture()
        defer {
            state.deactivate()
            withExtendedLifetime(hub) {}
            preferences.removePersistentDomain(forName: preferencesSuite)
        }
        state.draft = "/"
        let offer = ChatCommandOffer(state: state)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for dark in [true, false] {
            let root = ChatCommandSheet(offer: offer) { _ in XCTFail("Presentation must not apply a command") }
                .chromeTheme(ThemeCatalog.theme(named: dark ? "Dracula" : "Apple System Colors Light"),
                             windowTheme: dark ? .dark : .light)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.rootViewController = UIHostingController(rootView: root)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(window.rootViewController?.view.bounds.height ?? 0, 0)
            XCTAssertEqual(state.draft, "/")
            XCTAssertFalse(client.calls.contains { $0.hasPrefix("send ") || $0.hasPrefix("interrupt") })
            if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
                let name = device + "-chat-commands-" + (dark ? "dark" : "light") + ".png"
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appending(path: name))
            }
        }
    }

    private var preferencesSuite = ""

    private func fixture() async throws -> (PaneChatState, DaemonWorkspace, UserDefaults, TimelineFixtureClient) {
        preferencesSuite = "chat-command-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesSuite))
        var snapshot = try JSONDecoder().decode(TimelineSnapshot.self, from: Data(TimelineFixtureJSON.snapshot(0..<1).utf8))
        snapshot.session.commands = try commands(["compact", "review:tests"])
        let client = TimelineFixtureClient(snapshot: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: { client })
        let state = PaneChatState(member: HostPane(hostId: "fixture", pane: PaneId(7)), defaultPresentation: .chat,
                                  agent: .claude, preferences: preferences, pool: ChatModelPool())
        state.activate(in: hub)
        for _ in 0..<100 where state.model?.frame.session == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(state.model?.frame.session)
        return (state, hub, preferences, client)
    }

    private func commands(_ names: [String]) throws -> [TimelineCommand] {
        let values = names.map { ["name": $0, "description": "Run project checks", "source": "Project"] }
        return try JSONDecoder().decode([TimelineCommand].self, from: JSONSerialization.data(withJSONObject: values))
    }
}
#endif
