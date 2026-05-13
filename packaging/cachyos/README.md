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

## Quick Install (Recommended)

The fastest path is the one-shot installer that handles dependency order, dry-run preview, and pre-flight checks:

```bash
cd packaging/cachyos

# Preview what would happen
bash install.sh --check

# Real install (will prompt for sudo for each makepkg -si)
bash install.sh
```

The installer:
- Verifies you are on an Arch-based host (CachyOS, Arch, Manjaro, EndeavourOS).
- Checks build dependencies (`base-devel`, Rust, GTK4, etc.) and **auto-installs any that are missing** via `sudo pacman -S --needed --noconfirm`. You are prompted for sudo password once at the start; the rest runs unattended.
- Runs `makepkg -si` for each of the 5 packages in dependency order.
- Reports per-package success/failure and exits non-zero if anything failed.

Pass `--no-deps` to skip the dependency auto-install if you want to manage build deps manually.

If you prefer manual control, follow the **Build Order** / **Install Order** sections below.

## Build Prerequisites

```bash
# Required on the build machine:
sudo pacman -S --needed base-devel rust cargo clang pkg-config gtk4 libadwaita dbus pipewire wayland openssl sqlite
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

The `lifeos-cdi-setup` helper (installed with `lifeos-containers`) checks this for you
and prints the exact command with expected output if the spec is missing:

```bash
lifeos-cdi-setup
```

Verify manually:

```bash
ls /etc/cdi/nvidia.yaml        # file must exist and be non-empty
nvidia-ctk cdi list            # lists detected devices (e.g. nvidia.com/gpu=0)
```

After generating the spec, future NVIDIA driver updates will automatically trigger
a regeneration via the `lifeos-cdi-refresh.path` systemd unit (enabled by the
`lifeos-containers` post-install hook).

## Rootless CDI Verification

After the CDI spec is generated and `life init` has completed, verify that rootless
Podman containers can actually reach the GPU.

### 1. Sanity checks

Check that the container runtime backend and cgroup version are correct
(rootless GPU requires cgroup v2):

```bash
podman info --format '{{.Host.NetworkBackend}}'
# Expected: netavark (or pasta for rootless — either is fine)

podman info --format '{{.Host.CgroupVersion}}'
# Expected: v2
```

CachyOS ships with cgroup v2 by default since kernel 5.19. If you see `v1`, reboot
with `systemd.unified_cgroup_hierarchy=1` kernel parameter or upgrade your kernel.

### 2. GPU device permissions

Rootless CDI requires `/dev/nvidia*` to be readable by the user. Check:

```bash
ls -la /dev/nvidia* /dev/nvidiactl /dev/nvidia-uvm 2>/dev/null
```

Expected mode: `crw-rw-rw-` (0666) or at minimum `crw-rw----` with the user in
the `video` and `render` groups.

If permissions are 0660 and you see "Permission denied" errors in containers:

```bash
# Add yourself to video and render groups (requires re-login to take effect)
sudo usermod -aG video,render "$USER"

# Or set permissive mode on the current session (not persistent):
sudo chmod 0666 /dev/nvidia* /dev/nvidiactl /dev/nvidia-uvm
```

For a persistent fix without changing your groups, add a udev rule:

```bash
sudo tee /etc/udev/rules.d/70-nvidia-cdi.rules <<'EOF'
KERNEL=="nvidia*", MODE="0666"
KERNEL=="nvidiactl", MODE="0666"
KERNEL=="nvidia-uvm", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### 3. Rootless GPU probe

Run the official CUDA probe container rootless with CDI device injection:

```bash
podman run --rm \
  --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.0.0-base-ubi9 \
  nvidia-smi
```

Expected output: the standard `nvidia-smi` table showing your GPU name, driver
version, CUDA version, and memory. Example:

```
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 550.54.14   Driver Version: 550.54.14   CUDA Version: 12.4      |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA GeForce ...  Off  | 00000000:01:00.0  On |                  N/A |
```

If `podman run` fails with `nvidia.com/gpu=all: no such device`:

1. Verify the CDI spec exists: `ls /etc/cdi/nvidia.yaml`
2. Verify devices are listed: `nvidia-ctk cdi list`
3. Regenerate if stale: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
4. Confirm podman reads CDI: `podman run --rm --device nvidia.com/gpu=all --log-level debug ... 2>&1 | grep -i cdi`

If the probe hangs or the container starts but `nvidia-smi` prints no GPUs, check
that `nvidia-persistenced` is not holding an exclusive lock:

```bash
systemctl status nvidia-persistenced
# If active and causing issues: sudo systemctl stop nvidia-persistenced
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
