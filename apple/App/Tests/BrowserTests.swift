import XCTest
@testable import App

/// Sign-ins of programs on a host (`claude /login`, `codex login`): which URLs are sign-ins,
/// where their callback goes, and the code Claude Code wants pasted.
final class BrowserTests: XCTestCase {
    func testClaudesBrowserURLReturnsToALoopbackPort() throws {
        // What Claude Code hands to `BROWSER` (its callback server on 127.0.0.1).
        let url = try XCTUnwrap(URL(string: "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A39563%2Fcallback&scope=user%3Ainference&code_challenge=x&code_challenge_method=S256&state=s"))
        XCTAssertEqual(SignInLink(url), .loopback(port: 39563, path: "/callback"))
    }

    func testCodexLoginURLReturnsToItsFixedPort() throws {
        let url = try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_x&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid&state=s"))
        XCTAssertEqual(SignInLink(url), .loopback(port: 1455, path: "/auth/callback"))
        let ip = try XCTUnwrap(URL(string: "https://idp.example/authorize?redirect_uri=http://127.0.0.1:8085"))
        XCTAssertEqual(SignInLink(ip), .loopback(port: 8085, path: "/"))
    }

    func testClaudesPrintedURLShowsACodeToPaste() throws {
        let url = try XCTUnwrap(URL(string: "https://claude.ai/oauth/authorize?code=true&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s"))
        XCTAssertEqual(SignInLink(url), .pastedCode)
        let page = try XCTUnwrap(URL(string: "https://platform.claude.com/oauth/code/callback?code=AbC-123&state=xyz"))
        XCTAssertEqual(SignInLink.pastedCode(from: page), "AbC-123#xyz")
        XCTAssertNil(SignInLink.pastedCode(from: try XCTUnwrap(URL(string: "https://platform.claude.com/oauth/code/callback?code=AbC"))))
        XCTAssertNil(SignInLink.pastedCode(from: try XCTUnwrap(URL(string: "https://evil.example/oauth/code/callback?code=a&state=b"))))
    }

    func testOtherLinksAreNotSignIns() throws {
        for text in [
            "https://github.com/anthropics/claude-code",
            "http://localhost:5173/",
            "https://example.com/login?redirect_uri=https%3A%2F%2Fexample.com%2Fhome",
            "https://example.com/?redirect_uri=http%3A%2F%2Flocalhost%2Fcb",
        ] {
            XCTAssertNil(SignInLink(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testTheCallbackIsTheProvidersAnswer() {
        XCTAssertTrue(SignInLink.isCallback("/callback?code=a&state=b", path: "/callback"))
        XCTAssertTrue(SignInLink.isCallback("/auth/callback?error=access_denied", path: "/auth/callback"))
        XCTAssertFalse(SignInLink.isCallback("/", path: "/callback"))
        XCTAssertFalse(SignInLink.isCallback("/callback", path: "/callback"))
        XCTAssertFalse(SignInLink.isCallback("/success?code=a", path: "/callback"))
    }
}
