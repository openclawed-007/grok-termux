# grok-termux

Run [xAI Grok Build](https://github.com/xai-org/grok-build) on Termux.

Official `grok` is a static musl Linux binary. xAI does not support Android. On stock Termux the installer usually dies with `downloaded grok failed to run`, and even when the ELF loads, musl reads `/etc/resolv.conf` which Termux cannot provide.

This wrapper downloads the **official** `linux-aarch64` / `linux-x86_64` binary and keeps trying until something actually execs:

| Order | Backend | What it fixes | Extra packages |
|------|---------|----------------|----------------|
| 1 | **native** | DNS, via a 16-byte in-place patch `/etc/resolv.conf` → `/sdcard/.grokdns` | python |
| 2 | **proot-lite** | DNS without patching (bind-mounts a tiny rootfs). Still the official binary. | `proot` |
| 3 | **qemu** | Kernel will not load the ELF (non-PIE, 16 KiB page size, exec format error) | `qemu-user-aarch64` |
| 4 | **distro** | Last resort: official binary inside Ubuntu via `proot-distro` | `proot-distro` + Ubuntu |

No root required. Native is preferred. Proot is only used when native cannot work.

Unofficial. Not affiliated with xAI. The `grok` binary is theirs; this repo is the Termux glue.

## Install

Termux from **F-Droid or GitHub Releases** (not Play Store). aarch64 or x86_64.

```bash
curl -fsSL https://raw.githubusercontent.com/openclawed-007/grok-termux/main/install.sh | bash
```

Or clone:

```bash
git clone https://github.com/openclawed-007/grok-termux.git
cd grok-termux
bash install.sh
```

Then:

```bash
grok
```

Auth: `export XAI_API_KEY=xai-...`, or sign in from the TUI. If the browser handoff fails:

```bash
grok login --device-auth
```

Pin a version: `bash install.sh 1.0.5`

## Commands

| Command | Purpose |
|---------|---------|
| `grok` / `agent` | Grok Build (routed through the working backend) |
| `grok-termux doctor` | Android / page-size / DNS / smoke-test dump |
| `grok-termux backend` | print `native`, `proot-lite`, `qemu`, or `distro` |
| `grok-termux update` | re-download latest stable and re-probe |
| `grok-termux uninstall` | remove wrappers; `uninstall.sh --purge` also drops `~/.grok` |

Self-updates from inside grok (`Ctrl+U`) are adopted on the next launch; the DNS patch is re-applied if the new file restored the original string.

## Environment

| Variable | Effect |
|----------|--------|
| `GROK_CHANNEL` | `stable` (default), `alpha`, `enterprise` |
| `GROK_TERMUX_BACKEND` | force `native` / `proot-lite` / `qemu` / `distro` |
| `GROK_TERMUX_DISTRO` | proot-distro alias, default `ubuntu` |
| `XAI_API_KEY` | skip browser login |
| `GROK_TERMUX_DEBUG` | verbose logs |

## Why the official installer fails

`https://x.ai/cli/install.sh` treats Termux as Linux, downloads `grok-*-linux-aarch64`, then smoke-tests `--version`. That test fails when:

1. Android refuses a non-PIE or 4 KiB-aligned ELF (16 KiB-page phones).
2. Termux `LD_PRELOAD` (`termux-exec`) interferes — this launcher always unsets it.
3. musl then cannot resolve DNS because `/etc` is `/system/etc` and read-only.

Native success path: ELF loads + we overwrite the one hardcoded 16-byte path with `/sdcard/.grokdns` (run `termux-setup-storage` so that file is writable). If storage is denied, backend 2 bind-mounts a fake `/etc/resolv.conf` instead.

## Uninstall

```bash
bash ~/.grok/termux/uninstall.sh
# or
curl -fsSL https://raw.githubusercontent.com/openclawed-007/grok-termux/main/uninstall.sh | bash
```

## License

MIT for the wrapper scripts. Grok Build itself is licensed by xAI.
