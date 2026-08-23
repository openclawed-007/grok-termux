#!/usr/bin/env python3
"""Swap the musl DNS path inside a Grok Build binary.

Both strings are 16 bytes, so this is an in-place overwrite — no relocation:

  /etc/resolv.conf  ↔  /sdcard/.grokdns

Exit codes:
  0  already in the requested mode, or patched successfully
  2  neither string is present (this build cannot be patched)
  1  usage / IO error
"""
from __future__ import annotations

import sys
import mmap

NATIVE = b"/etc/resolv.conf"
SDCARD = b"/sdcard/.grokdns"
assert len(NATIVE) == len(SDCARD) == 16


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[2] not in ("native", "sdcard"):
        sys.stderr.write("usage: grok-dns.py <binary> native|sdcard\n")
        return 1
    path, mode = argv[1], argv[2]
    target = NATIVE if mode == "native" else SDCARD
    other = SDCARD if mode == "native" else NATIVE
    try:
        with open(path, "r+b") as f:
            mm = mmap.mmap(f.fileno(), 0)
            try:
                if mm.find(target) != -1 and mm.find(other) == -1:
                    return 0
                n = 0
                i = mm.find(other)
                while i != -1:
                    mm[i : i + 16] = target
                    n += 1
                    i = mm.find(other, i + 16)
                if n:
                    mm.flush()
                    sys.stderr.write(
                        f"[grok-termux] DNS path -> {target.decode()} ({n}x)\n"
                    )
                    return 0
            finally:
                mm.close()
    except OSError as exc:
        sys.stderr.write(f"[grok-termux] DNS patch failed: {exc}\n")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
