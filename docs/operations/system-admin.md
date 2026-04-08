# LifeOS System Administration Guide

This guide is for system administrators managing LifeOS deployments.

## Architecture Overview

### System Components

```
┌─────────────────────────────────────────────────────────────┐
│                        LifeOS System                         │
├─────────────────────────────────────────────────────────────┤
│  User Space                                                  │
│  ├── life CLI           - User interface                     │
│  ├── lifeosd            - Main user-session daemon           │
│  └── llama-server       - AI inference engine (llama.cpp)    │
├─────────────────────────────────────────────────────────────┤
│  Service Ownership                                           │
│  ├── lifeosd.service    - User service (canonical runtime)   │
│  ├── llama-server.service - System service (canonical runtime) │
│  └── lifeos-update-check.service - System update probe       │
├─────────────────────────────────────────────────────────────┤
│  bootc (Image-based Updates)                                 │
│  ├── booted deployment  - Currently running system           │
│  ├── staged deployment  - Update ready to apply              │
│  └── rollback deployment - Previous working version          │
├─────────────────────────────────────────────────────────────┤
│  composefs (Immutable /usr)                                  │
│  ├── /usr               - Read-only system files             │
│  ├── /etc               - Configuration (writable)           │
│  └── /var               - Variable data (writable)           │
└─────────────────────────────────────────────────────────────┘
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

```bash
# Trigger the update probe manually
sudo systemctl start lifeos-update-check.service

# View probe logs
journalctl -u lifeos-update-check.service
```

### llama-server Service

`llama-server` is shipped as a system service by default. Some recovery flows and
host-specific overrides may also run it as a user unit, but that is fallback behavior,
not the primary runtime model.

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

### Custom Update Server

Configure a custom OCI registry:

```toml
[updates]
channel = "custom"
custom_registry = "registry.example.com/lifeos"
```

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
