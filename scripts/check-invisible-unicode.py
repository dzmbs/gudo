#!/usr/bin/env python3
"""Fails if tracked text files contain characters that hide what code does.

Bidirectional controls reorder how source displays ("Trojan Source", CVE-2021-42574), and
invisible characters can smuggle instructions past review (GlassWorm, prompt injection). Write
them as escapes (`\\u{200d}`) where a test needs one.

Usage: scripts/check-invisible-unicode.py (from the repository root)
"""

import subprocess
import sys

SUSPECT = {
    *range(0x202A, 0x202F),  # LRE, RLE, PDF, LRO, RLO
    *range(0x2066, 0x206A),  # LRI, RLI, FSI, PDI
    0x200B,  # zero width space
    0x200E,  # left-to-right mark
    0x200F,  # right-to-left mark
    0x2060,  # word joiner
    0x061C,  # Arabic letter mark
    *range(0xE0000, 0xE0080),  # tag characters
}
# Generated bundles from upstream projects; checked when they are rebuilt.
SKIP_PREFIXES = ("vendor/", "apple/App/Resources/")


def main() -> int:
    files = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, check=True
    ).stdout.split(b"\0")
    bad = 0
    for name in filter(None, (f.decode() for f in files)):
        if name.startswith(SKIP_PREFIXES):
            continue
        try:
            with open(name, encoding="utf-8") as f:
                text = f.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            hits = sorted({f"U+{ord(c):04X}" for c in line if ord(c) in SUSPECT})
            if hits:
                print(f"{name}:{number}: {', '.join(hits)}")
                bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
