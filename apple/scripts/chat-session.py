#!/usr/bin/env python3
"""Writes a Claude Code session file (the 2.1.318 transcript format) for Chat UI tests and
screenshots: a question, thinking, a search, a read, an edit with its diff, a test run and a
summary with a list and code.

    chat-session.py <session-id> <cwd> <output.jsonl>
"""
import json
import sys
import uuid
from datetime import datetime, timedelta, timezone

session, cwd, output = sys.argv[1:4]
clock = datetime(2026, 11, 10, 21, 4, 0, tzinfo=timezone.utc)
parent = None
records = []
prompt_id = str(uuid.uuid4())


def stamp():
    global clock
    clock += timedelta(seconds=3)
    return clock.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def common(kind):
    return {"isSidechain": False, "type": kind, "userType": "external", "entrypoint": "cli",
            "cwd": cwd, "sessionId": session, "version": "2.1.318", "gitBranch": "main"}


def append(record):
    global parent
    record["parentUuid"] = parent
    record["uuid"] = str(uuid.uuid4())
    record["timestamp"] = stamp()
    parent = record["uuid"]
    records.append(record)
    return record["uuid"]


def user(text):
    record = common("user")
    record.update(promptId=prompt_id, message={"role": "user", "content": text})
    append(record)


def assistant(index, block, stop="tool_use"):
    record = common("assistant")
    record.update(
        message={"id": f"msg_chat_{index}", "type": "message", "role": "assistant",
                 "model": "claude-opus-4-6", "content": [block], "stop_reason": stop,
                 "stop_sequence": None,
                 "usage": {"input_tokens": 2400, "output_tokens": 180, "cache_creation_input_tokens": 0,
                           "cache_read_input_tokens": 0}},
        requestId=f"req_chat_{index}")
    return append(record)


def result(tool_id, source, content, details):
    record = common("user")
    record.update(promptId=prompt_id,
                  message={"role": "user", "content": [
                      {"tool_use_id": tool_id, "type": "tool_result", "content": content, "is_error": False}]},
                  toolUseResult=details, sourceToolAssistantUUID=source)
    append(record)


def tool(index, tool_id, name, tool_input, content, details):
    source = assistant(index, {"type": "tool_use", "id": tool_id, "name": name, "input": tool_input})
    result(tool_id, source, content, details)


form = f"{cwd}/src/signup/validate.ts"
original = ("export function isEmail(value: string): boolean {\n"
            "  return /^[a-z0-9.]+@[a-z0-9]+\\.[a-z]{2,3}$/.test(value)\n"
            "}\n")
fixed = ("export function isEmail(value: string): boolean {\n"
         "  return /^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$/i.test(value.trim())\n"
         "}\n")

user("Sign-up rejects emails like ana.lopez+news@mail.studio. Find out why and fix it.")
assistant(0, {"type": "thinking", "thinking": "The validator is probably too strict. I will find it first.",
              "signature": ""})
assistant(1, {"type": "text", "text": "I'll find the email check the form uses."})
tool(2, "toolu_chat_grep", "Bash", {"command": "rg -n 'isEmail' src", "description": "Find the email check"},
     "src/signup/validate.ts:1:export function isEmail(value: string): boolean {\n"
     "src/signup/Form.tsx:42:    if (!isEmail(email)) return setError('Enter a valid email')",
     {"stdout": "src/signup/validate.ts:1:export function isEmail(value: string): boolean {\n"
                "src/signup/Form.tsx:42:    if (!isEmail(email)) return setError('Enter a valid email')",
      "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False})
tool(3, "toolu_chat_read", "Read", {"file_path": form},
     "1\texport function isEmail(value: string): boolean {\n2\t  return /^[a-z0-9.]+@[a-z0-9]+\\.[a-z]{2,3}$/.test(value)\n3\t}",
     {"type": "text", "file": {"filePath": form, "content": original, "numLines": 3, "startLine": 1, "totalLines": 3}})
assistant(4, {"type": "text", "text": "Found it. The pattern allows only letters, digits and dots before the `@`, "
                                     "and a top-level domain of two or three letters, so `+` tags and `.studio` fail."})
tool(5, "toolu_chat_edit", "Edit",
     {"replace_all": False, "file_path": form,
      "old_string": "  return /^[a-z0-9.]+@[a-z0-9]+\\.[a-z]{2,3}$/.test(value)",
      "new_string": "  return /^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$/i.test(value.trim())"},
     f"The file {form} has been updated successfully.",
     {"filePath": form, "oldString": "  return /^[a-z0-9.]+@[a-z0-9]+\\.[a-z]{2,3}$/.test(value)",
      "newString": "  return /^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$/i.test(value.trim())", "originalFile": original,
      "structuredPatch": [{"oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 3, "lines": [
          " export function isEmail(value: string): boolean {",
          "-  return /^[a-z0-9.]+@[a-z0-9]+\\.[a-z]{2,3}$/.test(value)",
          "+  return /^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$/i.test(value.trim())",
          " }"]}],
      "userModified": False, "replaceAll": False})
tool(6, "toolu_chat_test", "Bash", {"command": "npm test -- signup", "description": "Run the sign-up tests"},
     "PASS src/signup/validate.test.ts\n  isEmail\n    ✓ accepts plus tags (2 ms)\n    ✓ accepts long domains\n"
     "    ✓ rejects spaces\n\nTests: 12 passed, 12 total",
     {"stdout": "PASS src/signup/validate.test.ts\n  isEmail\n    ✓ accepts plus tags (2 ms)\n    ✓ accepts long domains\n"
                "    ✓ rejects spaces\n\nTests: 12 passed, 12 total",
      "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False})
assistant(7, {"type": "text", "text":
              "Fixed. Sign-up now accepts addresses like `ana.lopez+news@mail.studio`.\n\n"
              "**What changed**\n"
              "- `+` tags and other characters before the `@` are allowed\n"
              "- Domains of any length work (`.studio`, `.photography`)\n"
              "- Spaces around the address are trimmed first\n\n"
              "```ts\nreturn /^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$/i.test(value.trim())\n```\n\n"
              "All 12 sign-up tests pass."}, stop="end_turn")

with open(output, "w") as file:
    for record in records:
        file.write(json.dumps(record, ensure_ascii=False) + "\n")
