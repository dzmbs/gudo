#!/usr/bin/env bash
# Sets up what the W3 screens' UI tests run against (apple/scripts/w3-ui-test.sh) and prints
# the directory: a git repository with changes, a stand-in `claude` that talks to the daemon's
# hooks like Claude Code does, and a stand-in `code serve-web` (a tiny page that logs keys).
#
#   apple/scripts/w3-fixtures.sh <dir>
set -euo pipefail

dir="$1"
work="$dir/work"
bin="$dir/bin"
repo="$work/proj"
mkdir -p "$repo/src" "$bin"
# Two more folders for the editor-pane tests (several VS Code tabs, one beside a terminal).
mkdir -p "$work/site" "$work/docs"
printf '<h1>site</h1>\n' >"$work/site/index.html"
printf '# docs\n' >"$work/docs/README.md"

# The pane shells: HOME is the work directory, so no user dotfiles; start in the repository.
cat >"$work/.zshrc" <<'EOF'
PROMPT='%1~ %# '
cd ~/proj 2>/dev/null
EOF

# A repository with a commit, then an edit, a new file and an image.
(
  cd "$repo"
  git init -q -b main
  git config user.email test@example.com
  git config user.name Test
  printf '# Test project\n\nA repository for the W3 screens.\n' >README.md
  printf 'fn main() {\n    println!("hello");\n}\n' >src/main.rs
  # A 1x1 PNG.
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99=\x1d\x00\x00\x00\x00IEND\xaeB`\x82' >logo.png
  git add -A
  git commit -q -m "Initial commit"
  printf '# Test project\n\nA repository for the W3 screens, edited.\n\nMore lines.\n' >README.md
  printf 'fn main() {\n    println!("hello, world");\n}\n' >src/main.rs
  printf 'untracked notes\n' >notes.txt
)

# Claude Code's stand-in: SessionStart, then per prompt UserPromptSubmit → (a PermissionRequest
# when the prompt says "permission") → an edit → Stop with the reply, through the daemon's hook
# command from --settings, exactly as the real CLI runs its hooks.
cat >"$bin/claude" <<'EOF'
#!/bin/bash
settings=""
while [ $# -gt 0 ]; do
  case "$1" in --settings) settings="$2"; shift 2 ;; *) shift ;; esac
done
hook_cmd=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["Stop"][0]["hooks"][0]["command"])' "$settings")
hook="${hook_cmd% Stop}"
send() { printf '%s' "$2" | eval "$hook $1"; }
sid="fake-$$"
json() { /usr/bin/python3 -c 'import json,sys; print(json.dumps(dict(a.split("=",1) for a in sys.argv[1:])))' "$@"; }
send SessionStart "$(json session_id=$sid hook_event_name=SessionStart source=startup cwd=$PWD)" >/dev/null
printf '\n  * Claude stand-in for tests\n\n'
while IFS= read -r line; do
  send UserPromptSubmit "$(json session_id=$sid hook_event_name=UserPromptSubmit cwd=$PWD)" >/dev/null
  echo "prompt: $line"
  case "$line" in
    *permission*)
      # "slowly": think a while first (time to leave the agent's tab, for the toast test).
      case "$line" in *slowly*) sleep 4 ;; esac
      echo "asking to run: rm -rf build"
      payload=$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"PermissionRequest","cwd":sys.argv[2],"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}))' "$sid" "$PWD")
      out=$(send PermissionRequest "$payload")
      # An edited approval (updatedInput) runs the edited command instead.
      edited=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["decision"]["updatedInput"]["command"])
except Exception: pass' 2>/dev/null)
      case "$out" in
        *'"allow"'*) if [ -n "$edited" ]; then echo "decision: allowed (edited: $edited)"; else echo "decision: allowed"; fi ;;
        *'"deny"'*) echo "decision: denied" ;;
        *) echo "decision: none" ;;
      esac
      ;;
  esac
  # A real turn takes seconds; the daemon snapshots the tree when the turn starts.
  sleep 1
  echo "turn: $line" >>agent-notes.txt
  send Stop "$(json session_id=$sid hook_event_name=Stop cwd=$PWD "last_assistant_message=Done: $line")" >/dev/null
done
EOF
chmod +x "$bin/claude"

# `code serve-web`'s stand-in: answers only with the token, serves a page that logs keys (to
# check that ⌘ shortcuts reach the editor, not the app).
cat >"$bin/code" <<'EOF'
#!/usr/bin/env python3
import http.server, sys
args = sys.argv[1:]
if "--version" in args:
    print("1.105.0\nfakecommit\narm64")
    sys.exit(0)
# `code tunnel …`'s stand-in (the opt-in Remote Tunnel): never signed in at first; the login
# prints a GitHub device code and completes by itself after a few seconds (in real life the user
# enters the code in their browser); the tunnel prints its vscode.dev link and stays up.
if args[:1] == ["tunnel"]:
    import os, time
    here = os.path.dirname(os.path.abspath(__file__))
    signed_in = os.path.join(here, "tunnel-signed-in")
    rest = args[1:]
    if rest[:1] == ["status"]:
        print('{"tunnel":null,"service_installed":false}')
        sys.exit(0)
    if rest[:2] == ["user", "show"]:
        sys.exit(0 if os.path.exists(signed_in) else 1)
    if rest[:2] == ["user", "login"]:
        print("To grant access to the server, please log into https://github.com/login/device and use code FAKE-1234", flush=True)
        time.sleep(8)
        open(signed_in, "w").close()
        sys.exit(0)
    name = rest[rest.index("--name") + 1] if "--name" in rest else "box"
    print("*\n* Visual Studio Code Server\n*", flush=True)
    print("Open this link in your browser https://vscode.dev/tunnel/%s/home/me" % name, flush=True)
    while True:
        time.sleep(1000)
port =int(args[args.index("--port") + 1])
token = args[args.index("--connection-token") + 1]
PAGE = b"""<!doctype html><html><head><meta name=viewport content="width=device-width">
<title>Fake VS Code</title><style>body{background:#1f1f1f;color:#ccc;font:16px -apple-system}</style></head>
<body tabindex=0><h1>Fake VS Code workbench</h1><p id=path></p><p>Keys: <span id=keys>none</span></p>
<p id=loads></p>
<input id=field aria-label="editor input" autofocus>
<script>
document.getElementById('path').textContent = 'Location ' + decodeURIComponent(location.search);
// How often this page loaded in this origin (one server per folder): a tab switch must not
// reload it; a suspended editor coming back does.
localStorage.loads = (+localStorage.loads || 0) + 1;
document.getElementById('loads').textContent = 'Page loads ' + localStorage.loads;
var keys = [];
document.addEventListener('keydown', function (e) {
  keys.push((e.metaKey ? 'cmd+' : '') + (e.shiftKey ? 'shift+' : '') + e.key.toLowerCase());
  document.getElementById('keys').textContent = keys.slice(-4).join(' ');
  if (e.metaKey) e.preventDefault();
}, true);
</script></body></html>"""
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = ("tkn=" + token) in self.path or ("vscode-tkn=" + token) in (self.headers.get("Cookie") or "")
        self.send_response(200 if ok else 403)
        self.send_header("Content-Type", "text/html")
        if ok:
            self.send_header("Set-Cookie", "vscode-tkn=" + token)
        self.end_headers()
        self.wfile.write(PAGE if ok else b"forbidden")
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
chmod +x "$bin/code"

# vscode.dev's stand-in for the tunnel test (the app is pointed at it with -testTunnelWebBase,
# so nothing is downloaded): a page whose Sign In button opens a popup, like vscode.dev's
# GitHub sign-in; the popup tells its opener and closes itself.
#   vscode-dev-stub <port>
cat >"$bin/vscode-dev-stub" <<'EOF'
#!/usr/bin/env python3
import http.server, sys
MAIN = b"""<!doctype html><html><head><meta name=viewport content="width=device-width">
<title>Fake vscode.dev</title><style>body{background:#1f1f1f;color:#ccc;font:16px -apple-system}
button{font-size:20px;padding:12px 24px}</style></head>
<body><h1>Fake vscode.dev workbench</h1><p id=where></p><p id=state>Signed out</p>
<button id=signin onclick="window.open('/popup', 'signin', 'width=480,height=640')">Sign In</button>
<script>
document.getElementById('where').textContent = 'Tunnel ' + location.pathname;
window.addEventListener('message', function (e) { document.getElementById('state').textContent = 'Popup said ' + e.data; });
</script></body></html>"""
POPUP = b"""<!doctype html><html><head><meta name=viewport content="width=device-width">
<title>Fake sign-in</title><style>body{background:#fff;color:#111;font:16px -apple-system}
button{font-size:20px;padding:12px 24px}</style></head>
<body><h1>Fake sign-in popup</h1>
<button id=finish onclick="window.opener.postMessage('signed-in', '*'); window.close()">Finish Sign In</button>
</body></html>"""
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(POPUP if self.path.startswith("/popup") else MAIN)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
chmod +x "$bin/vscode-dev-stub"

# A dev server for S-BR1 (the browser keeps the origin): prints a URL like Vite does, sets a
# cookie from the page, echoes what it was sent on /whoami and over a websocket on /ws.
cat >"$bin/devserver" <<'EOF'
#!/usr/bin/python3
import base64, hashlib, http.server, socketserver, sys
port, name = int(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else "localhost")
PAGE = b"""<!doctype html><title>devserver</title><body style="font: 24px -apple-system">
<p id=r>checking</p><script>
document.cookie = "dev=yes; path=/";
const out = { origin: location.origin };
fetch("/whoami").then(r => r.text()).then(t => {
  out.who = t;
  const ws = new WebSocket("ws://" + location.host + "/ws");
  ws.onopen = () => ws.send("hello");
  ws.onmessage = e => { out.ws = e.data; finish(); };
  ws.onerror = () => { out.ws = "error"; finish(); };
}).catch(e => { out.who = "fetch failed"; finish(); });
function finish() {
  document.getElementById("r").textContent = "origin=" + out.origin + " " + out.who + " ws=" + out.ws;
}
</script>"""
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if self.path == "/ws":
            key = self.headers.get("Sec-WebSocket-Key", "")
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
            self.wfile.flush()
            head = self.rfile.read(2)
            length = head[1] & 0x7F
            mask = self.rfile.read(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(length)))
            reply = b"echo:" + data
            self.wfile.write(bytes([0x81, len(reply)]) + reply)
            self.wfile.flush()
            # Stay open until the page closes it (an abrupt close can beat the message).
            try:
                while self.rfile.read(1):
                    pass
            except OSError:
                pass
            self.close_connection = True
            return
        if self.path == "/whoami":
            cookies = "; ".join(c.strip() for c in self.headers.get("Cookie", "").split(";") if c.strip().startswith("dev="))
            body = ("cookie=%s" % (cookies or "none")).encode()
            kind = "text/plain"
        else:
            body, kind = PAGE, "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
server = S(("127.0.0.1", port), H)
print("  Local:   http://%s:%d/" % (name, port), flush=True)
server.serve_forever()
EOF
chmod +x "$bin/devserver"

cat >"$dir/config.toml" <<EOF
[editor]
code = "$bin/code"
EOF

echo "$dir"
