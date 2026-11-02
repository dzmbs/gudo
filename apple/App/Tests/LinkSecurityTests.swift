import Foundation
import HostKit
import XCTest
@testable import App

/// What links, launch arguments and hosts may make the app do on their own.
@MainActor
final class LinkSecurityTests: XCTestCase {
    /// A valid ticket for daemon `abab…` (never dialled).
    static let ticket = "gudo://pair/AGV2XK5LVOV2XK5LVOV2XK5LVOV2XK5LVOV2XK5LVOV2XK5LVOV2WAIAP4AAAAOREIARM2DUORYHGORPF5ZGK3DBPEXGK6DBNVYGYZJPAEAQCAIBAEAQCAIBAEAQCAIBAEBAEAQCAIBAEAQCAIBAEAQCAIBIBIHRYKYTI"

    func testAPairingLinkShowsAddHostAndPairsNothing() throws {
        let model = WindowModel(app: .shared)
        let hosts = AppModel.shared.hosts.records.map(\.id)
        let link = try XCTUnwrap(URL(string: Self.ticket))
        XCTAssertNotNil(PairingTicket(url: link), "the fixture is a pairing link")

        model.openLink(link)

        XCTAssertEqual(model.sheet, .pairing)
        XCTAssertEqual(model.pairingMode, .ticket)
        XCTAssertEqual(model.pairingTicket, Self.ticket)
        XCTAssertEqual(AppModel.shared.hosts.records.map(\.id), hosts, "no host was added by the link")
    }

    func testAnInviteLinkOnlyOpensTheJoinSheet() {
        let model = WindowModel(app: .shared)
        model.openLink(URL(string: "\(WindowContent.urlScheme)://join/whatever")!)
        XCTAssertEqual(model.sheet, .join)
    }

    func testUniversalLinksOpenLikeTheAppsOwn() throws {
        let model = WindowModel(app: .shared)
        let payload = String(Self.ticket.dropFirst("gudo://pair/".count))
        model.openLink(try XCTUnwrap(URL(string: "https://\(Brand.webDomain)/pair#\(payload)")))
        XCTAssertEqual(model.sheet, .pairing)
        XCTAssertEqual(model.pairingTicket, "\(WindowContent.urlScheme)://pair/\(payload)")

        let join = try XCTUnwrap(URL(string: "https://\(Brand.webDomain)/join#abc"))
        XCTAssertEqual(AppLinks.fromWeb(join, scheme: "gudo")?.absoluteString, "gudo://join/abc")
        for other in ["https://elsewhere.example/join#abc", "http://\(Brand.webDomain)/join#abc", "https://\(Brand.webDomain)/admin#abc", "https://\(Brand.webDomain)/join"] {
            XCTAssertNil(AppLinks.fromWeb(try XCTUnwrap(URL(string: other)), scheme: "gudo"), other)
        }
    }

    func testTestHooksComeFromLaunchArgumentsOnly() {
        // Saved defaults (another process can write them) never turn a hook on.
        UserDefaults.standard.set(true, forKey: "testTrustHostKeys")
        UserDefaults.standard.set("/tmp/evil", forKey: "testBundledDaemons")
        defer {
            UserDefaults.standard.removeObject(forKey: "testTrustHostKeys")
            UserDefaults.standard.removeObject(forKey: "testBundledDaemons")
        }
        XCTAssertFalse(LaunchArguments().bool(forKey: "testTrustHostKeys"))
        XCTAssertNil(LaunchArguments().string(forKey: "testBundledDaemons"))
        // Launch arguments still work (UI tests).
        let arguments = LaunchArguments(["testTrustHostKeys": "YES", "testLinkDelayMs": "600"])
        XCTAssertTrue(arguments.bool(forKey: "testTrustHostKeys"))
        XCTAssertEqual(arguments.integer(forKey: "testLinkDelayMs"), 600)
    }

    func testHostsOpenWebPagesOnly() {
        for good in ["https://example.com/login", "http://localhost:3000/"] {
            XCTAssertTrue(HostLinks.mayOpen(URL(string: good)!), good)
        }
        for bad in [
            "file:///Users/me/.ssh/id_ed25519", "\(WindowContent.urlScheme)://pair/x", "javascript:alert(1)",
            "x-apple.systempreferences:com.apple.preference.security", "smb://attacker/share", "https://",
        ] {
            XCTAssertFalse(HostLinks.mayOpen(URL(string: bad)!), bad)
        }
        XCTAssertFalse(HostLinks.mayOpenExternally(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertTrue(HostLinks.mayOpenExternally(URL(string: "mailto:a@example.com")!))
    }

    func testTheCanvasNeverLeavesItsBundle() {
        let own = URL(string: "\(CanvasWebView.scheme)://bundle/index.html")!
        XCTAssertEqual(CanvasWebView.policy(for: own, mainFrame: true), .allow)
        XCTAssertEqual(CanvasWebView.policy(for: URL(string: "https://evil.example")!, mainFrame: true), .cancel)
        XCTAssertEqual(CanvasWebView.policy(for: URL(string: "file:///etc/passwd")!, mainFrame: true), .cancel)
        // A scene's embedded video still loads inside the page.
        XCTAssertEqual(CanvasWebView.policy(for: URL(string: "https://www.youtube.com/embed/x")!, mainFrame: false), .allow)
        XCTAssertEqual(CanvasWebView.policy(for: URL(string: "file:///etc/passwd")!, mainFrame: false), .cancel)
    }
}
