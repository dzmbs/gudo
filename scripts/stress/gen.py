#!/usr/bin/env python3
"""Pathological output generators for stress panes: gen.py <kind> [rate_per_s]

Writes to stdout forever (or until killed). A rate of 0 means as fast as possible.
"""
import os
import random
import sys
import time

kind = sys.argv[1]
rate = float(sys.argv[2]) if len(sys.argv) > 2 else 0
stdout = os.fdopen(1, "wb", buffering=0)
rng = random.Random(1)
count = 0


def chunk(i):
    if kind == "title":
        return b"\x1b]0;title %d\x07" % i
    if kind == "osc7":
        return b"\x1b]7;file://localhost/tmp/dir%d\x07" % (i % 1000)
    if kind == "osc133":
        return b"\x1b]133;A\x07$ \x1b]133;B\x07cmd %d\x1b]133;C\x07out\r\n\x1b]133;D;0\x07" % i
    if kind == "notify":
        return b"\x1b]9;note %d\x07\x1b]777;notify;t%d;body\x07" % (i, i)
    if kind == "osc7501":
        return b'\x1b]7501;{"state":"working","n":%d}\x07' % i
    if kind == "osc52":
        return b"\x1b]52;c;aGVsbG8gd29ybGQgJWQ=\x07"
    if kind == "osc52big":
        return b"\x1b]52;c;" + b"A" * (1 << 20) + b"\x07"
    if kind == "links":
        return b"\x1b]8;;https://example.com/%d\x1b\\link %d\x1b]8;;\x1b\\\r\n" % (i, i)
    if kind == "unicode":
        # Emoji, ZWJ sequences, flags, CJK, combining marks stacked deep, RTL, wide/narrow mix.
        parts = [
            "👩‍👩‍👧‍👦", "🇺🇳", "e" + "́" * 40, "漢字かな", "\u202eabc", "a‍b",
            "\U0001F600" * 3, "กิ์" * 5, "️" * 10, "각",
        ]
        return ("".join(rng.choice(parts) for _ in range(20)) + "\r\n").encode()
    if kind == "altscreen":
        return b"\x1b[?1049h\x1b[2J\x1b[Hframe %d\x1b[?1049l" % i
    if kind == "longline":
        return b"x" * 65536
    if kind == "kitty":
        # A 64x64 RGBA image, transmitted and placed, a new id each time.
        payload = __import__("base64").b64encode(bytes([i % 256, 0, 0, 255]) * 4096)
        return b"\x1b_Ga=T,f=32,s=64,v=64,i=%d;%s\x1b\\" % (i % 100000 + 1, payload)
    raise SystemExit("unknown kind " + kind)


start = time.monotonic()
while True:
    count += 1
    try:
        stdout.write(chunk(count))
    except BrokenPipeError:
        break
    if rate:
        due = start + count / rate
        delay = due - time.monotonic()
        if delay > 0:
            time.sleep(delay)
