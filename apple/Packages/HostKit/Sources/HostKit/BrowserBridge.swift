import Foundation
import UnnamedCore

// The app's browser, used from the host (`proto::browser`): URLs programs in a pane open
// through `BROWSER` (a sign-in), and browser tools agents call. The daemon sends each to one
// connection, the device the pane was last used from.

/// The browser half of `UnnamedCore.DaemonClient`, so the session can be tested with a fake.
nonisolated public protocol BrowserClientAPI: AnyObject, Sendable {
    func setBrowserListener(listener: any BrowserListener)
    func answerBrowserCall(id: UInt64, result: String?, error: String?)
}

extension DaemonClient: BrowserClientAPI {}

nonisolated final class BrowserRelay: BrowserListener {
    private let handler: @Sendable (BrowserPush) -> Void

    init(_ handler: @escaping @Sendable (BrowserPush) -> Void) {
        self.handler = handler
    }

    func onBrowserPush(push: BrowserPush) {
        handler(push)
    }
}

/// Browser pushes from one daemon connection, handed to the app on the main actor.
@MainActor
public final class BrowserSession {
    /// Receives every push (set by `HostsModel` for the app).
    public var onPush: ((BrowserPush) -> Void)?

    private var client: (any BrowserClientAPI)?
    private var pump: Task<Void, Never>?

    public init() {}

    /// Starts following a client's browser pushes (once per dial; public for tests).
    public func attach(_ client: any BrowserClientAPI) {
        self.client = client
        pump?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserPush.self)
        client.setBrowserListener(listener: BrowserRelay { continuation.yield($0) })
        pump = Task { [weak self] in
            for await push in stream {
                self?.onPush?(push)
            }
        }
    }

    func detach() {
        pump?.cancel()
        pump = nil
        client = nil
    }

    /// Answers a tool call: its JSON result, or why it failed.
    public func answer(_ id: UInt64, _ result: Result<String, BrowserCallError>) {
        switch result {
        case .success(let json): client?.answerBrowserCall(id: id, result: json, error: nil)
        case .failure(let error): client?.answerBrowserCall(id: id, result: nil, error: error.message)
        }
    }
}

/// Why a browser tool call failed, in words the agent reads.
public struct BrowserCallError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
