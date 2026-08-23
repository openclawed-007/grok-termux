#!/usr/bin/env python3
"""Unit tests for the 16-byte musl DNS path swap."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DNS_PY = ROOT / "lib" / "grok-dns.py"
NATIVE = b"/etc/resolv.conf"
SDCARD = b"/sdcard/.grokdns"


def run(path: Path, mode: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(DNS_PY), str(path), mode],
        capture_output=True,
        text=True,
    )


def test_roundtrip() -> None:
    payload = b"HDR" + NATIVE + b"MID" + NATIVE + b"END"
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(payload)
        path = Path(tmp.name)
    try:
        r = run(path, "sdcard")
        assert r.returncode == 0, r.stderr
        data = path.read_bytes()
        assert SDCARD in data and NATIVE not in data
        assert data.count(SDCARD) == 2

        r = run(path, "sdcard")
        assert r.returncode == 0

        r = run(path, "native")
        assert r.returncode == 0, r.stderr
        data = path.read_bytes()
        assert NATIVE in data and SDCARD not in data
        assert data.count(NATIVE) == 2
    finally:
        os.unlink(path)


def test_missing_strings() -> None:
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(b"no resolv path in here")
        path = Path(tmp.name)
    try:
        r = run(path, "sdcard")
        assert r.returncode == 2, r.stderr
    finally:
        os.unlink(path)


def test_usage() -> None:
    r = subprocess.run(
        [sys.executable, str(DNS_PY)],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 1
    assert "usage" in r.stderr


def test_lengths() -> None:
    assert len(NATIVE) == len(SDCARD) == 16


if __name__ == "__main__":
    tests = [test_lengths, test_roundtrip, test_missing_strings, test_usage]
    failed = 0
    for fn in tests:
        try:
            fn()
            print(f"ok  {fn.__name__}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {fn.__name__}: {exc}")
    sys.exit(1 if failed else 0)
