#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for f in install.sh uninstall.sh bin/grok-launch lib/grok-termux.sh; do
  if bash -n "${ROOT}/${f}"; then
    printf 'ok  bash -n %s\n' "$f"
  else
    printf 'FAIL bash -n %s\n' "$f"
    fail=1
  fi
done
# shellcheck is optional
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s bash "${ROOT}/install.sh" "${ROOT}/uninstall.sh" "${ROOT}/bin/grok-launch" \
    "${ROOT}/lib/grok-termux.sh" || fail=1
else
  printf 'ok  shellcheck skipped (not installed)\n'
fi

# source the lib on a normal Linux host and check helpers
# shellcheck disable=SC1091
. "${ROOT}/lib/grok-termux.sh"
plat="$(gt_platform)"
case "$plat" in
  linux-x86_64|linux-aarch64) printf 'ok  gt_platform=%s\n' "$plat" ;;
  *) printf 'FAIL gt_platform=%s\n' "$plat"; fail=1 ;;
esac

python3 - <<'PY'
assert len("/etc/resolv.conf") == 16
assert len("/sdcard/.grokdns") == 16
print("ok  dns path lengths")
PY

# Logs must not leak into command substitutions (that built grok-==> URLs).
log_out="$(gt_log "hello-log" 2>/dev/null || true)"
if [ -z "$log_out" ]; then
  printf 'ok  gt_log goes to stderr\n'
else
  printf 'FAIL gt_log leaked to stdout: %s\n' "$log_out"
  fail=1
fi
ver="$(gt_fetch_version 1.0.5)"
if [ "$ver" = "1.0.5" ]; then
  printf 'ok  gt_fetch_version stdout is the version only\n'
else
  printf 'FAIL gt_fetch_version stdout=%s\n' "$ver"
  fail=1
fi
parsed="$(gt_parse_version $'==> resolving latest stable version\n1.0.5\n')"
if [ "$parsed" = "1.0.5" ]; then
  printf 'ok  gt_parse_version strips log noise\n'
else
  printf 'FAIL gt_parse_version=%s\n' "$parsed"
  fail=1
fi

old_preload="${LD_PRELOAD-}"
export LD_PRELOAD=/tmp/fake-termux-exec.so
gt_env_prep
if [ "${LD_PRELOAD}" = "/tmp/fake-termux-exec.so" ]; then
  printf 'ok  gt_env_prep preserves LD_PRELOAD\n'
else
  printf 'FAIL gt_env_prep clobbered LD_PRELOAD (%s)\n' "${LD_PRELOAD-}"
  fail=1
fi
if [ -n "$old_preload" ]; then export LD_PRELOAD="$old_preload"; else unset LD_PRELOAD; fi

# Probe must not treat bionic linker errors as success (path contains "grok").
fake="$(mktemp)"
printf '%s\n' 'error: "/data/data/com.termux/files/usr/libexec/grok-termux/grok" has unexpected e_type: 2' > "$fake"
if gt_probe_loaded 1 "$fake"; then
  printf 'FAIL gt_probe_loaded treated e_type error as success\n'
  fail=1
else
  printf 'ok  gt_probe_loaded rejects e_type error\n'
fi
printf '%s\n' 'grok 1.0.5' > "$fake"
if gt_probe_loaded 0 "$fake"; then
  printf 'ok  gt_probe_loaded accepts a real version line\n'
else
  printf 'FAIL gt_probe_loaded rejected version output\n'
  fail=1
fi
rm -f "$fake"

python3 -m py_compile "${ROOT}/lib/grok-exec.py"
printf 'ok  grok-exec.py compiles\n'
if python3 "${ROOT}/lib/grok-exec.py" /bin/true; then
  printf 'ok  grok-exec.py SYS_execve /bin/true\n'
else
  printf 'FAIL grok-exec.py could not exec /bin/true\n'
  fail=1
fi

exit "$fail"
