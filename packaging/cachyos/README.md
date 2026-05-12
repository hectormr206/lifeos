# LifeOS — CachyOS Packaging

This directory contains PKGBUILD files for installing LifeOS natively on CachyOS.

For full documentation including prerequisites, CDI setup, and troubleshooting,
see [docs/operations/runtime-install.md](../../docs/operations/runtime-install.md).

---

## Package Structure

| Package | Contents | arch |
|---------|----------|------|
| `lifeos-cli` | `life` binary | x86_64 |
| `lifeos-daemon` | `lifeosd` binary + user systemd unit | x86_64 |
| `lifeos-desktop` | `lifeos-desktop` binary + user unit + .desktop | x86_64 |
| `lifeos-containers` | Quadlet templates, tmpfiles, sysusers, install helper | any |
| `lifeos-runtime` | Meta-package — depends on all four above | any |

## Build Prerequisites

```bash
# Required on the build machine:
sudo pacman -S --needed rust cargo clang pkg-config gtk4 libadwaita dbus pipewire wayland openssl sqlite
```

## Build Order

Build from innermost dependency outward. Each directory is an independent
`makepkg` invocation:

```bash
cd packaging/cachyos

# 1. CLI
cd lifeos-cli && makepkg -s --noconfirm && cd ..

# 2. Daemon
cd lifeos-daemon && makepkg -s --noconfirm && cd ..

# 3. Desktop companion
cd lifeos-desktop && makepkg -s --noconfirm && cd ..

# 4. Container config (arch-independent, builds quickly)
cd lifeos-containers && makepkg -s --noconfirm && cd ..

# 5. Meta-package (no build, just dependency declaration)
cd lifeos-runtime && makepkg -s --noconfirm && cd ..
```

## Install Order

Install in dependency order. pacman resolves this automatically with
`lifeos-runtime`, but for manual per-package install:

```bash
cd packaging/cachyos

# 1. Containers package first (creates system user + directories)
sudo pacman -U lifeos-containers/lifeos-containers-*.pkg.tar.zst

# 2. CLI, daemon, desktop (order among these doesn't matter)
sudo pacman -U \
  lifeos-cli/lifeos-cli-*.pkg.tar.zst \
  lifeos-daemon/lifeos-daemon-*.pkg.tar.zst \
  lifeos-desktop/lifeos-desktop-*.pkg.tar.zst

# 3. Meta-package (optional — marks the full stack as installed)
sudo pacman -U lifeos-runtime/lifeos-runtime-*.pkg.tar.zst
```

Or install everything at once via the meta-package:

```bash
sudo pacman -U lifeos-runtime/lifeos-runtime-*.pkg.tar.zst
```

pacman will automatically install the dependencies listed in `depends=`.

## NVIDIA CDI Setup (Required Before First Run)

Generate the Container Device Interface spec so rootless Quadlets can access the GPU:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Verify:

```bash
ls /etc/cdi/nvidia.yaml        # file must exist and be non-empty
nvidia-ctk cdi list            # lists detected devices (e.g. nvidia.com/gpu=0)
```

## First Run

```bash
life init
```

Expected output:

```
[step 1/5] distro detection ... OK (cachyos)
[step 2/5] prerequisites    ... OK (podman 5.3.1, nvidia-ctk 1.16.2, CDI spec present)
[step 3/5] filesystem       ... OK (/var/lib/lifeos, /run/lifeos)
[step 4/5] services         ... enabling lifeosd.service ... OK
                                enabling lifeos-llama-server.service ... OK
                                enabling lifeos-llama-embeddings.service ... OK
                                enabling lifeos-tts.service ... OK
                                enabling lifeos-simplex-bridge.service ... OK
[step 5/5] health checks    ... lifeosd :8081 HEALTHY
                                llama-server :8082 HEALTHY
                                embeddings :8083 HEALTHY
                                tts :8084 HEALTHY
                                simplex-bridge active

Dashboard: http://127.0.0.1:8081/dashboard?token=<bootstrap_token>
```

Exit codes: `0` = all healthy, `1` = partial (at least one service unhealthy),
`2` = prerequisite missing (actionable fix printed to stdout).

## Verification Commands

```bash
# Confirm all services running
systemctl --user status lifeosd.service lifeos-llama-server.service

# Dashboard reachable
curl -s http://127.0.0.1:8081/api/v1/health

# Check Quadlet symlinks
ls -la ~/.config/containers/systemd/lifeos-*.container

# Check logs
journalctl --user -u lifeosd.service --since "5 min ago"
```

## Quadlet Symlinks

The `lifeos-containers` package installs Quadlet templates to
`/usr/share/lifeos/quadlets/`. During `life init`, they are symlinked into
`~/.config/containers/systemd/` for the current user.

To do this manually:

```bash
lifeos-quadlet-install --user
systemctl --user daemon-reload
```

To remove symlinks (e.g., before uninstalling):

```bash
lifeos-quadlet-install --uninstall
systemctl --user daemon-reload
```

## Uninstalling

```bash
# Remove Quadlet symlinks first
lifeos-quadlet-install --uninstall && systemctl --user daemon-reload

# Stop and disable services
systemctl --user disable --now lifeosd.service \
  lifeos-llama-server.service lifeos-llama-embeddings.service \
  lifeos-tts.service lifeos-simplex-bridge.service

# Remove packages
sudo pacman -Rns lifeos-runtime lifeos-cli lifeos-daemon lifeos-desktop lifeos-containers

# Remove state (optional — keeps memory.db, models, etc.)
# sudo rm -rf /var/lib/lifeos /run/lifeos
# rm -rf ~/.config/lifeos
```
