import XCTest
@testable import App

/// What a browser tab's address field makes of what is typed, and what it suggests.
final class BrowserAddressTests: XCTestCase {
    private func url(_ text: String, _ engine: SearchEngine = .google) -> String? {
        BrowserAddress.url(for: text, engine: engine)?.absoluteString
    }

    func testAddressesOpenAsTyped() {
        XCTAssertEqual(url("https://github.com/a/b"), "https://github.com/a/b")
        XCTAssertEqual(url("about:blank"), "about:blank")
        XCTAssertEqual(url("  example.com  "), "https://example.com")
        XCTAssertEqual(url("example.com/docs?q=1"), "https://example.com/docs?q=1")
        XCTAssertEqual(url("sub.example.co.uk:8443/x"), "https://sub.example.co.uk:8443/x")
        XCTAssertEqual(url("printer.local"), "http://printer.local")
        XCTAssertEqual(url("devbox:8080"), "http://devbox:8080")
    }

    func testLocalServersAreHTTP() {
        XCTAssertEqual(url("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(url("localhost"), "http://localhost")
        XCTAssertEqual(url("127.0.0.1:8080/api"), "http://127.0.0.1:8080/api")
        XCTAssertEqual(url("app.localhost:5173"), "http://app.localhost:5173")
        XCTAssertEqual(url(":5173"), "http://localhost:5173")
        XCTAssertEqual(url("[::1]:3000"), "http://[::1]:3000")
        XCTAssertEqual(url("192.168.1.4:3000"), "http://192.168.1.4:3000")
    }

    func testEverythingElseSearches() {
        XCTAssertEqual(url("swift concurrency"), "https://www.google.com/search?q=swift%20concurrency")
        XCTAssertEqual(url("rust", .duckDuckGo), "https://duckduckgo.com/?q=rust")
        XCTAssertEqual(url("rust", .bing), "https://www.bing.com/search?q=rust")
        XCTAssertEqual(url("rust", .kagi), "https://kagi.com/search?q=rust")
        XCTAssertEqual(url("rust", .brave), "https://search.brave.com/search?q=rust")
        XCTAssertEqual(url("3000"), "https://www.google.com/search?q=3000")
        XCTAssertEqual(url("what is example.com"), "https://www.google.com/search?q=what%20is%20example.com")
        XCTAssertEqual(url("host:notaport"), "https://www.google.com/search?q=host:notaport")
        XCTAssertNil(url("   "))
    }

    func testSuggestionsPutDevServersAndVisitedPagesBeforeTheSearch() {
        let server = DetectedPort(port: 3000, process: "node", url: "http://localhost:3000/app", isHTTP: true, loopbackOnly: true, pane: "web")
        let redis = DetectedPort(port: 6379, process: "redis", url: nil, isHTTP: false, loopbackOnly: true, pane: nil)
        let history = [
            BrowserHistory.Entry(url: "https://docs.example.com/node", title: "Node docs", visits: 9, lastVisit: .now),
            BrowserHistory.Entry(url: "https://nodejs.org/", title: "Node.js", visits: 2, lastVisit: .now),
        ]
        let found = AddressSuggestion.make(for: "node", history: history, devServers: [server, redis], engine: .kagi)
        XCTAssertEqual(found.map(\.kind), [.devServer, .page, .page, .search])
        XCTAssertEqual(found[0].url.absoluteString, "http://localhost:3000/app", "the URL the server printed")
        XCTAssertEqual(found[1].detail, "nodejs.org", "an address that starts with the text comes first")
        XCTAssertEqual(found[3].url.absoluteString, "https://kagi.com/search?q=node")

        let typedAddress = AddressSuggestion.make(for: "localhost:3", history: [], devServers: [server], engine: .google)
        XCTAssertEqual(typedAddress.map(\.kind), [.devServer], "an address is not offered as a search")
        XCTAssertTrue(AddressSuggestion.make(for: " ", history: history, devServers: [server], engine: .google).isEmpty)
    }

    func testArrowKeysWalkTheSuggestionsAndBackToTheText() {
        XCTAssertEqual(AddressSuggestion.step(-1, by: 1, count: 3), 0)
        XCTAssertEqual(AddressSuggestion.step(2, by: 1, count: 3), -1)
        XCTAssertEqual(AddressSuggestion.step(-1, by: -1, count: 3), 2)
        XCTAssertEqual(AddressSuggestion.step(0, by: -1, count: 3), -1)
        XCTAssertEqual(AddressSuggestion.step(0, by: 1, count: 0), -1)
    }

    @MainActor
    func testHistoryKeepsVisitsButNotSignInCallbacks() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BrowserAddressTests"))
        defaults.removePersistentDomain(forName: "BrowserAddressTests")
        let history = BrowserHistory(defaults: defaults)
        let page = try XCTUnwrap(URL(string: "https://example.com/"))
        history.record(page, title: "")
        history.record(page, title: "Example")
        history.record(try XCTUnwrap(URL(string: "https://platform.claude.com/oauth/code/callback?code=a&state=b")), title: nil)
        history.record(try XCTUnwrap(URL(string: "http://localhost:39563/callback?code=a&state=b")), title: nil)
        history.record(try XCTUnwrap(URL(string: "about:blank")), title: nil)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.frequent.first?.visits, 2)
        XCTAssertEqual(history.frequent.first?.title, "Example")
        XCTAssertEqual(BrowserHistory(defaults: defaults).entries.count, 1, "kept across launches")
    }
}
