# LifeOS System Administration Guide

This guide is for system administrators managing LifeOS deployments.

> **Phase 3 / 7 / 8 of the architecture pivot (2026-Q2)**: lifeosd, the chat
> LLM, embeddings, TTS and the SimpleX bridge now run as **system Quadlet
> containers** under the `lifeos-` prefix instead of bespoke host services.
> The legacy unit names below are kept inside the bootc image as rollback
> targets but are **disabled by default** via `80-lifeos.preset`. New
> operational commands use the `lifeos-` prefixed names.

## Architecture Overview

### System Components

```
LifeOS System Quadlets (post-Phase-3/7/8 — canonical)
│
├── Core
│   └── lifeos-lifeosd.service             system  Axi daemon (HTTP API, memory, agentic chat,
│                                                  SimpleX bridge, whisper-cli for STT)
│
├── AI Runtime
│   ├── lifeos-llama-server.service        system  Local LLM inference (llama.cpp + Vulkan/CDI GPU)
│   ├── lifeos-llama-embeddings.service    system  Vector embeddings (nomic-embed-text)
│   ├── lifeos-tts.service                 system  Kokoro TTS (HTTP wrapper)
│   └── whisper-stt.service                system  Oneshot model bootstrap (downloads ggml-base.bin)
│
├── Communication
│   └── lifeos-simplex-bridge.service      system  SimpleX bot (E2E private messaging)
│
├── Bootstrap
│   ├── lifeos-state-migrate.service       system  Oneshot — migrate legacy
│   │                                              ~/.local/share/lifeos to /var/lib/lifeos
│   ├── lifeos-image-guardian.service      system  Pull missing container images at boot
│   └── lifeos-net.network                 system  Bridge for the side containers (10.89.0.0/24)
│
├── (Legacy host services — installed but DISABLED, kept for `bootc rollback`)
│   ├── lifeosd.service                    user    Pre-Phase-3 — gone
│   ├── llama-server.service / llama-embeddings.service  Pre-Phase-2/4 — gone
│   ├── simplex-chat.service               Pre-Phase-5 — gone
│
├── Maintenance Timers
│   ├── lifeos-maintenance-cleanup.timer   system  Every 12h — podman/Flatpak/Rust cache cleanup
│   ├── lifeos-flatpak-update.timer        system  Daily — unattended Flatpak updates
│   ├── lifeos-btrfs-snapshot.timer        system  Periodic BTRFS snapshots
│   ├── lifeos-aide-check.timer            system  File integrity checks
│   ├── lifeos-update-check.timer          system  Daily bootc update check (read-only probe)
│   ├── lifeos-update-stage.timer          system  Weekly update stage (Sun 04:00 — downloads, no apply)
│   ├── lifeos-smart-charge.timer          system  Battery health management
│   └── fstrim.timer                       system  Weekly SSD TRIM
│
├── Boot Services
│   ├── lifeos-first-boot.service          system  Initial setup (runs once)
│   ├── lifeos-flatpak-nvidia-sync.service system  GPU driver ↔ Flatpak GL sync
│   ├── lifeos-security-baseline.service   system  CIS hardening baseline
│   ├── lifeos-sentinel.service            system  System monitoring
│   ├── lifeos-cosmic-greeter-branding.service system Login screen branding
│   └── lifeos-refresh-bls-titles.service   system  Refresh GRUB titles after bootc upgrade
│
├── Hardware Management
│   ├── lifeos-thermal.service             system  Thermal throttling
│   ├── lifeos-power-profile.service       system  EPP switching
│   ├── lifeos-powertune.service           system  Power optimization
│   ├── lifeos-ecore-pin.service           system  Efficiency core pinning
│   ├── lifeos-battery.service             system  Battery monitoring
│   ├── lifeos-nvidia-signed-modules.service system Nvidia kernel modules
│   └── nvidia-persistenced.service        system  GPU context persistence
│
└── Display Manager
    └── cosmic-greeter.service             system  COSMIC login screen

System image (bootc / composefs)
  ├── booted deployment   — currently running system
  ├── staged deployment   — update ready to apply on next boot
  └── rollback deployment — previous working version

Filesystem ownership
  ├── /usr   — read-only (composefs)
  ├── /etc   — configuration (writable, persisted)
  └── /var   — variable data, logs, caches (writable, persisted)
```

### File System Layout

| Path    | Purpose                       | Persistence           |
| ------- | ----------------------------- | --------------------- |
| `/usr`  | System binaries and libraries | Immutable (composefs) |
| `/etc`  | Configuration files           | Persistent            |
| `/var`  | Variable data, logs, caches   | Persistent            |
| `/home` | User home directories         | Persistent            |
| `/boot` | Bootloader and kernel         | Managed by bootc      |
| `/root` | Root user home                | Persistent            |

## Service Management

Canonical runtime reference: `docs/architecture/service-runtime.md`.

### lifeosd (LifeOS Daemon)

The daemon provides:

- Health monitoring
- Update checking
- Metrics collection
- Desktop notifications
- D-Bus interface

`lifeosd` is operated canonically as a per-user service so it can inherit the desktop session
(Wayland, D-Bus, PipeWire, user secrets) without requiring a root-owned foreground session.

```bash
# Start/stop/restart
systemctl --user start lifeosd
systemctl --user stop lifeosd
systemctl --user restart lifeosd

# Enable/disable at login
systemctl --user enable lifeosd
systemctl --user disable lifeosd

# View status
systemctl --user status lifeosd

# View logs
journalctl --user -u lifeosd -f
```

Legacy/debug only when a host still exposes the system-scope alias:

```bash
sudo systemctl status lifeosd
```

### Update Check Service

LifeOS uses a **cache-first** update check flow to avoid running `bootc` from the unprivileged user daemon:

1. `lifeos-update-check.service` (system-scope, oneshot, root) runs on a timer and invokes `/usr/local/bin/lifeos-update-check.sh`.
2. The script shells out to `bootc status` + `bootc upgrade --check`, assembles a JSON payload with `jq`, and writes it **atomically** (temp file + rename) to `/var/lib/lifeos/update-state.json`.
3. The user daemon (`lifeosd`) reads that file on demand — it never shells out to `bootc` itself. This keeps the daemon unprivileged and deterministic.
4. Entries older than **48 hours** are treated as stale and surfaced as such in the API / dashboard.
5. If a probe fails (no network, GHCR down), the previous cache is **preserved** rather than wiped, so the UI keeps showing the last known good state instead of "unknown".

```bash
# Trigger the update probe manually
sudo systemctl start lifeos-update-check.service

# Inspect the cached payload the daemon reads
cat /var/lib/lifeos/update-state.json

# View probe logs
journalctl -u lifeos-update-check.service
```

### Update Stage Service and Timer

`lifeos-update-stage.service` downloads and stages a new image deployment without
applying it. The user controls when the staged deployment activates (reboot).

**Schedule:** `lifeos-update-stage.timer` runs every Sunday at 04:00 UTC with a
30-minute randomized delay (`RandomizedDelaySec=1800`) so all hosts do not hit GHCR
simultaneously. The timer is persistent — if the host was offline at 04:00, the stage
runs once on next boot.

**What it does:**
1. Reads `/var/lib/lifeos/update-state.json`. If `available=false`, exits without action.
2. If the current staged digest already matches the remote digest: exits 0 (`already staged, no-op`).
3. Runs `bootc upgrade` (no `--apply`) — downloads and stages the new deployment.
4. Writes result to `/var/lib/lifeos/update-stage-state.json`.
5. Emits a desktop notification and a POST to the Axi daemon API.

**What it does NOT do:**
- Does NOT run `bootc upgrade --apply`.
- Does NOT trigger a reboot under any circumstances.
- Does NOT use `set -x` (no credential leakage in journal).

**Service properties:** `Type=oneshot`, `User=root`, `TimeoutStartSec=30m`,
`ProtectHome=read-only`, `ProtectSystem=strict`, `ReadWritePaths=/var/lib/lifeos`.

```bash
# Trigger staging manually (e.g. after check reports update available)
sudo systemctl start lifeos-update-stage.service

# Inspect the stage state file
cat /var/lib/lifeos/update-stage-state.json

# View stage logs
journalctl -u lifeos-update-stage.service

# Check timer status
systemctl list-timers lifeos-update-stage.timer
```

To override the cadence (e.g. stage daily instead of weekly):

```bash
sudo mkdir -p /etc/systemd/system/lifeos-update-stage.timer.d/
sudo tee /etc/systemd/system/lifeos-update-stage.timer.d/10-cadence.conf > /dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1800
EOF
sudo systemctl daemon-reload
```

See [`docs/operations/update-flow.md`](update-flow.md) for the full check → stage → apply cycle.

### llama-server Service

`llama-server` is operated canonically as a system service. Some recovery flows and
host-specific overrides may also run it as a user unit, but that is fallback behavior,
not the primary runtime model.

**Pinned versions** (image build, see [`image/Containerfile`](../../image/Containerfile)):

| Component | Pinned tag | Notes |
|---|---|---|
| Base distro | `Fedora 44` (`FEDORA_MAJOR=44`) | bumped from Fedora 43 — kernel + glibc + every RPM rebuilt |
| llama.cpp | `b8999` (2026-05) | b8925 → b8999: ~74 commits, Vulkan opts + llama-server security patches |
| simplex-chat | `v6.5.0` (2026-04) | bumped from v6.4.11; minor release line |
| whisper.cpp | `v1.8.4` (2026-03) | Reproducible build (was unpinned HEAD) |
| Bun runtime | `1.3.13` (2026-04) | Used by Claude Code Channels plugins |
| Kokoro TTS | `kokoro==0.9.4` + `numpy==1.26.4` | numpy stays on 1.x for torch 2.4.1 ABI |

When bumping these in `image/Containerfile`, also update this table and the canonical upgrade checklist.

### Quadlet flip status

Per `docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md`. Each row reflects whether the service runs as a podman Quadlet (image pulled from GHCR) or as a host systemd service.

| Service | Mode | Generated unit |
|---|---|---|
| Kokoro TTS | Quadlet | `lifeos-tts.service` (Phase 1) |
| nomic embeddings | Quadlet | `lifeos-llama-embeddings.service` (Phase 2) |
| SimpleX bot | Quadlet | `lifeos-simplex-bridge.service` (Phase 5) |
| llama-server (chat) | host | `llama-server.service` (Phase 4 BLOCKED on nvidia-container-toolkit) |
| lifeosd (daemon) | host | `lifeosd.service` (Phase 3 deferred — UID/UserNS work) |

Legacy host service files for the flipped services (Kokoro, embeddings, SimpleX) stay installed in `/usr/lib/systemd/system/` as manual rollback targets but are no longer wired into `multi-user.target.wants/`.

### Memory plane SQLite tuning

Every connection opened by `MemoryPlaneManager::open_db` enables WAL +
synchronous=NORMAL + busy_timeout=5000 + cache_size=64 MiB +
mmap_size=256 MiB + temp_store=MEMORY. WAL gives 3–10× write throughput
and lets readers proceed during writes; the small power-loss durability
window is acceptable for a personal assistant. To verify on a running
host:

```bash
sqlite3 ~/.local/share/lifeos/memory.db 'PRAGMA journal_mode; PRAGMA synchronous;'
# expect: wal / 1
```

`conversation_history.json` is now persisted with a tempfile + fsync +
rename + parent-dir fsync sequence, with mode 0600 on the resulting
file. Crash mid-write no longer corrupts the file, and the file is no
longer world-readable across the rename.

```bash
# Manage default system service
sudo systemctl start llama-server
sudo systemctl stop llama-server
sudo systemctl restart llama-server

# View llama-server logs
journalctl -u llama-server -f

# Fallback only if this host does not ship the system unit
systemctl --user status llama-server
```

## Configuration Reference

### Daemon Configuration

File: `/etc/lifeos/daemon.toml`

```toml
# Health check interval (seconds)
health_check_interval_secs = 300

# Update check interval (seconds)
update_check_interval_secs = 3600

# Metrics collection interval (seconds)
metrics_collection_interval_secs = 60

# Enable desktop notifications
enable_notifications = true

# Enable automatic update staging
enable_auto_updates = true
```

### User Configuration

File: `~/.config/lifeos/lifeos.toml` or `/etc/lifeos/lifeos.toml`

```toml
version = "1"

[system]
hostname = "lifeos"
timezone = "America/New_York"
locale = "en_US.UTF-8"
keyboard = "us"

[ai]
enabled = true
provider = "llama-server"
model = "Qwen3.5-4B-Q4_K_M.gguf"
host = "127.0.0.1"
port = 8082

[security]
encryption = true
secure_boot = true
auto_lock = true
auto_lock_timeout = 300

[updates]
channel = "stable"
auto_check = true
auto_apply = false
schedule = "daily"
```

### GSettings Schema

Schema: `io.lifeos.desktop`

```bash
# View all settings
gsettings list-recursively io.lifeos.desktop

# Key settings
gsettings set io.lifeos.desktop theme-variant simple|pro
gsettings set io.lifeos.desktop first-boot-complete true|false
gsettings set io.lifeos.desktop show-welcome-on-login true|false
gsettings set io.lifeos.desktop dock-position left|right|bottom
gsettings set io.lifeos.desktop ai-assistant-enabled true|false
```

## Update Management

### Understanding bootc

LifeOS uses bootc for atomic, image-based updates:

```bash
# View current status
bootc status

# Check for updates
bootc upgrade --check

# Stage an update for next boot
bootc upgrade

# Rollback to previous version
bootc rollback

# Switch to different image/channel explicitly
bootc switch ghcr.io/hectormr206/lifeos:candidate
```

### Update Channels

| Channel   | Purpose             | Stability |
| --------- | ------------------- | --------- |
| `stable`    | Production use         | High      |
| `candidate` | Pre-release validation | Medium    |
| `edge`      | Latest development     | Low       |

Canonical rule:

- `bootc status` tells you what deployment is actually booted/staged.
- GHCR digest is the release artifact that matters operationally.
- `lifeos.toml` and `channels.toml` are policy/preferences only.

### Custom Update Server

LifeOS currently documents `stable`, `candidate`, and `edge` as the supported
channels for the signed GHCR release flow. A custom OCI registry path is not
part of the canonical shipped model today.

## Health Monitoring

### Health Checks

The daemon performs these checks:

1. **bootc status** - Verify bootc is operational
2. **Disk space** - Ensure sufficient free space
3. **Memory usage** - Check for memory pressure
4. **Network** - Verify internet connectivity
5. **Services** - Confirm critical services running

### Alert Thresholds

| Check        | Warning  | Critical |
| ------------ | -------- | -------- |
| Disk usage   | > 80%    | > 90%    |
| Memory usage | > 85%    | > 95%    |
| Load average | > CPUs×2 | > CPUs×4 |

### Manual Health Check

```bash
# User-session daemon health
life doctor
life check

# System image state
sudo bootc status
```

## Security

### Immutable System

LifeOS uses composefs for `/usr` immutability:

```bash
# Verify composefs is active
mount | grep composefs

# The /usr directory is read-only
touch /usr/test  # Will fail
```

### Service Hardening

The canonical `lifeosd` user unit includes:

- `NoNewPrivileges=true`
- `PrivateTmp=yes`
- `Restart=on-failure`
- `WatchdogSec=300`
- `Environment=LIFEOS_RUNTIME_DIR=%t/lifeos`

### SELinux

LifeOS supports SELinux in enforcing mode:

```bash
# Check SELinux status
getenforce

# View LifeOS-specific contexts
ls -Z /usr/bin/life
ls -Z /usr/bin/lifeosd
```

## Backup and Recovery

### System Capsules

LifeOS capsules are system snapshots:

```bash
# Create capsule
life capsule create pre-upgrade

# List capsules
life capsule list

# Export capsule
life capsule export pre-upgrade /backup/lifeos-pre-upgrade.tar.gz

# Restore from capsule
life capsule restore pre-upgrade
```

### bootc Backup

```bash
# The bootc system automatically maintains:
# - Current (booted) deployment
# - Previous (rollback) deployment

# View deployments
ostree admin status
```

### Recovery Mode

If the system won't boot:

1. Boot from LifeOS installation media
2. Select "Rescue Mode"
3. The system will attempt automatic repair
4. Or use manual recovery:

```bash
# In rescue shell
life recover
bootc rollback  # If needed
```

## Monitoring and Logging

### Centralized Logging

```bash
# View all LifeOS logs
journalctl -t lifeos

# View daemon logs
journalctl --user -u lifeosd

# View bootc logs
journalctl -t bootc

# Follow logs in real-time
journalctl -f
```

### Metrics

The daemon collects metrics:

```bash
# View current metrics (if exposed)
curl http://localhost:8082/metrics

# Or check logs
journalctl --user -u lifeosd | grep "metrics"
```

### Prometheus Integration

To export metrics to Prometheus:

```toml
[metrics]
enabled = true
listen_address = "0.0.0.0:9090"
path = "/metrics"
```

## Deployment

### Initial Deployment

1. Install LifeOS on target hardware
2. Boot system
3. First-boot wizard runs automatically
4. Configure additional settings as needed

### Mass Deployment

For deploying to multiple machines:

```bash
# Create custom image with pre-configured settings
# See: Containerfile.example

# Deploy via kickstart/preseed
# See: docs/DEPLOYMENT.md
```

### Enterprise Deployment

```bash
# Use configuration management
ansible-playbook -i inventory site.yml

# Or with cloud-init
# Include in cloud-init user-data
```

## Troubleshooting

### System Won't Boot

1. Check boot loader
2. Try previous deployment in GRUB
3. Use rescue mode from installation media
4. Run `life recover`

### Daemon Won't Start

```bash
# Check for errors
journalctl --user -u lifeosd -n 50

# Verify configuration
toml-test /etc/lifeos/daemon.toml

# Reset to defaults
sudo rm /etc/lifeos/daemon.toml
systemctl --user restart lifeosd
```

### Update Failures

```bash
# Check bootc status
bootc status --json

# View staged deployment
ostree admin status

# Manual cleanup if needed
bootc cleanup
```

### AI Service Issues

```bash
# Check llama-server status
sudo systemctl status llama-server

# View AI service logs
journalctl -u llama-server -n 50

# Fallback only if the host runs a user-scoped override instead
systemctl --user status llama-server

# Test inference
curl http://127.0.0.1:8082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"default","messages":[{"role":"user","content":"Hello"}]}'

# Check health
curl http://127.0.0.1:8082/health
```

## API Reference

### D-Bus Interface

The daemon exposes a D-Bus interface:

```bash
# List available methods
dbus-send --system --print-reply \
  --dest=io.lifeos.Daemon \
  /io/lifeos/Daemon \
  org.freedesktop.DBus.Introspectable.Introspect
```

### HTTP API (if enabled)

| Endpoint        | Method | Description          |
| --------------- | ------ | -------------------- |
| `/health`       | GET    | Health check         |
| `/status`       | GET    | System status        |
| `/metrics`      | GET    | Prometheus metrics   |
| `/update/check` | POST   | Trigger update check |

## Maintenance Tasks

### Daily

- Review logs for errors
- Check system status

### Weekly

- Apply updates if available
- Review health check reports
- Clean up old capsules

### Monthly

- Audit user accounts
- Review security logs
- Test rollback procedure
- Update documentation

## Resources

- **Man pages**: `man life`, `man lifeosd`, `man bootc`
- **Documentation index**: `docs/README.md`
- **Operations docs**: `docs/operations/`
- **GitHub**: https://github.com/hectormr/lifeos

---

_LifeOS System Administration Guide v0.1.0_

## Llama-server context size (PR #48)

Default `LIFEOS_AI_CTX_SIZE` is now **131072** (128K) — verified to fit
Qwen3.5-9B Q4_K_M with q8_0 KV cache in 12 GB VRAM with ~3 GB margin.

The user can override via:
- Dashboard → LLM Configuration panel
- API: `POST /api/v1/llm/ctx-size {"value": <int>}`
- Direct file: `/var/lib/lifeos/llama-server-user-override.env`

The override survives benchmarker regeneration. Validation: 1024 ≤ value ≤ 524288.
Restart of `llama-server.service` is automatic on change.

### Benchmarker ctx-size probe

On machines with a dedicated GPU, `lifeosd` actively probes a descending
ladder of ctx-sizes during the first-boot benchmark and pins the LARGEST
value that successfully boots `llama-server` with GPU layers > 0:

```
[131072, 65536, 32768, 16384, 8192]
```

The first rung tried is always `LIFEOS_AI_CTX_SIZE` from
`/etc/lifeos/llama-server.env` (or the user override). If that fails,
the benchmarker steps DOWN until one rung boots, and writes the chosen
value to `/var/lib/lifeos/llama-server-runtime-profile.env`.

CPU-only machines stay on the heuristic ceiling (16K / 12K / 8K based on
total RAM) — there is no probe step because each rung costs a full
llama-server restart and CPU-only boxes are RAM-fragile. To force a
larger ctx on a CPU-only machine, use the user override.
