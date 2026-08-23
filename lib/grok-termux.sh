#!/usr/bin/env bash
# grok-termux runtime: pick a backend that can actually exec Grok Build on
# Android/Termux, then keep using it (re-probing after self-updates).
#
# Backends, in preference order:
#   native      official musl binary + 16-byte DNS path patch
#   proot-lite  same binary, proot bind-mounts a writable /etc/resolv.conf
#   qemu        qemu-user (kernel will not load the ELF: PIE / page-size)
#   distro      proot-distro Ubuntu — last-resort full Linux userspace
#
# Not affiliated with xAI. The grok binary is xAI's; this repo is the wrapper.

# Intentionally no `set -e` here — sourced by the launcher and installer.

GT_HOME="${GROK_TERMUX_HOME:-${HOME}/.grok/termux}"
GT_STATE="${GT_HOME}/state"
GT_ROOTFS="${GT_HOME}/rootfs"
GT_RESOLV="${GT_HOME}/resolv.conf"
GT_VERSIONS="${HOME}/.grok/versions"
GT_DOWNLOADS="${HOME}/.grok/downloads"
GT_OFFICIAL_BIN="${HOME}/.grok/bin/grok"
GT_DNS_PY="${GT_HOME}/grok-dns.py"
GT_PRIMARY="${GROK_TERMUX_PRIMARY:-https://x.ai/cli}"
GT_FALLBACK="${GROK_TERMUX_FALLBACK:-https://storage.googleapis.com/grok-build-public-artifacts/cli}"
GT_CHANNEL="${GROK_CHANNEL:-stable}"
GT_DISTRO="${GROK_TERMUX_DISTRO:-ubuntu}"
GT_SDCARD_DNS="/sdcard/.grokdns"
GT_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

gt_log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
gt_warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
gt_die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }
gt_debug() { [ -n "${GROK_TERMUX_DEBUG:-}" ] && printf '\033[1;34m==>\033[0m %s\n' "$*" >&2 || true; }

# Isolate X.Y.Z from mixed stdout (logs, CRLF, channel-file noise).
gt_parse_version() {
  printf '%s' "$1" | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?' | head -1 || true
}

gt_is_termux() {
  [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/bin" ] || return 1
  [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files ]
}

gt_platform() {
  local arch
  case "$(uname -m)" in
    x86_64|amd64|AMD64) arch=x86_64 ;;
    arm64|aarch64|ARM64) arch=aarch64 ;;
    *) gt_die "unsupported architecture: $(uname -m) (need aarch64 or x86_64)" ;;
  esac
  printf 'linux-%s\n' "$arch"
}

gt_qemu_pkg() {
  case "$(uname -m)" in
    x86_64|amd64|AMD64) printf 'qemu-user-x86-64\n' ;;
    *) printf 'qemu-user-aarch64\n' ;;
  esac
}

gt_qemu_bin() {
  case "$(uname -m)" in
    x86_64|amd64|AMD64) printf 'qemu-x86_64\n' ;;
    *) printf 'qemu-aarch64\n' ;;
  esac
}

gt_have_cmd() { command -v "$1" >/dev/null 2>&1; }

gt_timeout() {
  local sec=$1; shift
  if gt_have_cmd timeout; then
    timeout -s KILL "$sec" "$@"
  else
    "$@"
  fi
}

gt_pkg() {
  gt_have_cmd pkg || gt_die "pkg not found — install Termux from F-Droid / GitHub, not Play Store"
  pkg install -y "$@" </dev/null
}

gt_have_system_resolv() {
  [ -s /etc/resolv.conf ] && grep -q '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null
}

gt_sdcard_writable() {
  mkdir -p /sdcard 2>/dev/null || true
  if : >/sdcard/.grok-termux-write-test 2>/dev/null; then
    rm -f /sdcard/.grok-termux-write-test
    return 0
  fi
  return 1
}

gt_seed_resolv() {
  local dest=$1
  mkdir -p "$(dirname "$dest")"
  if [ ! -s "$dest" ] || ! grep -q '^[[:space:]]*nameserver' "$dest" 2>/dev/null; then
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n' > "$dest"
  fi
}

gt_load_state() {
  GT_BACKEND="${GROK_TERMUX_BACKEND:-}"
  GT_VERSION="${GROK_TERMUX_VERSION:-}"
  if [ -f "$GT_STATE" ]; then
    # shellcheck disable=SC1090
    . "$GT_STATE"
  fi
}

gt_save_state() {
  mkdir -p "$GT_HOME" "$GT_VERSIONS" "$HOME/.grok/bin"
  cat > "$GT_STATE" <<EOF
GT_BACKEND=${GT_BACKEND}
GT_VERSION=${GT_VERSION}
GT_PLATFORM=${GT_PLATFORM}
GT_CHANNEL=${GT_CHANNEL}
EOF
}

gt_dns() {
  local bin=$1 mode=$2
  [ -f "$GT_DNS_PY" ] || return 1
  python3 "$GT_DNS_PY" "$bin" "$mode"
}

gt_existing_paths() {
  local p
  for p in "$@"; do
    [ -e "$p" ] && printf '%s\n' "$p"
  done
}

# --- locate / adopt binaries ------------------------------------------------

gt_find_bin() {
  local verified upd uver c base
  upd="$(readlink -f "$GT_OFFICIAL_BIN" 2>/dev/null || true)"
  base="$(basename "$upd" 2>/dev/null || true)"
  case "$base" in
    grok-[0-9]*-linux-aarch64|grok-[0-9]*-linux-x86_64)
      uver="${base#grok-}"
      uver="${uver%-linux-aarch64}"
      uver="${uver%-linux-x86_64}"
      if [ -f "$upd" ] && printf '%s' "$uver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
        if [ ! -f "${GT_VERSIONS}/${uver}" ] || ! cmp -s "$upd" "${GT_VERSIONS}/${uver}"; then
          cp -f "$upd" "${GT_VERSIONS}/${uver}" && chmod 700 "${GT_VERSIONS}/${uver}"
        fi
        GT_VERSION="$uver"
        printf '%s' "$uver" > "${GT_VERSIONS}/.verified"
      fi
      ;;
    grok-linux-aarch64|grok-linux-x86_64)
      # Official installer / Ctrl+U writes an unversioned filename.
      # Only adopt it when it is newer than the copy we already run, so the
      # first-install downloads/ snapshot does not replace a patched binary.
      verified="$(cat "${GT_VERSIONS}/.verified" 2>/dev/null || true)"
      if [ -f "$upd" ]; then
        if [ -z "$verified" ] || [ ! -f "${GT_VERSIONS}/${verified}" ] || [ "$upd" -nt "${GT_VERSIONS}/${verified}" ]; then
          cp -f "$upd" "${GT_VERSIONS}/latest"
          chmod 700 "${GT_VERSIONS}/latest"
          printf 'latest' > "${GT_VERSIONS}/.verified"
        fi
      fi
      ;;
  esac

  verified="$(cat "${GT_VERSIONS}/.verified" 2>/dev/null || true)"
  if [ -n "$verified" ] && [ -f "${GT_VERSIONS}/${verified}" ]; then
    printf '%s\n' "${GT_VERSIONS}/${verified}"
    return 0
  fi
  c="$(ls -1 "$GT_VERSIONS" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | head -1 || true)"
  if [ -n "$c" ] && [ -f "${GT_VERSIONS}/${c}" ]; then
    printf '%s\n' "${GT_VERSIONS}/${c}"
    return 0
  fi
  return 1
}

# --- exec helpers -----------------------------------------------------------

gt_env_prep() {
  unset LD_PRELOAD
  if gt_have_cmd termux-open-url; then
    export BROWSER="${BROWSER:-termux-open-url}"
  fi
  # Keep grok off FAT/sdcard for its own state; HOME is Termux internal storage.
  export HOME="${HOME}"
}

gt_exec_native() {
  local argv0=$1 bin=$2
  shift 2
  gt_env_prep
  exec -a "$(basename "$argv0")" "$bin" "$@"
}

gt_prepare_rootfs() {
  mkdir -p "${GT_ROOTFS}/tmp" "${GT_ROOTFS}/etc" "${GT_ROOTFS}/proc" "${GT_ROOTFS}/dev" "${GT_ROOTFS}/sys"
  gt_seed_resolv "${GT_ROOTFS}/etc/resolv.conf"
  if [ ! -s "${GT_ROOTFS}/etc/passwd" ]; then
    printf 'root:x:0:0:root:/:/bin/sh\n' > "${GT_ROOTFS}/etc/passwd"
  fi
  if [ ! -s "${GT_ROOTFS}/etc/group" ]; then
    printf 'root:x:0:\n' > "${GT_ROOTFS}/etc/group"
  fi
}

gt_proot_base() {
  local p
  gt_prepare_rootfs
  GT_PROOT_ARGS=(proot --kill-on-exit -r "$GT_ROOTFS" -w "$PWD")
  while IFS= read -r p; do
    GT_PROOT_ARGS+=(-b "$p")
  done < <(gt_existing_paths /dev /proc /sys /data /storage /sdcard /system "$GT_PREFIX" "$HOME" "$PWD")
}

gt_bin_patched_sdcard() {
  grep -a -q '/sdcard/.grokdns' "$1" 2>/dev/null
}

gt_exec_proot_lite() {
  local argv0=$1 bin=$2
  shift 2
  gt_have_cmd proot || gt_die "proot-lite backend selected but proot is not installed — re-run install.sh"
  gt_env_prep
  gt_proot_base
  exec -a "$(basename "$argv0")" "${GT_PROOT_ARGS[@]}" "$bin" "$@"
}

gt_exec_qemu() {
  local argv0=$1 bin=$2 q
  shift 2
  q="$(gt_qemu_bin)"
  gt_have_cmd "$q" || gt_die "qemu backend selected but $q is not installed — re-run install.sh"
  gt_env_prep
  if gt_have_system_resolv || gt_bin_patched_sdcard "$bin"; then
    exec -a "$(basename "$argv0")" "$q" "$bin" "$@"
  fi
  # musl still wants /etc/resolv.conf — wrap qemu in the mini rootfs.
  if gt_have_cmd proot; then
    gt_proot_base
    exec -a "$(basename "$argv0")" "${GT_PROOT_ARGS[@]}" "$q" "$bin" "$@"
  fi
  exec -a "$(basename "$argv0")" "$q" "$bin" "$@"
}

gt_distro_binds() {
  local p
  GT_DISTRO_BINDS=()
  for p in /data /sdcard /storage; do
    [ -e "$p" ] && GT_DISTRO_BINDS+=(--bind "$p")
  done
}

gt_exec_distro() {
  local argv0=$1 bin=$2
  shift 2
  gt_have_cmd proot-distro || gt_die "distro backend selected but proot-distro is missing — re-run install.sh"
  gt_env_prep
  gt_distro_binds
  exec proot-distro login "$GT_DISTRO" "${GT_DISTRO_BINDS[@]}" -- \
    /bin/bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$PWD" "$bin" "$@"
}

gt_probe() {
  local kind=$1 bin=$2
  local tmp rc=1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gt-probe.XXXXXX")"
  gt_env_prep
  case "$kind" in
    native)
      HOME="$tmp" gt_timeout 25 "$bin" --version </dev/null >/dev/null 2>&1 && rc=0
      ;;
    proot-lite)
      gt_proot_base
      HOME="$tmp" gt_timeout 35 "${GT_PROOT_ARGS[@]}" "$bin" --version </dev/null >/dev/null 2>&1 && rc=0
      ;;
    qemu)
      local q; q="$(gt_qemu_bin)"
      HOME="$tmp" gt_timeout 60 "$q" "$bin" --version </dev/null >/dev/null 2>&1 && rc=0
      ;;
    distro)
      gt_distro_binds
      HOME="$tmp" gt_timeout 90 proot-distro login "$GT_DISTRO" "${GT_DISTRO_BINDS[@]}" -- \
        /bin/bash -c 'exec "$1" --version' _ "$bin" </dev/null >/dev/null 2>&1 && rc=0
      ;;
  esac
  rm -rf "$tmp"
  return $rc
}

# --- install-time download / backend pick -----------------------------------

gt_fetch_version() {
  local v raw
  if [ -n "${1:-}" ]; then
    v="$(gt_parse_version "$1")"
    [ -n "$v" ] || gt_die "bad version: $1"
    printf '%s\n' "$v"
    return
  fi
  gt_log "resolving latest ${GT_CHANNEL} version"
  raw="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 20 "${GT_PRIMARY}/${GT_CHANNEL}" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    gt_warn "${GT_PRIMARY} unreachable, trying GCS"
    raw="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 20 "${GT_FALLBACK}/${GT_CHANNEL}" 2>/dev/null || true)"
  fi
  v="$(gt_parse_version "$raw")"
  [ -n "$v" ] || gt_die "could not resolve latest ${GT_CHANNEL} version"
  printf '%s\n' "$v"
}

gt_download_binary() {
  local version platform tmp dest url
  version="$(gt_parse_version "$1")"
  platform=$2
  [ -n "$version" ] || gt_die "refusing to download: version is empty or malformed ($1)"
  [ -n "$platform" ] || gt_die "refusing to download: missing platform"
  dest="${GT_VERSIONS}/${version}"
  tmp="${dest}.tmp.$$"
  mkdir -p "$GT_VERSIONS" "$GT_DOWNLOADS" "$(dirname "$GT_OFFICIAL_BIN")"
  gt_log "downloading grok ${version} (${platform})"
  url="${GT_PRIMARY}/grok-${version}-${platform}"
  if ! curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "$tmp" "$url"; then
    gt_warn "primary download failed, trying GCS"
    url="${GT_FALLBACK}/grok-${version}-${platform}"
    curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "$tmp" "$url" \
      || { rm -f "$tmp"; gt_die "download failed: grok-${version}-${platform}"; }
  fi
  chmod 700 "$tmp"
  mv -f "$tmp" "$dest"
  cp -f "$dest" "${GT_DOWNLOADS}/grok-${platform}"
  chmod 700 "${GT_DOWNLOADS}/grok-${platform}"
  ln -sfn "../downloads/grok-${platform}" "$GT_OFFICIAL_BIN"
  ln -sfn "../downloads/grok-${platform}" "${HOME}/.grok/bin/agent"
  printf '%s\n' "$version" > "${GT_VERSIONS}/.verified"
  # keep latest + previous
  local prev old b
  prev="$(ls -1 "$GT_VERSIONS" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -2 | head -1 || true)"
  for old in "$GT_VERSIONS"/*; do
    [ -f "$old" ] || continue
    b="$(basename "$old")"
    case "$b" in .*) continue ;; esac
    [ "$b" != "$version" ] && [ "$b" != "$prev" ] && rm -f "$old"
  done
  printf '%s\n' "$dest"
}

gt_try_storage() {
  gt_sdcard_writable && return 0
  if gt_have_cmd termux-setup-storage; then
    gt_log "requesting storage permission (needed for the no-proot DNS patch)"
    termux-setup-storage || true
    sleep 1
  fi
  gt_sdcard_writable
}

gt_prepare_dns_native() {
  local bin=$1
  if gt_have_system_resolv; then
    gt_dns "$bin" native || true
    return 0
  fi
  if gt_try_storage; then
    gt_seed_resolv "$GT_SDCARD_DNS"
    if gt_dns "$bin" sdcard; then
      return 0
    fi
    gt_warn "this grok build has no patchable /etc/resolv.conf string"
    return 1
  fi
  gt_warn "no writable /sdcard — native DNS patch unavailable"
  return 1
}

gt_ensure_qemu() {
  local q pkg
  q="$(gt_qemu_bin)"
  gt_have_cmd "$q" && return 0
  pkg="$(gt_qemu_pkg)"
  gt_log "installing ${pkg} (ELF loader fallback)"
  gt_pkg "$pkg"
  gt_have_cmd "$q"
}

gt_ensure_proot() {
  gt_have_cmd proot && return 0
  gt_log "installing proot (lightweight /etc bind)"
  gt_pkg proot
  gt_have_cmd proot
}

gt_ensure_distro() {
  local rootfs="${GT_PREFIX}/var/lib/proot-distro/installed-rootfs/${GT_DISTRO}"
  gt_have_cmd proot-distro || { gt_log "installing proot-distro"; gt_pkg proot-distro; }
  if [ ! -d "$rootfs" ]; then
    gt_log "installing ${GT_DISTRO} via proot-distro (last-resort backend, several hundred MB)"
    proot-distro install "$GT_DISTRO"
  fi
  [ -d "$rootfs" ]
}

gt_pick_backend() {
  local bin=$1 forced="${GROK_TERMUX_BACKEND:-}"
  if [ -n "$forced" ]; then
    gt_log "backend forced: ${forced}"
    case "$forced" in
      native|proot-lite|qemu|distro) GT_BACKEND="$forced" ;;
      *) gt_die "unknown GROK_TERMUX_BACKEND=$forced" ;;
    esac
    # still try to make it actually runnable
    case "$GT_BACKEND" in
      native) gt_prepare_dns_native "$bin" || gt_die "native backend requested but DNS cannot be wired" ;;
      proot-lite) gt_ensure_proot || gt_die "proot-lite requested but proot failed to install" ;;
      qemu) gt_ensure_qemu || gt_die "qemu requested but qemu failed to install" ;;
      distro) gt_ensure_distro || gt_die "distro requested but ${GT_DISTRO} failed to install" ;;
    esac
    if gt_probe "$GT_BACKEND" "$bin"; then
      return 0
    fi
    gt_die "forced backend ${GT_BACKEND} could not exec grok --version"
  fi

  gt_log "probing native exec"
  if gt_probe native "$bin"; then
    if gt_prepare_dns_native "$bin"; then
      GT_BACKEND=native
      gt_log "backend: native (no proot)"
      return 0
    fi
    if gt_ensure_proot && gt_probe proot-lite "$bin"; then
      GT_BACKEND=proot-lite
      gt_log "backend: proot-lite (DNS bind, still the official binary)"
      return 0
    fi
    GT_BACKEND=native
    gt_warn "native exec works but DNS is unpatched — network calls may fail"
    return 0
  fi

  gt_warn "native exec failed (common on 16 KiB-page devices / non-PIE ELF)"

  if gt_ensure_qemu; then
    gt_log "probing qemu-user"
    gt_prepare_dns_native "$bin" || true
    if gt_probe qemu "$bin"; then
      GT_BACKEND=qemu
      gt_log "backend: qemu-user"
      return 0
    fi
  else
    gt_warn "could not install qemu-user"
  fi

  if gt_ensure_distro && gt_probe distro "$bin"; then
    GT_BACKEND=distro
    gt_log "backend: proot-distro ${GT_DISTRO}"
    return 0
  fi

  gt_die "every backend failed. Install Termux from F-Droid, run termux-setup-storage, then re-run install.sh"
}

gt_install_wrappers() {
  local launch="${GT_HOME}/grok-launch"
  [ -f "$launch" ] || gt_die "internal error: launcher missing at $launch"
  chmod 755 "$launch" "${GT_HOME}/grok-dns.py" 2>/dev/null || true
  mkdir -p "${GT_PREFIX}/bin"
  ln -sfn "$launch" "${GT_PREFIX}/bin/grok"
  ln -sfn "$launch" "${GT_PREFIX}/bin/agent"
  ln -sfn "$launch" "${GT_PREFIX}/bin/grok-termux"
  gt_log "linked ${GT_PREFIX}/bin/grok (and agent, grok-termux)"
}

# --- runtime launch / doctor / cli ------------------------------------------

gt_launch() {
  local argv0=$1 bin backend
  shift
  gt_load_state
  bin="$(gt_find_bin)" || gt_die "no grok binary in ${GT_VERSIONS} — run install.sh"
  backend="${GT_BACKEND:-native}"

  # Prefer a live system resolv if one appeared (Magisk module, etc.).
  if [ "$backend" = native ] || [ "$backend" = qemu ]; then
    if gt_have_system_resolv; then
      gt_dns "$bin" native >/dev/null 2>&1 || true
    else
      if gt_sdcard_writable; then
        gt_seed_resolv "$GT_SDCARD_DNS"
        if ! gt_dns "$bin" sdcard >/dev/null 2>&1; then
          # unpatchable build: fall through to proot-lite when available
          if gt_have_cmd proot && [ "$backend" = native ]; then
            backend=proot-lite
          fi
        fi
      elif gt_have_cmd proot && [ "$backend" = native ]; then
        backend=proot-lite
      fi
    fi
  fi

  case "$backend" in
    native)     gt_exec_native "$argv0" "$bin" "$@" ;;
    proot-lite) gt_exec_proot_lite "$argv0" "$bin" "$@" ;;
    qemu)       gt_exec_qemu "$argv0" "$bin" "$@" ;;
    distro)     gt_exec_distro "$argv0" "$bin" "$@" ;;
    *)          gt_die "unknown backend '$backend' — re-run install.sh" ;;
  esac
}

gt_doctor() {
  local bin pagesize abi android
  gt_load_state
  printf 'grok-termux doctor\n'
  printf '  termux:     %s\n' "${TERMUX_VERSION:-unknown}"
  printf '  prefix:     %s\n' "$GT_PREFIX"
  printf '  uname:      %s %s\n' "$(uname -s)" "$(uname -m)"
  pagesize="$(getconf PAGESIZE 2>/dev/null || echo unknown)"
  abi="$(getprop ro.product.cpu.abi 2>/dev/null || echo unknown)"
  android="$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
  printf '  android:    %s\n' "$android"
  printf '  abi:        %s\n' "$abi"
  printf '  pagesize:   %s\n' "$pagesize"
  printf '  backend:    %s\n' "${GT_BACKEND:-unset}"
  printf '  version:    %s\n' "${GT_VERSION:-unset}"
  printf '  channel:    %s\n' "$GT_CHANNEL"
  printf '  /etc/resolv.conf nameserver: %s\n' "$(gt_have_system_resolv && echo yes || echo no)"
  printf '  /sdcard writable:            %s\n' "$(gt_sdcard_writable && echo yes || echo no)"
  printf '  proot:      %s\n' "$(gt_have_cmd proot && echo yes || echo no)"
  printf '  qemu:       %s\n' "$(gt_have_cmd "$(gt_qemu_bin)" && echo yes || echo no)"
  printf '  proot-distro %s: %s\n' "$GT_DISTRO" \
    "$([ -d "${GT_PREFIX}/var/lib/proot-distro/installed-rootfs/${GT_DISTRO}" ] && echo installed || echo no)"
  if bin="$(gt_find_bin)"; then
    printf '  binary:     %s (%s bytes)\n' "$bin" "$(wc -c < "$bin" | tr -d ' ')"
    if grep -a -q '/etc/resolv.conf' "$bin" 2>/dev/null; then
      printf '  dns string: /etc/resolv.conf (unpatched)\n'
    elif grep -a -q '/sdcard/.grokdns' "$bin" 2>/dev/null; then
      printf '  dns string: /sdcard/.grokdns (patched)\n'
    else
      printf '  dns string: not found\n'
    fi
    if gt_probe "${GT_BACKEND:-native}" "$bin"; then
      printf '  smoke test: grok --version OK via %s\n' "${GT_BACKEND:-native}"
    else
      printf '  smoke test: FAILED via %s — re-run install.sh\n' "${GT_BACKEND:-native}"
    fi
  else
    printf '  binary:     MISSING — run install.sh\n'
  fi
  printf '  wrappers:   grok=%s\n' "$(readlink -f "${GT_PREFIX}/bin/grok" 2>/dev/null || echo missing)"
}

gt_cli_usage() {
  cat <<EOF
grok-termux — run xAI Grok Build on Termux, native if possible.

Usage:
  grok-termux                 same as grok (launch the TUI)
  grok-termux doctor          environment + backend diagnostics
  grok-termux backend         print the active backend
  grok-termux update          re-download the latest grok binary and re-probe
  grok-termux reinstall       alias for update
  grok-termux uninstall       remove wrappers (keeps ~/.grok auth)
  grok-termux help

Env:
  GROK_CHANNEL            stable|alpha|enterprise (default stable)
  GROK_TERMUX_BACKEND     force native|proot-lite|qemu|distro
  GROK_TERMUX_DISTRO      proot-distro alias (default ubuntu)
  XAI_API_KEY             skip browser login
EOF
}

gt_dispatch() {
  local argv0=$1
  shift
  case "$(basename "$argv0")" in
    grok-termux)
      case "${1:-}" in
        doctor) gt_doctor; return ;;
        backend) gt_load_state; printf '%s\n' "${GT_BACKEND:-unknown}"; return ;;
        help|-h|--help) gt_cli_usage; return ;;
        uninstall)
          shift
          # shellcheck disable=SC1091
          [ -f "${GT_HOME}/uninstall.sh" ] && exec bash "${GT_HOME}/uninstall.sh" "$@"
          gt_die "uninstall.sh missing"
          ;;
        update|reinstall)
          shift
          exec bash "${GT_HOME}/install.sh" "$@"
          ;;
        "") gt_launch "$argv0" ;;
        *)  gt_launch "$argv0" "$@" ;;
      esac
      ;;
    *)
      gt_launch "$argv0" "$@"
      ;;
  esac
}
