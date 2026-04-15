# Developer Workstation Bootstrap

**Version:** 2.0
**Fecha:** 2026-04-15
**Estado:** Activo

---

## Purpose

Dev ergonomics live on the **host**, not in the image. The production image
(`ghcr.io/hectormr206/lifeos:edge`) is identical for end users and developers.
What differs is what the bootstrap script installs on *your laptop*:

- A tightened sudo policy (`/etc/sudoers.d/lifeos-dev-host`) that grants `NOPASSWD`
  for a narrow set of `bootc` and config-management commands.
- A systemd dropin that sets `RUST_LOG=debug` for the `lifeosd` user service.
- Optionally, a sentinel dropin that redirects `lifeos-sentinel.service` to a
  local copy at `/var/lib/lifeos/bin/lifeos-sentinel.sh` so you can iterate on
  sentinel behavior without rebuilding the image.

Nothing dev-specific is baked into the image. Running the bootstrap script twice
is safe — it is fully idempotent.

---

## Prerequisites

- GHCR public access confirmed:
  ```bash
  skopeo inspect --no-creds docker://ghcr.io/hectormr206/lifeos:edge
  ```
  Must exit 0. If non-zero, the public image is not yet available — check CI.
- Repo cloned: `git clone https://github.com/hectormr206/lifeos`.
- `visudo` installed (ships in `sudo` package — already present on LifeOS).
- `bootc` installed (ships in LifeOS image).

---

## Usage

```bash
sudo bash scripts/lifeos-dev-bootstrap.sh [OPTIONS]
```

| Flag | Effect |
|------|--------|
| (none) | Install sudoers policy + `RUST_LOG=debug` dropin |
| `--with-sentinel` | Also install sentinel dropin that redirects to `/var/lib/lifeos/bin/lifeos-sentinel.sh` |
| `--dry-run` | Print planned changes without writing anything |
| `--verbose` | Print each step as it runs |
| `-h` / `--help` | Show usage |

### Typical first run

```bash
# 1. Install bootstrap (with sentinel redirect)
sudo bash scripts/lifeos-dev-bootstrap.sh --with-sentinel

# 2. Verify everything looks correct before rebooting
sudo visudo -c
ls -la /etc/sudoers.d/lifeos-dev-host
ls -la ~/.config/systemd/user/lifeosd.service.d/10-dev-rust-log.conf
```

---

## Migration Sequence

The following 9-step sequence migrates a developer workstation from the old
`localhost/lifeos:dev` image to the current `ghcr.io/hectormr206/lifeos:edge`
workflow. Run each command exactly as shown.

```
1. sudo bash scripts/lifeos-dev-bootstrap.sh --with-sentinel
2. Verify sudoers: sudo visudo -c
   Verify files: ls -la /etc/sudoers.d/lifeos-dev-host ~/.config/systemd/user/lifeosd.service.d/10-dev-rust-log.conf
3. sudo bootc switch --transient ghcr.io/hectormr206/lifeos:edge
4. Reboot (user-initiated; NEVER automated)
5. After boot: bootc status — confirm ghcr.io/hectormr206/lifeos:edge is booted
6. systemctl --user show lifeosd -p Environment — confirm RUST_LOG=debug
7. sudo -l -U lifeos — confirm expected commands
8. Observe 24h
9. If healthy: sudo bootc switch ghcr.io/hectormr206/lifeos:edge (make non-transient)
```

**Step 3 uses `--transient`** so that if anything is wrong after reboot you can run
`sudo bootc rollback` and return to the previous deployment without any permanent change.
Step 9 makes the switch permanent only after 24 h of confirmed healthy operation.

---

## Rollback

If the system misbehaves after a `bootc switch`, run:

```bash
sudo bootc rollback
```

`bootc` keeps at least the last two deployments, so rollback is always available
immediately after switching. The host-side files installed by the bootstrap script
(`/etc/sudoers.d/lifeos-dev-host`, `~/.config/systemd/...`) are **not** touched by
`bootc rollback` — they live in `/etc` and `$HOME`, which bootc does not manage.

To roll back the bootstrap itself, the script backs up any file it modifies:

```bash
ls /etc/sudoers.d/lifeos-dev-host.backup-*
# Restore manually if needed:
sudo mv /etc/sudoers.d/lifeos-dev-host.backup-YYYYMMDD-HHMMSS /etc/sudoers.d/lifeos-dev-host
```

---

## Sentinel Iteration Guide

### When to use `--with-sentinel`

Use `--with-sentinel` when you need to modify `lifeos-sentinel.sh` behavior without
rebuilding the image. The dropin installed at
`/etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf` redirects
`lifeos-sentinel.service` to read the script from `/var/lib/lifeos/bin/lifeos-sentinel.sh`
(host-writable) instead of the image copy at `/usr/local/bin/lifeos-sentinel.sh` (read-only).

### How to iterate

```bash
# 1. Bootstrap with sentinel flag (first time only)
sudo bash scripts/lifeos-dev-bootstrap.sh --with-sentinel

# 2. The host copy is seeded from the image on first run:
ls /var/lib/lifeos/bin/lifeos-sentinel.sh

# 3. Edit the host copy freely
$EDITOR /var/lib/lifeos/bin/lifeos-sentinel.sh

# 4. Restart the service to pick up your changes
sudo systemctl restart lifeos-sentinel.service
journalctl -u lifeos-sentinel.service -f
```

### Reverting to the image copy

Remove the dropin (which re-runs bootstrap without `--with-sentinel`):

```bash
sudo bash scripts/lifeos-dev-bootstrap.sh   # without --with-sentinel
sudo systemctl daemon-reload
sudo systemctl restart lifeos-sentinel.service
```

The script backs up the dropin before removing it, so you can restore it later.

---

## Idempotency Note

The bootstrap script is safe to re-run after any image update or system change.
Running it again when all installed files already match the desired content
produces no filesystem changes and prints an `already up-to-date` line for each file.

```bash
# Safe to run any time — will no-op if nothing changed
sudo bash scripts/lifeos-dev-bootstrap.sh --with-sentinel
```
