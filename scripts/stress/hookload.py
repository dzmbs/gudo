#!/usr/bin/env python3
"""Load on the hook socket from inside a pane (it needs the pane's GUDO_SOCK and GUDO_TOKEN).

  hookload.py hooks <gudo-hook> <threads> <secs>    real gudo-hook processes, PreToolUse/PostToolUse
  hookload.py perm <gudo-hook> <threads> <secs>     real gudo-hook PermissionRequests, each new one
                                                  replacing the one held open
  hookload.py perm-every <gudo-hook> <gap> <secs>   a new PermissionRequest every <gap> seconds
  hookload.py term <threads> <secs> <tool> <json> terminal-tool calls (what `gudo-hook mcp` sends)

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
latencies, failures = [], []


def record(seconds, failure):
    with lock:
        latencies.append(seconds)
        if failure:
            failures.append(failure)


def un_hook(binary, event, payload, n, end):
    env = dict(os.environ, GUDO_HOOK_DEBUG="1")
    started = time.monotonic()
    try:
        # A held PermissionRequest returns once a newer one replaces it; the last one is
        # still held when the run ends.
        result = subprocess.run([binary, "claude", event], input=json.dumps(payload).encode(),
                                capture_output=True, env=env, timeout=max(1.0, end - started + 1))
        failure = result.stderr.decode().strip()[:120] or None
    except subprocess.TimeoutExpired:
        failure = "still held when the run ended"
    record(time.monotonic() - started, failure)


def term_call(tool, args):
    call = {"v": 1, "token": os.environ["GUDO_TOKEN"], "pane": os.environ["GUDO_PANE_ID"],
            "term": {"tool": tool, "args": args}}
    started = time.monotonic()
    failure = None
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(300)
        sock.connect(os.environ["GUDO_SOCK"])
        sock.sendall(json.dumps(call).encode() + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
        sock.close()
        reply = json.loads(data)
        if "error" in reply:
            failure = reply["error"]["code"] + ": " + reply["error"]["message"][:80]
    except Exception as error:  # noqa: BLE001 - every failure is a data point
        failure = type(error).__name__ + ": " + str(error)[:80]
    record(time.monotonic() - started, failure)


def perm_every(binary, gap, secs):
    """One agent asking for a new approval every `gap` seconds (the newest replaces the one
    held open), as a looping agent would."""
    env = dict(os.environ, GUDO_HOOK_DEBUG="1")
    end = time.monotonic() + secs
    held = []
    while time.monotonic() < end:
        process = subprocess.Popen([binary, "claude", "PermissionRequest"], stdin=subprocess.PIPE,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        process.stdin.write(json.dumps(PERM).encode())
        process.stdin.close()
        held.append(process)
        time.sleep(gap)
    for process in held:
        process.kill()
        process.wait()
    report = f"perm-every: {len(held)} requests, one every {gap} s\n"
    sys.stdout.write(report)
    out = os.environ.get("HOOKLOAD_OUT")
    if out:
        with open(out, "a") as out_file:
            out_file.write(report)


def main():
    mode = sys.argv[1]
    if mode == "perm-every":
        perm_every(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
        return
    if mode == "term":
        threads, secs, tool, args = int(sys.argv[2]), float(sys.argv[3]), sys.argv[4], json.loads(sys.argv[5])
        work = lambda n: term_call(tool, args)
    else:
        binary, threads, secs = sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
        if mode == "hooks":
            work = lambda n: un_hook(binary, "PreToolUse" if n % 2 else "PostToolUse", PRE, n, end)
        else:
            work = lambda n: un_hook(binary, "PermissionRequest", PERM, n, end)
    end = time.monotonic() + secs

    def worker(i):
        n = i
        while time.monotonic() < end:
            work(n)
            n += threads

    started = time.monotonic()
    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    wall = time.monotonic() - started
    samples = sorted(latencies)
    millis_at = lambda q: samples[min(len(samples) - 1, int(q * (len(samples) - 1)))] * 1000 if samples else 0
    kinds = {}
    for failure in failures:
        kinds[failure] = kinds.get(failure, 0) + 1
    report = (f"{mode}: {len(samples)} calls in {wall:.1f} s ({len(samples) / wall:.0f}/s), "
              f"p50 {millis_at(0.5):.1f} ms p99 {millis_at(0.99):.1f} ms max {millis_at(1):.1f} ms, {len(failures)} failed\n")
    for kind, count in sorted(kinds.items(), key=lambda item: -item[1])[:5]:
        report += f"  {count}x {kind}\n"
    sys.stdout.write(report)
    out = os.environ.get("HOOKLOAD_OUT")
    if out:
        with open(out, "a") as out_file:
            out_file.write(report)


main()
