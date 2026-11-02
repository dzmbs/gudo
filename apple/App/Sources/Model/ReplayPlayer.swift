import Foundation
import Observation
import WebKit

/// rrweb-player for one session in a page of its own: a throwaway data store, nothing it may
/// navigate to, and the recorded page drawn in rrweb's script-less sandboxed frame. A session
/// opened from a file also loads nothing from the network.
@MainActor
@Observable
final class ReplayPlayer {
    let page: WebPage
    /// Milliseconds from the first event; the whole length.
    private(set) var current = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    /// The recording's first event (ms since 1970): actions are placed against it.
    private(set) var startTime = 0.0
    private(set) var isReady = false
    /// The session has no page events to play (pictures only).
    private(set) var isEmpty = false
    var speed = 1.0 {
        didSet { call("replay.speed(args.s)", ["s": speed]) }
    }

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var size = CGSize(width: 800, height: 600)

    init(offline: Bool) async {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        if offline, let rules = await Self.offlineRules() {
            configuration.userContentController.add(rules)
        }
        page = WebPage(configuration: configuration, navigationDecider: Decider())
    }

    /// Loads the session's events (`[…]` JSON text) into the player at the given size.
    func load(events json: String, size: CGSize) async {
        self.size = size
        do {
            for try await event in page.load(html: Self.html, baseURL: URL(string: "about:blank")!) where event == .finished { break }
        } catch {
            isEmpty = true
            isReady = true
            return
        }
        let meta = try? await page.callJavaScript(
            "return replay.load(args.events, args.w, args.h)",
            arguments: ["args": ["events": json, "w": size.width, "h": size.height]]) as? [String: Any]
        guard let meta, meta["ok"] as? Bool == true else {
            isEmpty = true
            isReady = true
            return
        }
        startTime = (meta["start"] as? NSNumber)?.doubleValue ?? 0
        duration = (meta["total"] as? NSNumber)?.doubleValue ?? 0
        isReady = true
    }

    func offset(of action: ReplayAction) -> Double {
        min(duration, max(0, action.time.timeIntervalSince1970 * 1000 - startTime))
    }

    func play() {
        guard isReady, !isEmpty else { return }
        if current >= duration - 50 { seek(0) }
        call("replay.play()")
        isPlaying = true
        poll()
    }

    func pause() {
        call("replay.pause()")
        isPlaying = false
    }

    func seek(_ milliseconds: Double) {
        current = min(max(0, milliseconds), duration)
        call("replay.seek(args.t, args.p)", ["t": current, "p": isPlaying])
    }

    func resize(_ size: CGSize) {
        guard abs(size.width - self.size.width) > 1 || abs(size.height - self.size.height) > 1 else { return }
        self.size = size
        call("replay.resize(args.w, args.h)", ["w": size.width, "h": size.height])
    }

    func stop() {
        polling?.cancel()
    }

    private func poll() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled, let self, self.isPlaying {
                if let state = try? await self.page.callJavaScript("return replay.state()") as? [Any], state.count == 2 {
                    self.current = (state[0] as? NSNumber)?.doubleValue ?? self.current
                    if state[1] as? Bool == false, self.current >= self.duration - 50 { self.isPlaying = false }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func call(_ body: String, _ args: [String: Any] = [:]) {
        guard isReady, !isEmpty else { return }
        Task { _ = try? await page.callJavaScript("if (window.replay) " + body, arguments: ["args": args]) }
    }

    /// Only the player's own page loads; links in the recording go nowhere.
    private struct Decider: WebPage.NavigationDeciding {
        mutating func decidePolicy(
            for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            action.request.url?.scheme == "about" ? .allow : .cancel
        }
    }

    private static func offlineRules() async -> WKContentRuleList? {
        let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp):"},"action":{"type":"block"}}]"#
        return try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "replay-offline", encodedContentRuleList: rules)
    }

    private static func resource(_ name: String, _ fileExtension: String) -> String {
        Bundle.main.url(forResource: name, withExtension: fileExtension).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    static let html: String = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>\(resource("rrweb-player", "css"))
    html, body { margin: 0; height: 100%; overflow: hidden; background: transparent; }
    .rr-player { background: transparent !important; box-shadow: none !important; border-radius: 0 !important; float: none !important; }
    .rr-player__frame { background: transparent !important; }
    .replayer-wrapper { box-shadow: 0 1px 3px rgba(0,0,0,.25); border-radius: 6px; overflow: hidden; background: #fff; }
    .replayer-mouse-tail { pointer-events: none; }
    </style>
    <script>\(resource("rrweb-player", "js").replacingOccurrences(of: "</script", with: "<\\/script"))</script>
    <script>
    (() => {
      const Player = window.rrwebPlayer.default || window.rrwebPlayer;
      let player = null, time = 0, playing = false;
      window.replay = {
        load(json, width, height) {
          const events = JSON.parse(json);
          document.body.textContent = "";
          if (events.length < 2 || !events.some(e => e.type === 2)) return { ok: false };
          player = new Player({ target: document.body, props: {
            events, width, height, autoPlay: false, showController: false, skipInactive: true,
            mouseTail: { strokeStyle: "rgba(10,132,255,0.55)", lineWidth: 2, duration: 600 } } });
          player.addEventListener("ui-update-current-time", e => { time = e.payload; });
          player.addEventListener("ui-update-player-state", e => { playing = e.payload === "playing"; });
          player.goto(0, false);
          const meta = player.getMetaData();
          return { ok: true, start: meta.startTime, total: meta.totalTime };
        },
        state() { return [time, playing]; },
        play() { player.play(); },
        pause() { player.pause(); },
        seek(ms, play) { time = ms; player.goto(ms, play); },
        speed(s) { player.setSpeed(s); },
        resize(w, h) { player.$set({ width: w, height: h }); player.triggerResize(); },
      };
    })();
    </script>
    """
}
