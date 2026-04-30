# Quadlet dev workflow — iterar containers sin tocar la imagen bootc

This is the operational manual for the dual-registry workflow defined in
[`docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md` §5c](../strategy/prd-architecture-pivot-lean-bootc-quadlet.md). Read that PRD first if you haven't — this doc assumes you already understand *why* the architecture is split into bootc image (rare changes) + Quadlet containers (frequent changes).

> **Status:** Phase 0 of the architecture pivot. Infrastructure is in place; first Quadlet (TTS) ships in Phase 1.

## TL;DR cheatsheet

```
┌──────────────────────────────────────────────────────────────────┐
│  EDIT (dev machine)                                              │
│    cd ~/dev/gama/lifeos/lifeos                                   │
│    edit containers/<service>/...                                 │
│    podman build -t 10.66.66.1:5001/lifeos-<svc>:dev -f ...       │
│    podman push --tls-verify=false 10.66.66.1:5001/lifeos-<svc>:dev│
│                            │ via WG (privado)                    │
│                            ▼                                     │
│  TEST IN VIVO (laptop)                                           │
│    ssh laptop "podman pull --tls-verify=false                    │
│                10.66.66.1:5001/lifeos-<svc>:dev"                 │
│    ssh laptop "sudo systemctl restart lifeos-<svc>.service"      │
│    journalctl -fu lifeos-<svc>.service                           │
│                            │  funciona?                          │
│                            ▼ SÍ                                  │
│  PROMOTE (a release público)                                     │
│    podman tag 10.66.66.1:5001/lifeos-<svc>:dev \                 │
│               ghcr.io/hectormr206/lifeos-<svc>:stable            │
│    podman push ghcr.io/hectormr206/lifeos-<svc>:stable           │
│                            │                                     │
│                            ▼                                     │
│  NEXT BOOTC IMAGE                                                │
│    release-channels.yml referencia :stable en los Quadlets       │
│    el próximo build incluye la nueva versión validada            │
└──────────────────────────────────────────────────────────────────┘
```

## Los dos registros y para qué sirven

| Registro | URL | Propósito | Quién accede | Vida útil de tags |
|----------|-----|-----------|--------------|-------------------|
| **Dev** | `10.66.66.1:5001` | Iteración rápida; tags `:dev`, `:branch-*`, `:sha-abc` | Solo tú via WireGuard (privado) | 72h (auto-prune) |
| **Producción** | `ghcr.io/hectormr206/lifeos-*` | Releases; tags `:stable`, `:vN.N.N` | Público (open source) | Indefinida; manual retention |

Tags que **NUNCA** se borran automáticamente del registro dev: `stable`, `edge`, `latest`, `vN.N.N`. Cualquier otro tag con más de 72h de antigüedad es candidato a prune diario.

## Arrancar de cero

### Una sola vez, en el VPS

Si todavía no se corrió `vps-registry-setup.sh` o si querés re-aplicar la config (idempotente):

```bash
# desde tu dev machine (chains via laptop como bastion):
cat scripts/vps-registry-setup.sh | \
    ssh laptop 'ssh -i ~/.ssh/id_vps_claude hectormr@10.66.66.1 "bash -s"'
```

Asegura `REGISTRY_STORAGE_DELETE_ENABLED=true` en el container `lifeos-registry`. Sin esto, los DELETE manifest del prune diario no surten efecto y la storage del registro crece sin tope.

### Una sola vez, instalar el GC diario en VPS

```bash
# Asume que ya copiaste scripts/vps-registry-gc.{sh,service,timer} a la VPS
# (ver instalación inicial en la sesión 2026-04-30 — typically via scp + sudo cp).
ssh laptop 'ssh -i ~/.ssh/id_vps_claude hectormr@10.66.66.1 \
  "sudo -n systemctl enable --now lifeos-registry-gc.timer"'
```

Estado del timer:

```bash
ssh laptop 'ssh -i ~/.ssh/id_vps_claude hectormr@10.66.66.1 \
  "systemctl list-timers lifeos-registry-gc.timer --no-pager"'
```

GC manual (útil para liberar espacio antes de un build pesado):

```bash
ssh laptop 'ssh -i ~/.ssh/id_vps_claude hectormr@10.66.66.1 \
  "sudo -n systemctl start lifeos-registry-gc.service"'
ssh laptop 'ssh -i ~/.ssh/id_vps_claude hectormr@10.66.66.1 \
  "sudo -n journalctl -u lifeos-registry-gc.service -n 30 --no-pager"'
```

## Nombrado de containers — convención mandatory

Todos los containers del **sistema** LifeOS usan prefijo `lifeos-`:

- `lifeos-lifeosd`
- `lifeos-llama-server`
- `lifeos-llama-embeddings`
- `lifeos-tts`
- `lifeos-simplex-bridge`

Esto NO es estética — habilita las protecciones de Capa 2 (sudoers denylist) y Capa 5 (`run_command` blocklist) por pattern. Sin el prefijo, las defensas no aplican.

Containers de **experimentación / user / AI** NO usan ese prefijo y van rootless en `~/.config/containers/systemd/`.

## El ciclo completo, paso a paso, con un ejemplo real

Asumamos que estás iterando sobre `lifeos-tts` (Kokoro TTS).

### 1. Edit + build local

```bash
cd ~/dev/gama/lifeos/lifeos
edit containers/lifeos-tts/Containerfile
edit containers/lifeos-tts/entrypoint.sh

podman build \
  -t 10.66.66.1:5001/lifeos-tts:dev \
  -f containers/lifeos-tts/Containerfile \
  containers/lifeos-tts/
```

### 2. Push al registro dev (vía WireGuard, privado)

```bash
podman push --tls-verify=false 10.66.66.1:5001/lifeos-tts:dev
```

`--tls-verify=false` porque el registro dev no usa TLS (vive sobre WG, red privada). NUNCA exponer este registro a internet sin TLS + auth.

### 3. Pull + restart en laptop

```bash
ssh laptop "
  podman pull --tls-verify=false 10.66.66.1:5001/lifeos-tts:dev
  podman tag 10.66.66.1:5001/lifeos-tts:dev localhost/lifeos-tts:current

  # Quadlet apunta a localhost/lifeos-tts:current — solo cambiamos el digest,
  # no el tag, para evitar el bug 'Image specification is unchanged' que vimos
  # en bootc switch (ver feedback_bootc_root_storage.md).

  sudo systemctl restart lifeos-tts.service
  journalctl -fu lifeos-tts.service
"
```

### 4. Validar (golden path + smoke)

Tests específicos del servicio. Para `lifeos-tts`:

```bash
ssh laptop "curl -s http://127.0.0.1:8084/health | jq ."
ssh laptop "curl -s http://127.0.0.1:8084/voices | jq '.voices | length'"
```

Verificar que el container responde como antes del cambio. Si NO responde, podés ver logs detallados, hacer otra iteración, etc — todo SIN tocar la imagen bootc.

### 5. Cuando ya funciona, promote a producción

```bash
# Re-tag la imagen dev a la public stable
podman tag 10.66.66.1:5001/lifeos-tts:dev ghcr.io/hectormr206/lifeos-tts:stable

# Login a GHCR si no estás (usa un Personal Access Token con write:packages)
podman login ghcr.io

# Push
podman push ghcr.io/hectormr206/lifeos-tts:stable
```

### 6. Próximo bootc release

`release-channels.yml` ya tiene los Quadlet `.container` files apuntando a `:stable`. Cuando se mergee algo a `main` que dispare el workflow, el nuevo bootc image incluye automáticamente los Quadlets que apuntan al `:stable` recién promocionado.

## Si rompió algo, rollback en 10 segundos

```bash
ssh laptop "
  sudo systemctl stop lifeos-tts.service
  podman tag ghcr.io/hectormr206/lifeos-tts:stable localhost/lifeos-tts:current
  sudo systemctl start lifeos-tts.service
"
```

Esto revierte al `:stable` previo. NO rebooteás. NO tocás la imagen bootc. NO esperas un build de 30 minutos.

## Por qué un Quadlet no se cae aunque vos hagas algo torpe

Configuración Quadlet estándar (Capa 3 del defense-in-depth):

```ini
[Service]
Restart=always
RestartSec=5s
WatchdogSec=60s
```

Si vos accidentalmente matás el container con `podman kill -9` o el proceso adentro crashea por cualquier razón, systemd lo restablece en 5 segundos. El estado persiste en bind mounts a `/var/lib/lifeos/`, así que el container nuevo monta exactamente la misma DB, los mismos modelos, los mismos configs.

Ver `lifeos-image-guardian.service` (Capa 4) para la pieza que también re-baja la imagen del registro si alguien la borra de containers-storage local.

## Defensas activas — qué NO podés hacer (por diseño)

Capas implementadas en commit `67eb003` (PR #68, mergeado 2026-04-30):

- **Capa 5** — `run_command` desde Axi rechaza patterns destructivos en `daemon/src/axi_tools.rs::validate_command_safety`. Si el modelo propone `podman rm lifeos-tts`, el tool retorna error sin ejecutar.
- **Capa 2** — `/etc/sudoers.d/lifeos-axi` deniega `sudo podman rm/rmi/system prune`, `sudo systemctl stop lifeos-*`, y `sudo rm -rf /var/lib/lifeos*` incluso con tu password.
- **Capa 6** — `auditd` registra cualquier write a `/etc/containers/systemd/`, `/var/lib/containers/storage/`, `/etc/sudoers.d/`, `/var/lib/lifeos/`. Forensics post-incidente con `sudo ausearch -k lifeos_quadlet_changed`.

La única forma de bajar un container del sistema es vos, manualmente, desde una shell de root real (no via sudo desde la cuenta `lifeos`). Esto es por diseño — vos sos el operador, las protecciones son contra accidentes y AI-misuse.

## Troubleshooting

### "Image specification is unchanged" cuando hago `bootc switch`

El tag local matchea pero el digest no. Bug conocido. Workaround: el script `~/bin/vps-deploy-to-laptop.sh` usa `podman save` + `sudo podman load` para forzar que el ROOT containers-storage tenga la nueva imagen (porque bootc lee root, no user storage). Ver `feedback_bootc_root_storage.md`.

### El registro dev se llenó de tags viejos

Si por algún motivo el GC diario no se está ejecutando, hacelo manual:

```bash
ssh laptop 'ssh -i ~/.ssh/id_vps_claude hectormr@10.66.66.1 \
  "sudo -n systemctl start lifeos-registry-gc.service"'
```

Para protección extra: `TTL_HOURS=24` baja el TTL a un día.

### Mi container no arranca tras cambio de tag

Verificá que `podman tag` se ejecutó en la **root** containers-storage del laptop, no en la del usuario `lifeos` rootless. Si dudás, `sudo podman images localhost/lifeos-*` debe mostrar el digest nuevo.

## Próximos pasos pendientes

- **Capa 4** (image guardian) — pendiente para Fase 1 cuando exista el primer Quadlet `lifeos-*`.
- **Cosign signing** de cada container individual — extender `project_pending_image_signing_cosign`.
- **Migración a red podman privada `lifeos-net`** — Fase 6 del PRD, para reemplazar `Network=host`.
