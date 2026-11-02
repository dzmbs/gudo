import DesignSystem
import Foundation
import WebKit

/// Replay in Browser: runs a recorded session again in a new browser tab, finding each
/// step's element by its Playwright selector, or on a miss by its role, name and index (the
/// page changed since). Steps without either are skipped; what happened shows as toasts.
@MainActor
enum BrowserReplayRunner {
    static func run(_ session: ReplaySession, in window: WindowModel) {
        guard let start = session.startURL.flatMap(URL.init(string:)) else { return }
        let member = window.openBrowser(start, hostId: session.hostId, placement: .tab)
        Task {
            guard let pane = await window.browsers.pane(for: member, app: window.app) else { return }
            pane.start()
            await settle(pane)
            var done = 0, healed = 0, skipped = 0
            for (index, action) in session.actions.enumerated() {
                pane.agentActivity = "Replaying step \(index + 1) of \(session.actions.count)"
                switch await perform(action, on: pane, first: index == 0) {
                case .done: done += 1
                case .healed: done += 1; healed += 1
                case .skipped: skipped += 1
                }
                await settle(pane)
            }
            pane.agentActivity = nil
            let note = (healed > 0 ? " · \(healed) found by role" : "") + (skipped > 0 ? " · \(skipped) skipped" : "")
            window.toasts.show(Toast("Replayed \(done) of \(session.actions.count) steps" + note,
                                     systemImage: skipped == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                     style: skipped == 0 ? .success : .failure))
        }
    }

    enum Outcome { case done, healed, skipped }

    static func perform(_ action: ReplayAction, on pane: BrowserPane, first: Bool) async -> Outcome {
        let input = action.arguments
        switch action.kind {
        case "navigate":
            switch (input["url"] as? String ?? "").lowercased() {
            case "back": pane.page.goBack()
            case "forward": pane.page.goForward()
            case "reload": pane.page.reloadPage()
            default:
                // The tab opened on the first page already.
                if !first, let url = (action.urlAfter ?? input["url"] as? String).flatMap(URL.init(string:)) { pane.load(url) }
            }
            return .done
        case "press", "type" where input["target"] == nil, "scroll" where input["target"] == nil:
            return await act(action, pane, at: nil) ? .done : .skipped
        default:
            guard let found = await locate(action, pane) else { return .skipped }
            return await act(action, pane, at: found.point) ? (found.healed ? .healed : .done) : .skipped
        }
    }

    /// The element's centre in the viewport (CSS pixels), scrolled into view.
    private static func locate(_ action: ReplayAction, _ pane: BrowserPane) async -> (point: CGPoint, healed: Bool)? {
        guard action.selector != nil || action.role != nil else { return nil }
        let script = """
            const P = globalThis.__gudoPlaywright;
            if (!P) return null;
            const pw = new P.InjectedScript(window, { isUnderTest: false, sdkLanguage: "javascript", frameSeq: 0,
              testIdAttributeName: "data-testid", stableRafCount: 1, browserName: "webkit", customEngines: [] });
            const all = s => { try { return pw.querySelectorAll(pw.parseSelector(s), document); } catch { return []; } };
            let el = args.selector ? all(args.selector)[0] : null, healed = false;
            if (!el && args.role) {
              const name = args.name == null ? "" : "[name=" + JSON.stringify(args.name) + "s]";
              el = all("internal:role=" + args.role + name)[args.nth || 0];
              healed = !!el;
            }
            if (!el) return null;
            el.scrollIntoView({ block: "center", inline: "center" });
            const r = el.getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2, healed];
            """
        var args: [String: Any] = [:]
        args["selector"] = action.selector
        args["role"] = action.role
        args["name"] = action.name
        args["nth"] = action.nth
        guard let found = try? await pane.page.run(script, arguments: ["args": args], in: BrowserAgentScript.world) as? [Any],
              found.count == 3, let x = found[0] as? NSNumber, let y = found[1] as? NSNumber
        else { return nil }
        return (CGPoint(x: x.doubleValue, y: y.doubleValue), found[2] as? Bool ?? false)
    }

    /// The step through the agent's own page script, at a point (or the focus). Steps that
    /// wait for the user (paying, signing in) are skipped, never approved here.
    private static func act(_ action: ReplayAction, _ pane: BrowserPane, at point: CGPoint?) async -> Bool {
        var input = action.arguments
        input["kind"] = action.kind
        input["phase"] = "do"
        if let point { input["target"] = ["type": "coordinate", "x": point.x, "y": point.y] } else { input["target"] = nil }
        let result = try? await pane.page.run(
            "return window.__un ? window.__un.act(args) : null", arguments: ["args": input], in: BrowserAgentScript.world) as? [String: Any]
        guard let result else { return false }
        return result["needsUser"] == nil
    }

    private static func settle(_ pane: BrowserPane) async {
        try? await Task.sleep(for: .milliseconds(400))
        let deadline = ContinuousClock.now + .seconds(10)
        while pane.page.isLoading, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
