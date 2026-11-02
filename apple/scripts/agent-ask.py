#!/usr/bin/env python3
"""Plays an agent asking permission in a daemon's pane, through its hook socket, as Claude Code's
hooks do: SessionStart, then a PermissionRequest that waits for someone to answer. Prints the
decision ("allow" or "deny").

    apple/scripts/agent-ask.py <state-dir> <pane> [command]
"""
import json
import os
import socket
import sys

state, pane = sys.argv[1], sys.argv[2]
command = sys.argv[3] if len(sys.argv) > 3 else "rm -rf build"
token = open(os.path.join(state, "hook.token")).read().strip()
path = open(os.path.join(state, "hook.endpoint")).read().strip()


def send(seq, event, payload):
    request = {"v": 1, "token": token, "pane": pane, "agent": "claude", "event": event, "seq": seq, "payload": payload}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(path)
        sock.sendall(json.dumps(request).encode() + b"\n")
        answer = b""
        while not answer.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            answer += chunk
    return json.loads(answer or b"{}")


session = {"session_id": "presence-test", "cwd": state}
send(1, "SessionStart", {**session, "hook_event_name": "SessionStart", "source": "startup"})
answer = send(2, "PermissionRequest", {
    **session,
    "hook_event_name": "PermissionRequest",
    "permission_mode": "default",
    "tool_name": "Bash",
    "tool_input": {"command": command, "description": "Clean the build"},
})
try:
    hook_output = json.loads(answer.get("stdout") or "{}")
    print(hook_output["hookSpecificOutput"]["decision"]["behavior"])
except (KeyError, ValueError, TypeError):
    print("none")
