import WebKit
import XCTest
@testable import App

/// Major sites serve the in-app browser the pages they serve Safari. Live pages, so they run only
/// with `TEST_RUNNER_GUDO_NETWORK_TESTS=1`.
@MainActor
final class BrowserCompatibilityTests: XCTestCase {
    func testTheUserAgentEndsLikeSafaris() {
        XCTAssertEqual(BrowserUserAgent.applicationName(safariVersion: "26.1", mobile: false), "Version/26.1 Safari/605.1.15")
        XCTAssertEqual(BrowserUserAgent.applicationName(safariVersion: "26.1", mobile: true), "Version/26.1 Mobile/15E148 Safari/604.1")
        XCTAssertTrue(BrowserUserAgent.safariVersion.hasPrefix("\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
    }

    func testWebsitesGetTheSystemLanguagesUnlessOneIsChosen() {
        XCTAssertEqual(WebsiteLanguage.defaultTag, "")
        XCTAssertNil(WebsiteLanguage.acceptLanguage(WebsiteLanguage.defaultTag))
    }

    func testGoogleServesItsCurrentHomePage() async throws {
        let page = try await load("https://www.google.com/").page
        let modern = try await page.run("return !!document.querySelector('textarea[name=q]')", in: .page) as? Bool
        XCTAssertEqual(modern, true, "the current search box, not the basic HTML page")
        let agent = try await page.run("return navigator.userAgent", in: .page) as? String
        XCTAssertTrue(agent?.contains(" Safari/") == true, agent ?? "")
    }

    func testGitHubAndYouTubeRender() async throws {
        let github = try await load("https://github.com/").page
        let githubTitle = github.title
        XCTAssertTrue(githubTitle.contains("GitHub"), githubTitle)
        let youtube = try await load("https://www.youtube.com/").page
        let unsupported = try await youtube.run(
            "return /browser is not supported|browser isn't supported|update your browser/i.test(document.body.innerText)", in: .page) as? Bool
        XCTAssertEqual(youtube.title, "YouTube")
        XCTAssertEqual(unsupported, false)
    }

    private func load(_ address: String) async throws -> BrowserPane {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GUDO_NETWORK_TESTS"] == "1", "live sites (TEST_RUNNER_GUDO_NETWORK_TESTS=1)")
        let pane = BrowserPane(url: URL(string: address)!, dataStore: .nonPersistent())
        pane.load(URL(string: address)!)
        let deadline = Date.now.addingTimeInterval(30)
        repeat { try await Task.sleep(for: .milliseconds(250)) } while (pane.page.isLoading || pane.page.url == nil) && Date.now < deadline
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(pane.page.isLoading, "\(address) loaded")
        return pane
    }
}
