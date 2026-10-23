// The agent's page script (BrowserAgentScript): runs in every frame, in the agent's content
// world, on top of Playwright's injected script (playwright-injected.js, Apache-2.0).
//
// - Snapshots: Playwright's aria tree ("ai" mode) as one line per element, `role "name" [ref_N]`.
//   A ref stays with its element; a ref whose element was re-rendered is found again by its
//   role, name and index among elements with both.
// - Actions wait until the target is visible, enabled and still, check that the point they
//   use hits it (else name what covers it), then send the input sequence a real pointer or
//   keyboard makes, each event in its own task (after Playwright's WebView input).
// - `probe`/`effect` tell whether an action changed anything.
(() => {
  if (window.__un || !globalThis.__unPlaywright) return;
  const { InjectedScript, WebViewInput, asLocator } = globalThis.__unPlaywright;
  const pw = new InjectedScript(window, {
    isUnderTest: false, sdkLanguage: "javascript", frameSeq: 0, testIdAttributeName: "data-testid",
    stableRafCount: 1, browserName: "webkit", customEngines: [],
  });
  const keyboardless = new WebViewInput(window, document);

  const refs = new Map(), ids = new WeakMap();
  let next = 1, last = null, lastKey = "", lastRefs = new Set(), picked = null;
  const MAX = 50000;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const clip = (s, n) => { s = (s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };
  const quote = s => '"' + s.replace(/"/g, "'") + '"';

  // DOM changes outside our overlay: how many, and when the last was (actions wait for quiet).
  let mutations = 0, lastMutation = Date.now();
  new MutationObserver(records => {
    for (const r of records) {
      const el = r.target.nodeType === 1 ? r.target : r.target.parentElement;
      if (el && el.closest && el.closest("#__un-overlay")) continue;
      mutations++; lastMutation = Date.now();
    }
  }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });

  // Frames: each registers with the app; a parent learns which iframe element holds which frame.
  const token = Math.random().toString(36).slice(2, 10);
  const frameTokens = new WeakMap();
  const announce = () => { try { window.webkit.messageHandlers.unAgentFrame.postMessage({ token, main: window === window.top }); } catch {} };
  announce();
  addEventListener("pageshow", e => { if (e.persisted) announce(); });
  addEventListener("message", e => {
    const d = e.data;
    if (!d || typeof d !== "object") return;
    if (typeof d.__unFrameHello === "string") {
      for (const f of document.querySelectorAll("iframe, frame")) if (f.contentWindow === e.source) frameTokens.set(f, d.__unFrameHello);
    } else if (d.__unFrameAsk === true && e.source === window.parent && window !== window.top) {
      window.parent.postMessage({ __unFrameHello: token }, "*");
    }
  });
  if (window !== window.top) window.parent.postMessage({ __unFrameHello: token }, "*");
  const askFrames = () => { for (const f of document.querySelectorAll("iframe, frame")) if (!frameTokens.has(f)) try { f.contentWindow.postMessage({ __unFrameAsk: true }, "*"); } catch {} };

  const INTERACTIVE = new Set(["link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "slider",
    "spinbutton", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "listbox", "treeitem", "iframe"]);
  const VALUE_ROLES = new Set(["textbox", "searchbox", "combobox", "spinbutton", "slider"]);
  const isSecret = el => el && el.tagName === "INPUT" && (el.type === "password" || /^cc-|one-time-code/.test(el.autocomplete || ""));
  const roleOf = el => pw.utils.getAriaRole(el) || el.tagName.toLowerCase();
  const nameOf = el => clip(pw.utils.getElementAccessibleNameText(el, false), 100);

  function deepActive() {
    let a = document.activeElement;
    while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
    return a;
  }
  function deepFromPoint(x, y) {
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) { const inner = el.shadowRoot.elementFromPoint(x, y); if (!inner || inner === el) break; el = inner; }
    return el;
  }
  function inView(el) {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  }

  // MARK: Snapshots

  function refOf(el, role, name, nth) {
    let r = ids.get(el);
    if (!r) { r = "ref_" + next++; ids.set(el, r); }
    refs.set(r, { el: new WeakRef(el), role, name, nth });
    return r;
  }
  function value(el, role) {
    if (!el || !VALUE_ROLES.has(role)) return "";
    if (el.tagName === "SELECT") return " = " + quote(clip(el.selectedOptions[0]?.text, 60));
    if (!("value" in el) || el.value === "" || el.value == null) return "";
    return isSecret(el) ? ' = "••••"' : " = " + quote(clip(String(el.value), 80));
  }
  function states(node, el) {
    const out = [];
    if (node.level) out.push("level=" + node.level);
    if (node.checked !== undefined) out.push(node.checked === "mixed" ? "mixed" : node.checked ? "checked" : "unchecked");
    if (node.expanded !== undefined) out.push(node.expanded ? "expanded" : "collapsed");
    if (node.pressed === true || node.pressed === "mixed") out.push(node.pressed === true ? "pressed" : "mixed");
    if (node.selected) out.push("selected");
    if (node.disabled) out.push("disabled");
    if (node.invalid) out.push("invalid");
    if (node.active) out.push("focused");
    if (el && el.tagName === "INPUT" && el.type === "password") out.push("password");
    return out.length ? " (" + out.join(", ") + ")" : "";
  }

  // The aria tree as lines. interactive: controls in view, flat; visible: the tree in view;
  // all: the whole tree.
  function render(root, filter, depth) {
    const snap = pw.utils.generateAriaTree(root, { mode: "ai" });
    const lines = [], counts = new Map(), shown = [];
    const elOf = n => (n.ref && snap.info.get(n.ref)?.element) || null;
    const visit = (node, level, parentView, inPointer) => {
      const textOnly = node.children.length === 1 && typeof node.children[0] === "string";
      for (const child of node.children) {
        if (typeof child === "string") {
          if (filter !== "interactive" && !textOnly && parentView && level <= depth && child.trim()) lines.push("  ".repeat(level) + "text: " + clip(child, 200));
          continue;
        }
        const el = elOf(child);
        const view = filter === "all" ? true : el ? inView(el) : parentView;
        const pointer = child.box.cursor === "pointer" && !inPointer;
        const role = child.role;
        if (role === "presentation" || role === "none") { visit(child, level, view, inPointer || pointer); continue; }
        let include;
        if (filter === "interactive") include = !!el && view && child.box.visible && (INTERACTIVE.has(role) || pointer);
        else include = view && level <= depth && !(role === "generic" && !child.name && !pointer && !(child.children.length === 1 && typeof child.children[0] === "string"));
        if (include) {
          const key = role + "\u0000" + child.name, nth = counts.get(key) || 0;
          counts.set(key, nth + 1);
          let s = "  ".repeat(filter === "interactive" ? 0 : level) + role;
          if (child.name) s += " " + quote(clip(child.name, 100));
          s += value(el, role) + states(child, el);
          if (child.props.url && !child.props.url.startsWith("javascript:")) s += " → " + clip(child.props.url, 80);
          if (child.props.placeholder && !child.name) s += " placeholder=" + quote(clip(child.props.placeholder, 60));
          if (el) { s += " [" + refOf(el, role, child.name, nth) + "]"; shown.push(el); }
          if (pointer && !INTERACTIVE.has(role)) s += " [cursor=pointer]";
          if (role === "iframe" && el) { const t = frameTokens.get(el); if (t) s += " ⟦frame " + t + "⟧"; }
          const only = child.children.length === 1 && typeof child.children[0] === "string" ? child.children[0] : "";
          if (only && !(el && VALUE_ROLES.has(role) && "value" in el)) s += ": " + clip(only, filter === "interactive" ? 80 : 200);
          lines.push(s);
        }
        if (VALUE_ROLES.has(role) && el && "value" in el) continue;
        visit(child, include ? level + 1 : level, view, inPointer || pointer || (child.box.cursor === "pointer"));
      }
    };
    visit(snap.root, 0, true, false);
    askFrames();
    return { lines, shown };
  }

  function snapshot(args) {
    const filter = args.filter || "interactive", depth = Math.max(1, args.depth || 15);
    const root = args.ref ? resolve({ type: "ref", ref: args.ref }) : (document.body || document.documentElement);
    const { lines } = render(root, filter, depth);
    const key = location.href + "|" + filter + "|" + (args.ref || "") + "|" + depth;
    const nowRefs = new Set(lines.map(l => l.match(/\[(ref_\d+)\]/)?.[1]).filter(Boolean));
    let body;
    if (!args.full && last && lastKey === key) {
      const before = new Set(last.map(l => l.trim())), now = new Set(lines.map(l => l.trim()));
      const added = lines.map(l => l.trim()).filter(l => !before.has(l)), removed = last.map(l => l.trim()).filter(l => !now.has(l));
      const fresh = l => { const r = l.match(/\[(ref_\d+)\]/)?.[1]; return r && !lastRefs.has(r); };
      // Frames are listed whether or not they changed: the app fills in their own changes.
      const framed = lines.map(l => l.trim()).filter(l => l.includes("⟦frame ") && !added.includes(l)).map(l => "= " + l);
      body = added.length || removed.length
        ? "Changed since the last snapshot (* new, + changed, - gone):\n" +
          added.map(l => (fresh(l) ? "* " : "+ ") + l).concat(removed.map(l => "- " + l)).concat(framed).join("\n")
        : ["No change since the last snapshot."].concat(framed).join("\n");
    } else {
      body = lines.length ? lines.join("\n") : "(no " + (filter === "interactive" ? "interactive " : "") + "elements" + (filter === "all" ? "" : " in view") + ")";
    }
    last = lines; lastKey = key; lastRefs = nowRefs;
    const head = args.frame ? "" : "Page: " + clip(document.title, 120) + " — " + location.href +
      (captcha() ? "\nThis page shows a CAPTCHA: ask the user to solve it on the device." : "") + "\n";
    let text = head + body;
    if (text.length > MAX) text = text.slice(0, MAX) + "\n… cut at " + MAX + " characters: narrow it with depth or ref.";
    return text;
  }

  // MARK: Targets

  let healed = null;
  function resolve(target) {
    if (!target) return deepActive() || document.body;
    if (target.type === "coordinate") {
      const el = deepFromPoint(target.x, target.y);
      if (!el) throw new Error("Nothing is at (" + target.x + ", " + target.y + "): the viewport is " + innerWidth + "×" + innerHeight + ".");
      return el;
    }
    const entry = refs.get(target.ref);
    const el = entry?.el.deref();
    if (el && el.isConnected) return el;
    if (entry) {
      const again = refind(entry);
      if (again) {
        entry.el = new WeakRef(again); ids.set(again, target.ref);
        healed = target.ref + " was re-rendered; found it again as " + entry.role + (entry.name ? " " + quote(entry.name) : "") + ".";
        return again;
      }
    }
    throw new Error(target.ref + " is stale or not found on the current page. Re-read the page with browser_snapshot to get fresh references.");
  }
  // A re-rendered element: the one with the same role and name (the nth of several).
  function refind(entry) {
    const snap = pw.utils.generateAriaTree(document.body || document.documentElement, { mode: "ai" });
    const found = [];
    const visit = node => {
      for (const c of node.children) {
        if (typeof c === "string") continue;
        const el = c.ref && snap.info.get(c.ref)?.element;
        if (el && c.role === entry.role && c.name === entry.name && el.isConnected) found.push(el);
        visit(c);
      }
    };
    visit(snap.root);
    if (found.length === 1) return found[0];
    return found[entry.nth] || null;
  }
  // What a recording needs to find the element again.
  function describe(el, target) {
    const entry = target && target.ref ? refs.get(target.ref) : null;
    const out = { role: entry?.role || roleOf(el), name: entry?.name ?? nameOf(el), nth: entry?.nth ?? 0 };
    try { out.selector = pw.generateSelectorSimple(el); out.locator = asLocator("javascript", out.selector); } catch {}
    return out;
  }

  // The point to act at: the middle of the element's largest visible box.
  function pointFor(el) {
    let best = null, area = 0;
    for (const r of el.getClientRects()) {
      const x0 = Math.max(0, r.left), y0 = Math.max(0, r.top), x1 = Math.min(innerWidth, r.right), y1 = Math.min(innerHeight, r.bottom);
      const a = (x1 - x0) * (y1 - y0);
      if (x1 > x0 && y1 > y0 && a > area) { area = a; best = { x: Math.round((x0 + x1) / 2), y: Math.round((y0 + y1) / 2) }; }
    }
    if (best) return best;
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  }
  function bringIntoView(el) {
    const r = el.getBoundingClientRect();
    if (r.top < 0 || r.left < 0 || r.bottom > innerHeight || r.right > innerWidth) el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
  }

  const MISSING = {
    visible: "is not visible", enabled: "is disabled", editable: "is read-only or disabled", stable: "keeps moving (an animation)",
  };
  // The element's box is the same twice, a frame apart (timers, not animation frames: a page
  // in a hidden pane draws none).
  async function stable(el) {
    const box = () => { const r = el.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].join(); };
    const before = box();
    if (document.visibilityState === "visible") await sleep(20); else { await task(() => {}); await task(() => {}); }
    return box() === before;
  }
  // Waits (at most 3 s) until the element can take the action.
  async function actionable(el, kind, label) {
    const states = kind === "fill" || kind === "type" ? ["visible", "enabled", "editable"] : kind === "hover" ? ["visible"] : ["visible", "enabled"];
    const deadline = Date.now() + 3000;
    for (;;) {
      bringIntoView(el);
      let r;
      try { r = await pw.checkElementStates(el, states, true); } catch (e) { throw new Error(label + ": " + e.message); }
      if (r === undefined && kind !== "fill" && kind !== "type" && !(await stable(el))) r = { missingState: "stable" };
      if (r === undefined) return;
      if (r === "error:notconnected") throw new Error(label + " left the page. Snapshot again.");
      if (Date.now() > deadline) throw new Error(label + " " + (MISSING[r.missingState] || "is not " + r.missingState) + ".");
      await sleep(100);
    }
  }
  // Waits (at most 1.5 s) until the point hits the element; else what covers it.
  async function hitTarget(el, p) {
    const deadline = Date.now() + 1500;
    for (;;) {
      const target = pw.retarget(el, "button-link") || el;
      const r = pw.expectHitTarget(p, target);
      if (r === "done") return null;
      if (Date.now() > deadline) return r.hitTargetDescription;
      await sleep(100);
      p = pointFor(el);
    }
  }

  // MARK: Input (after Playwright's WebViewInput: one task per event, marked so its
  // hit-target interceptor checks them)

  // A task of its own, through a message port: timers in a page out of sight run once a second.
  const post = fn => { const c = new MessageChannel(); c.port1.onmessage = () => { c.port1.close(); fn(); }; c.port2.postMessage(0); };
  keyboardless._setTimeout = post;
  const task = fn => new Promise(resolve => post(() => { try { resolve(fn()); } catch { resolve(undefined); } }));
  const mark = e => { Object.defineProperty(e, "__pwTrustedSynthetic", { value: true }); return e; };
  function mods(m) {
    const s = (m || "").toLowerCase();
    return { shiftKey: s.includes("shift"), ctrlKey: s.includes("ctrl"), altKey: s.includes("alt") || s.includes("option"), metaKey: s.includes("cmd") || s.includes("meta") };
  }
  function mouseInit(p, m, buttons, detail) {
    return { bubbles: true, cancelable: true, composed: true, view: window, clientX: p.x, clientY: p.y, screenX: p.x, screenY: p.y, button: 0, buttons, detail, ...m };
  }
  const pointer = (type, p, m, buttons) => task(() => deepFromPoint(p.x, p.y)?.dispatchEvent(mark(new PointerEvent(type, { ...mouseInit(p, m, buttons, 0), pointerId: 1, pointerType: "mouse", isPrimary: true }))));
  const mouse = (type, p, m, buttons, detail) => task(() => {
    const t = deepFromPoint(p.x, p.y) || document.documentElement;
    return { target: t, ok: t.dispatchEvent(mark(new MouseEvent(type, mouseInit(p, m, buttons, detail)))) };
  });
  const FOCUSABLE = "a[href], button, input, select, textarea, summary, iframe, [tabindex], [contenteditable=''], [contenteditable='true']";
  function focusFrom(t) {
    for (let e = t; e; e = e.parentElement || e.getRootNode()?.host) {
      if (e.matches && e.matches(FOCUSABLE) && !e.disabled) { if (deepActive() !== e) e.focus({ preventScroll: true }); return; }
    }
    const a = deepActive();
    if (a && a !== document.body && a.blur) a.blur();
  }
  async function move(p, m) {
    await keyboardless.mouseMove({ x: p.x, y: p.y, button: 0, buttons: 0, ...m });
  }
  async function click(p, m, count) {
    await move(p, m);
    for (let i = 1; i <= count; i++) {
      await pointer("pointerdown", p, m, 1);
      const down = await mouse("mousedown", p, m, 1, i);
      if (down && down.ok) await task(() => focusFrom(down.target));
      await pointer("pointerup", p, m, 0);
      await mouse("mouseup", p, m, 0, i);
      await mouse("click", p, m, 0, i);
    }
    if (count === 2) await mouse("dblclick", p, m, 0, 2);
  }

  const NAMED = {
    enter: ["Enter", "Enter", 13, "\r"], return: ["Enter", "Enter", 13, "\r"], tab: ["Tab", "Tab", 9], escape: ["Escape", "Escape", 27],
    esc: ["Escape", "Escape", 27], backspace: ["Backspace", "Backspace", 8], delete: ["Delete", "Delete", 46], space: [" ", "Space", 32, " "],
    up: ["ArrowUp", "ArrowUp", 38], down: ["ArrowDown", "ArrowDown", 40], left: ["ArrowLeft", "ArrowLeft", 37], right: ["ArrowRight", "ArrowRight", 39],
    arrowup: ["ArrowUp", "ArrowUp", 38], arrowdown: ["ArrowDown", "ArrowDown", 40], arrowleft: ["ArrowLeft", "ArrowLeft", 37], arrowright: ["ArrowRight", "ArrowRight", 39],
    home: ["Home", "Home", 36], end: ["End", "End", 35], pageup: ["PageUp", "PageUp", 33], pagedown: ["PageDown", "PageDown", 34],
  };
  function keyOf(name, m) {
    const named = NAMED[name.toLowerCase()];
    let key, code, keyCode, text;
    if (named) [key, code, keyCode, text] = named;
    else if ([...name].length === 1) {
      key = name; const up = name.toUpperCase();
      code = /[a-z]/i.test(name) ? "Key" + up : /\d/.test(name) ? "Digit" + name : "";
      keyCode = /[a-z\d]/i.test(name) ? up.charCodeAt(0) : name.charCodeAt(0);
      text = name;
    } else {
      key = name[0].toUpperCase() + name.slice(1); code = key; keyCode = 0;
    }
    if (m.ctrlKey || m.metaKey) text = undefined;
    return { key, code, keyCode, text };
  }
  function textInput(target, text) {
    const e = document.createEvent("TextEvent");
    e.initTextEvent("textInput", true, true, window, text);
    return target.dispatchEvent(mark(e));
  }
  // One key: keydown, keypress and textInput (whose default inserts the text and fires
  // beforeinput/input), keyup; then what the key does when the page lets it.
  async function key(chord) {
    const parts = chord.split("+").filter(Boolean), m = mods(parts.slice(0, -1).join("+"));
    const k = keyOf(parts[parts.length - 1] || "+", m);
    const init = { bubbles: true, cancelable: true, composed: true, view: window, key: k.key, code: k.code, keyCode: k.keyCode, which: k.keyCode, ...m };
    const el = deepActive() || document.body;
    const down = await task(() => el.dispatchEvent(mark(new KeyboardEvent("keydown", init))));
    let typed = false;
    if (down && k.text !== undefined) {
      const press = await task(() => el.dispatchEvent(mark(new KeyboardEvent("keypress", { ...init, charCode: k.text.charCodeAt(0), keyCode: k.text.charCodeAt(0), which: k.text.charCodeAt(0) }))));
      const editable = el.isContentEditable || (/^(INPUT|TEXTAREA)$/.test(el.tagName) && !/^(checkbox|radio|button|submit|reset|file|image|range|color)$/.test(el.type));
      if (press && editable && k.key !== "Enter") typed = await task(() => (textInput(el, k.text), true));
      if (press && k.key === "Enter" && (el.tagName === "TEXTAREA" || el.isContentEditable)) typed = await task(() => (textInput(el, "\n"), true));
    }
    if (down) await task(() => defaultAction(el, k, m, typed));
    await task(() => el.dispatchEvent(mark(new KeyboardEvent("keyup", init))));
  }
  // What a key does by default that a script's event does not.
  function defaultAction(el, k, m, typed) {
    const text = "value" in el && /^(INPUT|TEXTAREA)$/.test(el.tagName);
    if ((m.metaKey || m.ctrlKey) && k.key.toLowerCase() === "a") { if (el.select) el.select(); else document.execCommand("selectAll"); return; }
    switch (k.key) {
      case "Enter":
        if (typed) return;
        if (el.tagName === "INPUT" && el.form) {
          const submit = el.form.querySelector("button:not([type]), button[type=submit], input[type=submit], input[type=image]");
          if (submit) submit.click(); else el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
        } else if (el.tagName === "A" || el.tagName === "BUTTON" || el.getAttribute("role") === "button" || el.getAttribute("role") === "link") el.click();
        return;
      case " ":
        if (!typed && (el.tagName === "BUTTON" || el.type === "checkbox" || el.type === "radio" || el.getAttribute("role") === "button")) el.click();
        else if (!typed) scrollBy({ top: innerHeight * 0.8, behavior: "instant" });
        return;
      case "Backspace": document.execCommand("delete"); return;
      case "Delete": document.execCommand("forwardDelete"); return;
      case "Tab": {
        const all = [...document.querySelectorAll(FOCUSABLE)].filter(e => e.tabIndex >= 0 && !e.disabled && pw.utils.isElementVisible(e));
        const i = all.indexOf(el);
        (all[(i + (m.shiftKey ? -1 : 1) + all.length) % all.length] || el).focus();
        return;
      }
      case "ArrowUp": case "ArrowDown": case "ArrowLeft": case "ArrowRight": case "Home": case "End": case "PageUp": case "PageDown": {
        const d = { ArrowUp: -40, ArrowDown: 40, PageUp: -innerHeight * 0.8, PageDown: innerHeight * 0.8 }[k.key];
        if (el.tagName === "SELECT" && (k.key === "ArrowUp" || k.key === "ArrowDown")) {
          const i = Math.max(0, Math.min(el.options.length - 1, el.selectedIndex + (k.key === "ArrowUp" ? -1 : 1)));
          if (i !== el.selectedIndex) { el.selectedIndex = i; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); }
        } else if (text && el.setSelectionRange) {
          try {
            const at = k.key === "Home" || k.key === "ArrowUp" ? 0 : k.key === "End" || k.key === "ArrowDown" ? el.value.length
              : Math.max(0, Math.min(el.value.length, (k.key === "ArrowLeft" ? el.selectionStart - 1 : el.selectionEnd + 1)));
            el.setSelectionRange(at, at);
          } catch {}
        } else if (d) scrollBy({ top: d, behavior: "instant" });
        else if (k.key === "Home" || k.key === "End") scrollTo({ top: k.key === "Home" ? 0 : document.documentElement.scrollHeight, behavior: "instant" });
        return;
      }
    }
  }
  // Text, a key per character; a long rest goes in at once.
  async function type(text) {
    const chars = [...text];
    for (const c of chars.slice(0, 200)) await key(c === "\n" ? "Enter" : c);
    if (chars.length > 200) { const el = deepActive() || document.body; await task(() => textInput(el, chars.slice(200).join(""))); }
  }
  // Puts text in place of the selection as typing does; else the way frameworks still notice.
  function insert(el, text) {
    const before = "value" in el ? el.value : el.textContent;
    if (text === "") document.execCommand("delete"); else textInput(el, text);
    const now = "value" in el ? el.value : el.textContent;
    if (now !== before || now === text) return;
    if (el.isContentEditable) { document.execCommand("insertText", false, text); return; }
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
    el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
  }
  async function fill(el, raw, label) {
    if (el.tagName === "SELECT") {
      const want = String(raw);
      let r = pw.selectOptions(el, [{ valueOrLabel: want }]);
      if (r === "error:optionsnotfound") {
        const lower = want.toLowerCase();
        const o = [...el.options].find(o => o.value.toLowerCase() === lower || o.text.trim().toLowerCase() === lower);
        r = o ? pw.selectOptions(el, [o]) : r;
      }
      if (r === "error:optionsnotfound") throw new Error("No option “" + want + "”; the options are: " + [...el.options].map(o => o.text.trim()).join(", "));
      if (r === "error:optionnotenabled") throw new Error("The option “" + want + "” is disabled.");
      return;
    }
    const role = roleOf(el);
    if (el.type === "checkbox" || el.type === "radio" || role === "checkbox" || role === "radio" || role === "switch") {
      const want = raw === true || /^(true|on|yes|checked|1)$/i.test(String(raw));
      const now = pw.elementState(el, "checked").matches;
      if (now !== want) await clickElement(el, {}, 1, label);
      return;
    }
    if (el.type === "file") throw new Error("That is a file field: use browser_upload.");
    await actionable(el, "fill", label);
    if (pw.fill(el, String(raw)) === "needsinput") await task(() => insert(deepActive() || el, String(raw)));
  }

  // MARK: Acting

  let intercepted = null;
  async function clickElement(el, m, count, label, force) {
    if (!force) await actionable(el, "click", label);
    const p = pointFor(el);
    if (!force) {
      const cover = await hitTarget(el, p);
      if (cover) { intercepted = cover; throw new Error(label + " is covered by " + cover + " at (" + p.x + ", " + p.y + "): close or scroll it away first (it is in the snapshot), or pass force: true."); }
    }
    const watch = force ? null : pw.setupHitTargetInterceptor(el, "mouse", p, false);
    await click(p, m, count);
    const r = watch && typeof watch === "object" ? watch.stop() : "done";
    if (r !== "done") intercepted = r.hitTargetDescription;
    return p;
  }

  // What changed since `probe`: an action with none had no effect.
  const probes = new Map();
  function state(el) {
    return {
      url: location.href, title: document.title, active: deepActive(), mutations,
      scroll: scrollX + "," + scrollY + (el && el.scrollTop !== undefined ? "," + el.scrollTop + "," + el.scrollLeft : ""),
      value: el ? ("value" in el ? String(el.value) : el.isContentEditable ? el.textContent : null) : null,
      checked: el && "checked" in el ? el.checked : null, selected: el && "selectedIndex" in el ? el.selectedIndex : null,
      expanded: el?.getAttribute?.("aria-expanded") ?? null, open: el?.open ?? null,
    };
  }
  function effect(id) {
    const p = probes.get(id);
    if (!p) return { changes: [] };
    probes.delete(id);
    const el = p.el?.deref(), now = state(el && el.isConnected ? el : null), b = p.before, out = [];
    if (now.url !== b.url) out.push("navigated");
    if (now.title !== b.title) out.push("title changed");
    if (el && !el.isConnected) out.push("the element was replaced");
    if (now.value !== b.value && now.value !== null) out.push("value changed");
    if (now.checked !== b.checked || now.selected !== b.selected || now.expanded !== b.expanded || now.open !== b.open) out.push("state changed");
    // Focus on the element itself comes with clicking it, not from the page.
    if (now.active !== b.active && now.active !== el) out.push("focus moved");
    if (now.scroll !== b.scroll) out.push("scrolled");
    if (now.mutations !== b.mutations) out.push((now.mutations - b.mutations) + " DOM changes");
    return { changes: out, intercepted: p.intercepted };
  }

  // What needs the user: sign-in, payment and sending steps are theirs on the device.
  const RISKY = /\b(buy|pay|purchase|place (your )?order|checkout|check out|subscribe|donate|transfer|send money|confirm (payment|purchase|order)|delete (my )?account)\b/i;
  function sensitive(el, kind, args) {
    const submits = kind === "click" || (kind === "press" && /\b(enter|return)\b/i.test(args.keys || "")) || (kind === "type" && args.submit);
    if ((kind === "type" || kind === "fill") && isSecret(el)) return { kind: "handoff", reason: "Sign-in or payment details go in on the device: type them yourself, then tap Done." };
    if (submits) {
      const text = clip((el.innerText || el.value || el.getAttribute("aria-label") || ""), 80);
      const form = el.form || el.closest?.("form");
      if (RISKY.test(text)) return { kind: "approve", reason: "The agent wants to press “" + text + "”." };
      if (form && (el.type === "submit" || kind !== "click") && form.querySelector("input[type=password],input[autocomplete^=cc-]"))
        return { kind: "approve", reason: "The agent wants to submit a sign-in or payment form." };
    }
    return null;
  }
  const captcha = () => !!document.querySelector("iframe[src*='recaptcha'],iframe[src*='hcaptcha'],iframe[src*='challenges.cloudflare'],.g-recaptcha,.h-captcha,.cf-turnstile");

  async function act(args) {
    const kind = args.kind, target = args.target, el = resolve(target);
    const label = target && target.ref ? target.ref : target ? "(" + target.x + ", " + target.y + ")" : "the focused element";
    if (!args.approved) { const need = sensitive(el, kind, args); if (need) return { needsUser: need }; }
    if (args.phase === "show") {
      if (target && target.type !== "coordinate") bringIntoView(el);
      show(el, target && target.type === "coordinate" ? target : pointFor(el));
      return { shown: true, hidden: document.visibilityState === "hidden" };
    }
    const info = target ? describe(el, target) : null, note = healed;
    healed = null; intercepted = null;
    const id = args.id || String(Date.now());
    probes.set(id, { el: new WeakRef(kind === "type" && !target ? deepActive() || el : el), before: state(kind === "type" && !target ? deepActive() : el) });
    const m = mods(args.modifiers), coord = target && target.type === "coordinate";
    switch (kind) {
      case "click": case "double_click": {
        const count = kind === "click" ? 1 : 2;
        if (coord) await click(target, m, count); else await clickElement(el, m, count, label, args.force);
        break;
      }
      case "click_element": el.click(); break;
      case "hover":
        if (!coord && !args.force) await actionable(el, "hover", label);
        await move(coord ? target : pointFor(el), m);
        break;
      case "type":
        if (target) {
          if (coord) await click(target, m, 1); else await clickElement(el, {}, 1, label, args.force);
          if (!coord && !args.force) await actionable(deepActive() || el, "type", label);
        }
        await type(String(args.text ?? ""));
        if (args.submit) await key("Enter");
        break;
      case "fill": await fill(el, args.value, label); break;
      case "press":
        if (target && !coord) el.focus();
        for (let i = 0; i < (args.repeat || 1); i++) for (const chord of String(args.keys).split(/\s+/).filter(Boolean)) await key(chord);
        break;
      case "scroll": {
        const d = (args.amount || 3) * 120, dx = args.direction === "left" ? -d : args.direction === "right" ? d : 0, dy = args.direction === "up" ? -d : args.direction === "down" ? d : 0;
        const p = coord ? target : target ? pointFor(el) : { x: innerWidth / 2, y: innerHeight / 2 };
        await task(() => (deepFromPoint(p.x, p.y) || document.documentElement).dispatchEvent(mark(new WheelEvent("wheel", { bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, deltaX: dx, deltaY: dy, deltaMode: 0 }))));
        let s = target ? el : document.scrollingElement;
        while (s && s !== document.scrollingElement && !(s.scrollHeight > s.clientHeight || s.scrollWidth > s.clientWidth)) s = s.parentElement;
        (s || document.scrollingElement).scrollBy({ left: dx, top: dy, behavior: "instant" });
        break;
      }
      case "scroll_to": el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" }); break;
      case "upload": {
        const input = el.tagName === "INPUT" && el.type === "file" ? el
          : pw.retarget(el, "follow-label")?.type === "file" ? pw.retarget(el, "follow-label")
          : el.querySelector?.("input[type=file]") || (el.closest?.("form, label, div") || document).querySelector("input[type=file]");
        if (!input) throw new Error(label + " is not a file field and has none nearby. Click the control that opens the file picker, then call browser_upload without a target.");
        const r = pw.setInputFiles(input, args.files);
        if (r) throw new Error(r);
        break;
      }
      default: throw new Error("Unknown action " + kind);
    }
    probes.get(id) && (probes.get(id).intercepted = intercepted);
    return { done: true, target: info, note };
  }

  // MARK: The overlay: the agent's cursor and a highlight on what it is about to act on.

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

  window.__un = {
    token,
    snapshot,
    act,
    effect,
    find(query) {
      const words = query.toLowerCase().split(/\W+/).filter(w => w.length > 1);
      const { lines } = render(document.body || document.documentElement, "all", 64);
      const scored = [];
      for (const l of lines) {
        if (!/\[ref_\d+\]/.test(l)) continue;
        const hay = l.toLowerCase(), r = l.trim().split(" ")[0];
        const score = words.reduce((s, w) => s + (hay.includes(w) ? 1 : 0), 0) + (INTERACTIVE.has(r) ? 0.5 : 0);
        if (score >= 1) scored.push([score, l.trim()]);
      }
      scored.sort((a, b) => b[0] - a[0]);
      const out = scored.slice(0, 20).map(s => s[1]);
      return out.length ? out.join("\n") : "Nothing on the page matches “" + query + "”.";
    },
    text() {
      const main = document.querySelector("main, article, [role=main]");
      let t = (main ? main.innerText + "\n\n" : "") + document.body.innerText;
      t = "Page: " + clip(document.title, 120) + " — " + location.href + "\n" + t.trim();
      return t.length > MAX ? t.slice(0, MAX) + "\n… cut at " + MAX + " characters." : t;
    },
    // Milliseconds since the DOM last changed.
    quiet() { return Date.now() - lastMutation; },
    met(args) {
      return !!((args.text && document.body.innerText.includes(args.text)) || (args.selector && document.querySelector(args.selector)));
    },
    viewport() {
      const d = document.documentElement;
      return { width: innerWidth, height: innerHeight, x: scrollX, y: scrollY,
               pageWidth: Math.max(d.scrollWidth, innerWidth), pageHeight: Math.max(d.scrollHeight, innerHeight) };
    },
    // Where a frame's iframe element sits in this frame's viewport (its content box).
    frameOffset(t) {
      for (const f of document.querySelectorAll("iframe, frame")) {
        if (frameTokens.get(f) !== t) continue;
        const r = f.getBoundingClientRect(), s = getComputedStyle(f);
        return { x: r.left + parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft), y: r.top + parseFloat(s.borderTopWidth) + parseFloat(s.paddingTop) };
      }
      return null;
    },
    // The frame under a point, if an iframe is there: its token and the point inside it.
    frameAt(x, y) {
      const el = deepFromPoint(x, y);
      if (!el || !/^i?frame$/i.test(el.tagName) || !frameTokens.get(el)) return null;
      const o = this.frameOffset(frameTokens.get(el));
      return { token: frameTokens.get(el), x: x - o.x, y: y - o.y };
    },
    label(on, prefix) {
      const o = overlay();
      o.querySelectorAll("[data-label]").forEach(n => n.remove());
      if (!on) return 0;
      let n = 0;
      for (const el of render(document.body || document.documentElement, "interactive", 64).shown) {
        const ref = ids.get(el);
        if (!ref) continue;
        const r = el.getBoundingClientRect(), tag = document.createElement("div");
        tag.dataset.label = "";
        tag.textContent = (prefix || "") + ref.slice(4);
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
        const el = e.target, role = roleOf(el), name = nameOf(el);
        show(el, { x: e.clientX, y: e.clientY });
        picked = role + (name ? " " + quote(name) : "") + " [" + refOf(el, role, name, 0) + "]\n  on " + location.href + (el.innerText ? "\n  text: " + clip(el.innerText, 200) : "");
      };
      addEventListener("click", handler, true);
      return true;
    },
    picked() { const p = picked; picked = null; return p || ""; },
  };
  addEventListener("pagehide", () => { last = null; });
})();
