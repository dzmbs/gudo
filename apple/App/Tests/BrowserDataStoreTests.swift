import PaneLayout
import WebKit
import XCTest
@testable import App

/// Which cookies and storage a page gets: a host's pages never share the user's own browsing
/// or another host's.
@MainActor
final class BrowserDataStoreTests: XCTestCase {
    private let routing = DevServerRouting.shared

    func testOwnBrowsingAndEachHostHaveTheirOwnStore() {
        let own = routing.dataStore(forHost: nil)
        XCTAssertNil(own.identifier, "the user's own pages: the app's default store")
        XCTAssertTrue(own.isPersistent)

        let hostA = routing.dataStore(forHost: "store-host-a")
        let hostB = routing.dataStore(forHost: "store-host-b")
        XCTAssertEqual(hostA.identifier, DevServerRouting.storeIdentifier("store-host-a"))
        XCTAssertEqual(hostB.identifier, DevServerRouting.storeIdentifier("store-host-b"))
        XCTAssertNotEqual(hostA.identifier, hostB.identifier)
        XCTAssertTrue(hostA.isPersistent, "a host's sign-ins survive a relaunch")
        XCTAssertTrue(routing.dataStore(forHost: "store-host-a") === hostA, "one instance per host")
    }

    /// A page a host opened while its proxy is off (or the host is not connected yet, after a
    /// relaunch) must not fall back to the default store, where it could read the user's cookies.
    func testAHostsPageNeverFallsBackToTheUsersStore() async throws {
        routing.isEnabled = false
        defer { routing.isEnabled = true }
        let panes = BrowserPanes()
        let member = BrowserMember(hostId: "store-host-c", url: "https://example.com/")
        let made = await panes.pane(for: member, app: .shared)
        let pane = try XCTUnwrap(made)
        XCTAssertEqual(pane.dataStore.identifier, DevServerRouting.storeIdentifier("store-host-c"))
        XCTAssertTrue(pane.dataStore === routing.dataStore(forHost: "store-host-c"))

        let ownMade = await panes.pane(for: BrowserMember(hostId: nil, url: "https://example.com/"), app: .shared)
        let own = try XCTUnwrap(ownMade)
        XCTAssertNil(own.dataStore.identifier)
        panes.prune(keeping: [])
    }

    func testForgettingAHostDeletesItsCookies() async throws {
        let store = routing.dataStore(forHost: "store-host-d")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: "session", .value: "secret",
            .expires: Date().addingTimeInterval(3600),
        ]))
        await store.httpCookieStore.setCookie(cookie)
        let before = await store.httpCookieStore.allCookies()
        XCTAssertEqual(before.map(\.name), ["session"])
        await routing.forgetHost("store-host-d")
        let after = await routing.dataStore(forHost: "store-host-d").httpCookieStore.allCookies()
        XCTAssertTrue(after.isEmpty, "a new host with this id starts empty")
        await routing.forgetHost("store-host-d")
    }
}
