#!/usr/bin/env python3
"""Load on the hook socket from inside a pane (it needs the pane's UN_SOCK and UN_TOKEN).

  hookload.py hooks <un-hook> <threads> <secs>    real un-hook processes, PreToolUse/PostToolUse
  hookload.py perm <un-hook> <threads> <secs>     real un-hook PermissionRequests, each new one
                                                  replacing the one held open
  hookload.py term <threads> <secs> <tool> <json> terminal-tool calls (what `un-hook mcp` sends)

Prints calls, rate, latency percentiles and failures to stdout and to $HOOKLOAD_OUT if set.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

PRE = {
    "session_id": "stress", "hook_event_name": "PreToolUse", "tool_name": "Bash",
    "tool_input": {"command": "npm test", "description": "Run test suite"}, "cwd": "/tmp",
}
PERM = {
    "session_id": "stress", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
    "tool_input": {"command": "rm -rf node_modules", "description": "Remove node_modules"},
    "cwd": "/tmp",
    "permission_suggestions": [{"type": "addRules", "behavior": "allow",
                                "rules": [{"toolName": "Bash", "ruleContent": "rm -rf x"}],
                                "destination": "localSettings"}],
}

lock = threading.Lock()
lat, fails = [], []


def record(seconds, failure):
    with lock:
        lat.append(seconds)
        if failure:
            fails.append(failure)


def un_hook(binary, event, payload, n):
    env = dict(os.environ, UN_HOOK_DEBUG="1")
    started = time.monotonic()
    p = subprocess.run([binary, "claude", event], input=json.dumps(payload).encode(),
                       capture_output=True, env=env)
    record(time.monotonic() - started, p.stderr.decode().strip()[:120] or None)


def term_call(tool, args):
    call = {"v": 1, "token": os.environ["UN_TOKEN"], "pane": os.environ["UN_PANE_ID"],
            "term": {"tool": tool, "args": args}}
    started = time.monotonic()
    failure = None
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(300)
        s.connect(os.environ["UN_SOCK"])
        s.sendall(json.dumps(call).encode() + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        reply = json.loads(data)
        if "error" in reply:
            failure = reply["error"]["code"] + ": " + reply["error"]["message"][:80]
    except Exception as e:  # noqa: BLE001 - every failure is a data point
        failure = type(e).__name__ + ": " + str(e)[:80]
    record(time.monotonic() - started, failure)


def main():
    mode = sys.argv[1]
    if mode == "term":
        threads, secs, tool, args = int(sys.argv[2]), float(sys.argv[3]), sys.argv[4], json.loads(sys.argv[5])
        work = lambda n: term_call(tool, args)
    else:
        binary, threads, secs = sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
        if mode == "hooks":
            work = lambda n: un_hook(binary, "PreToolUse" if n % 2 else "PostToolUse", PRE, n)
        else:
            work = lambda n: un_hook(binary, "PermissionRequest", PERM, n)
    end = time.monotonic() + secs

    def worker(i):
        n = i
        while time.monotonic() < end:
            work(n)
            n += threads

    started = time.monotonic()
    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for t in pool:
        t.start()
    for t in pool:
        t.join()
    wall = time.monotonic() - started
    v = sorted(lat)
    at = lambda q: v[min(len(v) - 1, int(q * (len(v) - 1)))] * 1000 if v else 0
    kinds = {}
    for f in fails:
        kinds[f] = kinds.get(f, 0) + 1
    report = (f"{mode}: {len(v)} calls in {wall:.1f} s ({len(v) / wall:.0f}/s), "
              f"p50 {at(0.5):.1f} ms p99 {at(0.99):.1f} ms max {at(1):.1f} ms, {len(fails)} failed\n")
    for k, c in sorted(kinds.items(), key=lambda kv: -kv[1])[:5]:
        report += f"  {c}x {k}\n"
    sys.stdout.write(report)
    out = os.environ.get("HOOKLOAD_OUT")
    if out:
        with open(out, "a") as f:
            f.write(report)


main()
