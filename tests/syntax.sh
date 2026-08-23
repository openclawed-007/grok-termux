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

exit "$fail"
