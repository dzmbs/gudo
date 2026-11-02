import CoreGraphics
import Foundation
import ImageIO
import WebKit

/// Records agents' browser sessions: each action with a picture of the page after it, and the
/// page itself as rrweb events, until the agent leaves the page alone for a while.
///
/// rrweb runs in a content world of its own so nothing of it is visible to the page (no globals,
/// handlers or patched prototypes). What an isolated world misses (CSSOM rules inserted after the
/// first snapshot) comes back with fresh snapshots taken after actions. Frames from other origins
/// send their events through the app rather than `postMessage`, so a page never sees what its
/// embedded frames (a payment form) recorded.
@MainActor
final class BrowserRecorder {
    static let shared = BrowserRecorder()

    static let world = WKContentWorld.world(name: "gudo-replay")

    /// A session ends after this long without an action; the next starts another.
    var idleGap: TimeInterval = 15 * 60
    var store: ReplayStore = .shared

    private struct Live {
        var session: ReplaySession
        var lastCheckout: Date
        var full = false
    }

    /// By `BrowserPane.id`.
    private var live: [UUID: Live] = [:]
    private var pages: [UUID: WeakPage] = [:]
    private var saving: [UUID: Task<Void, Never>] = [:]

    private struct WeakPage {
        weak var page: (any BrowserPageContent)?
    }

    private init() {
        BrowserAgent.shared.onAction = { [weak self] entry in self?.record(entry) }
    }

    /// The recorder in every frame, idle until a session starts.
    static func install(in controller: WKUserContentController, page id: UUID) {
        controller.addUserScript(WKUserScript(source: rrweb, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addScriptMessageHandler(Handler(page: id), contentWorld: world, name: "gudoReplay")
    }

    /// The page's configuration must have gone through `install`.
    func attach(_ page: any BrowserPageContent, id: UUID) {
        pages = pages.filter { $0.value.page != nil }
        pages[id] = WeakPage(page: page)
    }

    func isRecording(_ page: UUID) -> Bool { live[page] != nil }

    /// Cleanup leaves these alone.
    var liveSessions: Set<UUID> { Set(live.values.map(\.session.id)) }

    func record(_ entry: BrowserActionEntry) {
        guard ReplayStore.isEnabled, let page = pages[entry.page]?.page else { return }
        var current = live[entry.page]
        if let session = current?.session,
           session.hostId != entry.pane.hostId || session.paneId != entry.pane.pane.rawValue
           || entry.time.timeIntervalSince(session.ended) > idleGap
        {
            finish(entry.page)
            current = nil
        }
        if current == nil {
            let session = ReplaySession(started: entry.time, title: page.title, hostId: entry.pane.hostId, paneId: entry.pane.pane.rawValue, page: entry.page)
            guard (try? store.create(session)) != nil else { return }
            current = Live(session: session, lastCheckout: entry.time)
            live[entry.page] = current
            store.cleanUp(keeping: liveSessions)
            Task { _ = try? await page.run("window.__gudoReplay && window.__gudoReplay.start()", in: Self.world) }
        }
        guard var current else { return }
        let index = current.session.actions.count
        current.session.actions.append(ReplayAction(entry, id: index))
        current.session.ended = entry.time
        if !page.title.isEmpty { current.session.title = page.title }
        let checkout = entry.time.timeIntervalSince(current.lastCheckout) > 10
        if checkout { current.lastCheckout = entry.time }
        live[entry.page] = current
        let id = current.session.id
        let previous = saving[id]
        saving[id] = Task { [weak self] in
            await previous?.value
            let frame = await Self.keyframe(page)
            guard let self, var session = self.live[entry.page]?.session ?? self.store.session(id) else { return }
            if checkout { _ = try? await page.run("window.__gudoReplay && window.__gudoReplay.checkout()", in: Self.world) }
            if let frame, let name = self.store.writeKeyframe(frame, session: id, action: index), index < session.actions.count {
                session.actions[index].keyframe = name
                if self.live[entry.page]?.session.id == id { self.live[entry.page]?.session.actions[index].keyframe = name }
            }
            try? self.store.save(session)
        }
    }

    func finish(_ page: UUID) {
        guard let current = live.removeValue(forKey: page) else { return }
        let id = current.session.id
        Task {
            await saving[id]?.value
            saving[id] = nil
            store.close(id)
        }
    }

    func flush(_ page: UUID) async {
        guard let webPage = pages[page]?.page, let id = live[page]?.session.id else { return }
        _ = try? await webPage.run("window.__gudoReplay && window.__gudoReplay.flush()", in: Self.world)
        await saving[id]?.value
    }

    // MARK: Events from the page

    fileprivate func received(_ body: [String: Any], page: UUID, frame: WKFrameInfo) -> Any? {
        switch body["type"] as? String {
        case "hello":
            return live[page] != nil
        case "events":
            guard frame.isMainFrame, var current = live[page], !current.full else { return nil }
            let events = body["events"] as? [String] ?? []
            if !store.append(events: events, to: current.session.id) {
                current.full = true
                current.session.truncated = true
                live[page] = current
                try? store.save(current.session)
            }
            return nil
        case "frame":
            // A cross-origin frame's events go to the page's recorder, which places them.
            guard !frame.isMainFrame, live[page] != nil, let webPage = pages[page]?.page, let message = body["message"] else { return nil }
            let origin = Self.origin(frame.securityOrigin)
            let url = frame.request.url?.absoluteString ?? ""
            Task {
                _ = try? await webPage.run(
                    "window.__gudoReplay && window.__gudoReplay.frame(message, origin, url)",
                    arguments: ["message": message, "origin": origin, "url": url], in: Self.world)
            }
            return nil
        default:
            return nil
        }
    }

    static func origin(_ origin: WKSecurityOrigin) -> String {
        let defaultPort = origin.protocol == "https" ? 443 : origin.protocol == "http" ? 80 : 0
        return "\(origin.protocol)://\(origin.host)" + (origin.port == 0 || origin.port == defaultPort ? "" : ":\(origin.port)")
    }

    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        let page: UUID

        init(page: UUID) {
            self.page = page
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any] else { return (nil, nil) }
            return (BrowserRecorder.shared.received(body, page: page, frame: message.frameInfo), nil)
        }
    }

    /// The visible page as a JPEG at most 960 points wide.
    static func keyframe(_ page: any BrowserPageContent) async -> Data? {
        guard let size = try? await page.run("return [innerWidth, innerHeight]", in: world) as? [Double],
              size.count == 2, size[0] > 0, size[1] > 0,
              let data = try? await page.picture(CGRect(x: 0, y: 0, width: size[0], height: size[1]), width: min(size[0], 960))
        else { return nil }
        return jpeg(data)
    }

    nonisolated static func jpeg(_ data: Data, quality: Double = 0.6) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let jpegData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? jpegData as Data : nil
    }

    /// Built by apple/scripts/build-agent-browser.sh; exposes `__gudoRRWeb`.
    static let rrweb: String = {
        guard let url = Bundle.main.url(forResource: "rrweb-record", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }()

    /// Records only if the app says so. Same-origin frames are recorded through the top frame;
    /// cross-origin frames pass their events to the app instead of to their parent.
    static let bootstrap = #"""
    (() => {
      if (window.__gudoReplay || !window.__gudoRRWeb) return;
      const handler = window.webkit.messageHandlers.gudoReplay;
      const post = m => handler.postMessage(m);
      const top = window === window.top;
      if (!top) { try { void window.parent.document; return; } catch {} }
      let stop = null, queue = [], timer = 0, relay = null, lastFullSnapshot = 0;
      const flush = () => {
        clearTimeout(timer); timer = 0;
        if (!queue.length) return Promise.resolve();
        const events = queue; queue = [];
        return post({ type: "events", events }).catch(() => {});
      };
      const emit = event => {
        queue.push(JSON.stringify(event));
        if (event.type === 2) lastFullSnapshot = Date.now();
        if (queue.length >= 200) flush(); else if (!timer) timer = setTimeout(flush, 300);
      };
      const options = {
        emit, recordCrossOriginIframes: true,
        // Every input goes through maskInputFn, which hides passwords and card fields only.
        maskAllInputs: true,
        maskInputFn: (text, el) => !el || el.type === "password" || /^cc-/.test(el.autocomplete || "") ? "*".repeat(text.length) : text,
        sampling: { mousemove: 50, scroll: 150 },
        slimDOMOptions: { script: true, comment: true, headFavicon: true, headWhitespace: true, headMetaSocial: true,
          headMetaRobots: true, headMetaHttpEquiv: true, headMetaVerification: true, headMetaAuthorship: true },
      };
      const start = () => {
        if (stop) return true;
        const { record } = window.__gudoRRWeb;
        if (top) {
          // rrweb hears frames on window "message"; take its listener so only the app feeds it.
          window.addEventListener = function (type, fn, opts) {
            if (this === window && type === "message" && !relay) { relay = fn; return; }
            return EventTarget.prototype.addEventListener.call(this, type, fn, opts);
          };
          try { stop = record(options) || null; } finally { delete window.addEventListener; }
        } else {
          // This world's own `parent` (the page's is untouched): events go to the app.
          window.parent = {
            postMessage: m => { post({ type: "frame", message: m }).catch(() => {}); },
            get document() { throw new DOMException("cross-origin", "SecurityError"); },
          };
          stop = record(options) || null;
        }
        return true;
      };
      const frames = (doc, out) => {
        for (const f of doc.querySelectorAll("iframe, frame")) {
          out.push(f);
          try { if (f.contentDocument) frames(f.contentDocument, out); } catch {}
        }
        return out;
      };
      Object.defineProperty(window, "__gudoReplay", { value: {
        start,
        flush,
        checkout() { if (stop && top && Date.now() - lastFullSnapshot > 1000) window.__gudoRRWeb.record.takeFullSnapshot(true); return flush(); },
        // A frame's events, from the app: rrweb places them by the frame's window.
        frame(message, origin, url) {
          if (!relay || !message || typeof message !== "object") return;
          const at = f => { try { return new URL(f.src, document.baseURI); } catch { return null; } };
          const all = frames(document, []);
          const same = all.filter(f => { const u = at(f); return u && u.protocol + "//" + u.host === origin; });
          const el = all.find(f => at(f)?.href === url) || same[0];
          if (!el || !el.contentWindow) return;
          message.origin = origin;
          relay({ data: message, origin, source: el.contentWindow });
        },
      } });
      addEventListener("pagehide", () => { flush(); });
      post({ type: "hello" }).then(on => { if (on) start(); }, () => {});
    })();
    """#
}
