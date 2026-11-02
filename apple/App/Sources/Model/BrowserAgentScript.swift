import WebKit

/// The scripts a browser page carries for agents (`BrowserAgent`).
///
/// - `agent` runs in every frame, in its own content world out of the page's reach:
///   Playwright's injected script (`AgentBrowser/playwright-injected.js`, built by
///   apple/scripts/build-agent-browser.sh) and ours on top (`AgentBrowser/agent.js`): snapshots
///   with `ref_N` references, actions that wait for their target and check what they hit, the
///   agent's cursor, labels for annotated screenshots, and pointing out an element for the agent.
///   Each frame announces itself on `frameHandler` so the app can call into it.
/// - `recorder` runs in the main frame's page world: it keeps console messages, uncaught errors
///   and the page's fetch and XHR requests for `browser_console`, `browser_network` and for
///   waiting until requests an action started are done.
enum BrowserAgentScript {
    static let world = WKContentWorld.world(name: "gudo-agent")
    /// The message handler frames announce themselves on (`{token, main}`).
    static let frameHandler = "gudoAgentFrame"

    static func install(in controller: WKUserContentController, frames: (any WKScriptMessageHandler)? = nil) {
        controller.addUserScript(WKUserScript(source: agent, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let frames { controller.add(frames, contentWorld: world, name: frameHandler) }
    }

    static let agent: String = {
        let parts = ["playwright-injected", "agent"].map { name -> String in
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                AppModel.log.fault("missing \(name, privacy: .public).js")
                return ""
            }
            return text
        }
        return parts.joined(separator: "\n;\n")
    }()

    static let recorder = #"""
    (() => {
      if (window.__gudoRecorder) return;
      const log = { console: [], network: [], pending: 0, started: 0, lastActivity: Date.now() };
      Object.defineProperty(window, "__gudoRecorder", { value: log, enumerable: false });
      const keep = (list, item) => { list.push(item); if (list.length > 300) list.shift(); };
      const text = (args) => args.map(a => {
        if (typeof a === "string") return a;
        try { return a instanceof Error ? a.stack || String(a) : JSON.stringify(a); } catch { return String(a); }
      }).join(" ").slice(0, 2000);
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level];
        console[level] = function (...args) { keep(log.console, { level, text: text(args), at: Date.now() }); return original.apply(this, args); };
      }
      addEventListener("error", e => keep(log.console, { level: "error", text: (e.message || "error") + (e.filename ? " (" + e.filename + ":" + e.lineno + ")" : ""), at: Date.now() }));
      addEventListener("unhandledrejection", e => keep(log.console, { level: "error", text: "Unhandled rejection: " + text([e.reason]), at: Date.now() }));
      const begin = (method, url) => { log.pending++; log.started++; log.lastActivity = Date.now(); return { method, url: String(url).slice(0, 500), start: performance.now() }; };
      const end = (entry, status, type) => {
        log.pending = Math.max(0, log.pending - 1); log.lastActivity = Date.now();
        keep(log.network, { ...entry, status, type: type || "", ms: Math.round(performance.now() - entry.start) });
      };
      const fetch0 = window.fetch;
      if (fetch0) window.fetch = function (input, init) {
        const entry = begin((init && init.method) || (input && input.method) || "GET", (input && input.url) || input);
        return fetch0.apply(this, arguments).then(r => { end(entry, r.status, r.headers.get("content-type")); return r; },
                                                  e => { end(entry, 0, "failed: " + e); throw e; });
      };
      const open0 = XMLHttpRequest.prototype.open, send0 = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__un = { method, url }; return open0.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        if (this.__un) {
          const entry = begin(this.__un.method, this.__un.url);
          this.addEventListener("loadend", () => end(entry, this.status, this.getResponseHeader("content-type")));
        }
        return send0.apply(this, arguments);
      };
    })();
    """#
}

/// The frames of one page that run the agent's script, by the token each announced, and the
/// web view to call into them with. Numbers (`f1`, `f2`, …) name child frames in refs.
@MainActor
final class BrowserFrames: NSObject, WKScriptMessageHandler {
    private(set) weak var webView: WKWebView?
    /// The page's web view, once a frame first speaks from it.
    var onWebView: ((WKWebView) -> Void)?
    private(set) var main: String?
    private var frames: [String: WKFrameInfo] = [:]
    private var numbers: [String: Int] = [:]
    private var next = 1

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
        if let web = message.webView, web !== webView { onWebView?(web) }
        webView = message.webView
        if body["main"] as? Bool == true, message.frameInfo.isMainFrame {
            main = token
            frames.removeAll()
        }
        frames[token] = message.frameInfo
    }

    func frame(_ token: String) -> WKFrameInfo? { frames[token] }

    var tokens: [String] { Array(frames.keys) }

    /// The child frame's number, made on first use and never reused.
    func number(of token: String) -> Int {
        if let n = numbers[token] { return n }
        numbers[token] = next
        next += 1
        return numbers[token]!
    }

    func token(of number: Int) -> String? {
        numbers.first { $0.value == number }?.key
    }
}
