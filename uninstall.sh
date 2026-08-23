#!/usr/bin/env bash
# Remove grok-termux wrappers. Auth and config in ~/.grok are kept unless --purge.
set -euo pipefail

GT_HOME="${GROK_TERMUX_HOME:-${HOME}/.grok/termux}"
GT_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PURGE=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help)
      cat <<EOF
uninstall.sh — remove grok-termux wrappers from Termux

  uninstall.sh           drop grok / agent / grok-termux links and ${GT_HOME}
  uninstall.sh --purge   also delete ~/.grok (auth, config, downloaded binaries)
EOF
      exit 0
      ;;
  esac
done

is_ours() {
  local t
  t="$(readlink -f "$1" 2>/dev/null || true)"
  case "$t" in
    "${GT_HOME}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

for name in grok agent grok-termux; do
  p="${GT_PREFIX}/bin/${name}"
  if [ -L "$p" ] && is_ours "$p"; then
    rm -f "$p"
    printf '==> removed %s\n' "$p"
  fi
done

rm -rf "$GT_HOME"
printf '==> removed %s\n' "$GT_HOME"

if [ "$PURGE" = 1 ]; then
  rm -rf "${HOME}/.grok"
  printf '==> purged %s\n' "${HOME}/.grok"
else
  printf '==> kept %s (pass --purge to delete auth + binaries)\n' "${HOME}/.grok"
fi
