// Home page: the spotlight on cards and glass buttons, the tilt fallback for browsers without
// scroll-driven animations, and the working demo inside the device. Everything here is canned
// and local: nothing typed into the demo leaves the page.
(function () {
  var fine = window.matchMedia("(hover: hover) and (pointer: fine)").matches;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // A light that follows the pointer. Cards share it so a neighbour's edge lights up too.
  if (fine) {
    var lit = [].slice.call(document.querySelectorAll(".point, .btn.glass"));
    var px = 0, py = 0, queued = false;
    var paint = function () {
      queued = false;
      lit.forEach(el => {
        var r = el.getBoundingClientRect();
        el.style.setProperty("--x", (px - r.left) + "px");
        el.style.setProperty("--y", (py - r.top) + "px");
      });
    };
    document.addEventListener("pointermove", e => {
      px = e.clientX; py = e.clientY;
      if (!queued) { queued = true; requestAnimationFrame(paint); }
    }, { passive: true });
  }

  var stage = document.querySelector(".stage");
  if (!stage) return;
  var app = stage.querySelector(".app");
  var device = stage.querySelector(".device");
  var copy = document.querySelector(".hero-copy");
  var kb = stage.querySelector(".kb");
  var mn = app.querySelector(".mn");
  var sb = app.querySelector(".sb");
  var sbl = app.querySelector(".sbl");
  var sda = !document.documentElement.classList.contains("no-sda");
  var narrow = window.matchMedia("(max-width: 699px)");
  var SPRING = "cubic-bezier(0.3, 1.25, 0.5, 1)";

  /* ---------- a clock that stops while the device is off screen ---------- */

  var tasks = [], base = performance.now(), paused = true, pausedAt = 0, timer = 0;
  function vnow() { return paused ? pausedAt : performance.now() - base; }
  function arm() {
    clearTimeout(timer);
    if (paused || !tasks.length) return;
    var next = Infinity;
    tasks.forEach(t => { if (t.t < next) next = t.t; });
    timer = setTimeout(runDue, Math.max(0, next - vnow()));
  }
  function runDue() {
    var now = vnow(), due = [], rest = [];
    tasks.forEach(t => { (t.t <= now ? due : rest).push(t); });
    tasks = rest;
    due.sort((a, b) => a.t - b.t || a.n - b.n);
    due.forEach(t => { t.fn(); });
    arm();
  }
  var seq = 0;
  function later(ms, fn, group) { tasks.push({ t: vnow() + ms, fn: fn, g: group, n: seq++ }); arm(); }
  function cancel(group) { tasks = tasks.filter(t => t.g !== group); arm(); }
  function pause() { if (paused) return; pausedAt = vnow(); paused = true; clearTimeout(timer); }
  function resume() { if (!paused) return; base = performance.now() - pausedAt; paused = false; arm(); }

  var started = false, visible = true;
  function sync() {
    var go = started && visible && !document.hidden;
    stage.classList.toggle("paused", !go);
    if (go) resume(); else pause();
  }

  /* ---------- the tilt ---------- */

  // 0 when the stage's top meets the bottom of the window, 1 at the top; the CSS maps it the same way.
  function progress() { return 1 - stage.getBoundingClientRect().top / window.innerHeight; }
  function clamp(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  var frame = 0;
  function onScroll() {
    frame = 0;
    var raw = progress();
    if (!sda && !reduce) {
      device.style.setProperty("--p", clamp((raw - 0.45) / 0.43).toFixed(4));
      copy.style.setProperty("--c", clamp(window.scrollY / (0.7 * window.innerHeight)).toFixed(4));
    }
    if (!started && (raw >= 0.84 || reduce)) { started = true; sync(); }
  }
  window.addEventListener("scroll", () => { if (!frame) frame = requestAnimationFrame(onScroll); }, { passive: true });
  window.addEventListener("resize", onScroll);
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(e => { visible = e[0].isIntersecting; sync(); }).observe(stage);
  }
  document.addEventListener("visibilitychange", sync);

  /* ---------- drawing ---------- */

  var SVG = "http://www.w3.org/2000/svg";
  function icon(id, cls) {
    var s = document.createElementNS(SVG, "svg"), u = document.createElementNS(SVG, "use");
    if (cls) s.setAttribute("class", cls);
    u.setAttribute("href", "#" + id);
    s.appendChild(u);
    return s;
  }
  function node(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  // Markup for our own strings only; anything a visitor typed goes through esc() or textContent.
  function frag(html) { var d = document.createElement("div"); d.innerHTML = html; return d.firstElementChild; }
  function use(id, cls) { return '<svg' + (cls ? ' class="' + cls + '"' : "") + '><use href="#' + id + '"/></svg>'; }
  function esc(s) { return String(s).replace(/[&<>"]/g, c => { return "&#" + c.charCodeAt(0) + ";"; }); }
  function $$(sel, root) { return [].slice.call((root || app).querySelectorAll(sel)); }
  // "[g]ok[/]" colours a run; only used for our own strings, never for what a visitor types.
  function fill(parent, str) {
    var cls = "";
    str.split(/(\[[a-z]{1,2}\]|\[\/\])/).forEach(part => {
      if (!part) return;
      if (part === "[/]") { cls = ""; return; }
      var m = /^\[([a-z]{1,2})\]$/.exec(part);
      if (m) { cls = m[1]; return; }
      parent.appendChild(cls ? node("span", cls, part) : document.createTextNode(part));
    });
    return parent;
  }
  function line(str, cls) { return fill(node("div", "ln" + (cls ? " " + cls : "")), str || ""); }
  function bottom(scroll) { scroll.scrollTop = scroll.scrollHeight; }
  var GL = { working: ["g-spin", "st-work spin", "Working"], needs: ["g-need", "st-need", "Needs you"], done: ["g-done", "st-done", "Done"], idle: ["g-idle", "st-idle", "Idle"] };
  function gl(s, cls) { return use(GL[s][0], GL[s][1] + (cls ? " " + cls : "")); }
  // Lists that rearrange slide each item from where it was to where it is now.
  function flip(box, change, from) {
    var old = {};
    $$("[data-k]", box).forEach(el => { old[el.getAttribute("data-k")] = el.getBoundingClientRect(); });
    if (from) old[from[0]] = from[1];
    change();
    if (reduce) return;
    $$("[data-k]", box).forEach(el => {
      var o = old[el.getAttribute("data-k")], r = el.getBoundingClientRect();
      if (!o) { el.animate([{ opacity: 0 }, { opacity: 1 }], 220); return; }
      var dx = o.left - r.left, dy = o.top - r.top;
      if (Math.abs(dx) + Math.abs(dy) > 0.5) el.animate([{ transform: "translate(" + dx + "px," + dy + "px)" }, { transform: "none" }], { duration: 440, easing: SPRING });
    });
  }

  /* ---------- state shared by the card, headers and badges ---------- */

  var whens = [].slice.call(stage.querySelectorAll("[data-when]")), ccAt = 0;
  function setState(s) {
    if (stage.getAttribute("data-state") !== s) ccAt = vnow() / 1000;
    // On iPhone the request arrives as a banner that tucks itself away, as notifications do.
    flag("data-stowed", false);
    if (s === "needs") later(8000, () => { flag("data-stowed", true); }, "agent");
    stage.setAttribute("data-state", s);
    whens.forEach(el => {
      if (el.getAttribute("data-when").split(" ").indexOf(s) < 0) el.setAttribute("hidden", "");
      else el.removeAttribute("hidden");
    });
    claude && bottom(claude.scroll);
    changed();
  }
  function flag(name, on) { if (on) stage.setAttribute(name, ""); else stage.removeAttribute(name); }

  /* ---------- the keyboard: one hidden input feeds whatever has focus ---------- */

  var target = null, fields = [], ctrl = false;
  function setTarget(t) {
    if (target && target.blur) target.blur();
    target = t;
    kb.value = t ? t.value : "";
    paintCursors();
  }
  function paintCursors() {
    var typing = document.activeElement === kb;
    shells.forEach(s => { s.cursor.classList.toggle("idle", !(typing && target === s)); });
    fields.forEach(f => { f.el.classList.toggle("on", typing && target === f); });
  }
  kb.addEventListener("focus", () => {
    if (!target && !screen) setTarget(layout.focused().shell || null);
    paintCursors();
  });
  kb.addEventListener("blur", paintCursors);
  kb.addEventListener("input", () => {
    if (!target || target.busy) { kb.value = target ? target.value : ""; return; }
    interact();
    if (ctrl && kb.value.length === target.value.length + 1) {
      var ch = kb.value.charAt(kb.selectionStart - 1);
      kb.value = target.value;
      ctrlKey(target, ch);
      return;
    }
    target.value = kb.value;
    target.pos = kb.selectionStart;
    target.render();
  });
  kb.addEventListener("keyup", () => {
    if (target && target.cursor && target.pos !== kb.selectionStart) { target.pos = kb.selectionStart; target.render(); }
  });
  kb.addEventListener("keydown", e => {
    if ((e.metaKey || e.ctrlKey) && shortcut(e)) { e.preventDefault(); return; }
    if (!target) return;
    if (e.key === "Enter") { e.preventDefault(); interact(); target.enter(); kb.value = target ? target.value : ""; }
    else if (e.key === "Tab" && target.complete && target.value) { e.preventDefault(); target.complete(); }
    else if (target.key && target.key(e)) e.preventDefault();
  });
  function shortcut(e) {
    var k = e.key.toLowerCase(), go = fn => { interact(); fn(); return true; };
    if (e.altKey) return e.code === "Enter" && e.metaKey ? go(() => { layout.float(); }) : false;
    if (e.metaKey && e.ctrlKey && e.shiftKey && (k === "arrowup" || k === "arrowdown")) return go(() => { moveTab(k === "arrowup" ? -1 : 1); });
    if (k === "k" || k === "p") return go(palette.open);
    if (k === "d") return go(() => { layout.split(e.shiftKey ? "down" : "right"); });
    if (k === "enter" && e.shiftKey) return go(() => { layout.zoom(); });
    if (k === "m" && e.shiftKey) return go(() => { layout.minimize(layout.focused()); });
    if (k === "]" || k === "[") return go(() => { layout.next(k === "[" ? -1 : 1); });
    if (/^[1-9]$/.test(k) && !e.shiftKey) { var t = order()[+k - 1]; return t ? go(() => { switchTab(t.name); }) : false; }
    return false;
  }
  function type(owner) {
    setTarget(owner);
    kb.focus({ preventScroll: true });
  }
  function caret(o) {
    var v = o.value, p = o.pos == null || o.pos > v.length ? v.length : o.pos;
    o.typed.textContent = v.slice(0, p);
    o.cursor.textContent = v.charAt(p);
    o.after.textContent = v.slice(p + 1);
  }
  function setPos(t, p) {
    t.pos = Math.max(0, Math.min(t.value.length, p));
    if (document.activeElement === kb) kb.setSelectionRange(t.pos, t.pos);
    t.render();
  }
  function insert(t, s) {
    var v = t.value, p = t.pos == null ? v.length : t.pos;
    t.value = v.slice(0, p) + s + v.slice(p);
    kb.value = t.value;
    setPos(t, p + s.length);
  }
  // A latched or held Ctrl with a letter, as a terminal reads it.
  function ctrlKey(t, ch) {
    ctrl = false;
    $$(".kbar .lat").forEach(k => { k.classList.remove("lat"); });
    ch = ch.toLowerCase();
    if (ch === "c") { t.interrupt && t.interrupt(); return; }
    if (ch === "l" && t.clear) { t.clear(); return; }
    if (ch === "u") { t.value = ""; kb.value = ""; setPos(t, 0); return; }
    if (ch === "a" || ch === "e") { setPos(t, ch === "a" ? 0 : t.value.length); return; }
    if (ch === "d" && t.print) t.print("Close this pane with [b]gudo close[/] or the palette.");
  }
  // A text field outside the terminal: replies, quick connect, notes.
  function Field(el, onEnter, onEsc) {
    var f = { value: "", el: el, pos: null,
      render: () => { el.querySelector(".ct").textContent = f.value; el.classList.toggle("has", !!f.value); },
      enter: () => { var v = f.value.trim(); if (!v) return; f.value = ""; f.render(); onEnter(v); },
      key: function (e) { if (e.key === "Escape" && onEsc) { onEsc(); return true; } return false; } };
    fields.push(f);
    return f;
  }

  /* ---------- shells ---------- */

  var repo = { changed: false };
  var PROMPT = "[pa]~/src/api[/] [m]main[/] [g]❯[/] ", LOCAL = "[pa]~[/] [g]❯[/] ";
  var shells = [], sid = 0;

  function Shell(pane, opts) {
    this.pane = pane;
    this.scroll = pane.querySelector(".scroll");
    this.prompt = opts.prompt || PROMPT;
    this.run = opts.run || runShell;
    this.grp = opts.grp || "sh" + sid++;
    this.value = "";
    this.pos = null;
    this.history = [];
    this.at = 0;
    this.busy = false;
    this.cursor = node("span", "cur idle");
    this.after = node("span", "typed");
    pane.shell = this;
    shells.push(this);
    this.fresh();
  }
  Shell.prototype.fresh = function () {
    this.live = line(this.prompt);
    this.typed = node("span", "typed");
    this.live.appendChild(this.typed);
    this.live.appendChild(this.cursor);
    this.live.appendChild(this.after);
    this.scroll.appendChild(this.live);
    bottom(this.scroll);
  };
  Shell.prototype.render = function () { caret(this); bottom(this.scroll); };
  Shell.prototype.print = function (str, plain) {
    var l = plain ? node("div", "ln", str) : line(str);
    this.scroll.insertBefore(l, this.live);
    var lines = this.scroll.children;
    while (lines.length > 80) this.scroll.removeChild(lines[0]);
    bottom(this.scroll);
  };
  Shell.prototype.enter = function () {
    if (this.busy) return;
    var cmd = this.value.trim();
    this.cursor.textContent = "";
    this.live.removeChild(this.cursor);
    this.typed.textContent = this.value;
    this.after.remove();
    this.live.classList.add("done");
    this.live = null;
    this.value = "";
    this.pos = null;
    if (cmd) { this.history.push(cmd); this.at = this.history.length; }
    var self = this;
    var out = cmd ? this.run(cmd, this) : null;
    var finish = this.done = () => { self.busy = false; self.fresh(); self.render(); paintCursors(); };
    if (out && out.then) { this.busy = true; out.then(finish); }
    else finish();
  };
  Shell.prototype.key = function (e) {
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      this.at = Math.max(0, Math.min(this.history.length, this.at + (e.key === "ArrowUp" ? -1 : 1)));
      this.value = this.history[this.at] || "";
      this.pos = null;
      kb.value = this.value;
      this.render();
      return true;
    }
    if (e.ctrlKey && /^[cluae]$/.test(e.key)) { ctrlKey(this, e.key); return true; }
    return false;
  };
  Shell.prototype.interrupt = function () {
    if (this.busy) { cancel(this.grp); this.print("^C"); this.done(); return; }
    this.cursor.textContent = "";
    this.live.removeChild(this.cursor);
    this.typed.textContent = this.value;
    this.after.textContent = "^C";
    this.live = null;
    this.value = ""; this.pos = null; kb.value = "";
    this.fresh(); this.render();
  };
  Shell.prototype.clear = function () {
    while (this.scroll.firstChild !== this.live) this.scroll.removeChild(this.scroll.firstChild);
  };
  var WORDS = ["help", "ls", "git status", "git log", "git diff", "cargo test", "cargo build", "cargo run", "claude", "claude --resume",
    "codex", "gudo ls", "gudo split", "gudo float", "gudo zoom", "gudo share", "gudo review", "gudo open localhost:3000", "gudo-hostd status", "clear", "history"];
  Shell.prototype.complete = function () {
    var v = this.value, hits = WORDS.filter(w => w.indexOf(v) === 0 && w !== v);
    if (!hits.length) return;
    var pre = hits.reduce((a, b) => { var i = 0; while (i < a.length && a[i] === b[i]) i++; return a.slice(0, i); });
    if (hits.length === 1) pre += " ";
    if (pre.length > v.length) { this.value = pre; kb.value = pre; setPos(this, pre.length); return; }
    var at = v.lastIndexOf(" ") + 1;
    this.print(hits.map(h => h.slice(at)).join("  "), true);
  };
  // Lines that arrive over time, like a real build.
  Shell.prototype.stream = function (rows) {
    var self = this;
    return { then: function (done) {
      var t = 0;
      rows.forEach(r => {
        t += r[0];
        later(t, () => { if (typeof r[1] === "function") r[1](); else self.print(r[1]); }, self.grp);
      });
      later(t + 60, done, self.grp);
    } };
  };

  function testRows() {
    return [
      [200, "[g]   Compiling[/] api v0.4.0 (/home/you/src/api)"],
      [1500, "[g]    Finished[/] `test` profile in 4.82s"],
      [250, "[g]     Running[/] unittests src/lib.rs"],
      [120, ""],
      [80, "running 49 tests"],
      [140, "test auth::rotates_keys ... [g]ok[/]"],
      [90, "test export::limits_burst ... [g]ok[/]"],
      [90, "test export::resets_window ... [g]ok[/]"],
      [110, "test sessions::expire ... [g]ok[/]"],
      [80, "test sessions::resume ... [g]ok[/]"],
      [320, ""],
      [60, "test result: [g]ok[/]. 49 passed; 0 failed; finished in 0.41s"]
    ];
  }

  function runShell(cmd, sh) {
    var words = cmd.split(/\s+/), head = words[0], rest = cmd.slice(head.length).trim();
    switch (head) {
      case "help":
        ["This is a demo shell in your browser. Try:",
         "  [b]ls[/], [b]git status[/], [b]git diff[/], [b]cargo test[/]",
         "  [b]claude[/] \"add a health check\"   ask the agent in the left pane",
         "  [b]claude --resume[/], [b]codex[/]",
         "  [b]gudo ls[/], [b]gudo split[/], [b]gudo float[/], [b]gudo share[/]",
         "  [b]gudo open localhost:3000[/], [b]gudo review[/], [b]clear[/]",
         "Press ⌘K for the command palette. Hold ⌘ for shortcuts."].forEach(s => { sh.print(s); });
        return;
      case "ls":
        sh.print(sh.prompt === LOCAL ? "[b]Desktop[/]  [b]Documents[/]  [b]Downloads[/]  [b]src[/]" : "Cargo.lock  Cargo.toml  README.md  [b]migrations[/]  [b]src[/]  [b]tests[/]");
        return;
      case "pwd": sh.print(sh.prompt === LOCAL ? "/Users/you" : "/home/you/src/api"); return;
      case "whoami": sh.print("you"); return;
      case "hostname": sh.print(tab(current).host); return;
      case "date": sh.print(new Date().toString().replace(/ \(.*\)$/, ""), true); return;
      case "uname": sh.print("Linux studio 6.12.9 x86_64 GNU/Linux"); return;
      case "echo": sh.print(rest.replace(/^["']|["']$/g, ""), true); return;
      case "clear": sh.clear(); return;
      case "history": sh.history.forEach((h, i) => { sh.print("  " + (i + 1) + "  " + h, true); }); return;
      case "cat":
        if (/readme/i.test(rest)) {
          ["# api", "", "The payments API. Run it with `cargo run`, test it with `cargo test`."].forEach(s => { sh.print(s, true); });
        } else sh.print("cat: " + (rest || "missing operand") + ": No such file or directory", true);
        return;
      case "git": return git(words[1], cmd, sh);
      case "cargo":
        if (words[1] === "test") return sh.stream(testRows());
        if (words[1] === "build" || words[1] === "check") {
          return sh.stream([[200, "[g]   Compiling[/] api v0.4.0 (/home/you/src/api)"], [1400, "[g]    Finished[/] `dev` profile in 3.07s"]]);
        }
        if (words[1] === "run") {
          return sh.stream([[200, "[g]    Finished[/] `dev` profile in 0.31s"], [120, "[g]     Running[/] `target/debug/api`"], [300, "listening on :8080"]]);
        }
        sh.print("Rust's package manager. Try [b]cargo test[/] or [b]cargo build[/].");
        return;
      case "claude":
        if (/^(--resume|-r|--continue|-c)\b/.test(rest)) return resumeClaude(sh);
        return askClaude(rest.replace(/^["']|["']$/g, ""), sh);
      case "codex":
        if (rest) { sh.print("[d]Sent to Codex in tab 2 (web on devbox).[/]"); later(400, () => { sendReply("cx", rest.replace(/^["']|["']$/g, "")); }); return; }
        sh.print("Codex runs in tab 2, [b]web[/] on devbox. Switching to it.");
        later(700, () => { switchTab("web"); });
        return;
      case "gudo": return gudo(words.slice(1), sh);
      case "gudo-hostd": return hostd(words[1], sh);
      case "vim": case "nvim": case "nano": case "emacs": case "top": case "htop": case "ssh":
        sh.print(head + ": not in this demo. Install Gudo to run the real thing.", true);
        return;
      case "sudo": sh.print("sudo: not in this demo", true); return;
      case "exit": sh.print("Close this pane with [b]gudo close[/] or the palette (⌘K)."); return;
      default:
        sh.print("zsh: command not found: " + head, true);
    }
  }

  function git(sub, cmd, sh) {
    if (sub === "status") {
      if (/-s|--short/.test(cmd)) { if (repo.changed) { sh.print(" [r]M[/] src/routes/export.rs"); sh.print("[r]??[/] src/limit.rs"); } return; }
      sh.print("On branch main");
      sh.print("Your branch is up to date with 'origin/main'.");
      if (repo.changed) {
        sh.print("");
        sh.print("Changes not staged for commit:");
        sh.print("        [r]modified:   src/routes/export.rs[/]");
        sh.print("Untracked files:");
        sh.print("        [r]src/limit.rs[/]");
      } else sh.print("nothing to commit, working tree clean");
      return;
    }
    if (sub === "log") {
      sh.print("[y]4c1e9a2[/] Add session expiry");
      sh.print("[y]b7d03f1[/] Rotate signing keys daily");
      sh.print("[y]19a6e44[/] Export: stream CSV rows");
      return;
    }
    if (sub === "diff") {
      if (!repo.changed) return;
      if (/--stat/.test(cmd)) {
        sh.print(" src/routes/export.rs | 3 [g]++[/][r]-[/]");
        sh.print(" 1 file changed, 2 insertions(+), 1 deletion(-)");
        return;
      }
      ["[b]@@ -38,5 +38,6 @@[/] pub async fn export(", "     let key = auth.key();", "[r]-    export(&key).await[/]",
       "[g]+    Limit::per_minute(10).check(&key)?;[/]", "[g]+    export(&key).await[/]", "[d]Run gudo review to see the whole turn.[/]"].forEach(s => { sh.print(s); });
      return;
    }
    if (sub === "pull") { sh.print("Already up to date."); return; }
    if (sub === "branch") { sh.print("* [g]main[/]"); return; }
    sh.print("git: try status, log, diff or pull here.", true);
  }

  function gudo(args, sh) {
    var a = args[0];
    if (!a || a === "--help" || a === "-h" || a === "help") {
      ["Developer client for the host daemon", "", "[b]Usage:[/] gudo <COMMAND>", "",
       "  ls       List hosts, tabs and agents", "  split    Split the focused pane ([b]--down[/] to stack)",
       "  zoom     Toggle zoom of the focused pane", "  float    Float the focused pane, or dock it again",
       "  open     Open a page beside this pane", "  review   Review the agent's last turn",
       "  share    Invite someone to this session", "  close    Close the focused pane"].forEach(s => { sh.print(s); });
      return;
    }
    if (a === "split") { layout.split(args.indexOf("--down") >= 0 || args.indexOf("-d") >= 0 ? "down" : "right"); return; }
    if (a === "zoom") { layout.zoom(); return; }
    if (a === "float") { layout.float(); return; }
    if (a === "close") { later(120, () => { layout.close(sh.pane); }); return; }
    if (a === "review") { later(150, review); return; }
    if (a === "agents" || a === "hosts") { later(150, () => { show(a); }); return; }
    if (a === "share") {
      sh.print("Invite for [b]" + current + "[/] · Driver · Session · 24 hours · 1 person");
      sh.print("[pa]https://gudo.dev/join#hN3xQ7…q8Zt[/]  [d]expires in 23 hr[/]");
      later(500, openShare);
      return;
    }
    if (a === "open") {
      var url = (args[1] || "localhost:3000").replace(/^https?:\/\//, "").replace(/\/$/, "");
      if (!/^(localhost|127\.0\.0\.1):\d+$/.test(url)) { sh.print("gudo: this demo opens local dev servers, like localhost:3000", true); return; }
      sh.print("[d]Opening " + url + " beside this pane.[/]");
      later(250, () => { openBrowser(url); });
      return;
    }
    if (a === "ls") {
      var hosts = {};
      order().forEach((t, i) => { (hosts[t.host] = hosts[t.host] || []).push([t, i + 1]); });
      Object.keys(hosts).forEach(h => {
        sh.print("[b]" + h + "[/]  [g]live[/] [d]· " + (h === "devbox" ? "relay 41 ms" : h === "studio" ? "direct 4 ms" : "local") + "[/]");
        hosts[h].forEach(p => {
          var t = p[0], ag = t.ag && A[t.ag], st = ag ? stateOf(ag) : "";
          var pad = (s, n) => { while (s.length < n) s += " "; return s; };
          sh.print("  " + p[1] + "  " + pad(t.name, 12) + pad(t.proj || "", 10) + "[d]" + pad(t.ctx, 14) + "[/]" +
            (st ? (st === "needs" ? "[y]needs you[/]" : st === "working" ? "[m]working[/]" : "[g]done[/]") : ""));
        });
      });
      return;
    }
    sh.print("gudo: unknown command '" + a + "'. See gudo --help.", true);
  }

  function hostd(a, sh) {
    if (a === "status") { sh.print("[g]running[/] · pid 812 · up 6 days"); return; }
    if (a === "devices") {
      sh.print("[d]KEY       NAME              PAIRED[/]");
      sh.print("9f3a61c2  iPad Pro          12 Oct");
      sh.print("e04b77d9  iPhone            12 Oct");
      sh.print("51c8a0fe  MacBook Pro       3 Oct");
      return;
    }
    if (a === "pair") { sh.print("Pairing works in the real app: run this on your own machine."); return; }
    ["Terminal and coding-agent host daemon", "", "[b]Usage:[/] gudo-hostd <COMMAND>", "",
     "  run         Run the daemon in the foreground", "  pair        Print a one-time pairing ticket as text and QR code",
     "  status      Show whether the daemon is running", "  devices     List the paired owner devices",
     "  unpair      Remove a paired device", "  service     Install or remove the login service"].forEach(s => { sh.print(s); });
  }

  function resumeClaude(sh) {
    if (claude.busy) { sh.print("Claude Code is busy in the left pane. Answer it first.", true); return; }
    return sh.stream([
      [0, "[b]Resume a conversation[/]"],
      [60, "[g]❯[/] Add rate limiting to the export endpoint   [d]6 min ago · 24 messages[/]"],
      [40, "  Rotate signing keys daily                  [d]2 days ago · 61 messages[/]"],
      [40, "  Export: stream CSV rows                    [d]4 days ago · 38 messages[/]"],
      [900, "[d]Resumed in the left pane.[/]"],
      [100, () => {
        switchTab("api");
        claude.say("");
        claude.say("[d]  ⎿ Resumed · Add rate limiting to the export endpoint · 24 messages[/]");
        layout.focus(claude.pane);
        type(claude);
      }]
    ]);
  }

  /* ---------- Claude Code in the left pane ---------- */

  var DEFAULT_ASK = "Add rate limiting to the export endpoint";

  function Claude(pane) {
    this.pane = pane;
    this.scroll = pane.querySelector(".scroll");
    this.spin = pane.querySelector(".spinl");
    this.perm = pane.querySelector(".perm");
    this.word = pane.querySelector(".sp-w");
    this.secs = pane.querySelector(".sp-t");
    this.box = pane.querySelector(".cc-in");
    this.typed = this.box.querySelector(".typed");
    this.value = "";
    this.pos = null;
    this.busy = false;
    this.scroll.appendChild(this.spin);
    this.cursor = node("span", "cur idle");
    this.after = node("span", "typed");
    this.typed.parentNode.insertBefore(this.after, this.typed.nextSibling);
    this.typed.parentNode.insertBefore(this.cursor, this.after);
    pane.shell = this;
    shells.push(this);
  }
  Claude.prototype.render = function () { caret(this); this.box.classList.toggle("has", !!this.value); };
  Claude.prototype.say = function (str, cls) { this.scroll.insertBefore(line(str, cls), this.perm); bottom(this.scroll); };
  Claude.prototype.enter = function () {
    var ask = this.value.trim();
    if (!ask || this.busy) return;
    this.value = "";
    this.pos = null;
    this.render();
    this.run(ask, false);
  };
  Claude.prototype.key = function (e) {
    if (e.key === "Escape" || (e.ctrlKey && e.key === "c")) { this.interrupt(); return true; }
    return false;
  };
  Claude.prototype.interrupt = function () {
    if (!this.busy) return;
    cancel("agent");
    this.busy = false;
    this.say("[d]  ⎿ [/][r]Interrupted[/][d] · What should Claude do instead?[/]");
    setState("idle");
  };
  Claude.prototype.clear = function () {
    var keep = [this.perm, this.spin];
    [].slice.call(this.scroll.children).forEach(c => { if (keep.indexOf(c) < 0) c.remove(); });
  };
  Claude.prototype.tick = function () {
    var self = this;
    later(1000, () => {
      if (!self.busy) return;
      self.secs.textContent = String(+self.secs.textContent + 1);
      self.tick();
    }, "agent");
  };
  Claude.prototype.run = function (ask, auto) {
    var self = this, t = 0;
    this.busy = true;
    this.ask = ask;
    cancel("agent");
    var at = (ms, fn) => { t += ms; later(t, fn, "agent"); };
    if (this.scroll.children.length > 2) this.say("");
    var asked = line("[d]>[/] ");
    asked.appendChild(document.createTextNode(ask));
    this.scroll.insertBefore(asked, this.perm);
    this.say("");
    this.word.textContent = "Thinking…";
    this.secs.textContent = "0";
    setState("working");
    this.tick();
    at(1200, () => { self.tool("Read", "src/routes/export.rs"); });
    at(400, () => { self.say("[d]  └ Read 84 lines[/]"); });
    at(600, () => { self.word.textContent = "Editing…"; self.tool("Update", "src/routes/export.rs"); });
    at(400, () => { self.say("[d]  └ 2 additions, 1 removal[/]"); });
    at(80, () => { self.say("[d]    40[/] [r]-[/] export(&key).await", "del"); });
    at(50, () => { self.say("[d]    40[/] [g]+[/] Limit::per_minute(10).check(&key)?;", "add"); });
    at(50, () => { self.say("[d]    41[/] [g]+[/] export(&key).await", "add"); repo.changed = true; });
    at(700, () => { self.word.textContent = "Thinking…"; });
    at(800, () => { self.tool("Bash", "cargo test -p api").firstChild.classList.add("bash"); });
    at(500, () => {
      setState("needs");
      if (auto && attract) autoApprove();
    });
  };
  // "● Read(src/routes/export.rs)", the tool name in bold.
  Claude.prototype.tool = function (name, arg) {
    var l = line("[g]●[/] ");
    l.appendChild(node("b", null, name));
    l.appendChild(document.createTextNode("(" + arg + ")"));
    this.scroll.insertBefore(l, this.perm);
    bottom(this.scroll);
    return l;
  };
  Claude.prototype.approve = function () {
    if (stage.getAttribute("data-state") !== "needs") return;
    var self = this, t = 0;
    var at = (ms, fn) => { t += ms; later(t, fn, "agent"); };
    this.word.textContent = "Testing…";
    setState("running");
    if (attract) focusAuto(this.pane);
    at(300, () => { self.say("[d]  └[/] Compiling api v0.4.0"); });
    at(1400, () => { self.say("    Finished test profile in 4.82s"); });
    at(300, () => { self.say("    running 49 tests"); });
    at(300, () => { self.say("    test export::limits_burst ... [g]ok[/]"); });
    at(200, () => { self.say("    test export::resets_window ... [g]ok[/]"); });
    at(150, () => { self.say("[d]    … +46 lines[/]"); });
    at(1000, () => { self.say("    test result: [g]ok[/]. 49 passed; 0 failed"); });
    at(800, () => {
      self.say("");
      if (self.ask === DEFAULT_ASK) {
        self.say("[fg]●[/] All 49 tests pass. Export now allows 10");
        self.say("  requests a minute per key and answers 429");
        self.say("  with Retry-After when a key goes over.");
      } else {
        self.say("[fg]●[/] Done. The change is in src/routes/export.rs");
        self.say("  and all 49 tests pass. This is a demo, so");
        self.say("  the plan is the same whatever you ask.");
      }
      self.busy = false;
      setState("done");
    });
  };
  Claude.prototype.deny = function () {
    if (stage.getAttribute("data-state") !== "needs") return;
    var self = this;
    setState("running");
    this.word.textContent = "Stopping…";
    later(250, () => { self.say("[d]  └ [/][r]Declined.[/][d] Nothing ran.[/]"); }, "agent");
    later(900, () => {
      self.say("");
      self.say("[fg]●[/] Okay, I won't run the tests. The edit is");
      self.say("  in place. Tell me how you want to check it.");
      self.busy = false;
      setState("idle");
    }, "agent");
  };

  function askClaude(ask, sh) {
    switchTab("api");
    if (!ask) { sh.print("Claude Code runs in the left pane. Type your request there."); type(claude); layout.focus(claude.pane); return; }
    if (claude.busy) { sh.print("Claude Code is busy. Answer its request first.", true); return; }
    sh.print("[d]Sent to Claude Code in the left pane.[/]");
    interact();
    claude.run(ask, false);
  }

  /* ---------- agents on every host ---------- */

  var A = {
    cc: { id: "cc", prog: "Claude Code", mk: "g-star", host: "studio", dir: "api", tab: "api" },
    cc2: { id: "cc2", prog: "Claude Code", mk: "g-star", host: "devbox", dir: "infra", tab: "infra", state: "needs", unread: 1, at: -140,
      task: "Move the session store to Redis", last: "Wants to check the plan before it changes anything.",
      req: ["Bash", "terraform plan -out tf.plan"],
      doing: "Running terraform plan…",
      after: "Plan: 3 to add, 0 to change, 0 to destroy. Say the word and I'll apply it.",
      no: "Okay, I won't run the plan. The edits are in sessions.tf.",
      log: ["[d]>[/] Move the session store to Redis", "", "[g]●[/] [k]Read[/](sessions.tf)", "[d]  └ Read 41 lines[/]",
        "[g]●[/] [k]Update[/](sessions.tf)", "[d]  └ 9 additions, 2 removals[/]", "[y]●[/] [k]Bash[/](terraform plan -out tf.plan)"],
      perm: ["[b]Bash command[/]", "  terraform plan -out tf.plan", "[d]  Preview the Redis cluster change[/]", "Do you want to proceed?", "[b]❯ 1. Yes[/]", "  2. Yes, don't ask again for terraform plan", "  3. No, and tell Claude what to do"],
      ran: ["[d]  └[/] Refreshing state…", "    aws_elasticache_cluster.sessions: [g]+ create[/]", "    aws_security_group.redis: [g]+ create[/]", "    aws_ssm_parameter.redis_url: [g]+ create[/]"],
      spin: "[o]✻ Planning…[/] [d](esc to interrupt)[/]" },
    cx: { id: "cx", prog: "Codex", mk: "i-term", host: "devbox", dir: "web", tab: "web", state: "working", at: -252,
      task: "Build the new onboarding flow", last: "Adding the welcome step",
      after: "The welcome step is in and 14 tests pass. The preview is on localhost:3000.",
      log: ["[d]›[/] Build the new onboarding flow", "", "[m]•[/] Explored", "[d]  └ Read src/onboarding/steps.tsx, flow.ts[/]",
        "[m]•[/] Edited src/onboarding/steps.tsx [g]+48[/] [r]-6[/]", "[m]•[/] Ran npm test -- onboarding", "[d]  └ 12 passed[/]", "[m]•[/] Adding the welcome step"],
      spin: "[d]Working (esc to interrupt)[/]" },
    pi: { id: "pi", prog: "pi", mk: "m-pi", host: "studio", dir: "notes", tab: "notes", state: "done", unread: 1, at: -720,
      task: "Summarise last night's incident", last: "Wrote RUNBOOK.md: three causes, two fixes and a timeline.",
      log: ["[d]>[/] Summarise last night's incident", "", "[k]read[/] incident-1102.log [d](2,418 lines)[/]", "[k]read[/] alerts.json",
        "[k]write[/] RUNBOOK.md [g]+64[/]", "", "Wrote RUNBOOK.md: three causes, two fixes and a timeline."],
      spin: "[d]⠋ Working…[/]" }
  };
  function ccState() {
    var s = stage.getAttribute("data-state");
    return s === "working" || s === "running" ? "working" : s === "needs" ? "needs" : s === "idle" ? "idle" : "done";
  }
  function stateOf(a) { return a.id === "cc" ? ccState() : a.state; }
  function syncCC() {
    var a = A.cc, s = ccState();
    a.state = s; a.at = ccAt;
    a.task = claude.ask || DEFAULT_ASK;
    a.req = s === "needs" ? ["Bash", "cargo test -p api"] : null;
    a.last = s === "needs" ? "Wants to run the API tests." : s === "working" ? claude.word.textContent : s === "idle" ? "Waiting for you." :
      a.task === DEFAULT_ASK ? "All 49 tests pass. Export now allows 10 requests a minute per key." : "Done. The change is in src/routes/export.rs.";
  }
  function needs() { return (ccState() === "needs") + (A.cc2.state === "needs"); }
  // Everything that shows an agent's state follows it.
  function changed(a) {
    if (!claude) return;
    var n = needs();
    $$(".nb").forEach(b => { b.textContent = n; b.hidden = !n; });
    if (!drag) renderSidebar();
    if (a) paintAgent(a);
    if (screen === "agents") renderInbox();
    if (screen === "hosts") renderHosts();
  }
  function advance(a, kind, text) {
    a.unread = 0;
    a.at = vnow() / 1000;
    var req = a.req;
    a.req = null;
    if (kind === "deny") {
      a.state = "done";
      a.last = a.no;
      a.log.push("[d]  └ [/][r]Declined.[/][d] Nothing ran.[/]", "", "[fg]●[/] " + a.no);
      changed(a);
      return;
    }
    a.state = "working";
    if (kind === "approve") { a.last = a.doing; a.log = a.log.concat(a.ran); }
    else { a.last = "Thinking…"; a.log.push("", { t: (a.id === "cx" ? "› " : "> ") + text }); }
    changed(a);
    later(kind === "approve" ? 2600 : 3200, () => {
      a.state = "done"; a.unread = 1; a.at = vnow() / 1000;
      a.last = kind === "approve" ? a.after : "Done. This is a demo, so the answer is always the same.";
      a.log.push("", (a.id === "cx" ? "[m]•[/] " : "[fg]●[/] ") + a.last);
      changed(a);
    }, "inbox");
    if (req) a.ask = req;
  }
  function act(id, v) {
    interact();
    var a = A[id];
    if (v === "open") { switchTab(a.tab); return; }
    if (v === "reply") {
      replying = id;
      reply.value = "";
      reply.el.querySelector(".cp").textContent = "Reply to " + a.prog + "…";
      reply.render();
      renderInbox();
      type(reply);
      return;
    }
    if (v === "send") { reply.enter(); return; }
    if (id === "cc") { if (v === "approve") claude.approve(); else claude.deny(); return; }
    if (a.state === "needs") advance(a, v);
  }
  function sendReply(id, text) {
    var a = A[id];
    if (id === "cc") {
      if (ccState() === "needs") { claude.deny(); later(1100, () => { claude.run(text, false); }); }
      else if (!claude.busy) claude.run(text, false);
      return;
    }
    if (a.state === "working") return;
    if (a.state === "needs") { advance(a, "deny"); later(900, () => { advance(a, "reply", text); }); return; }
    advance(a, "reply", text);
  }
  function age(a) {
    var s = Math.max(0, Math.round(vnow() / 1000 - a.at));
    if (stateOf(a) === "working") return Math.floor(s / 60) + ":" + ("0" + s % 60).slice(-2);
    return s < 60 ? "now" : s < 3600 ? Math.floor(s / 60) + "m" : Math.floor(s / 3600) + "h";
  }

  // An agent's own pane in its tab.
  function agentPane(a) {
    var pane = staticView(a.tab, a.prog, "", []);
    pane.agent = a;
    pane.classList.add("agp");
    a.pane = pane;
    paintAgent(a);
  }
  function paintAgent(a) {
    if (!a.pane) return;
    var s = stateOf(a), ph = a.pane.firstChild, sc = a.pane.querySelector(".scroll");
    ph.innerHTML = gl(s) + "<b>" + a.prog + '</b><span class="' + GL[s][1].split(" ")[0] + '">' + GL[s][2] + "</span>";
    ph.appendChild(phb());
    sc.textContent = "";
    a.log.forEach(l => { sc.appendChild(typeof l === "string" ? line(l) : node("div", "ln", l.t)); });
    if (s === "needs" && a.perm) {
      var p = node("div", "perm");
      a.perm.forEach(l => { p.appendChild(line(l)); });
      sc.appendChild(p);
    }
    if (s === "working") { sc.appendChild(line("")); sc.appendChild(line(a.spin)); }
    bottom(sc);
  }

  /* ---------- panes: focus, split, zoom, float, minimize ---------- */

  function phb() {
    return frag('<span class="phb"><svg data-pa="float"><use href="#i-float"/></svg><svg data-pa="min"><use href="#i-min"/></svg>' +
      '<svg data-pa="zoom"><use href="#i-zoom"/></svg><svg data-pa="close"><use href="#i-x"/></svg></span>');
  }
  function shellPane(title, sub) {
    var pane = node("section", "pane");
    var ph = node("div", "ph");
    ph.appendChild(icon("i-term", "pm"));
    ph.appendChild(node("b", null, title));
    ph.appendChild(node("span", null, sub));
    ph.appendChild(phb());
    var term = node("div", "term"), scroll = node("div", "scroll");
    term.appendChild(scroll);
    pane.appendChild(ph);
    pane.appendChild(term);
    return pane;
  }
  function settle(el) { requestAnimationFrame(() => { requestAnimationFrame(() => { el.classList.remove("born"); }); }); }

  var layout = {
    view: () => app.querySelector(".view.on"),
    panes: function () { return $$(".pane:not(.min)", this.view()); },
    focused: function () { return this.view().querySelector(".pane.focus:not(.min)") || this.panes()[0]; },
    focus: function (pane) {
      var v = pane.closest(".view");
      $$(".pane.focus", v).forEach(p => { p.classList.remove("focus"); });
      pane.classList.add("focus");
      setTarget(pane.shell || null);
    },
    split: function (dir, make) {
      var cur = this.focused(), root = this.view().querySelector(".panes");
      if (this.panes().length >= 6) return;
      var pane = make ? make() : shellPane("zsh", tab(current).host === "This Mac" ? "~" : "~/src/api");
      pane.classList.add("born");
      if (cur.classList.contains("float")) { cur = this.panes().filter(p => !p.classList.contains("float"))[0]; }
      var col = cur.parentNode;
      if (dir === "down") {
        col.insertBefore(pane, cur.nextSibling);
      } else {
        var nc = node("div", "col born");
        nc.appendChild(pane);
        root.insertBefore(nc, col.nextSibling);
        pane.classList.remove("born");
        settle(nc);
      }
      settle(pane);
      if (!make) new Shell(pane, { prompt: tab(current).host === "This Mac" ? LOCAL : PROMPT });
      root.classList.remove("zoomed");
      this.focus(pane);
      title();
      return pane;
    },
    zoom: function () { this.view().querySelector(".panes").classList.toggle("zoomed"); title(); },
    float: function () {
      var pane = this.focused(), root = this.view().querySelector(".panes");
      if (pane.classList.contains("float")) return this.dock(pane);
      if (this.panes().length < 2) return;
      pane.home = pane.parentNode;
      pane.homeNext = pane.nextSibling;
      pane.classList.add("float");
      root.appendChild(pane);
      root.classList.remove("zoomed");
    },
    dock: function (pane) {
      var home = pane.home && pane.home.isConnected ? pane.home : this.view().querySelector(".col");
      pane.classList.remove("float", "fz");
      home.insertBefore(pane, pane.homeNext && pane.homeNext.parentNode === home ? pane.homeNext : null);
    },
    // A floating window shrinks onto a chip at the tab's bottom right and comes back out of it.
    minimize: function (pane) {
      if (!pane || !pane.classList.contains("float")) return;
      var root = pane.parentNode, tray = root.querySelector(".tray");
      if (!tray) { tray = node("div", "tray"); root.appendChild(tray); }
      var chip = frag('<span class="chip">' + use(pane.shell ? "i-term" : "i-globe", "pm") + "<b></b>" + use("g-idle", "st-idle") + "</span>");
      chip.querySelector("b").textContent = pane.querySelector(".ph b").textContent;
      chip.pane = pane;
      tray.appendChild(chip);
      var a = pane.getBoundingClientRect(), b = chip.getBoundingClientRect(), self = this;
      var done = function () {
        pane.classList.add("min");
        pane.classList.remove("focus");
        chip.classList.remove("pre");
        self.focus(self.panes()[0]);
        title();
      };
      if (reduce) return done();
      chip.classList.add("pre");
      var to = "translate(" + (b.left - a.left) + "px," + (b.top - a.top) + "px) scale(" + (b.width / a.width).toFixed(3) + "," + (b.height / a.height).toFixed(3) + ")";
      pane.animate([{ transform: "none" }, { transform: to, opacity: 1, offset: 0.86 }, { transform: to, opacity: 0 }],
        { duration: 440, easing: "cubic-bezier(0.45, 0, 0.2, 1)" }).onfinish = done;
    },
    restore: function (chip) {
      var pane = chip.pane, b = chip.getBoundingClientRect();
      pane.classList.remove("min");
      chip.remove();
      this.focus(pane);
      pane.parentNode.appendChild(pane);
      title();
      if (reduce) return;
      var a = pane.getBoundingClientRect();
      pane.animate([{ transform: "translate(" + (b.left - a.left) + "px," + (b.top - a.top) + "px) scale(" + (b.width / a.width).toFixed(3) + "," + (b.height / a.height).toFixed(3) + ")", opacity: 0.4 },
        { transform: "none", opacity: 1 }], { duration: 480, easing: SPRING });
    },
    close: function (pane) {
      pane = pane || this.focused();
      if (pane === claude.pane || this.panes().length < 2) return;
      var col = pane.parentNode, i = shells.indexOf(pane.shell);
      if (i >= 0) shells.splice(i, 1);
      pane.remove();
      if (col.classList.contains("col") && !col.querySelector(".pane")) col.remove();
      this.focus(this.panes()[0]);
      title();
    },
    next: function (d) {
      var ps = this.panes(), i = ps.indexOf(this.focused());
      this.focus(ps[(i + (d || 1) + ps.length) % ps.length]);
    }
  };
  function paneAct(pane, a) {
    layout.focus(pane);
    if (a === "float") layout.float();
    else if (a === "min") layout.minimize(pane);
    else if (a === "close") layout.close(pane);
    else if (pane.classList.contains("float")) {
      pane.classList.add("anim");
      pane.classList.toggle("fz");
      later(450, () => { pane.classList.remove("anim"); });
    } else layout.zoom();
  }

  // Dragging a floating pane by its header.
  app.addEventListener("pointerdown", e => {
    var ph = e.target.closest(".pane.float:not(.fz) > .ph");
    if (!ph || e.target.closest("[data-pa]")) return;
    var pane = ph.parentNode, box = pane.parentNode.getBoundingClientRect(), r = pane.getBoundingClientRect();
    var dx = e.clientX - r.left, dy = e.clientY - r.top;
    ph.setPointerCapture(e.pointerId);
    var move = function (m) {
      var x = Math.max(0, Math.min(box.width - r.width, m.clientX - box.left - dx));
      var y = Math.max(0, Math.min(box.height - r.height, m.clientY - box.top - dy));
      pane.style.setProperty("--fx", (x / box.width * 100).toFixed(2) + "%");
      pane.style.setProperty("--fy", (y / box.height * 100).toFixed(2) + "%");
    };
    var up = () => { ph.removeEventListener("pointermove", move); ph.removeEventListener("pointerup", up); ph.removeEventListener("pointercancel", up); };
    ph.addEventListener("pointermove", move);
    ph.addEventListener("pointerup", up);
    ph.addEventListener("pointercancel", up);
  });

  /* ---------- tabs, projects and the sidebar ---------- */

  var tabs = [
    { name: "api", host: "studio", ctx: "claude", dir: "api", proj: "Payments", ag: "cc" },
    { name: "web", host: "devbox", ctx: "codex", dir: "web", proj: "Payments", ag: "cx" },
    { name: "tests", host: "studio", ctx: "cargo watch -x check", dir: "api" },
    { name: "db", host: "studio", ctx: "psql api_dev", dir: "api", mk: "i-db" },
    { name: "notes", host: "studio", ctx: "pi", dir: "notes", ag: "pi" },
    { name: "infra", host: "devbox", ctx: "claude", dir: "infra", ag: "cc2" }
  ];
  var projects = [{ name: "Payments", c: 0 }], hostList = ["studio", "devbox"], colors = 1;
  var friendly = ["quiet-otter", "brisk-heron", "calm-finch", "amber-lynx"], made = 0;
  var views = app.querySelector(".views");
  function tab(name) { return tabs.filter(t => t.name === name)[0]; }
  function sections() {
    var out = projects.map(p => { return { p: p, tabs: tabs.filter(t => t.proj === p.name) }; });
    return out.concat(hostList.map(h => { return { h: h, tabs: tabs.filter(t => !t.proj && t.host === h) }; }));
  }
  function order() { return [].concat.apply([], sections().map(s => s.tabs)); }
  function slot(t) {
    var a = t.ag && A[t.ag];
    return a && t.name !== current ? gl(stateOf(a), "slot") : use(t.mk || "i-term", "slot");
  }
  function listHTML(check) {
    var html = "", n = 0;
    sections().forEach(s => {
      if (s.p) html += '<div class="gh" data-k="p' + s.p.name + '" data-proj="' + s.p.name + '"><i class="pdot c' + s.p.c + '"></i>' + s.p.name + '<svg data-act="newtab"><use href="#i-plus"/></svg></div>';
      else html += '<div class="gh" data-k="h' + s.h + '" data-host="' + s.h + '">' + use(s.h === "This Mac" ? "i-mac" : "i-host", "hi") + s.h + '<svg data-act="newtab"><use href="#i-plus"/></svg></div>';
      s.tabs.forEach(t => {
        var on = t.name === current && !screen;
        html += '<div class="row tab' + (s.p ? " proj c" + s.p.c : "") + (on ? " sel" : "") + '" data-tab="' + t.name + '" data-k="t' + t.name + '"><span class="n">' + ++n + "</span>" + slot(t) +
          '<span class="tt">' + t.name + "<small>" + (s.p ? t.host + " · " : "") + t.ctx + "</small></span>" + (check && on ? use("i-check", "ck") : "") + "</div>";
      });
    });
    return html;
  }
  function renderSidebar(animate, from) {
    var html = listHTML();
    if (html === drawn) return;
    drawn = html;
    if (animate) flip(sbl, () => { sbl.innerHTML = html; }, from);
    else sbl.innerHTML = html;
  }
  function prune() { projects = projects.filter(p => { return tabs.some(t => t.proj === p.name); }); }
  function place(t, ref, after) {
    tabs.splice(tabs.indexOf(t), 1);
    tabs.splice(tabs.indexOf(ref) + (after ? 1 : 0), 0, t);
  }
  function group(t, onto) {
    if (!onto.proj) {
      var name = onto.dir, i = 2;
      while (projects.some(p => p.name === name)) name = onto.dir + " " + i++;
      projects.push({ name: name, c: colors++ % 4 });
      onto.proj = name;
    }
    t.proj = onto.proj;
    place(t, onto, true);
  }
  function moveTab(d) {
    var o = order(), t = tab(current), i = o.indexOf(t), n = o[i + d];
    if (!n) return;
    if (n.proj !== t.proj && !(n.proj ? true : n.host === t.host)) return;
    t.proj = n.proj || null;
    place(t, n, d > 0);
    prune();
    renderSidebar(true);
  }
  function title() {
    var t = tab(current), n = layout.panes().length, z = layout.view().querySelector(".panes.zoomed");
    app.querySelector(".tb .t-name").textContent = t.name;
    app.querySelector(".tb .t-sub").textContent = (t.proj || t.host) + " · " + (z ? "Zoomed" : n > 1 ? n + " panes" : t.ctx);
    app.querySelector(".pb .t-name").textContent = t.name;
    app.querySelector(".pb .t-host").textContent = t.host;
  }

  // Drag a tab onto another to group them, or between rows to move it; the rows make room.
  var drag = null, drawn = "";
  sb.addEventListener("pointerdown", e => {
    var row = e.target.closest(".sbl .row.tab");
    if (!row || e.button > 0 || narrow.matches) return;
    var d = drag = { row: row, t: tab(row.getAttribute("data-tab")), id: e.pointerId, x: e.clientX, y: e.clientY, touch: e.pointerType !== "mouse" };
    if (d.touch) d.timer = setTimeout(() => { if (drag === d) start(d); }, 300);
  });
  window.addEventListener("pointermove", e => {
    var d = drag;
    if (!d || e.pointerId !== d.id) return;
    if (!d.on) {
      if (Math.abs(e.clientX - d.x) + Math.abs(e.clientY - d.y) < 6) return;
      if (d.touch) { clearTimeout(d.timer); drag = null; return; }
      start(d);
    }
    over(d, e.clientX, e.clientY);
  });
  window.addEventListener("pointerup", e => { if (drag && e.pointerId === drag.id) drop(drag); });
  window.addEventListener("pointercancel", () => { if (drag) { clearTimeout(drag.timer); if (drag.on) { drag.zone = null; drop(drag); } drag = null; } });
  sb.addEventListener("touchmove", e => { if (drag && drag.on) e.preventDefault(); }, { passive: false });
  function start(d) {
    d.on = true;
    interact();
    var ar = app.getBoundingClientRect();
    d.k = app.offsetWidth / ar.width;
    d.ar = ar;
    d.kids = [].slice.call(sbl.children);
    d.kr = d.kids.map(el => el.getBoundingClientRect());
    d.H = d.row.getBoundingClientRect().height + 1;
    d.rows = $$(".row.tab, .gh[data-proj]", sbl).filter(r => r !== d.row).map(el => { return { el: el, r: el.getBoundingClientRect() }; });
    d.row.classList.add("dragging");
    d.chip = frag('<div class="dchip">' + slot(d.t) + "<b>" + d.t.name + "</b><small>" + d.t.host + "</small></div>");
    app.appendChild(d.chip);
    over(d, d.x, d.y);
  }
  function over(d, x, y) {
    d.chip.style.transform = "translate(" + ((x - d.ar.left) * d.k + 12) + "px," + ((y - d.ar.top) * d.k - d.chip.offsetHeight - 10) + "px)";
    var hit = null, zone = null;
    d.rows.forEach(o => { if (y >= o.r.top && y < o.r.bottom) hit = o; });
    if (!hit && d.rows.length && y > d.rows[d.rows.length - 1].r.bottom) { hit = d.rows[d.rows.length - 1]; zone = "after"; }
    if (hit && !zone) {
      var f = (y - hit.r.top) / (hit.r.bottom - hit.r.top);
      zone = hit.el.classList.contains("gh") ? "on" : f < 0.27 ? "before" : f > 0.73 ? "after" : "on";
    }
    var ht = hit && tab(hit.el.getAttribute("data-tab")), hp = hit && (ht ? ht.proj : hit.el.getAttribute("data-proj"));
    if (zone === "on" && ht && ht.proj && ht.proj === d.t.proj) zone = null;
    if (zone !== "on" && ht && !ht.proj && ht.host !== d.t.host) zone = null;
    var key = zone && zone + hit.el.getAttribute("data-k");
    if (key === d.key) return;
    d.key = key; d.zone = zone; d.hit = hit; d.ht = ht; d.hp = hp;
    // The row sits in the gap where it would land; the rows between make room.
    var kids = d.kids, di = kids.indexOf(d.row), at = zone && zone !== "on" ? kids.indexOf(hit.el) + (zone === "after") : -1, K = d.kr, to = 0;
    if (at > di) at--;
    if (at >= 0 && at !== di) to = at < di ? K[at].top - K[di].top : K[at].bottom - K[di].bottom;
    kids.forEach((el, i) => {
      el.classList.remove("tgt");
      var y = el === d.row ? to : at < 0 ? 0 : i >= at && i < di ? d.H : i > di && i <= at ? -d.H : 0;
      el.style.transform = y ? "translateY(" + y * d.k + "px)" : "";
      var l = el.querySelector(".lbl");
      if (l) l.remove();
    });
    if (zone === "on") {
      hit.el.classList.add("tgt");
      hit.el.appendChild(node("em", "lbl", hp ? "Add to " + hp : "Group"));
    }
  }
  function drop(d) {
    drag = null;
    clearTimeout(d.timer);
    if (!d.on) return;
    d.moved = true;
    var t = d.t, z = d.zone, from = ["t" + t.name, d.chip.getBoundingClientRect()];
    if (z === "on" && d.ht) group(t, d.ht);
    else if (z === "on") {
      t.proj = d.hp;
      var last = tabs.filter(x => x.proj === d.hp && x !== t).pop();
      if (last) place(t, last, true);
    } else if (z) { t.proj = d.ht.proj || null; place(t, d.ht, z === "after"); }
    prune();
    d.chip.remove();
    renderSidebar(true, from);
    if (z === "on") {
      var row = sbl.querySelector('[data-tab="' + t.name + '"]');
      if (row) { row.classList.add("lit"); later(700, () => { row.classList.remove("lit"); }); }
    }
    $$(".dragging", sbl).forEach(r => { r.classList.remove("dragging"); });
    $$("[style]", sbl).forEach(r => { r.style.transform = ""; });
    dragged = true;
    setTimeout(() => { dragged = false; }, 0);
    title();
  }
  var dragged = false;

  function staticView(name, paneTitle, paneSub, rows) {
    var v = node("div", "view");
    v.setAttribute("data-view", name);
    var root = node("div", "panes"), col = node("div", "col"), pane = shellPane(paneTitle, paneSub);
    pane.classList.add("focus");
    rows.forEach(r => { pane.querySelector(".scroll").appendChild(line(r)); });
    col.appendChild(pane); root.appendChild(col); v.appendChild(root); views.appendChild(v);
    return pane;
  }
  var builders = {
    web: () => { agentPane(A.cx); },
    notes: () => { agentPane(A.pi); },
    infra: () => { agentPane(A.cc2); },
    tests: function () {
      staticView("tests", "cargo watch", "~/src/api", [
        "[d][Running 'cargo check'][/]", "[g]    Checking[/] api v0.4.0 (/home/you/src/api)",
        "[g]    Finished[/] `dev` profile in 1.12s", "[d][Finished running. Exit status: 0][/]"]);
    },
    db: function () {
      var pane = staticView("db", "psql", "api_dev", ["psql (17.2)", "Type \"help\" for help.", ""]);
      new Shell(pane, { prompt: "api_dev=# ", run: sql });
    }
  };
  function sql(q, sh) {
    var s = q.toLowerCase().replace(/;$/, "");
    if (s === "\\q" || s === "exit") { sh.print("This pane stays open in the demo.", true); return; }
    if (s === "\\dt") {
      ["[d]        List of relations[/]", " Schema |   Name   | Type  | Owner", "--------+----------+-------+-------",
       " public | keys     | table | api", " public | payments | table | api", " public | sessions | table | api", "(3 rows)"].forEach(r => { sh.print(r); });
      return;
    }
    if (/^select count\(\*\) from (\w+)$/.test(s)) {
      var n = { sessions: 1284, payments: 90211, keys: 37 }[RegExp.$1];
      if (n == null) { sh.print("ERROR:  relation \"" + RegExp.$1 + "\" does not exist", true); return; }
      [" count ", "-------", " " + n, "(1 row)"].forEach(r => { sh.print(r, true); });
      return;
    }
    if (s === "help") { sh.print("Try \\dt or select count(*) from sessions;", true); return; }
    sh.print("ERROR:  this demo knows \\dt and select count(*) from a table", true);
  }

  var current = "api";
  function switchTab(name, dir) {
    if (!app.querySelector('.view[data-view="' + name + '"]')) builders[name]();
    var was = current;
    current = name;
    if (screen) show("");
    $$(".view", views).forEach(v => { v.classList.toggle("on", v.getAttribute("data-view") === name); });
    renderSidebar();
    layout.focus(layout.focused());
    title();
    if (dir && was !== name && !reduce) layout.view().animate([{ transform: "translateX(" + dir * 28 + "%)", opacity: 0 }, { transform: "none", opacity: 1 }], { duration: 320, easing: "cubic-bezier(0.2, 0.9, 0.3, 1)" });
  }
  function newTab(host, proj) {
    if (made >= friendly.length) return;
    var cur = tab(current);
    host = host || cur.host;
    var name = friendly[made++], local = host === "This Mac";
    var t = { name: name, host: host, ctx: "zsh", dir: local ? "home" : "api", proj: proj || null };
    if (proj && cur.proj === proj) tabs.splice(tabs.indexOf(cur) + 1, 0, t); else tabs.push(t);
    if (hostList.indexOf(host) < 0) hostList.unshift(host);
    builders[name] = function () {
      var pane = staticView(name, "zsh", local ? "~" : "~/src/api", []);
      new Shell(pane, { prompt: local ? LOCAL : PROMPT });
    };
    current = name;
    renderSidebar(true);
    switchTab(name);
    type(layout.focused().shell);
  }

  /* ---------- screens: Agents and Hosts ---------- */

  var screen = "", scr = {}, replying = null, filter = 0, ticking = false, seen = false;
  var SIDE = '<span class="glass circ" data-act="sidebar">' + use("i-side") + "</span>";
  var reply = Field(frag('<div class="cmp"><span class="ct"></span><span class="cp"></span><span class="snd" data-ia="send">' + use("i-up") + "</span></div>"),
    v => { var id = replying; replying = null; kb.blur(); setTarget(null); sendReply(id, v); renderInbox(); },
    () => { replying = null; setTarget(null); renderInbox(); });

  function show(s) {
    screen = s;
    app.setAttribute("data-screen", s);
    if (s && !scr[s]) {
      scr[s] = frag('<div class="scr" data-scr="' + s + '"><div class="sbar">' + SIDE + '<div class="ttl">' + (s === "agents" ? "Agents" : "Hosts") + "<small></small></div></div>" +
        (s === "agents" ? '<div class="flt">' + ["All", "Needs You", "Running", "Finished"].map((w, i) => '<span data-f="' + i + '">' + w + "</span>").join("") + "</div>" :
          '<div class="qc">' + use("i-find") + '<span class="ct"></span><span class="cp">user@host</span></div>') + '<div class="lst"></div></div>');
      mn.appendChild(scr[s]);
      if (s === "hosts") qc = Field(scr[s].querySelector(".qc"), connect);
    }
    Object.keys(scr).forEach(k => { scr[k].classList.toggle("on", k === s); });
    $$(".tbar [data-act]").forEach(el => { var on = el.getAttribute("data-act") === (s || "term"); el.classList.toggle("on", on); el.classList.toggle("glass", on); });
    $$(".sb > .row").forEach(el => { el.classList.toggle("sel", el.getAttribute("data-act") === s); });
    renderSidebar();
    if (s) {
      setTarget(null);
      kb.blur();
      if (!reduce) scr[s].animate([{ opacity: 0 }, { opacity: 1 }], 160);
      if (s === "agents") renderInbox(); else renderHosts();
    }
  }

  function agRow(a) {
    var s = stateOf(a), working = s === "working";
    return '<div class="ag' + (s === "needs" ? " need" : "") + (a.unread ? " new" : "") + '" data-ag="' + a.id + '"><div class="a1">' + gl(s, "gl") +
      "<b>" + esc(a.task) + "</b>" + (a.unread ? '<i class="ud"></i>' : "") + "<time>" + age(a) + "</time>" +
      (working ? "" : '<span class="qi" data-ia="reply" title="Reply">' + use("i-reply") + "</span>") +
      '<span class="qi" data-ia="open" title="Open">' + use("i-open") + "</span></div>" +
      '<div class="a2">' + use(a.mk, "mk" + (a.id.charAt(1) === "c" ? " cl" : "")) + a.prog + " · " + a.host + " · " + a.dir + "</div>" +
      '<div class="a3">' + esc(a.last) + "</div>" +
      (a.req ? '<div class="req"><small>' + a.req[0] + "</small>" + esc(a.req[1]) + '</div><div class="vb"><span class="qb" data-ia="deny">Deny</span><span class="ok" data-ia="approve">Approve</span></div>' : "") +
      "</div>";
  }
  function renderInbox() {
    var el = scr.agents;
    if (!el || screen !== "agents") return;
    syncCC();
    var list = [A.cc2, A.cc, A.cx, A.pi], html = "", unread = 0, n = needs();
    [["needs", "Needs you"], ["working", "Running"], ["done", "Finished"]].forEach((g, i) => {
      if (filter && filter !== i + 1) return;
      var rows = list.filter(a => { var s = stateOf(a); return (s === "idle" ? "done" : s) === g[0]; });
      if (!rows.length) return;
      html += '<div class="sec">' + g[1] + " <span>" + rows.length + "</span></div>";
      rows.forEach(a => { html += agRow(a); });
    });
    list.forEach(a => { unread += !!a.unread; });
    var lst = el.querySelector(".lst");
    lst.innerHTML = html || '<div class="empty">Nothing here</div>';
    if (replying) { var r = lst.querySelector('[data-ag="' + replying + '"]'); if (r) r.appendChild(reply.el); }
    el.querySelector(".sbar small").textContent = [n ? n + " need you" : "", unread ? unread + " new" : ""].filter(Boolean).join(" · ") || "All caught up";
    $$("[data-f]", el).forEach(f => { f.classList.toggle("on", +f.getAttribute("data-f") === filter); });
    if (unread && !seen) {
      seen = true;
      later(1500, () => { seen = false; if (screen === "agents") { list.forEach(a => { a.unread = 0; }); renderInbox(); } }, "inbox");
    }
    if (!ticking) tick();
  }
  function tick() {
    ticking = true;
    later(1000, () => {
      ticking = false;
      if (screen !== "agents") return;
      $$(".ag", scr.agents).forEach(r => { r.querySelector("time").textContent = age(A[r.getAttribute("data-ag")]); });
      tick();
    }, "inbox");
  }

  var HOSTS = [
    { n: "This Mac", ic: "i-mac", ad: "local", st: "Connected · helper running", u: ["Claude · 8% of 5h"] },
    { n: "studio", ic: "i-host", ad: "studio.lan", st: "Connected · direct · 4 ms", u: ["Claude · 62% of 5h · resets 14:20", "Codex · 18% of week"] },
    { n: "devbox", ic: "i-host", ad: "devbox.tail9c2.ts.net", st: "Connected · relay · 41 ms", u: ["Claude · 91% of 5h · resets 13:05", "Codex · 34% of 5h"] }
  ];
  var OTHER = [{ n: "nas", ic: "i-host", ad: "nas.local", bad: "Can't reach", why: "Offline since 09:12. Is it awake?" }], qc;
  function hostRow(h) {
    var ts = tabs.filter(t => t.host === h.n), need = 0, work = 0;
    ts.forEach(t => { var s = t.ag && stateOf(A[t.ag]); need += s === "needs"; work += s === "working"; });
    return '<div class="hr" data-hn="' + esc(h.n) + '">' + use(h.ic, "hic") + '<div class="hb"><b>' + esc(h.n) + "</b><small>" + esc(h.ad) + "</small>" +
      '<span class="hs">' + (h.bad ? '<em class="' + (h.bad === "Can't reach" ? "bad" : "") + '">' + h.bad + "</em> · " + esc(h.why) : h.st) + "</span>" +
      (h.u || []).map(u => '<span class="us' + (+/(\d+)%/.exec(u)[1] > 80 ? " hot" : "") + '">' + u + "</span>").join("") + "</div>" +
      '<span class="hc">' + (h.bad ? "" : "<span>" + (ts.length ? ts.length + (ts.length === 1 ? " tab" : " tabs") : "No tabs") + "</span>") + (need ? gl("needs") + "<span>" + need + "</span>" : "") + (work ? gl("working") + "<span>" + work + "</span>" : "") + "</span></div>";
  }
  function renderHosts() {
    var el = scr.hosts;
    if (!el || screen !== "hosts") return;
    var html = "", n = needs();
    if (n) {
      html += '<div class="sec">Needs you <span>' + n + "</span></div>";
      [A.cc2, A.cc].forEach(a => {
        if (stateOf(a) === "needs") html += '<div class="hr nd" data-go="agents">' + gl("needs", "hic") + '<div class="hb"><b>' + a.host + "</b><small>" + a.prog + " in " + a.dir + '</small><span class="hs">Wants to run ' + esc(a.req[1]) + "</span></div></div>";
      });
    }
    html += '<div class="sec">Active <span>' + HOSTS.length + "</span></div>" + HOSTS.map(hostRow).join("");
    html += '<div class="sec">Other</div>' + OTHER.map(hostRow).join("");
    el.querySelector(".lst").innerHTML = html;
    el.querySelector(".sbar small").textContent = HOSTS.length + " connected" + (n ? " · " + n + " need you" : "");
  }
  function connect(v) {
    var h = { n: v.replace(/^.*@/, "").slice(0, 40), ic: "i-host", ad: v.slice(0, 48), bad: "Connecting", why: "Dialling over SSH…" };
    OTHER.unshift(h);
    renderHosts();
    later(1400, () => { h.bad = "Can't reach"; h.why = "This is a demo. Install Gudo to connect to your own hosts."; renderHosts(); }, "inbox");
  }
  function openHost(n) {
    var t = order().filter(t => t.host === n)[0];
    if (t) switchTab(t.name);
    else if (n === "This Mac") newTab(n);
  }

  /* ---------- sheets over the app ---------- */

  var sheetOpen = null;
  function Sheet(html, opts) {
    var el = frag('<div class="scrim" hidden>' + html + "</div>");
    app.appendChild(el);
    var me = { value: "", el: el, render: function () {}, enter: () => { if (opts.enter) opts.enter(); },
      key: function (e) { if (e.key === "Escape") { me.close(); return true; } return false; },
      show: function () {
        if (sheetOpen) sheetOpen.close();
        sheetOpen = me;
        me.before = target;
        el.hidden = false;
        if (!reduce) el.firstChild.animate(narrow.matches ? [{ transform: "translateY(100%)" }, { transform: "none" }] : [{ transform: "scale(0.96)", opacity: 0 }, { transform: "none", opacity: 1 }],
          { duration: narrow.matches ? 420 : 240, easing: narrow.matches ? SPRING : "ease-out" });
        setTarget(me);
        if (opts.show) opts.show();
      },
      close: function () {
        if (sheetOpen !== me) return;
        sheetOpen = null;
        el.hidden = true;
        setTarget(me.before && me.before !== me && fields.indexOf(me.before) < 0 ? me.before : (layout.focused().shell || null));
      } };
    return me;
  }

  // Share: roles, an invite link and a code to scan.
  var share;
  function qr() {
    var n = 25, d = "", s = 7;
    var rnd = () => { s = (s * 16807) % 2147483647; return s / 2147483647; };
    var finder = (x, y) => x < 7 && y < 7 || x >= n - 7 && y < 7 || x < 7 && y >= n - 7;
    for (var y = 0; y < n; y++) for (var x = 0; x < n; x++) {
      var on;
      if (finder(x, y)) {
        var fx = x < 7 ? x : x - (n - 7), fy = y < 7 ? y : y - (n - 7), r = Math.max(Math.abs(fx - 3), Math.abs(fy - 3));
        on = r !== 2;
      } else if (x === 7 || y === 7 || x === n - 8 && y < 8 || y === n - 8 && x < 8) on = false;
      else if (x === 6 || y === 6) on = (x + y) % 2 === 0;
      else on = rnd() < 0.48;
      if (on) d += "M" + x + " " + y + "h1v1h-1z";
    }
    return '<svg class="qr" viewBox="-2 -2 29 29"><rect x="-2" y="-2" width="29" height="29" rx="1.5"/><path d="' + d + '"/></svg>';
  }
  function openShare() {
    interact();
    if (!share) {
      var roles = [["viewer", "i-eye", "Viewer", "Sees the panes, live"], ["prompter", "i-bubble", "Prompter", "Sends prompts to agents"], ["driver", "i-kbd", "Driver", "Types in the terminal"]];
      share = Sheet('<div class="sheet share"><div class="sh-h"><div class="sh-t"><b>Share ' + current + "</b><small>You and Mira · you own this host</small></div>" +
        '<span class="av c5">MH</span><span class="qb" data-sh="close">Done</span></div><div class="sh-b">' +
        '<div class="sec">Invite</div><div class="roles">' + roles.map((r, i) => {
          return '<span class="role' + (i ? "" : " on lock") + (i === 2 ? " on" : "") + '" data-role="' + r[0] + '">' + use(r[1]) + "<b>" + r[2] + "</b><small>" + r[3] + "</small></span>";
        }).join("") + '</div><div class="seg">' + ["Host", "Session", "Tab", "Pane"].map(w => "<span" + (w === "Session" ? ' class="on"' : "") + ">" + w + "</span>").join("") + "</div>" +
        '<div class="opt"><span>Expires</span><em>24 hours' + use("i-chev") + '</em></div><div class="opt"><span>Who can use it</span><em>1 person' + use("i-chev") + "</em></div>" +
        '<span class="pbtn" data-sh="create">Create Invite Link</span>' +
        '<div class="inv" hidden>' + qr() + '<div class="inv-t"><b class="sum"></b><code>gudo.dev/join#hN3xQ7…q8Zt</code><small>Expires in 23 hr</small>' +
        '<span class="qb" data-sh="copy">' + use("i-copy") + "Copy Link</span></div></div>" +
        '<div class="sec">People here <span>2</span></div><div class="pp"><span class="av c4">YO</span><div><b>You</b><small>Owner · in api</small></div></div>' +
        '<div class="pp"><span class="av c5">MH</span><div><b>Mira Holt</b><small>In zsh · watching</small></div><em>Viewer · Session</em></div></div></div>',
        { enter: () => { shareAct("create"); }, show: () => { share.el.querySelector(".sh-t b").textContent = "Share " + current; } });
    }
    share.show();
  }
  function shareAct(a, el) {
    var box = share.el;
    if (a === "close") return share.close();
    if (a === "role") { if (!el.classList.contains("lock")) el.classList.toggle("on"); return; }
    if (a === "copy") { el.lastChild.textContent = "Copied"; el.firstChild.firstChild.setAttribute("href", "#i-check"); return; }
    if (a === "create") {
      var b = box.querySelector(".pbtn");
      if (b.classList.contains("busy")) return;
      if (b.hidden) { b.hidden = false; box.querySelector(".inv").hidden = true; $$(".roles, .seg, .opt", box).forEach(x => { x.hidden = false; }); b.textContent = "Create Invite Link"; return; }
      b.classList.add("busy");
      b.textContent = "Signing invite…";
      later(700, () => {
        b.classList.remove("busy");
        b.hidden = true;
        $$(".roles, .seg, .opt", box).forEach(x => { x.hidden = true; });
        var on = $$(".role.on b", box).map(r => r.textContent);
        box.querySelector(".sum").textContent = on[on.length - 1] + " · " + box.querySelector(".seg .on").textContent + " · 24 hours · 1 person";
        var c = box.querySelector("[data-sh=copy]");
        c.lastChild.textContent = "Copy Link";
        c.firstChild.firstChild.setAttribute("href", "#i-copy");
        box.querySelector(".inv").hidden = false;
      });
    }
  }

  // Review: Claude's last turn as a diff, with notes that go back as one prompt.
  var diff, notes = [], noteField;
  var DIFF = [
    ["M", "src/routes/", "export.rs", 2, 1, [["h", "@@ -36,6 +36,7 @@ pub async fn export("], [" ", 36, 36, "pub async fn export("], [" ", 37, 37, "    auth: Auth,"],
      [" ", 38, 38, ") -> Result<Csv, ApiError> {"], [" ", 39, 39, "    let key = auth.key();"], ["-", 40, "", "    export(&key).await"],
      ["+", "", 40, "    Limit::per_minute(10).check(&key)?;"], ["+", "", 41, "    export(&key).await"], [" ", 41, 42, "}"]]],
    ["A", "src/", "limit.rs", 12, 0, [["h", "@@ -0,0 +1,12 @@"], ["+", "", 1, "use std::time::Duration;"], ["+", "", 2, ""],
      ["+", "", 3, "pub struct Limit { per: Duration, max: u32 }"], ["+", "", 4, ""], ["+", "", 5, "impl Limit {"],
      ["+", "", 6, "    pub fn per_minute(max: u32) -> Self {"], ["+", "", 7, "        Self { per: Duration::from_secs(60), max }"], ["+", "", 8, "    }"],
      ["+", "", 9, "    pub fn check(&self, key: &Key) -> Result<(), ApiError> {"], ["+", "", 10, "        window(key, self.per).hit(self.max)"], ["+", "", 11, "    }"], ["+", "", 12, "}"]]]
  ];
  function review() {
    interact();
    if (!diff) {
      var files = "", body = "";
      DIFF.forEach((f, i) => {
        files += '<span class="df-f" data-df="' + i + '"><i class="s' + f[0] + '">' + f[0] + "</i>" + f[2] + '<em><g>+' + f[3] + "</g> <r>−" + f[4] + "</r></em></span>";
        body += '<div class="df-file" id="df' + i + '"><div class="fh"><i class="s' + f[0] + '">' + f[0] + "</i><span>" + f[1] + "</span><b>" + f[2] + '</b><em><g>+' + f[3] + "</g> <r>−" + f[4] + "</r></em></div>" +
          f[5].map(l => {
            return l[0] === "h" ? '<div class="dl hk"><span></span><span></span><code>' + esc(l[1]) + "</code></div>" :
              '<div class="dl' + (l[0] === "+" ? " add" : l[0] === "-" ? " del" : "") + '"><span>' + l[1] + "</span><span>" + l[2] + "</span><code>" + esc(l[3]) + "</code></div>";
          }).join("") + "</div>";
      });
      diff = Sheet('<div class="sheet diff"><div class="sh-h"><span class="qb" data-sh="close">Done</span><div class="sh-t ctr"><b>api</b><small>main</small></div>' +
        '<span class="scope">' + use("g-star", "cl") + "Claude Code · turn 4 · 6 min ago" + use("i-chev") + "</span></div>" +
        '<div class="df-sum">2 files · <g>+14</g> <r>−1</r></div><div class="df"><div class="df-files">' + files + '</div><div class="df-body">' + body + "</div></div>" +
        '<div class="df-bar"><span class="nt">Tap a line to leave a note</span><span class="pbtn" data-sh="send" hidden>Send to Claude Code</span></div></div>', { enter: sendNotes });
      noteField = Field(frag('<div class="note cmp"><span class="ct"></span><span class="cp">Note for Claude Code…</span></div>'), v => {
        noteField.el.remove();
        var c = node("div", "note");
        c.textContent = v;
        noteField.line.after(c);
        notes.push(noteField.line.querySelector("span:nth-child(2)").textContent + ": " + v);
        var bar = diff.el.querySelector(".df-bar");
        bar.querySelector(".nt").textContent = notes.length + (notes.length > 1 ? " notes" : " note") + " · Goes to Claude Code as one prompt";
        bar.querySelector(".pbtn").hidden = false;
        setTarget(diff);
      }, () => { noteField.el.remove(); setTarget(diff); });
    }
    diff.show();
  }
  function noteAt(l) {
    if (l.classList.contains("hk")) return;
    noteField.line = l;
    noteField.value = "";
    noteField.render();
    l.after(noteField.el);
    type(noteField);
  }
  function sendNotes() {
    if (!notes.length) return;
    var bar = diff.el.querySelector(".nt");
    if (claude.busy) { bar.textContent = "Claude Code is busy. Send when it's done."; return; }
    var ask = "Notes on export.rs and limit.rs: " + notes.join("; ");
    notes = [];
    $$(".df-body .note", diff.el).forEach(n => { n.remove(); });
    bar.textContent = "Tap a line to leave a note";
    diff.el.querySelector("[data-sh=send]").hidden = true;
    diff.close();
    switchTab("api");
    claude.run(ask, false);
  }

  // A web page beside the shell, as `gudo open` or the palette makes one.
  var PAGE = '<div class="w-nav"><b>payments</b><span class="on">Overview</span><span>Exports</span><span>Keys</span><i class="w-av"></i></div>' +
    '<div class="w-main"><h4>Overview</h4><p>Last 24 hours</p><div class="w-cards"><div><small>Volume</small><b>$48,210</b><em class="up">+12%</em></div>' +
    '<div><small>Success</small><b>99.2%</b><em>steady</em></div><div><small>Limited</small><b>37</b><em class="dn">429s</em></div></div>' +
    '<div class="w-chart"></div><table class="w-t"><tr><td>exp_9f3a</td><td>orders.csv</td><td><i class="ok">200</i></td><td>2.1 MB</td></tr>' +
    '<tr><td>exp_9f39</td><td>refunds.csv</td><td><i class="ok">200</i></td><td>340 KB</td></tr><tr><td>exp_9f38</td><td>orders.csv</td><td><i class="no">429</i></td><td>·</td></tr></table></div>';
  function openBrowser(url) {
    interact();
    url = url || "localhost:3000";
    if (tab(current).host === "This Mac" || screen) switchTab("api");
    var made = layout.split("right", () => {
      var p = frag('<section class="pane www"><div class="ph">' + use("i-globe", "pm") + "<b>" + url + "</b><span>web</span></div>" +
        '<div class="br"><div class="bb">' + use("i-back") + use("i-fwd", "off") + '<svg data-bb="reload"><use href="#i-reload"/></svg><span class="addr">' + url + "</span></div>" +
        '<i class="prog"></i><div class="pg">' + PAGE + "</div></div></section>");
      p.firstChild.appendChild(phb());
      var ch = p.querySelector(".w-chart");
      [5, 7, 6, 9, 8, 11, 10, 13, 12, 9, 14, 16, 15, 18, 13, 17, 19, 22, 20, 24].forEach(h => { var i = node("i"); i.style.height = h * 4 + "%"; ch.appendChild(i); });
      return p;
    });
    if (made) load(made);
  }
  function load(p) {
    var pr = p.querySelector(".prog"), pg = p.querySelector(".pg");
    pr.classList.remove("go"); void pr.offsetWidth; pr.classList.add("go");
    if (!reduce) pg.animate([{ opacity: 0 }, { opacity: 0, offset: 0.4 }, { opacity: 1 }], 700);
  }

  /* ---------- the command palette ---------- */

  var palette = (function () {
    var el = app.querySelector(".pal"), list = el.querySelector(".pal-list"), text = el.querySelector(".pal-text");
    var items = [], sel = 0, before = null, open = false;
    var me = {
      value: "",
      render: () => { text.textContent = me.value; build(); },
      enter: () => { var it = items[sel]; me.close(); if (it) it.run(); },
      key: function (e) {
        if (e.key === "Escape") { me.close(); return true; }
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          sel = (sel + (e.key === "ArrowDown" ? 1 : -1) + items.length) % Math.max(1, items.length);
          paintSel();
          return true;
        }
        return false;
      },
      open: function () {
        if (open) return me.close();
        if (sheetOpen) sheetOpen.close();
        open = true;
        before = target;
        el.removeAttribute("hidden");
        me.value = "";
        text.textContent = "";
        build();
        type(me);
      },
      close: function () {
        if (!open) return;
        open = false;
        el.setAttribute("hidden", "");
        setTarget(before && before !== me ? before : (layout.focused().shell || null));
      },
      isOpen: () => open
    };
    function commands() {
      var f = layout.focused(), out = [], t = tab(current), fl = f && f.classList.contains("float");
      if (stage.getAttribute("data-state") === "needs") {
        out.push(["Needs you", "Approve cargo test -p api", "g-need", "", () => { claude.approve(); }, "studio · api"]);
        out.push(["Needs you", "Deny cargo test -p api", "g-need", "", () => { claude.deny(); }, "studio · api"]);
      }
      if (A.cc2.state === "needs") out.push(["Needs you", "Approve terraform plan", "g-need", "", () => { act("cc2", "approve"); }, "devbox · infra"]);
      order().forEach((t, i) => { out.push(["Tabs", t.name, "i-term", i < 9 ? "⌘" + (i + 1) : "", () => { switchTab(t.name); }, t.host]); });
      out.push(["Terminal", "New Tab", "i-plus", "", () => { newTab(); }]);
      out.push(["Terminal", "Split Right", "i-split", "⌘D", () => { layout.split("right"); }]);
      out.push(["Terminal", "Split Down", "i-split", "⇧⌘D", () => { layout.split("down"); }]);
      out.push(["Terminal", "Zoom Pane", "i-zoom", "⇧⌘↩", () => { layout.zoom(); }]);
      out.push(["Terminal", fl ? "Dock Pane" : "Float Pane", "i-float", "⌥⌘↩", () => { layout.float(); }]);
      if (fl) out.push(["Terminal", "Minimize Window", "i-min", "⇧⌘M", () => { layout.minimize(f); }]);
      if (f && f !== claude.pane && layout.panes().length > 1) out.push(["Terminal", "Close Pane", "i-x", "", () => { layout.close(); }]);
      out.push(["Terminal", "Toggle Sidebar", "i-side", "", () => { app.classList.toggle("nosb"); }]);
      if (!t.proj) out.push(["Tab", "New Project from Tab", "i-plus", "", () => { group(t, t); renderSidebar(true); title(); }]);
      else out.push(["Tab", "Remove from " + t.proj, "i-x", "", () => { t.proj = null; prune(); renderSidebar(true); title(); }]);
      out.push(["Tab", "Move Tab Up", "i-up", "⌃⇧⌘↑", () => { moveTab(-1); }]);
      out.push(["Tab", "Move Tab Down", "i-down", "⌃⇧⌘↓", () => { moveTab(1); }]);
      out.push(["Go", "Agents", "i-tray", "", () => { show("agents"); }]);
      out.push(["Go", "Hosts", "i-host", "", () => { show("hosts"); }]);
      out.push(["Go", "Ask Claude…", "g-star", "", () => { switchTab("api"); layout.focus(claude.pane); type(claude); }]);
      out.push(["Go", "Review Changes", "i-diff", "", review, "Claude Code · turn 4"]);
      out.push(["Go", "Open localhost:3000", "i-globe", "", () => { openBrowser(); }, "beside this pane"]);
      out.push(["Go", "Share Session…", "i-share", "", openShare]);
      out.push(["Go", "Run cargo test", "i-term", "", () => { switchTab("api"); var z = app.querySelector('[data-pane="zsh"]'); if (z) { layout.focus(z); typeLine(z.shell, "cargo test", null); } }]);
      if (fine) out.push(["Go", "Keyboard Shortcuts", "i-cmd", "hold ⌘", () => { hud(true); }]);
      return out;
    }
    function build() {
      var q = me.value.trim().toLowerCase();
      items = [];
      list.textContent = "";
      var sec = "";
      commands().forEach(c => {
        if (q && (c[1] + " " + c[0]).toLowerCase().indexOf(q) < 0) return;
        if (c[0] !== sec) { sec = c[0]; list.appendChild(node("div", "pal-sec", sec)); }
        var row = node("div", "pr");
        row.appendChild(icon(c[2], c[2] === "g-need" ? "st-need" : ""));
        row.appendChild(node("span", null, c[1]));
        if (c[5]) row.appendChild(node("small", null, c[5]));
        if (c[3]) row.appendChild(node("kbd", null, c[3]));
        var item = { run: c[4], row: row };
        row.addEventListener("pointermove", () => { if (sel !== items.indexOf(item)) { sel = items.indexOf(item); paintSel(); } });
        row.addEventListener("click", () => { me.close(); item.run(); });
        items.push(item);
        list.appendChild(row);
      });
      if (!items.length) list.appendChild(node("div", "pal-none", "No matches"));
      sel = 0;
      list.scrollTop = 0;
      paintSel();
    }
    function paintSel() {
      items.forEach((it, i) => { it.row.classList.toggle("sel", i === sel); });
      var r = items[sel] && items[sel].row;
      if (!r) return;
      if (r.offsetTop < list.scrollTop) list.scrollTop = r.offsetTop - 30;
      else if (r.offsetTop + r.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = r.offsetTop + r.offsetHeight - list.clientHeight;
    }
    return me;
  })();

  /* ---------- holding ⌘ shows the shortcuts, as on iPad ---------- */

  var hudEl = null, hudT = 0, pointerIn = false;
  var KEYS = [["Terminal", [["Command Palette", "⌘K"], ["Split Right", "⌘D"], ["Split Down", "⇧⌘D"], ["Go to Tab 1 to 9", "⌘1…9"], ["Move Tab Up", "⌃⇧⌘↑"]]],
    ["Pane", [["Zoom", "⇧⌘↩"], ["Float or Dock", "⌥⌘↩"], ["Minimize Window", "⇧⌘M"], ["Next Pane", "⌘]"], ["Previous Pane", "⌘["]]],
    ["Shell", [["Interrupt", "⌃C"], ["Clear", "⌃L"], ["Complete", "⇥"], ["History", "↑ ↓"], ["Stop Claude", "esc"]]]];
  function hud(on) {
    clearTimeout(hudT);
    hudT = 0;
    if (on && !hudEl) {
      hudEl = frag('<div class="hud" hidden>' + KEYS.map(c => {
        return '<div class="hcol"><h5>' + c[0] + "</h5>" + c[1].map(k => "<div><span>" + k[0] + "</span><kbd>" + k[1] + "</kbd></div>").join("") + "</div>";
      }).join("") + "</div>");
      app.appendChild(hudEl);
    }
    if (hudEl) hudEl.hidden = !on;
  }
  device.addEventListener("pointerenter", () => { pointerIn = true; });
  device.addEventListener("pointerleave", () => { pointerIn = false; });
  document.addEventListener("keydown", e => {
    if (e.key === "Meta") {
      if (!hudT && (pointerIn || document.activeElement === kb) && visible && !narrow.matches) hudT = setTimeout(() => { hud(true); }, 600);
      return;
    }
    if (hudT || (hudEl && !hudEl.hidden)) hud(false);
    if (e.target === kb || !(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== "k" || !visible) return;
    e.preventDefault();
    interact();
    palette.open();
  });
  document.addEventListener("keyup", e => { if (e.key === "Meta") hud(false); });
  window.addEventListener("blur", () => { hud(false); });

  /* ---------- iPhone: key bar, switcher, swipes ---------- */

  var keybar = app.querySelector(".kbar"), switcher;
  keybar.addEventListener("pointerdown", e => {
    var k = e.target.closest("[data-key]");
    if (!k) return;
    e.preventDefault();
    interact();
    var key = k.getAttribute("data-key"), t = target && target.cursor ? target : layout.focused().shell;
    if (!reduce) k.animate([{ transform: "scale(0.9)" }, { transform: "none" }], { duration: 260, easing: SPRING });
    if (key === "ctrl") { ctrl = !ctrl; k.classList.toggle("lat", ctrl); return; }
    if (!t) return;
    if (target !== t) setTarget(t);
    if (key === "esc") { if (t.interrupt && t === claude) t.interrupt(); else if (palette.isOpen()) palette.close(); return; }
    if (key === "tab") { if (t.complete) t.complete(); return; }
    if (key === "up" || key === "down") { if (t.key) t.key({ key: key === "up" ? "ArrowUp" : "ArrowDown" }); return; }
    if (key === "left" || key === "right") { setPos(t, (t.pos == null ? t.value.length : t.pos) + (key === "left" ? -1 : 1)); return; }
    if (ctrl) { ctrlKey(t, key); return; }
    if (!t.busy) insert(t, key);
  });
  function openSwitcher() {
    interact();
    if (!switcher) switcher = Sheet('<div class="sheet sw"><i class="grab"></i><div class="sw-h"><b></b><span class="qb" data-sh="close">Done</span></div><div class="sw-l"></div></div>', {});
    switcher.el.querySelector(".sw-l").innerHTML = listHTML(true) + '<div class="row nt" data-act="newtab">' + use("i-plus", "ic") + "<span>New Terminal</span></div>";
    switcher.el.querySelector(".sw-h b").textContent = tabs.length + " Tabs";
    switcher.show();
  }
  var swipe = null;
  views.addEventListener("pointerdown", e => { if (narrow.matches) swipe = { x: e.clientX, y: e.clientY, id: e.pointerId }; });
  views.addEventListener("pointerup", e => {
    var s = swipe;
    swipe = null;
    if (!s || s.id !== e.pointerId) return;
    var dx = e.clientX - s.x, dy = e.clientY - s.y;
    if (Math.abs(dx) < 50 || Math.abs(dy) > Math.abs(dx) * 0.6) return;
    interact();
    var o = order(), i = o.indexOf(tab(current)), n = o[i + (dx < 0 ? 1 : -1)];
    if (n) switchTab(n.name, dx < 0 ? 1 : -1);
  });

  /* ---------- clicks inside the device ---------- */

  app.addEventListener("click", e => {
    var t = e.target;
    if (dragged) return;
    if (palette.isOpen() && !t.closest(".pal")) { palette.close(); if (!t.closest("[data-act]")) return; }
    if (sheetOpen && t === sheetOpen.el) { sheetOpen.close(); return; }
    var x = t.closest("[data-sh]");
    if (x) {
      interact();
      var a = x.getAttribute("data-sh");
      if (a === "close") sheetOpen.close();
      else if (a === "send") sendNotes();
      else shareAct(a, x);
      return;
    }
    if (share && t.closest(".share")) {
      var role = t.closest(".role"), seg = t.closest(".seg span");
      if (role) shareAct("role", role);
      if (seg) $$(".seg span", share.el).forEach(s => { s.classList.toggle("on", s === seg); });
      return;
    }
    if (diff && t.closest(".diff")) {
      var f = t.closest("[data-df]"), l = t.closest(".dl");
      if (f) { var fe = diff.el.querySelector("#df" + f.getAttribute("data-df")); fe.parentNode.scrollTop = fe.offsetTop - fe.parentNode.offsetTop; }
      else if (l) noteAt(l);
      else if (t.closest(".note.cmp")) type(noteField);
      return;
    }
    var ac = t.closest("[data-act]");
    if (ac) {
      interact();
      var a2 = ac.getAttribute("data-act");
      if (sheetOpen && ac.closest(".sw")) sheetOpen.close();
      if (a2 === "palette") palette.open();
      else if (a2 === "sidebar") app.classList.toggle("nosb");
      else if (a2 === "split") layout.split("right");
      else if (a2 === "newtab") { var g = ac.closest(".gh"); newTab(g && g.getAttribute("data-host"), g && g.getAttribute("data-proj")); }
      else if (a2 === "next") layout.next();
      else if (a2 === "share") openShare();
      else if (a2 === "switcher") openSwitcher();
      else if (a2 === "agents" || a2 === "hosts") show(a2);
      else if (a2 === "term") show("");
      return;
    }
    var tb = t.closest("[data-tab]");
    if (tb) { interact(); if (sheetOpen) sheetOpen.close(); switchTab(tb.getAttribute("data-tab")); return; }
    var ia = t.closest("[data-ia]");
    if (ia) { act(ia.closest("[data-ag]").getAttribute("data-ag"), ia.getAttribute("data-ia")); return; }
    if (t.closest(".cmp")) { type(reply); return; }
    var fl = t.closest("[data-f]");
    if (fl) { interact(); filter = +fl.getAttribute("data-f"); renderInbox(); return; }
    var ag = t.closest("[data-ag]");
    if (ag) { act(ag.getAttribute("data-ag"), "open"); return; }
    if (t.closest(".qc")) { interact(); type(qc); return; }
    var go = t.closest("[data-go]");
    if (go) { interact(); show("agents"); return; }
    var hr = t.closest("[data-hn]");
    if (hr) { interact(); openHost(hr.getAttribute("data-hn")); return; }
    var chip = t.closest(".chip");
    if (chip) { interact(); layout.restore(chip); return; }
    var pa = t.closest("[data-pa]");
    if (pa) { interact(); paneAct(pa.closest(".pane"), pa.getAttribute("data-pa")); return; }
    var nav = t.closest(".w-nav span");
    if (nav) { $$("span", nav.parentNode).forEach(s => { s.classList.toggle("on", s === nav); }); nav.closest(".pg").querySelector("h4").textContent = nav.textContent; load(nav.closest(".pane")); return; }
    if (t.closest("[data-bb]")) { load(t.closest(".pane")); return; }
    if (t.closest(".ask-a .ok")) { interact(); claude.approve(); return; }
    if (t.closest(".ask-a .q")) { interact(); claude.deny(); return; }
    if (t.closest(".ask") && narrow.matches) { interact(); show("agents"); return; }
    var opt = t.closest(".perm .ln");
    if (opt) {
      var txt = opt.textContent, who = opt.closest(".pane").agent;
      var yes = /1\. Yes|2\. Yes/.test(txt), no = /3\. No/.test(txt);
      if (yes || no) {
        interact();
        if (who) act(who.id, yes ? "approve" : "deny");
        else if (yes) claude.approve(); else claude.deny();
        return;
      }
    }
    var pane = t.closest(".pane");
    if (pane) {
      interact();
      layout.focus(pane);
      if (pane.shell) type(pane.shell);
    }
  });

  /* ---------- attract mode: plays until the visitor does something ---------- */

  var attract = !reduce, interacted = false;
  function interact() {
    if (!started) { started = true; sync(); }
    if (interacted) return;
    interacted = true;
    attract = false;
    cancel("attract");
    flag("data-ptr", false); flag("data-press", false);
    app.classList.remove("fade");
    if (zsh && !zsh.busy && zsh.value) { zsh.value = ""; zsh.pos = null; zsh.render(); }
  }
  function typeLine(sh, text, group) {
    var t = 0;
    for (var i = 1; i <= text.length; i++) {
      t += 45 + ((i * 37) % 7) * 10;
      later(t, (s => { return () => { sh.value = s; sh.pos = null; sh.render(); }; })(text.slice(0, i)), group);
    }
    later(t + 260, () => { sh.enter(); }, group);
  }
  function autoApprove() {
    later(1300, () => { flag("data-ptr", true); }, "attract");
    later(2300, () => { flag("data-press", true); }, "attract");
    later(2550, () => { flag("data-press", false); flag("data-ptr", false); claude.approve(); }, "attract");
  }
  function focusAuto(pane) { if (!narrow.matches && !screen) layout.focus(pane); }

  var claude, zsh, logs;
  var claudePane = app.querySelector('[data-pane="claude"]');
  var zshPane = app.querySelector('[data-pane="zsh"]');
  var logPane = app.querySelector('[data-pane="logs"]');

  function setupShell() {
    var sc = zshPane.querySelector(".scroll");
    var old = sc.querySelector(".cur");
    if (old) old.parentNode.remove();
    zsh = new Shell(zshPane, { grp: "shell" });
  }
  function begin() {
    // Back to the opening frame: the prompt sent, Claude about to start.
    cancel("attract"); cancel("agent"); cancel("shell");
    app.classList.remove("fade");
    repo.changed = false;
    claude.clear();
    var sc = zshPane.querySelector(".scroll");
    while (sc.firstChild !== zsh.live) sc.removeChild(sc.firstChild);
    zsh.print(PROMPT + "git pull");
    zsh.print("Already up to date.");
    zsh.value = ""; zsh.render();
    layout.focus(claudePane);
    claude.run(DEFAULT_ASK, true);
    later(3000, () => { focusAuto(zshPane); }, "attract");
    later(3300, () => { typeLine(zsh, "git status -s", "attract"); }, "attract");
    later(13000, () => { focusAuto(zshPane); typeLine(zsh, "git diff --stat", "attract"); }, "attract");
    later(21000, () => { app.classList.add("fade"); }, "attract");
    later(21500, begin, "attract");
  }
  function streamLogs() {
    var clock = 16 * 60 + 9, paths = ["GET /health [g]200[/]", "GET /v1/sessions [g]200[/]", "POST /v1/payments [g]201[/]", "GET /v1/export [g]200[/]"], i = 0;
    var next = function () {
      later(4200 + (i % 3) * 900, () => {
        clock += 7 + (i % 4) * 5;
        var m = Math.floor(clock / 60), s = clock % 60;
        logs.print("[f]21:" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s + "[/] api[812]: " + paths[i++ % paths.length]);
        next();
      }, "logs");
    };
    next();
  }

  $$(".pane .ph").forEach(ph => { ph.appendChild(phb()); });
  claude = new Claude(claudePane);
  setupShell();
  logs = { scroll: logPane.querySelector(".scroll"), print: function (str) {
    this.scroll.appendChild(line(str));
    while (this.scroll.children.length > 60) this.scroll.firstChild.remove();
    bottom(this.scroll);
  } };
  // Codex finishes its task a while in, so it can be answered too.
  later(30000, () => {
    var a = A.cx;
    a.state = "done"; a.unread = 1; a.at = vnow() / 1000; a.last = a.after;
    a.log.push("[d]  └ 14 passed[/]", "", "[m]•[/] " + a.after);
    changed(a);
  }, "inbox");

  if (attract) begin();
  else { layout.focus(zshPane); repo.changed = true; bottom(claude.scroll); changed(); }
  if (!reduce) streamLogs();
  onScroll();
})();
