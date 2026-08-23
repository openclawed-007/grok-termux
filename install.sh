#!/usr/bin/env bash
# grok-termux — make xAI Grok Build run on Termux, whatever Android throws at it.
#
#   curl -fsSL https://raw.githubusercontent.com/openclawed-007/grok-termux/main/install.sh | bash
#
# On a regular Linux host this just runs the official installer.
set -euo pipefail

RAW="${GROK_TERMUX_RAW:-https://raw.githubusercontent.com/openclawed-007/grok-termux/main}"
FILES=(install.sh lib/grok-termux.sh lib/grok-dns.py bin/grok-launch uninstall.sh)

gt_bootstrap_die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

script_dir() {
  local s="${BASH_SOURCE[0]:-}"
  if [ -n "$s" ] && [ -f "$s" ]; then
    cd "$(dirname "$s")" && pwd
    return 0
  fi
  return 1
}

is_termux() {
  [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/bin" ] || return 1
  [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files ]
}

if ! is_termux; then
  printf '==> not Termux — running the official xAI installer\n'
  if [ -n "${1:-}" ]; then
    curl -fsSL https://x.ai/cli/install.sh | bash -s -- "$1"
  else
    curl -fsSL https://x.ai/cli/install.sh | bash
  fi
  exit $?
fi

GT_HOME="${GROK_TERMUX_HOME:-${HOME}/.grok/termux}"
mkdir -p "$GT_HOME"

SRC=""
if SRC="$(script_dir)" && [ -f "${SRC}/lib/grok-termux.sh" ]; then
  :
else
  SRC="$(mktemp -d "${TMPDIR:-/tmp}/grok-termux.XXXXXX")"
  printf '==> fetching grok-termux sources\n'
  command -v curl >/dev/null || gt_bootstrap_die "curl is required"
  mkdir -p "${SRC}/lib" "${SRC}/bin"
  for f in "${FILES[@]}"; do
    curl -fsSL --retry 3 --retry-delay 2 "${RAW}/${f}" -o "${SRC}/${f}" \
      || gt_bootstrap_die "failed to fetch ${f}"
  done
fi

cp -f "${SRC}/lib/grok-termux.sh" "${GT_HOME}/grok-termux.sh"
cp -f "${SRC}/lib/grok-dns.py" "${GT_HOME}/grok-dns.py"
cp -f "${SRC}/bin/grok-launch" "${GT_HOME}/grok-launch"
cp -f "${SRC}/uninstall.sh" "${GT_HOME}/uninstall.sh"
cp -f "${SRC}/install.sh" "${GT_HOME}/install.sh" 2>/dev/null || true
chmod 755 "${GT_HOME}/grok-launch" "${GT_HOME}/uninstall.sh" "${GT_HOME}/install.sh" \
  "${GT_HOME}/grok-dns.py" 2>/dev/null || true

# shellcheck disable=SC1091
. "${GT_HOME}/grok-termux.sh"

case "${1:-}" in
  -h|--help|help)
    gt_cli_usage
    exit 0
    ;;
  --doctor|doctor)
    gt_doctor
    exit 0
    ;;
  --uninstall|uninstall)
    shift
    exec bash "${GT_HOME}/uninstall.sh" "$@"
    ;;
esac

gt_log "grok-termux: installing Grok Build on Termux"

command -v pkg >/dev/null || gt_die "pkg not found. Use Termux from F-Droid or GitHub Releases, not the Play Store."

gt_log "installing base packages"
pkg update -y </dev/null >/dev/null 2>&1 || true
gt_pkg curl python git coreutils || gt_die "pkg install curl python git coreutils failed"
# best-effort extras grok likes
gt_pkg ripgrep fd termux-api 2>/dev/null || true

GT_PLATFORM="$(gt_platform)"
PINNED="${1:-}"
case "$PINNED" in
  --*) gt_die "unknown flag: $PINNED (try install.sh --help)" ;;
esac
GT_VERSION="$(gt_fetch_version "$PINNED")"
gt_log "version ${GT_VERSION}  platform ${GT_PLATFORM}  channel ${GT_CHANNEL}"

bin="$(gt_download_binary "$GT_VERSION" "$GT_PLATFORM")"
gt_pick_backend "$bin"
gt_save_state
gt_install_wrappers

echo
gt_log "installed grok ${GT_VERSION}  backend=${GT_BACKEND}"
gt_log "start:   grok"
gt_log "auth:    export XAI_API_KEY=xai-...    or sign in from the TUI"
gt_log "device:  grok login --device-auth      (no local browser needed)"
gt_log "health:  grok-termux doctor"
gt_log "update:  grok-termux update            (or Ctrl+U inside grok, then restart)"
