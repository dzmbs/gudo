import WebKit

/// The scripts a browser page carries for agents (`BrowserAgent`).
///
/// - `agent` runs in its own content world, out of the page's reach: it reads the page as an
///   accessibility tree with `ref_N` references (kept per element until the page navigates),
///   acts on elements (pointer and key events, form values), draws the agent's cursor and a
///   highlight before each action, labels refs for annotated screenshots, and lets the user
///   point at an element for the agent.
/// - `recorder` runs in the page's world: it keeps console messages, uncaught errors and the
///   page's fetch and XHR requests for `browser_console` and `browser_network`.
enum BrowserAgentScript {
    static let world = WKContentWorld.world(name: "unnamed-agent")

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: agent, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    static let recorder = #"""
    (() => {
      if (window.__unRecorder) return;
      const log = { console: [], network: [], pending: 0, lastActivity: Date.now() };
      Object.defineProperty(window, "__unRecorder", { value: log, enumerable: false });
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
      const begin = (method, url) => { log.pending++; log.lastActivity = Date.now(); return { method, url: String(url).slice(0, 500), start: performance.now() }; };
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

    static let agent = #"""
    (() => {
      if (window.__un) return;
      const refs = new Map(), ids = new WeakMap();
      let next = 1, last = null, lastKey = "", picked = null;
      const MAX = 50000;

      const refOf = el => { let r = ids.get(el); if (!r) { r = "ref_" + next++; ids.set(el, r); refs.set(r, new WeakRef(el)); } return r; };
      const clip = (s, n) => { s = (s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };
      const INPUT_ROLES = { checkbox: "checkbox", radio: "radio", range: "slider", number: "spinbutton", search: "searchbox",
        button: "button", submit: "button", reset: "button", image: "button", file: "button", color: "button" };
      const TAG_ROLES = { A: "link", BUTTON: "button", SELECT: "combobox", TEXTAREA: "textbox", IMG: "img", NAV: "navigation",
        MAIN: "main", HEADER: "banner", FOOTER: "contentinfo", FORM: "form", UL: "list", OL: "list", LI: "listitem",
        TABLE: "table", TR: "row", TD: "cell", TH: "columnheader", DIALOG: "dialog", SUMMARY: "button", P: "paragraph",
        ASIDE: "complementary", SECTION: "region", ARTICLE: "article", LABEL: "label", OPTION: "option", IFRAME: "iframe",
        VIDEO: "video", AUDIO: "audio" };
      const INTERACTIVE = new Set(["link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "slider",
        "spinbutton", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "listbox", "treeitem"]);

      function role(el) {
        const explicit = el.getAttribute("role");
        if (explicit) return explicit.split(" ")[0];
        if (el.tagName === "A") return el.hasAttribute("href") ? "link" : "";
        if (el.tagName === "INPUT") return el.type === "hidden" ? "" : INPUT_ROLES[el.type] || "textbox";
        if (/^H[1-6]$/.test(el.tagName)) return "heading";
        if (el.isContentEditable && el.parentElement && !el.parentElement.isContentEditable) return "textbox";
        return TAG_ROLES[el.tagName] || "";
      }
      function label(el) {
        const by = el.getAttribute("aria-labelledby");
        if (by) { const t = by.split(" ").map(id => document.getElementById(id)?.innerText || "").join(" "); if (t.trim()) return t; }
        const aria = el.getAttribute("aria-label"); if (aria) return aria;
        if (el.labels && el.labels.length) return Array.from(el.labels).map(l => l.innerText).join(" ");
        return "";
      }
      function name(el, r) {
        let n = label(el);
        if (!n && (el.tagName === "IMG" || el.type === "image")) n = el.alt || "";
        if (!n && ["textbox", "searchbox", "combobox", "spinbutton"].includes(r)) n = el.placeholder || el.title || "";
        if (!n && el.tagName === "INPUT" && ["submit", "button", "reset"].includes(el.type)) n = el.value;
        if (!n && ["link", "button", "heading", "tab", "menuitem", "option", "listitem", "cell", "columnheader", "paragraph", "label", "switch", "checkbox", "radio"].includes(r))
          n = el.innerText || el.textContent || "";
        if (!n) n = el.title || "";
        return clip(n, r === "paragraph" ? 160 : 100);
      }
      function shown(el) {
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }
      function inView(el) {
        const r = el.getBoundingClientRect();
        return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
      }
      const isSecret = el => el.tagName === "INPUT" && (el.type === "password" || /^cc-|one-time-code/.test(el.autocomplete || ""));
      function state(el, r) {
        const out = [];
        if (r === "heading") out.push("level=" + el.tagName.slice(1));
        if ("checked" in el && ["checkbox", "radio", "switch"].includes(r)) out.push(el.checked ? "checked" : "unchecked");
        if (el.getAttribute("aria-expanded")) out.push(el.getAttribute("aria-expanded") === "true" ? "expanded" : "collapsed");
        if (el.disabled || el.getAttribute("aria-disabled") === "true") out.push("disabled");
        if (el === document.activeElement) out.push("focused");
        if (el.tagName === "INPUT" && el.type === "password") out.push("password");
        return out.length ? " (" + out.join(", ") + ")" : "";
      }
      function value(el, r) {
        if (!["textbox", "searchbox", "combobox", "spinbutton", "slider"].includes(r)) return "";
        if (el.tagName === "SELECT") return ' = "' + clip(el.selectedOptions[0]?.text, 60) + '"';
        if (!("value" in el) || el.value === "") return "";
        return isSecret(el) ? ' = "••••"' : ' = "' + clip(el.value, 80) + '"';
      }
      function line(el, r, indent) {
        const href = r === "link" && el.getAttribute("href") && !el.getAttribute("href").startsWith("javascript:") ? " → " + clip(el.getAttribute("href"), 80) : "";
        return "  ".repeat(indent) + r + (name(el, r) ? ' "' + name(el, r).replace(/"/g, "'") + '"' : "") + value(el, r) + state(el, r) + href + " [" + refOf(el) + "]";
      }
      const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "HEAD", "META", "LINK"]);

      function walk(root, filter, depth) {
        const lines = [];
        const visit = (el, level, d) => {
          if (SKIP.has(el.tagName) || el.id === "__un-overlay") return;
          if (el.getAttribute && el.getAttribute("aria-hidden") === "true") return;
          let r = role(el), included = false;
          if (r && shown(el) && (filter === "all" || inView(el))) {
            if (filter === "interactive") included = INTERACTIVE.has(r);
            else included = INTERACTIVE.has(r) || !!name(el, r) || ["list", "table", "form", "dialog", "navigation", "main"].includes(r);
          }
          if (included) lines.push(line(el, r, filter === "interactive" ? 0 : level));
          if (d <= 1 || (included && ["link", "button", "heading", "paragraph", "option", "listitem", "cell"].includes(r) && filter !== "interactive")) return;
          for (const child of el.children) visit(child, included ? level + 1 : level, d - 1);
          if (el.shadowRoot) for (const child of el.shadowRoot.children) visit(child, included ? level + 1 : level, d - 1);
        };
        visit(root, 0, filter === "interactive" ? 64 : depth);
        return lines;
      }
      function resolve(target) {
        if (!target) return document.activeElement || document.body;
        if (target.type === "coordinate") {
          const el = document.elementFromPoint(target.x, target.y);
          if (!el) throw new Error("Nothing is at (" + target.x + ", " + target.y + "): the viewport is " + innerWidth + "×" + innerHeight + ".");
          return el;
        }
        const el = refs.get(target.ref)?.deref();
        if (!el || !el.isConnected) throw new Error(target.ref + " is stale or not found on the current page. Re-read the page with browser_snapshot to get fresh references.");
        return el;
      }
      function point(el, target) {
        if (target && target.type === "coordinate") return { x: target.x, y: target.y };
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        const r = el.getBoundingClientRect();
        return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
      }

      // The agent's cursor and a highlight on what it is about to act on.
      function overlay() {
        let o = document.getElementById("__un-overlay");
        if (!o) {
          o = document.createElement("div");
          o.id = "__un-overlay";
          o.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647";
          o.innerHTML = '<div data-box style="position:fixed;border:2px solid #0A84FF;border-radius:6px;background:rgba(10,132,255,.12);opacity:0;transition:all .18s ease"></div>' +
            '<div data-cursor style="position:fixed;width:18px;height:18px;margin:-9px 0 0 -9px;border-radius:9px;background:#0A84FF;box-shadow:0 0 0 3px rgba(255,255,255,.85),0 2px 8px rgba(0,0,0,.35);opacity:0;transition:all .25s ease"></div>';
          document.documentElement.appendChild(o);
        }
        return o;
      }
      function show(el, p) {
        const o = overlay(), box = o.querySelector("[data-box]"), cursor = o.querySelector("[data-cursor]");
        const r = el.getBoundingClientRect();
        Object.assign(box.style, { left: r.left - 3 + "px", top: r.top - 3 + "px", width: r.width + 6 + "px", height: r.height + 6 + "px", opacity: 1 });
        Object.assign(cursor.style, { left: p.x + "px", top: p.y + "px", opacity: 1 });
        clearTimeout(o.fade);
        o.fade = setTimeout(() => { box.style.opacity = 0; cursor.style.opacity = 0; }, 1200);
      }

      function mods(m) {
        const s = (m || "").toLowerCase();
        return { shiftKey: s.includes("shift"), ctrlKey: s.includes("ctrl"), altKey: s.includes("alt") || s.includes("option"), metaKey: s.includes("cmd") || s.includes("meta") };
      }
      function pointer(el, p, type, m, detail) {
        const init = { bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, button: 0, detail: detail || 1, view: window, ...mods(m) };
        if (type.startsWith("pointer")) el.dispatchEvent(new PointerEvent(type, { ...init, pointerId: 1, pointerType: "mouse", isPrimary: true }));
        else el.dispatchEvent(new MouseEvent(type, init));
      }
      function click(el, p, m, detail) {
        pointer(el, p, "pointerdown", m, detail); pointer(el, p, "mousedown", m, detail);
        if (el.focus) el.focus({ preventScroll: true });
        pointer(el, p, "pointerup", m, detail); pointer(el, p, "mouseup", m, detail);
        pointer(el, p, "click", m, detail);
      }
      function setValue(el, v) {
        const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, "value").set.call(el, v);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }
      function insert(el, text) {
        if (el.isContentEditable) { document.execCommand("insertText", false, text); return; }
        if (!("value" in el)) throw new Error("The focused element does not take text; target a text field.");
        const start = el.selectionStart ?? el.value.length, end = el.selectionEnd ?? el.value.length;
        setValue(el, el.value.slice(0, start) + text + el.value.slice(end));
        try { el.setSelectionRange(start + text.length, start + text.length); } catch {}
      }
      const KEYS = { enter: "Enter", return: "Enter", tab: "Tab", escape: "Escape", esc: "Escape", backspace: "Backspace",
        delete: "Delete", space: " ", up: "ArrowUp", down: "ArrowDown", left: "ArrowLeft", right: "ArrowRight",
        arrowup: "ArrowUp", arrowdown: "ArrowDown", arrowleft: "ArrowLeft", arrowright: "ArrowRight",
        home: "Home", end: "End", pageup: "PageUp", pagedown: "PageDown" };
      function press(chord) {
        const parts = chord.split("+"), key = KEYS[parts[parts.length - 1].toLowerCase()] || parts[parts.length - 1];
        const m = mods(parts.slice(0, -1).join("+")), el = document.activeElement || document.body;
        const init = { key, code: key.length === 1 ? "Key" + key.toUpperCase() : key, bubbles: true, cancelable: true, composed: true, ...m };
        const go = el.dispatchEvent(new KeyboardEvent("keydown", init));
        if (key.length === 1 && !m.metaKey && !m.ctrlKey) el.dispatchEvent(new KeyboardEvent("keypress", init));
        if (go) {
          if ((m.metaKey || m.ctrlKey) && key.toLowerCase() === "a") { if (el.select) el.select(); else document.execCommand("selectAll"); }
          else if (key === "Enter" && el.form && el.tagName === "INPUT") el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
          else if (key === "Enter" && (el.tagName === "A" || el.tagName === "BUTTON")) el.click();
          else if (key === "Backspace" && "value" in el) {
            const s = el.selectionStart ?? el.value.length, e = el.selectionEnd ?? s;
            setValue(el, s === e ? el.value.slice(0, Math.max(0, s - 1)) + el.value.slice(e) : el.value.slice(0, s) + el.value.slice(e));
          }
          else if (key === "Tab") {
            const all = Array.from(document.querySelectorAll("a[href],button,input,select,textarea,[tabindex]:not([tabindex='-1'])")).filter(shown);
            const i = all.indexOf(el); (all[(i + (m.shiftKey ? -1 : 1) + all.length) % all.length] || el).focus();
          }
          else if (key.length === 1 && !m.metaKey && !m.ctrlKey && ("value" in el || el.isContentEditable)) insert(el, key);
        }
        el.dispatchEvent(new KeyboardEvent("keyup", init));
      }

      // What needs the user: sign-in, payment and sending steps are theirs on the device.
      const RISKY = /\b(buy|pay|purchase|place (your )?order|checkout|check out|subscribe|donate|transfer|send money|confirm (payment|purchase|order)|delete (my )?account)\b/i;
      function sensitive(el, kind, args) {
        const submits = kind === "click" || (kind === "press" && /\b(enter|return)\b/i.test(args.keys || "")) || (kind === "type" && args.submit);
        if ((kind === "type" || kind === "fill") && isSecret(el)) return { kind: "handoff", reason: "Sign-in or payment details go in on the device: type them yourself, then tap Done." };
        if (submits) {
          const text = clip((el.innerText || el.value || el.getAttribute("aria-label") || ""), 80);
          const form = el.form || el.closest?.("form");
          if (RISKY.test(text)) return { kind: "approve", reason: 'The agent wants to press “' + text + '”.' };
          if (form && (el.type === "submit" || kind !== "click") && form.querySelector("input[type=password],input[autocomplete^=cc-]"))
            return { kind: "approve", reason: "The agent wants to submit a sign-in or payment form." };
        }
        return null;
      }
      const captcha = () => !!document.querySelector("iframe[src*='recaptcha'],iframe[src*='hcaptcha'],iframe[src*='challenges.cloudflare'],.g-recaptcha,.h-captcha,.cf-turnstile");

      window.__un = {
        snapshot(args) {
          const filter = args.filter || "interactive", depth = Math.max(1, args.depth || 15);
          const root = args.ref ? resolve({ type: "ref", ref: args.ref }) : document.body;
          const lines = walk(root, filter, depth);
          const key = location.href + "|" + filter + "|" + (args.ref || "") + "|" + depth;
          const head = "Page: " + clip(document.title, 120) + " — " + location.href + (captcha() ? "\nThis page shows a CAPTCHA: ask the user to solve it on the device." : "");
          let body;
          if (!args.full && last && lastKey === key) {
            const before = new Set(last), now = new Set(lines);
            const added = lines.filter(l => !before.has(l)), removed = last.filter(l => !now.has(l));
            body = added.length || removed.length
              ? "Changed since the last snapshot:\n" + added.map(l => "+ " + l.trim()).concat(removed.map(l => "- " + l.trim())).join("\n")
              : "No change since the last snapshot.";
          } else {
            body = lines.length ? lines.join("\n") : "(no " + (filter === "interactive" ? "interactive " : "") + "elements" + (filter === "all" ? "" : " in view") + ")";
          }
          last = lines; lastKey = key;
          let text = head + "\n" + body;
          if (text.length > MAX) text = text.slice(0, MAX) + "\n… cut at " + MAX + " characters: narrow it with depth or ref.";
          return text;
        },
        find(query) {
          const words = query.toLowerCase().split(/\W+/).filter(w => w.length > 1);
          const scored = [];
          const visit = el => {
            if (SKIP.has(el.tagName)) return;
            const r = role(el);
            if (r && shown(el)) {
              const hay = (r + " " + name(el, r) + " " + (el.placeholder || "") + " " + (el.name || "") + " " + (el.id || "") + " " + (el.type || "")).toLowerCase();
              const score = words.reduce((s, w) => s + (hay.includes(w) ? 1 : 0), 0) + (INTERACTIVE.has(r) ? 0.5 : 0);
              if (score >= 1) scored.push([score, el, r]);
            }
            for (const c of el.children) visit(c);
          };
          visit(document.body);
          scored.sort((a, b) => b[0] - a[0]);
          const out = scored.slice(0, 20).map(([, el, r]) => line(el, r, 0));
          return out.length ? out.join("\n") : "Nothing on the page matches “" + query + "”.";
        },
        text() {
          const main = document.querySelector("main, article, [role=main]");
          let t = (main ? main.innerText + "\n\n" : "") + document.body.innerText;
          t = "Page: " + clip(document.title, 120) + " — " + location.href + "\n" + t.trim();
          return t.length > MAX ? t.slice(0, MAX) + "\n… cut at " + MAX + " characters." : t;
        },
        // Two calls a moment apart (the caller waits between them), so the user sees what comes:
        // "show" checks the step and highlights its target, "do" performs it.
        act(args) {
          const kind = args.kind, el = resolve(args.target);
          if (!args.approved) { const need = sensitive(el, kind, args); if (need) return { needsUser: need }; }
          const p = point(el, args.target);
          if (args.phase === "show") { show(el, p); return { shown: true, hidden: document.visibilityState === "hidden" }; }
          switch (kind) {
            case "click": click(el, p, args.modifiers, 1); if (args.native) el.click(); break;
            case "double_click": click(el, p, args.modifiers, 1); click(el, p, args.modifiers, 2); pointer(el, p, "dblclick", args.modifiers, 2); break;
            case "hover": for (const t of ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"]) pointer(el, p, t); break;
            case "type":
              if (args.target) { click(el, p); }
              insert(document.activeElement && document.activeElement !== document.body ? document.activeElement : el, args.text);
              if (args.submit) press("Enter");
              break;
            case "fill": {
              if (el.tagName === "SELECT") {
                const want = String(args.value).toLowerCase();
                const option = Array.from(el.options).find(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want);
                if (!option) throw new Error("No option “" + args.value + "”; the options are: " + Array.from(el.options).map(o => o.text.trim()).join(", "));
                setValue(el, option.value);
              } else if (el.type === "checkbox" || el.type === "radio") {
                if (el.checked !== !!args.value) click(el, p);
              } else if ("value" in el) { el.focus(); setValue(el, String(args.value)); }
              else if (el.isContentEditable) { el.focus(); document.execCommand("selectAll"); document.execCommand("insertText", false, String(args.value)); }
              else throw new Error("That element is not a form field.");
              break;
            }
            case "press": for (let i = 0; i < (args.repeat || 1); i++) for (const chord of args.keys.split(/\s+/).filter(Boolean)) press(chord); break;
            case "scroll": {
              const d = (args.amount || 3) * 120, dx = args.direction === "left" ? -d : args.direction === "right" ? d : 0, dy = args.direction === "up" ? -d : args.direction === "down" ? d : 0;
              let s = args.target ? el : document.scrollingElement;
              while (s && s !== document.scrollingElement && !(s.scrollHeight > s.clientHeight || s.scrollWidth > s.clientWidth)) s = s.parentElement;
              (s || document.scrollingElement).scrollBy({ left: dx, top: dy, behavior: "instant" });
              break;
            }
            case "scroll_to": break;
            default: throw new Error("Unknown action " + kind);
          }
          return { done: true };
        },
        met(args) {
          return !!((args.text && document.body.innerText.includes(args.text)) || (args.selector && document.querySelector(args.selector)));
        },
        viewport() {
          const d = document.documentElement;
          return { width: innerWidth, height: innerHeight, x: scrollX, y: scrollY,
                   pageWidth: Math.max(d.scrollWidth, innerWidth), pageHeight: Math.max(d.scrollHeight, innerHeight) };
        },
        label(on) {
          const o = overlay();
          o.querySelectorAll("[data-label]").forEach(n => n.remove());
          if (!on) return 0;
          let n = 0;
          for (const l of walk(document.body, "interactive", 64)) {
            const ref = l.match(/\[(ref_\d+)\]$/)?.[1], el = ref && refs.get(ref)?.deref();
            if (!el) continue;
            const r = el.getBoundingClientRect(), tag = document.createElement("div");
            tag.dataset.label = "";
            tag.textContent = ref.slice(4);
            tag.style.cssText = "position:fixed;left:" + Math.max(0, r.left) + "px;top:" + Math.max(0, r.top) + "px;font:bold 11px -apple-system;color:#fff;background:#E5484D;padding:0 3px;border-radius:3px;line-height:15px";
            o.appendChild(tag); n++;
          }
          return n;
        },
        // The user points at an element for the agent: the next tap is captured, not acted on;
        // `picked` hands it over once.
        pick() {
          picked = null;
          const handler = e => {
            e.preventDefault(); e.stopPropagation();
            removeEventListener("click", handler, true);
            const el = e.target, r = role(el) || el.tagName.toLowerCase();
            show(el, { x: e.clientX, y: e.clientY });
            picked = line(el, r, 0) + "\n  on " + location.href + (el.innerText ? "\n  text: " + clip(el.innerText, 200) : "");
          };
          addEventListener("click", handler, true);
          return true;
        },
        picked() { const p = picked; picked = null; return p || ""; },
      };
      addEventListener("pagehide", () => { last = null; });
    })();
    """#
}
