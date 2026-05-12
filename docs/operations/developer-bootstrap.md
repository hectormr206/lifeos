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

---

## Desarrollo en CachyOS (host nativo, sin bootc)

A partir de Fase 3, el host de referencia del maintainer es **CachyOS**.
El flujo de desarrollo sobre CachyOS difiere en algunos puntos respecto al
workflow de bootc documentado arriba.

### Prerequisitos de Arch que no están en Fedora

```bash
# Herramientas de build base
sudo pacman -S base-devel git rustup

# Inicializar rustup (si no está configurado)
rustup default stable
rustup component add clippy rustfmt

# Podman rootless (sin docker group)
sudo pacman -S podman fuse-overlayfs slirp4netns
```

> En CachyOS **no** existe el grupo `docker`. Podman corre rootless de forma
> nativa — no hay que agregar el usuario a ningún grupo especial.

### Ejecutar tests con podman en Arch

Los tests de integración que prueban Quadlets o contenedores corren igual que
en Fedora, pero algunas sutilezas de Arch requieren atención:

```bash
# Asegurar que el socket de podman user esté activo
systemctl --user start podman.socket

# Correr todos los tests del daemon
cargo test -p lifeosd

# Test individual
cargo test -p lifeosd test_name
```

Si un test falla con `permission denied on /run/user/1000/podman/podman.sock`,
verificá que `podman.socket` esté activo:

```bash
systemctl --user status podman.socket
```

### Compilar con las features exactas de CI

El CI compila con las mismas features en todos los perfiles. En CachyOS hay
que asegurarse de tener las dependencias nativas correspondientes:

```bash
# Dependencias de sistema para todas las features
sudo pacman -S dbus pipewire gtk4 libadwaita openssl sqlite

# Build con el conjunto exacto de features del CI
cargo build --manifest-path daemon/Cargo.toml \
  --features "dbus,http-api,ui-overlay,wake-word,messaging"

# Clippy con el mismo conjunto
cargo clippy --manifest-path daemon/Cargo.toml \
  --features "dbus,http-api,ui-overlay,wake-word,messaging" \
  -- -D warnings
```

### Iterar sobre el daemon sin instalar el paquete

Para desarrollo rápido, corrés `lifeosd` directamente desde el target de cargo:

```bash
# Terminal 1: build + run del daemon en modo debug
RUST_LOG=debug cargo run --manifest-path daemon/Cargo.toml

# Terminal 2: verificar que responde
curl -s http://127.0.0.1:8081/api/v1/health
```

Los Quadlets de contenedores (llama-server, TTS, etc.) pueden estar corriendo
como servicios de usuario normales en paralelo — el daemon en modo dev los
detecta por TCP igual que en producción.

### Variables de entorno útiles para desarrollo

```bash
# Usar directorio de datos local en vez de /var/lib/lifeos
export LIFEOS_DATA_DIR="$HOME/.local/share/lifeos-dev"

# Activar logging detallado por módulo
export RUST_LOG="lifeosd=debug,lifeosd::axi_tools=trace"

# Limpiar estado entre sesiones de prueba
rm -rf "$LIFEOS_DATA_DIR" && mkdir -p "$LIFEOS_DATA_DIR"
```

### Rollback en CachyOS (sin bootc)

No hay `bootc rollback` en el workflow nativo. En su lugar, git y pacman
son el mecanismo de reversión:

```bash
# Revertir a la versión instalada desde el paquete
sudo pacman -U ~/.cache/paru/lifeos-daemon-*.pkg.tar.zst

# O compilar un commit específico y remplazar el binario
git checkout <commit_anterior>
cargo build --release --manifest-path daemon/Cargo.toml
sudo install -m 755 target/release/lifeosd /usr/bin/lifeosd
systemctl --user restart lifeosd.service
```
