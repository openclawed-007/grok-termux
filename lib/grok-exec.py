#!/usr/bin/env python3
"""execve a static musl binary without going through libc execve.

Termux LD_PRELOAD (termux-exec) wraps execve/execv/posix_spawn in every
process started from bash. That hook feeds the file to Android linker64,
which only accepts ET_DYN and errors:

    error: ".../grok" has unexpected e_type: 2

A raw SYS_execve syscall bypasses the hook; the kernel binfmt_elf loader
then maps the ET_EXEC static binary itself.
"""
from __future__ import annotations

import ctypes
import os
import platform
import sys

# Linux syscall numbers (Android uses the same ABI).
SYS_EXECVE = {
    "aarch64": 221,
    "arm64": 221,
    "x86_64": 59,
    "amd64": 59,
    "i686": 11,
    "armv7l": 11,
    "armv8l": 221,
}


def _libc() -> ctypes.CDLL:
    last = None
    for name in (None, "libc.so", "libc.so.6"):
        try:
            return ctypes.CDLL(name, use_errno=True)
        except OSError as exc:
            last = exc
    raise OSError(f"could not load libc: {last}")


def raw_execve(path: str, argv: list[str], env: dict[str, str]) -> None:
    nr = SYS_EXECVE.get(platform.machine())
    if nr is None:
        os.execve(path, argv, env)

    libc = _libc()
    syscall = libc.syscall
    syscall.restype = ctypes.c_long

    keep = []

    def cstr(s: str) -> ctypes.c_char_p:
        buf = ctypes.create_string_buffer(s.encode())
        keep.append(buf)
        return ctypes.cast(buf, ctypes.c_char_p)

    c_path = cstr(path)
    c_argv = (ctypes.c_char_p * (len(argv) + 1))()
    for i, a in enumerate(argv):
        c_argv[i] = cstr(a)
    c_argv[len(argv)] = None

    items = [f"{k}={v}" for k, v in env.items() if k != "LD_PRELOAD"]
    c_env = (ctypes.c_char_p * (len(items) + 1))()
    for i, item in enumerate(items):
        c_env[i] = cstr(item)
    c_env[len(items)] = None

    syscall(ctypes.c_long(nr), c_path, c_argv, c_env)
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err), path)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: grok-exec.py <binary> [args...]\n")
        return 2
    path = argv[1]
    raw_execve(path, [path, *argv[2:]], dict(os.environ))
    return 127


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except OSError as exc:
        sys.stderr.write(f"[grok-exec] {exc}\n")
        sys.exit(exc.errno or 127)
