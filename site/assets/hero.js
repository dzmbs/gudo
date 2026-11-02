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
      lit.forEach(function (el) {
        var r = el.getBoundingClientRect();
        el.style.setProperty("--x", (px - r.left) + "px");
        el.style.setProperty("--y", (py - r.top) + "px");
      });
    };
    document.addEventListener("pointermove", function (e) {
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
  var sda = !document.documentElement.classList.contains("no-sda");
  var narrow = window.matchMedia("(max-width: 699px)");

  /* ---------- a clock that stops while the device is off screen ---------- */

  var tasks = [], base = performance.now(), paused = true, pausedAt = 0, timer = 0;
  function vnow() { return paused ? pausedAt : performance.now() - base; }
  function arm() {
    clearTimeout(timer);
    if (paused || !tasks.length) return;
    var next = Infinity;
    tasks.forEach(function (t) { if (t.t < next) next = t.t; });
    timer = setTimeout(runDue, Math.max(0, next - vnow()));
  }
  function runDue() {
    var now = vnow(), due = [], rest = [];
    tasks.forEach(function (t) { (t.t <= now ? due : rest).push(t); });
    tasks = rest;
    due.sort(function (a, b) { return a.t - b.t || a.n - b.n; });
    due.forEach(function (t) { t.fn(); });
    arm();
  }
  var seq = 0;
  function later(ms, fn, group) { tasks.push({ t: vnow() + ms, fn: fn, g: group, n: seq++ }); arm(); }
  function cancel(group) { tasks = tasks.filter(function (t) { return t.g !== group; }); arm(); }
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
  window.addEventListener("scroll", function () { if (!frame) frame = requestAnimationFrame(onScroll); }, { passive: true });
  window.addEventListener("resize", onScroll);
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (e) { visible = e[0].isIntersecting; sync(); }).observe(stage);
  }
  document.addEventListener("visibilitychange", sync);

  /* ---------- drawing lines ---------- */

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
  // "[g]ok[/]" colours a run; only used for our own strings, never for what a visitor types.
  function fill(parent, str) {
    var cls = "";
    str.split(/(\[[a-z]{1,2}\]|\[\/\])/).forEach(function (part) {
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

  /* ---------- state shared by the card, headers and badges ---------- */

  var whens = [].slice.call(stage.querySelectorAll("[data-when]"));
  function setState(s) {
    stage.setAttribute("data-state", s);
    whens.forEach(function (el) {
      if (el.getAttribute("data-when").split(" ").indexOf(s) < 0) el.setAttribute("hidden", "");
      else el.removeAttribute("hidden");
    });
    claude && bottom(claude.scroll);
  }
  function flag(name, on) { if (on) stage.setAttribute(name, ""); else stage.removeAttribute(name); }

  /* ---------- the keyboard: one hidden input feeds whatever has focus ---------- */

  var target = null;
  function setTarget(t) {
    if (target && target.blur) target.blur();
    target = t;
    kb.value = t ? t.value : "";
    paintCursors();
  }
  function paintCursors() {
    var typing = document.activeElement === kb;
    shells.forEach(function (s) { s.cursor.classList.toggle("idle", !(typing && target === s)); });
  }
  kb.addEventListener("focus", paintCursors);
  kb.addEventListener("blur", paintCursors);
  kb.addEventListener("input", function () {
    if (!target || target.busy) { kb.value = target ? target.value : ""; return; }
    interact();
    target.value = kb.value;
    target.render();
  });
  kb.addEventListener("keydown", function (e) {
    var mod = e.metaKey || e.ctrlKey;
    if (mod && !e.altKey && shortcut(e)) { e.preventDefault(); return; }
    if (!target) return;
    if (e.key === "Enter") { e.preventDefault(); interact(); target.enter(); kb.value = target.value; }
    else if (target.key && target.key(e)) e.preventDefault();
  });
  function shortcut(e) {
    var k = e.key.toLowerCase();
    if (k === "k" || (k === "p" && e.shiftKey)) { interact(); palette.open(); return true; }
    if (k === "d") { interact(); layout.split(e.shiftKey ? "down" : "right"); return true; }
    if (k === "enter" && e.shiftKey) { interact(); layout.zoom(); return true; }
    return false;
  }
  document.addEventListener("keydown", function (e) {
    if (e.target === kb || !(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== "k" || !visible) return;
    e.preventDefault();
    interact();
    palette.open();
  });
  function type(owner) {
    setTarget(owner);
    kb.focus({ preventScroll: true });
  }

  /* ---------- shells ---------- */

  var repo = { changed: false };
  var PROMPT = "[pa]~/src/api[/] [m]main[/] [g]❯[/] ";
  var shells = [];

  function Shell(pane, opts) {
    this.pane = pane;
    this.scroll = pane.querySelector(".scroll");
    this.prompt = opts.prompt || PROMPT;
    this.run = opts.run || runShell;
    this.value = "";
    this.history = [];
    this.at = 0;
    this.busy = false;
    this.cursor = node("span", "cur idle");
    pane.shell = this;
    shells.push(this);
    this.fresh();
  }
  Shell.prototype.fresh = function () {
    this.live = line(this.prompt);
    this.typed = node("span", "typed");
    this.live.appendChild(this.typed);
    this.live.appendChild(this.cursor);
    this.scroll.appendChild(this.live);
    bottom(this.scroll);
  };
  Shell.prototype.render = function () { this.typed.textContent = this.value; bottom(this.scroll); };
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
    this.live.removeChild(this.cursor);
    this.live.classList.add("done");
    this.live = null;
    this.value = "";
    if (cmd) { this.history.push(cmd); this.at = this.history.length; }
    var self = this;
    var out = cmd ? this.run(cmd, this) : null;
    var finish = function () { self.busy = false; self.fresh(); self.render(); paintCursors(); };
    if (out && out.then) { this.busy = true; out.then(finish); }
    else finish();
  };
  Shell.prototype.key = function (e) {
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      this.at = Math.max(0, Math.min(this.history.length, this.at + (e.key === "ArrowUp" ? -1 : 1)));
      this.value = this.history[this.at] || "";
      kb.value = this.value;
      this.render();
      return true;
    }
    if (e.key === "l" && e.ctrlKey) { this.clear(); return true; }
    return false;
  };
  Shell.prototype.clear = function () {
    while (this.scroll.firstChild !== this.live) this.scroll.removeChild(this.scroll.firstChild);
  };
  // Lines that arrive over time, like a real build.
  Shell.prototype.stream = function (rows, group) {
    var self = this;
    return { then: function (done) {
      var t = 0;
      rows.forEach(function (r) {
        t += r[0];
        later(t, function () { self.print(r[1]); }, group || "shell");
      });
      later(t + 60, done, group || "shell");
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
         "  [b]ls[/], [b]git status[/], [b]git log[/], [b]cargo test[/]",
         "  [b]claude[/] \"add a health check\"   ask the agent in the left pane",
         "  [b]gudo split[/], [b]gudo zoom[/], [b]gudo float[/]   arrange panes",
         "  [b]gudo --help[/], [b]gudo-hostd --help[/], [b]clear[/]",
         "Press ⌘K for the command palette."].forEach(function (s) { sh.print(s); });
        return;
      case "ls":
        sh.print("Cargo.lock  Cargo.toml  README.md  [b]migrations[/]  [b]src[/]  [b]tests[/]");
        return;
      case "pwd": sh.print("/home/you/src/api"); return;
      case "whoami": sh.print("you"); return;
      case "hostname": sh.print("studio"); return;
      case "date": sh.print(new Date().toString().replace(/ \(.*\)$/, ""), true); return;
      case "uname": sh.print("Linux studio 6.12.9 x86_64 GNU/Linux"); return;
      case "echo": sh.print(rest.replace(/^["']|["']$/g, ""), true); return;
      case "clear": sh.clear(); return;
      case "history": sh.history.forEach(function (h, i) { sh.print("  " + (i + 1) + "  " + h, true); }); return;
      case "cat":
        if (/readme/i.test(rest)) {
          ["# api", "", "The payments API. Run it with `cargo run`, test it with `cargo test`."].forEach(function (s) { sh.print(s, true); });
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
      case "claude": return askClaude(rest.replace(/^["']|["']$/g, ""), sh);
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
      if (/-s|--short/.test(cmd)) { if (repo.changed) sh.print(" [r]M[/] src/routes/export.rs"); return; }
      sh.print("On branch main");
      sh.print("Your branch is up to date with 'origin/main'.");
      if (repo.changed) {
        sh.print("");
        sh.print("Changes not staged for commit:");
        sh.print("        [r]modified:   src/routes/export.rs[/]");
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
       "[g]+    Limit::per_minute(10).check(&key)?;[/]", "[g]+    export(&key).await[/]"].forEach(function (s) { sh.print(s); });
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
       "  attach   Show the focused pane in this terminal", "  ls       List sessions, tabs and panes",
       "  split    Split the focused pane ([b]--down[/] to stack)", "  zoom     Toggle zoom of the focused pane",
       "  float    Float the focused pane, or dock it again", "  close    Close the focused pane",
       "  send     Type text into the focused pane"].forEach(function (s) { sh.print(s); });
      return;
    }
    if (a === "split") { layout.split(args.indexOf("--down") >= 0 || args.indexOf("-d") >= 0 ? "down" : "right"); return; }
    if (a === "zoom") { layout.zoom(); return; }
    if (a === "float") { layout.float(); return; }
    if (a === "close") { later(120, function () { layout.close(sh.pane); }); return; }
    if (a === "ls") {
      sh.print("studio  [g]live[/]");
      tabs.forEach(function (t, i) { sh.print("  " + (i + 1) + "  " + t.name + "  [d]" + t.sub + "[/]"); });
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
     "  unpair      Remove a paired device", "  service     Install or remove the login service"].forEach(function (s) { sh.print(s); });
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
    this.typed = pane.querySelector(".cc-in .typed");
    this.value = "";
    this.busy = false;
    this.scroll.appendChild(this.spin);
    this.cursor = node("span", "cur idle");
    this.typed.parentNode.insertBefore(this.cursor, this.typed.nextSibling);
    pane.shell = this;
    shells.push(this);
  }
  Claude.prototype.render = function () { this.typed.textContent = this.value; };
  Claude.prototype.say = function (str, cls) { this.scroll.insertBefore(line(str, cls), this.perm); bottom(this.scroll); };
  Claude.prototype.enter = function () {
    var ask = this.value.trim();
    if (!ask || this.busy) return;
    this.value = "";
    this.render();
    this.run(ask, false);
  };
  Claude.prototype.clear = function () {
    var keep = [this.perm, this.spin];
    [].slice.call(this.scroll.children).forEach(function (c) { if (keep.indexOf(c) < 0) c.remove(); });
  };
  Claude.prototype.tick = function () {
    var self = this;
    later(1000, function () {
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
    var at = function (ms, fn) { t += ms; later(t, fn, "agent"); };
    if (this.scroll.children.length > 2) this.say("");
    var asked = line("[d]>[/] ");
    asked.appendChild(document.createTextNode(ask));
    this.scroll.insertBefore(asked, this.perm);
    this.say("");
    this.word.textContent = "Thinking…";
    this.secs.textContent = "0";
    setState("working");
    this.tick();
    at(1200, function () { self.tool("Read", "src/routes/export.rs"); });
    at(400, function () { self.say("[d]  └ Read 84 lines[/]"); });
    at(600, function () { self.word.textContent = "Editing…"; self.tool("Update", "src/routes/export.rs"); });
    at(400, function () { self.say("[d]  └ 2 additions, 1 removal[/]"); });
    at(80, function () { self.say("[d]    40[/] [r]-[/] export(&key).await", "del"); });
    at(50, function () { self.say("[d]    40[/] [g]+[/] Limit::per_minute(10).check(&key)?;", "add"); });
    at(50, function () { self.say("[d]    41[/] [g]+[/] export(&key).await", "add"); repo.changed = true; });
    at(700, function () { self.word.textContent = "Thinking…"; });
    at(800, function () { self.tool("Bash", "cargo test -p api").firstChild.classList.add("bash"); });
    at(500, function () {
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
    var at = function (ms, fn) { t += ms; later(t, fn, "agent"); };
    this.word.textContent = "Testing…";
    setState("running");
    if (attract) focusAuto(this.pane);
    at(300, function () { self.say("[d]  └[/] Compiling api v0.4.0"); });
    at(1400, function () { self.say("    Finished test profile in 4.82s"); });
    at(300, function () { self.say("    running 49 tests"); });
    at(300, function () { self.say("    test export::limits_burst ... [g]ok[/]"); });
    at(200, function () { self.say("    test export::resets_window ... [g]ok[/]"); });
    at(150, function () { self.say("[d]    … +46 lines[/]"); });
    at(1000, function () { self.say("    test result: [g]ok[/]. 49 passed; 0 failed"); });
    at(800, function () {
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
    later(250, function () { self.say("[d]  └ [/][r]Declined.[/][d] Nothing ran.[/]"); }, "agent");
    later(900, function () {
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

  /* ---------- panes: focus, split, zoom, float ---------- */

  function shellPane(title, sub) {
    var pane = node("section", "pane");
    var ph = node("div", "ph");
    ph.appendChild(icon("i-term", "pm"));
    ph.appendChild(node("b", null, title));
    ph.appendChild(node("span", null, sub));
    var term = node("div", "term"), scroll = node("div", "scroll");
    term.appendChild(scroll);
    pane.appendChild(ph);
    pane.appendChild(term);
    return pane;
  }

  var layout = {
    view: function () { return app.querySelector(".view.on"); },
    panes: function () { return [].slice.call(this.view().querySelectorAll(".pane")); },
    focused: function () { return this.view().querySelector(".pane.focus") || this.panes()[0]; },
    focus: function (pane) {
      var v = pane.closest(".view");
      [].slice.call(v.querySelectorAll(".pane.focus")).forEach(function (p) { p.classList.remove("focus"); });
      pane.classList.add("focus");
      if (pane.shell) setTarget(pane.shell);
      else setTarget(null);
    },
    split: function (dir) {
      var cur = this.focused(), root = this.view().querySelector(".panes");
      if (this.panes().length >= 6) return;
      var pane = shellPane("zsh", "~/src/api");
      pane.classList.add("born");
      if (cur.classList.contains("float")) { cur = this.panes().filter(function (p) { return !p.classList.contains("float"); })[0]; }
      var col = cur.parentNode;
      if (dir === "down") {
        col.insertBefore(pane, cur.nextSibling);
      } else {
        var nc = node("div", "col born");
        nc.appendChild(pane);
        root.insertBefore(nc, col.nextSibling);
        pane.classList.remove("born");
        pane = nc.firstChild;
        requestAnimationFrame(function () { requestAnimationFrame(function () { nc.classList.remove("born"); }); });
      }
      requestAnimationFrame(function () { requestAnimationFrame(function () { pane.classList.remove("born"); }); });
      new Shell(pane, {});
      root.classList.remove("zoomed");
      this.focus(pane);
      title();
    },
    zoom: function () { this.view().querySelector(".panes").classList.toggle("zoomed"); },
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
      pane.classList.remove("float");
      home.insertBefore(pane, pane.homeNext && pane.homeNext.parentNode === home ? pane.homeNext : null);
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
    next: function () {
      var ps = this.panes(), i = ps.indexOf(this.focused());
      this.focus(ps[(i + 1) % ps.length]);
    }
  };

  // Dragging a floating pane by its header.
  app.addEventListener("pointerdown", function (e) {
    var ph = e.target.closest(".pane.float > .ph");
    if (!ph) return;
    var pane = ph.parentNode, box = pane.parentNode.getBoundingClientRect(), r = pane.getBoundingClientRect();
    var dx = e.clientX - r.left, dy = e.clientY - r.top;
    ph.setPointerCapture(e.pointerId);
    var move = function (m) {
      var x = Math.max(0, Math.min(box.width - r.width, m.clientX - box.left - dx));
      var y = Math.max(0, Math.min(box.height - r.height, m.clientY - box.top - dy));
      pane.style.setProperty("--fx", (x / box.width * 100).toFixed(2) + "%");
      pane.style.setProperty("--fy", (y / box.height * 100).toFixed(2) + "%");
    };
    var up = function () { ph.removeEventListener("pointermove", move); ph.removeEventListener("pointerup", up); ph.removeEventListener("pointercancel", up); };
    ph.addEventListener("pointermove", move);
    ph.addEventListener("pointerup", up);
    ph.addEventListener("pointercancel", up);
  });

  /* ---------- tabs ---------- */

  var tabs = [
    { name: "api", sub: "Payments", host: "studio" },
    { name: "web", sub: "Payments · codex", host: "devbox" },
    { name: "tests", sub: "studio · cargo watch", host: "studio" },
    { name: "db", sub: "studio · psql", host: "studio" }
  ];
  var friendly = ["quiet-otter", "brisk-heron", "calm-finch", "amber-lynx", "still-pine"];
  var views = app.querySelector(".views");

  function staticView(name, paneTitle, paneSub, rows, glyph) {
    var v = node("div", "view");
    v.setAttribute("data-view", name);
    var root = node("div", "panes"), col = node("div", "col"), pane = shellPane(paneTitle, paneSub);
    if (glyph) { var g = icon("g-spin", "st-work spin"); pane.firstChild.replaceChild(g, pane.firstChild.firstChild); pane.firstChild.appendChild(node("span", "st-work", "Working")); }
    pane.classList.add("focus");
    rows.forEach(function (r) { pane.querySelector(".scroll").appendChild(line(r)); });
    col.appendChild(pane); root.appendChild(col); v.appendChild(root); views.appendChild(v);
    return pane;
  }
  var builders = {
    web: function () {
      staticView("web", "Codex", "", [
        "[d]›[/] Build the new onboarding flow", "",
        "[m]•[/] Explored", "[d]  └ Read src/onboarding/steps.tsx, flow.ts[/]",
        "[m]•[/] Edited src/onboarding/steps.tsx [g]+48[/] [r]-6[/]",
        "[m]•[/] Ran npm test -- onboarding", "[d]  └ 12 passed[/]",
        "[m]•[/] Adding the welcome step", "", "[d]Working (4m 12s · esc to interrupt)[/]"], true);
    },
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
       " public | keys     | table | api", " public | payments | table | api", " public | sessions | table | api", "(3 rows)"].forEach(function (r) { sh.print(r); });
      return;
    }
    if (/^select count\(\*\) from (\w+)$/.test(s)) {
      var n = { sessions: 1284, payments: 90211, keys: 37 }[RegExp.$1];
      if (n == null) { sh.print("ERROR:  relation \"" + RegExp.$1 + "\" does not exist", true); return; }
      [" count ", "-------", " " + n, "(1 row)"].forEach(function (r) { sh.print(r, true); });
      return;
    }
    if (s === "help") { sh.print("Try \\dt or select count(*) from sessions;", true); return; }
    sh.print("ERROR:  this demo knows \\dt and select count(*) from a table", true);
  }

  function title() {
    var tab = tabs.filter(function (t) { return t.name === current; })[0];
    var n = layout.panes().length;
    app.querySelector(".tb .t-name").textContent = tab.name;
    app.querySelector(".tb .t-sub").textContent = tab.sub + (n > 1 ? " · " + n + " panes" : "");
    app.querySelector(".pb .t-name").textContent = tab.name;
    app.querySelector(".pb .t-host").textContent = tab.host;
  }
  var current = "api";
  function switchTab(name) {
    if (!app.querySelector('.view[data-view="' + name + '"]')) builders[name]();
    current = name;
    [].slice.call(views.children).forEach(function (v) { v.classList.toggle("on", v.getAttribute("data-view") === name); });
    [].slice.call(app.querySelectorAll("[data-tab]")).forEach(function (r) { r.classList.toggle("sel", r.getAttribute("data-tab") === name); });
    layout.focus(layout.focused());
    title();
  }
  function newTab() {
    var name = friendly[(tabs.length - 4) % friendly.length];
    if (tabs.length >= 9) return;
    tabs.push({ name: name, sub: "studio · zsh", host: "studio" });
    var row = node("div", "row tab");
    row.setAttribute("data-tab", name);
    row.appendChild(node("span", "n", String(tabs.length)));
    row.appendChild(icon("i-term", "slot"));
    var tt = node("span", "tt", name);
    tt.appendChild(node("small", null, "~/src/api"));
    row.appendChild(tt);
    var rows = app.querySelectorAll(".sb .row.tab");
    var lastRow = rows[rows.length - 1];
    lastRow.parentNode.insertBefore(row, lastRow.nextSibling);
    builders[name] = function () {
      var pane = staticView(name, "zsh", "~/src/api", []);
      new Shell(pane, {});
    };
    switchTab(name);
    type(layout.focused().shell);
  }

  /* ---------- the command palette ---------- */

  var palette = (function () {
    var el = app.querySelector(".pal"), list = el.querySelector(".pal-list"), text = el.querySelector(".pal-text");
    var items = [], sel = 0, before = null, open = false;
    var me = {
      value: "",
      render: function () { text.textContent = me.value; build(); },
      enter: function () { var it = items[sel]; me.close(); if (it) it.run(); },
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
      isOpen: function () { return open; }
    };
    function commands() {
      var f = layout.focused(), out = [];
      if (stage.getAttribute("data-state") === "needs") {
        out.push(["Needs you", "Approve cargo test -p api", "g-need", "", function () { claude.approve(); }]);
        out.push(["Needs you", "Deny cargo test -p api", "g-need", "", function () { claude.deny(); }]);
      }
      tabs.forEach(function (t, i) { out.push(["Tabs", t.name, "i-term", "⌘" + (i + 1), function () { switchTab(t.name); }, t.host]); });
      out.push(["Terminal", "New Tab", "i-plus", "", newTab]);
      out.push(["Terminal", "Split Right", "i-split", "⌘D", function () { layout.split("right"); }]);
      out.push(["Terminal", "Split Down", "i-split", "⇧⌘D", function () { layout.split("down"); }]);
      out.push(["Terminal", "Zoom Pane", "i-find", "⇧⌘↩", function () { layout.zoom(); }]);
      out.push(["Terminal", f && f.classList.contains("float") ? "Dock Pane" : "Float Pane", "i-side", "", function () { layout.float(); }]);
      if (f && f !== claude.pane && layout.panes().length > 1) out.push(["Terminal", "Close Pane", "i-plus", "", function () { layout.close(); }]);
      out.push(["Terminal", "Toggle Sidebar", "i-side", "", function () { app.classList.toggle("nosb"); }]);
      out.push(["Go", "Ask Claude…", "g-star", "", function () { switchTab("api"); layout.focus(claude.pane); type(claude); }]);
      out.push(["Go", "Run cargo test", "i-term", "", function () { switchTab("api"); var z = app.querySelector('[data-pane="zsh"]'); if (z) { layout.focus(z); typeLine(z.shell, "cargo test", null); } }]);
      return out;
    }
    function build() {
      var q = me.value.trim().toLowerCase();
      items = [];
      list.textContent = "";
      var sec = "";
      commands().forEach(function (c) {
        if (q && (c[1] + " " + c[0]).toLowerCase().indexOf(q) < 0) return;
        if (c[0] !== sec) { sec = c[0]; list.appendChild(node("div", "pal-sec", sec)); }
        var row = node("div", "pr");
        row.appendChild(icon(c[2], c[2] === "g-need" ? "st-need" : ""));
        row.appendChild(node("span", null, c[1]));
        if (c[5]) row.appendChild(node("small", null, c[5]));
        if (c[3]) row.appendChild(node("kbd", null, c[3]));
        var item = { run: c[4], row: row };
        row.addEventListener("pointermove", function () { if (sel !== items.indexOf(item)) { sel = items.indexOf(item); paintSel(); } });
        row.addEventListener("click", function () { me.close(); item.run(); });
        items.push(item);
        list.appendChild(row);
      });
      if (!items.length) list.appendChild(node("div", "pal-none", "No matches"));
      sel = 0;
      paintSel();
    }
    function paintSel() { items.forEach(function (it, i) { it.row.classList.toggle("sel", i === sel); }); }
    return me;
  })();

  /* ---------- clicks inside the device ---------- */

  app.addEventListener("click", function (e) {
    var t = e.target;
    if (palette.isOpen() && !t.closest(".pal")) { palette.close(); if (!t.closest("[data-act]")) return; }
    var act = t.closest("[data-act]");
    if (act) {
      interact();
      var a = act.getAttribute("data-act");
      if (a === "palette") palette.open();
      else if (a === "sidebar") app.classList.toggle("nosb");
      else if (a === "split") layout.split("right");
      else if (a === "newtab") newTab();
      else if (a === "next") layout.next();
      return;
    }
    var tab = t.closest("[data-tab]");
    if (tab) { interact(); switchTab(tab.getAttribute("data-tab")); return; }
    if (t.closest(".ask-a .ok")) { interact(); claude.approve(); return; }
    if (t.closest(".ask-a .q")) { interact(); claude.deny(); return; }
    var opt = t.closest(".perm .ln");
    if (opt) {
      var txt = opt.textContent;
      if (/1\. Yes|2\. Yes/.test(txt)) { interact(); claude.approve(); return; }
      if (/3\. No/.test(txt)) { interact(); claude.deny(); return; }
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
    if (zsh && !zsh.busy && zsh.value) { zsh.value = ""; zsh.render(); }
  }
  function typeLine(sh, text, group) {
    var t = 0;
    for (var i = 1; i <= text.length; i++) {
      t += 45 + ((i * 37) % 7) * 10;
      later(t, (function (s) { return function () { sh.value = s; sh.render(); }; })(text.slice(0, i)), group);
    }
    later(t + 260, function () { sh.enter(); }, group);
  }
  function autoApprove() {
    later(1300, function () { flag("data-ptr", true); }, "attract");
    later(2300, function () { flag("data-press", true); }, "attract");
    later(2550, function () { flag("data-press", false); flag("data-ptr", false); claude.approve(); }, "attract");
  }
  function focusAuto(pane) { if (!narrow.matches) layout.focus(pane); }

  var claude, zsh, logs;
  var claudePane = app.querySelector('[data-pane="claude"]');
  var zshPane = app.querySelector('[data-pane="zsh"]');
  var logPane = app.querySelector('[data-pane="logs"]');

  function setupShell() {
    var sc = zshPane.querySelector(".scroll");
    var old = sc.querySelector(".cur");
    if (old) old.parentNode.remove();
    zsh = new Shell(zshPane, {});
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
    later(3000, function () { focusAuto(zshPane); }, "attract");
    later(3300, function () { typeLine(zsh, "git status -s", "attract"); }, "attract");
    later(13000, function () { focusAuto(zshPane); typeLine(zsh, "git diff --stat", "attract"); }, "attract");
    later(21000, function () { app.classList.add("fade"); }, "attract");
    later(21500, begin, "attract");
  }
  function streamLogs() {
    var clock = 16 * 60 + 9, paths = ["GET /health [g]200[/]", "GET /v1/sessions [g]200[/]", "POST /v1/payments [g]201[/]", "GET /v1/export [g]200[/]"], i = 0;
    var next = function () {
      later(4200 + (i % 3) * 900, function () {
        clock += 7 + (i % 4) * 5;
        var m = Math.floor(clock / 60), s = clock % 60;
        logs.print("[f]21:" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s + "[/] api[812]: " + paths[i++ % paths.length]);
        next();
      }, "logs");
    };
    next();
  }

  claude = new Claude(claudePane);
  setupShell();
  logs = { scroll: logPane.querySelector(".scroll"), print: function (str) {
    this.scroll.appendChild(line(str));
    while (this.scroll.children.length > 60) this.scroll.firstChild.remove();
    bottom(this.scroll);
  } };

  if (attract) begin();
  else { layout.focus(zshPane); repo.changed = true; bottom(claude.scroll); }
  if (!reduce) streamLogs();
  onScroll();
})();
