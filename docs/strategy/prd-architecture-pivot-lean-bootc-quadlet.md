# PRD — LifeOS Architecture Pivot: Lean bootc + Quadlet Containers

**Status:** Draft v2 · 2026-04-30 (revisado tras feedback Hector — descartado pivot Bluefin, agregado HA + dual-registry workflow + container size optimization)
**Author:** Hector + Claude (Opus 4.7)
**Inspiración:** Conversación de iteración lenta + dolor de NVIDIA driver maintenance · Discusión "todo en bootc" vs "bootc mínimo + apps en containers"
**Predecesor:** Arquitectura monolítica actual de LifeOS (todo el stack de IA dentro de la imagen bootc Fedora pura)

---

## 1. Visión

> **Separar las tres capas que hoy están fusionadas en LifeOS — el sistema operativo (bootc image), las aplicaciones de IA (Quadlet containers), y el ambiente de desarrollo (Distrobox) — para que cada una evolucione a su propio ritmo y vos puedas iterar en horas en vez de días.**

Hoy, todo lo que es LifeOS — desde el kernel hasta el TTS de Kokoro — vive dentro de una sola imagen bootc gigante. Cada cambio en `lifeosd` o en un servicio de IA implica:

1. Rebuild de imagen completa (~20 min)
2. Push a GHCR (~5 min más)
3. Pull y `bootc switch` en laptop
4. **Reboot del laptop**
5. Validar si funciona; si no, repetir el ciclo desde 1

**Esto NO es lo que bootc fue diseñado para soportar.** bootc está pensado para que la **imagen sea un OS mínimo y estable**, y las **aplicaciones corran encima como contenedores manejados por systemd**. El error mental "todo va en el bootc" es la causa raíz del dolor de iteración.

### Por qué AHORA es el momento

1. **Pain point validado por experiencia real:** sesión del 2026-04-28/29 documenta múltiples ciclos build → deploy → "se rompió otra cosa", incluyendo el bug de silent forgetting que tomó 3 PRs y un día completo de troubleshooting porque sólo se reproducía en imagen instalada.
2. **Arquitectura lista para migrar:** los servicios ya hablan por **HTTP REST localhost** (lifeosd ↔ llama-server :8082, llama-embeddings :8083, lifeos-tts-server :8084, simplex-chat :5226). **Cero cambios de código** para containerizar — sólo empaquetar.
3. **Modelos ya están fuera de la imagen:** los GGUF de inferencia (~13GB) viven en `/var/lib/lifeos/models/`, no en `/usr/`. La imagen bootc actualmente es ~14GB principalmente por dependencias del sistema, no por payload de IA.
4. **El stack VPS-builder + WG deploy ya armado:** el self-hosted runner en VPS y los scripts `vps-prepare-laptop-update.sh` / `vps-deploy-to-laptop.sh` permiten iterar containers individuales sin reconstruir la imagen completa.

---

## 2. Restricciones duras (no negociables)

| Restricción | Razón |
|-------------|-------|
| **Privacidad 100% local** debe mantenerse | LifeOS es privacy-first. Containerización NO debe abrir puertos al exterior. `Network=host` o red podman privada solamente. |
| **Cero regresión funcional en T+0 post-migración** | Cada servicio debe comportarse idéntico antes/después de containerizar. Si Axi respondía SimpleX antes, debe responder igual después. |
| **Migración reversible por servicio** | Cada Quadlet debe poder rollback al binario del bootc image sin tocar otros servicios. No big bang. |
| **GPU passthrough debe funcionar para llama-server** | El single-mayor consumidor de recursos (Qwen3.5-9B con 99 GPU layers) debe seguir corriendo en GPU NVIDIA via CDI. |
| **SQLite + sqlite-vec siguen siendo single-file** | `/var/lib/lifeos/memory.db` se accede por bind mount desde el container de lifeosd. Sin DB-as-a-service. |
| **Modelos GGUF read-only desde container** | `/var/lib/lifeos/models/` se monta `:ro,Z` en cada container que los necesita. Updates del modelo viven afuera del container. |
| **bootc image debe quedar < 4GB descomprimida** | Hoy está en ~14GB. Target post-migración: kernel + systemd + podman + quadlets + drivers. Punto. |

---

## 3. Arquitectura propuesta

### Tres capas, tres ritmos de cambio

```
┌──────────────────────────────────────────────┐
│  LAYER 1: bootc image (estable, mínima)      │  ← rebase mensual o menos
│  - Kernel + systemd + podman + quadlet       │
│  - NVIDIA driver + nvidia-container-toolkit  │
│  - Configs base (resolved.conf, firewalld)   │
│  - Modelos pequeños read-only (whisper,      │
│    wespeaker, rustpotter)                    │
│  - Quadlet definitions (.container files)    │
└──────────────────────────────────────────────┘
                  ▲
┌──────────────────────────────────────────────┐
│  LAYER 2: Quadlet containers (mutables)      │  ← podman pull diario
│  - lifeosd.container        (Rust daemon)    │
│  - llama-server.container   (Qwen3.5 + GPU)  │
│  - llama-embed.container    (nomic, CPU)     │
│  - lifeos-tts.container     (Kokoro, CPU)    │
│  - simplex-bridge.container (SimpleX bot)    │
│  - whisper-stt.container    (futuro)         │
└──────────────────────────────────────────────┘
                  ▲
┌──────────────────────────────────────────────┐
│  LAYER 3: Distrobox (desarrollo)             │  ← cada vez que codeás
│  - lifeos-dev: Fedora 43 mutable             │
│  - rustup, cargo, gcc, lldb, etc             │
│  - Acceso a /var/lib/lifeos/ del host        │
└──────────────────────────────────────────────┘
```

### Networking: Opción A (host) primero, B (red privada) después

**Fase inicial — `Network=host`**: Cada Quadlet usa la red del host. Los puertos `8082/8083/8084/8081/5226` quedan exactamente donde están. Cero cambio de URLs en `lifeosd`.

**Fase posterior — red podman privada `lifeos-net`**: Servicios se llaman por nombre DNS interno (`http://llama-server:8082`). Más limpio y aislado, requiere actualizar referencias hardcoded en lifeosd. Diferido hasta que la migración base esté estable.

### Ejemplo concreto: llama-server.container con GPU

```ini
# /etc/containers/systemd/lifeos-llama-server.container
[Unit]
Description=LifeOS LLM (Qwen3.5-9B GPU)
After=network-online.target nvidia-cdi-refresh.service
Wants=nvidia-cdi-refresh.service

[Container]
Image=ghcr.io/hectormr206/lifeos-llama-server:stable
ContainerName=lifeos-llama-server
Network=host
AddDevice=nvidia.com/gpu=all
Volume=/var/lib/lifeos/models:/models:ro,Z
Environment=LLAMA_MODEL=/models/Qwen3.5-9B-Q4_K_M.gguf
Environment=LLAMA_MMPROJ=/models/Qwen3.5-9B-mmproj-F16.gguf
EnvironmentFile=-/var/lib/lifeos/llama-server-runtime-profile.env
Exec=--model ${LLAMA_MODEL} --mmproj ${LLAMA_MMPROJ} --jinja \
     --host 127.0.0.1 --port 8082 --n-gpu-layers 99 \
     --ctx-size 131072 --flash-attn auto

[Service]
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target default.target
```

`AddDevice=nvidia.com/gpu=all` es CDI (Container Device Interface) — la forma moderna y limpia de pasar GPU a containers. Reemplaza `--gpus all` legacy de Docker.

---

## 4. Imagen base — decisión confirmada

**Mantenemos Fedora bootc puro + nuestro propio `lifeos-nvidia` driver layer.**

```dockerfile
FROM quay.io/fedora/fedora-bootc:43
# + capa propia ghcr.io/hectormr206/lifeos-nvidia-drivers para NVIDIA
```

### Por qué NO migramos a Bluefin (decisión 2026-04-30)

Evaluamos Bluefin-nvidia-open como alternativa para offload del NVIDIA driver maintenance, pero los caveats reales tras la investigación lo desaconsejan:

- **Bluefin está deprecando closed drivers** — solo soporta `nvidia-open` que requiere GPU Turing+ (RTX 20/30/40, GTX 16xx). Si LifeOS quiere correr en laptops con Pascal/Maxwell, Bluefin queda fuera.
- **Driver 595.58.03 actual de Bluefin tiene bugs reportados** (performance degradation, crashes RTX 3060 mobile). NO es trouble-free.
- **Dependencia de release cadence ajeno** — pinning a tags GTS ayuda pero no elimina el riesgo.
- **El stack actual ya funciona** con `lifeos-nvidia` y la build dolorosa del driver es trabajo aislado al CI, no bloquea iteración del producto.

### Implicación para el resto del PRD

El NVIDIA driver y el `nvidia-container-toolkit` SIGUEN viviendo en la imagen bootc (porque el módulo de kernel no puede vivir en container). Lo que ganamos con la migración a Quadlet **no es deshacernos del trabajo del driver** — es deshacernos del trabajo de iteración de TODO LO DEMÁS:

```
Imagen bootc post-migración:
  - kernel + systemd
  - podman + Quadlet generator
  - lifeos-nvidia driver + nvidia-container-toolkit (CDI)
  - configs base (resolved.conf, firewalld)
  - modelos pequeños read-only (whisper, wespeaker, rustpotter)
  - Quadlet definitions (.container files)

Y NADA MÁS. lifeosd, llama-server, embeddings, TTS, bridges → todos containers.
```

---

## 5. Inner loop de desarrollo — el cambio que va a salvar el día a día

### Antes (hoy)

```
edit lifeosd code
  ↓ cargo build (5 min)
  ↓ push to main
  ↓ VPS runner builds image (15-25 min)
  ↓ skopeo copy GHCR → VPS registry (5 min)
  ↓ podman save | sudo podman load (3 min)
  ↓ bootc switch + upgrade (1 min)
  ↓ REBOOT laptop (2 min)
  ↓ validate
  ↓ broken? GOTO 1
TOTAL: 30-40 minutos por iteración
```

### Después (target)

```
edit lifeosd code
  ↓ cargo build inside Distrobox (1-2 min, cache warm)
  ↓ podman build lifeosd:dev (1 min, layer cache)
  ↓ systemctl restart lifeos-lifeosd.service
  ↓ validate
  ↓ broken? GOTO 1
TOTAL: 3-5 minutos por iteración
```

**Ganancia: ~10x velocidad de iteración.** Sin reboots, sin tocar el OS, sin validar en imagen completa hasta el final.

### Comandos clave del nuevo workflow

```bash
# 1. Crear distrobox dev (una sola vez)
distrobox create --name lifeos-dev --image fedora:43 --nvidia
distrobox enter lifeos-dev
# adentro: rustup default stable, cargo, etc.

# 2. Iterar un servicio individual sin tocar otros
podman build -t localhost/lifeosd:dev -f containers/lifeosd/Containerfile .
sudo systemctl stop lifeos-lifeosd.service
# editar /etc/containers/systemd/lifeos-lifeosd.container temporalmente para apuntar a :dev
sudo systemctl daemon-reload
sudo systemctl start lifeos-lifeosd.service
journalctl -fu lifeos-lifeosd.service

# 3. Validar imagen bootc completa en VM (cuando toca)
bootc-image-builder --type qcow2 ghcr.io/hectormr206/lifeos:edge
virt-install --name lifeos-test --memory 16384 --vcpus 4 \
  --disk path=./lifeos.qcow2 --import --os-variant fedora43
# ciclo de validación: 3-5 min vs 30-40 min
```

---

## 5b. High Availability — auto-restart con state preservation

**Requisito explícito de Hector:** los containers nunca se caen, y si se caen se restablecen con todo su estado intacto.

### Regla mental

> **El container puede morir libremente porque NO tiene state adentro.** Todo el state (DBs, modelos, configs, logs persistentes) vive en el HOST como bind mount. Container muere → systemd lo restablece → vuelve a montar el mismo bind mount → state intacto.

### Configuración Quadlet estándar para todos los servicios

```ini
[Container]
# ... image, volumes, ports ...

[Service]
Restart=always              # systemd lo levanta SIEMPRE si muere
RestartSec=5s               # esperá 5s antes de relanzar (evita thrashing)
TimeoutStartSec=120s        # llama-server con modelo grande necesita tiempo de warmup
WatchdogSec=60s             # si el container no responde "alive" en 60s → kill + restart

[Install]
WantedBy=multi-user.target default.target
```

### Mapping state → bind mounts

| Servicio | State persistente | Bind mount (read-write) | Bind mount (read-only) |
|----------|-------------------|--------------------------|-------------------------|
| `lifeosd` | `memory.db`, `calendar.db`, `task_queue.db`, `scheduled_tasks.db`, configs, logs | `/var/lib/lifeos:/var/lib/lifeos:Z` | `/var/lib/lifeos/models:/models:ro,Z` |
| `llama-server` | (ninguno — stateless) | — | `/var/lib/lifeos/models:/models:ro,Z` |
| `llama-embeddings` | (ninguno) | — | `/var/lib/lifeos/models:/models:ro,Z` |
| `lifeos-tts` | (ninguno — voces baked en imagen) | — | (ninguno) |
| `simplex-bridge` | `/var/lib/lifeos/simplex/` (perfil del bot) | `/var/lib/lifeos/simplex:/data:Z` | — |

### Validación obligatoria de HA en cada fase

Antes de declarar una fase completa, smoke test:

```bash
sudo systemctl kill -s SIGKILL lifeos-<servicio>.service
# El container muere violentamente
sleep 10
sudo systemctl status lifeos-<servicio>.service
# DEBE estar active (running) con un nuevo PID
# Y el state DEBE estar intacto (DB con datos previos, models montados, etc)
```

Si el restart automático no funciona o el state se pierde, la fase queda **bloqueada hasta resolver**.

---

## 5c. Dual-registry promotion workflow

**Premisa:** dos registros con propósitos distintos para separar iteración rápida (privada) de release pública.

```
┌──────────────────────────────────────────────────────────────────┐
│  REGISTRO DEV — 10.66.66.1:5001 (privado, solo WireGuard)        │
│  - tags: :dev, :branch-feature-x, :sha-abc123                    │
│  - propósito: iteración rápida desde dev machine                 │
│  - vida útil: corta, se prune cada 72h                           │
│  - acceso: solo desde dev machine + laptop via WG                │
└──────────────────────────────────────────────────────────────────┘
                            ▲ podman push (build local)
                            │
                            │ podman pull (laptop test)
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  REGISTRO PROD — ghcr.io/hectormr206/lifeos-* (público)          │
│  - tags: :stable, :v1.2.3, :latest                               │
│  - propósito: producción, parte del bootc image release          │
│  - vida útil: indefinida, retention manual                       │
│  - acceso: público (open source), pull sin auth                  │
└──────────────────────────────────────────────────────────────────┘
                            ▲ podman tag :dev :stable + push
                            │ (PROMOCIÓN explícita post-validación)
```

### Flujo completo (ejemplo: cambio en `lifeosd`)

```bash
# === PASO 1: Iterar en dev machine ===
cd ~/dev/gama/lifeos/lifeos
edit daemon/src/...
podman build -t 10.66.66.1:5001/lifeos-lifeosd:dev \
  -f containers/lifeosd/Containerfile .
podman push --tls-verify=false 10.66.66.1:5001/lifeos-lifeosd:dev

# === PASO 2: Test en vivo en laptop (sin reboot) ===
ssh laptop "
  podman pull --tls-verify=false 10.66.66.1:5001/lifeos-lifeosd:dev
  podman tag 10.66.66.1:5001/lifeos-lifeosd:dev localhost/lifeos-lifeosd:current
  sudo systemctl restart lifeos-lifeosd.service
  journalctl --user -fu lifeos-lifeosd.service
"
# Validar comportamiento real en el laptop, en vivo

# === PASO 3: Si funciona → promocionar a producción ===
podman tag 10.66.66.1:5001/lifeos-lifeosd:dev \
  ghcr.io/hectormr206/lifeos-lifeosd:stable
podman push ghcr.io/hectormr206/lifeos-lifeosd:stable

# === PASO 4: Próximo bootc image release ===
# release-channels.yml ya pinned a :stable en los Quadlet definitions
# El nuevo bootc image incluirá lifeos-lifeosd:stable validado
# (la imagen no contiene el container — solo el .container file que apunta a :stable)
```

### Si rompe algo, rollback inmediato

```bash
# En laptop, sin reboot:
ssh laptop "
  sudo systemctl stop lifeos-lifeosd.service
  podman tag ghcr.io/hectormr206/lifeos-lifeosd:stable localhost/lifeos-lifeosd:current
  sudo systemctl start lifeos-lifeosd.service
"
# Vuelve al :stable previo en ~10 segundos
```

### Garbage collection del registry dev

Cron en VPS (ya existe pattern para podman):

```bash
# Cada 72h — eliminar tags :dev y :branch-* viejos del registry privado
podman exec lifeos-vps-registry registry garbage-collect /etc/docker/registry/config.yml
podman image prune --filter "until=72h" -f
```

---

## 5d. Container size optimization

**Objetivo:** containers chicos sin caer en unikernels (que descartamos por incompatibilidad con el stack — ver pendiente futuro `project_pending_unikernel_eval_tinyagents`).

### Técnicas

**1) Distroless / scratch base para containers Rust** (lifeosd):

```dockerfile
# Build stage — Fedora con cargo
FROM fedora:43 AS builder
RUN dnf install -y rust cargo openssl-devel sqlite-devel
WORKDIR /build
COPY . .
RUN cargo build --release --manifest-path daemon/Cargo.toml

# Runtime stage — distroless con solo libs runtime
FROM gcr.io/distroless/cc-debian12
COPY --from=builder /build/daemon/target/release/lifeosd /usr/bin/lifeosd
COPY --from=builder /usr/lib64/libsqlite3.so.0 /usr/lib/x86_64-linux-gnu/
ENTRYPOINT ["/usr/bin/lifeosd"]
```

Resultado esperado: ~30-50 MB vs ~500 MB con full Fedora runtime.

**2) Multi-stage para llama-server** (Vulkan + GPU):

```dockerfile
# Build stage con todas las deps
FROM fedora:43 AS builder
RUN dnf install -y cmake gcc-c++ vulkan-headers glslang glslc \
    pkgconf-pkg-config curl-devel
WORKDIR /build
RUN git clone https://github.com/ggml-org/llama.cpp /tmp/llama.cpp \
    && cd /tmp/llama.cpp && git checkout <pinned-tag> \
    && cmake -B build -DGGML_VULKAN=ON -DLLAMA_BUILD_SERVER=ON \
    && cmake --build build -j1

# Runtime stage — solo lo mínimo para correr
FROM fedora:43-minimal
RUN microdnf install -y vulkan-loader libcurl --setopt=tsflags=nodocs && microdnf clean all
COPY --from=builder /build/build/bin/llama-server /usr/sbin/llama-server
ENTRYPOINT ["/usr/sbin/llama-server"]
```

Resultado esperado: ~200-300 MB vs ~2 GB con build deps.

**3) Compartir layer base entre containers**

Definir un `lifeos-base` mínimo común:

```dockerfile
# containers/lifeos-base/Containerfile
FROM fedora:43-minimal
RUN microdnf install -y ca-certificates tzdata libcurl --setopt=tsflags=nodocs \
    && microdnf clean all
```

Cada servicio extiende:
```dockerfile
FROM ghcr.io/hectormr206/lifeos-base:1
COPY --from=builder /build/... /usr/bin/...
```

Podman dedupe layers automáticamente → 5 containers compartiendo lifeos-base = lifeos-base se descarga UNA vez.

**4) NO bake modelos en containers**

Confirmado en restricciones: GGUF van por bind mount, NO COPY al container. Esto es esencial — un GGUF en container haría imágenes de 5-15 GB cada una.

### Targets de tamaño post-optimización

| Container | Sin optimización | Con optimización | % reducción |
|-----------|------------------|-------------------|-------------|
| `lifeos-lifeosd` (Rust) | ~500 MB | ~30-50 MB | **90%** |
| `lifeos-llama-server` (Vulkan) | ~2 GB | ~200-300 MB | **85%** |
| `lifeos-embeddings` (CPU) | ~2 GB | ~200 MB | **90%** |
| `lifeos-tts` (Python ONNX + voices) | ~1.5 GB | ~600-800 MB | **50%** |
| `lifeos-simplex-bridge` | ~300 MB | ~80 MB | **75%** |

Total combinado: ~6 GB de containers en lugar de ~25 GB de imagen monolítica. Y se descargan en paralelo con dedupe.

---

## 5e. Protección de containers del sistema (defense in depth)

**Premisa:** LifeOS corre con un modelo de amenaza realista — usuario distraído, AI con `run_command` que ejecuta shell, modelos LLM que a veces alucinan comandos. Un `podman rm`, `podman system prune` o `systemctl stop` mal ejecutado puede tirar servicios críticos.

**Esta sección define la protección que aplica a TODOS los containers del sistema LifeOS — los actuales (`lifeosd`, `llama-server`, `llama-embeddings`, `lifeos-tts`, `simplex-bridge`) Y todos los que agreguemos en el futuro.** Cada container nuevo del sistema HEREDA estas 6 capas automáticamente porque son políticas a nivel OS, no por servicio.

### Convención de naming (obligatoria)

Todos los containers del sistema LifeOS deben tener prefijo **`lifeos-`** y vivir en Quadlet rootful (`/etc/containers/systemd/`). Esto permite que las protecciones por pattern (`lifeos-*`) funcionen sin enumeración explícita:

- `lifeos-lifeosd.container`
- `lifeos-llama-server.container`
- `lifeos-llama-embeddings.container`
- `lifeos-tts.container`
- `lifeos-simplex-bridge.container`
- `lifeos-<futuro>.container` ← cualquier container nuevo del sistema

Containers que NO sean del sistema (creados por user o AI experimentando) DEBEN ir rootless en `~/.config/containers/systemd/` y NO usar el prefijo `lifeos-`.

### Capa 1 — Separación rootful/rootless

| Aspecto | Sistema (LifeOS) | Usuario / AI |
|---------|------------------|--------------|
| **Storage** | `/var/lib/containers/storage/` | `~/.local/share/containers/storage/` |
| **Quadlets** | `/etc/containers/systemd/` (root-owned) | `~/.config/containers/systemd/` (lifeos-owned) |
| **Gestión** | systemd PID 1 | systemd --user |
| **Naming** | prefijo `lifeos-*` | sin prefijo `lifeos-` |

`podman rm` ejecutado por user `lifeos` (sin sudo) **NO PUEDE TOCAR** los containers del sistema — están en otro storage físico. Es separación por filesystem, no por reglas.

### Capa 2 — Sudoers restrictivo (denylist explícita)

Agregar a `/etc/sudoers.d/lifeos-axi` post-Quadlet:

```bash
# DENY explícito de operaciones destructivas sobre containers/services del sistema
Cmnd_Alias LIFEOS_PROTECTED_PODMAN = \
    /usr/bin/podman rm *lifeos-*, \
    /usr/bin/podman rmi *lifeos-*, \
    /usr/bin/podman stop *lifeos-*, \
    /usr/bin/podman kill *lifeos-*, \
    /usr/bin/podman system prune *, \
    /usr/bin/podman volume rm *

Cmnd_Alias LIFEOS_PROTECTED_SYSTEMD = \
    /usr/bin/systemctl stop lifeos-*, \
    /usr/bin/systemctl disable lifeos-*, \
    /usr/bin/systemctl mask lifeos-*, \
    /usr/bin/systemctl kill lifeos-*

# El "!" deniega — incluso si lifeos tuviera sudo general, estos comandos fallan
lifeos ALL=(root) !LIFEOS_PROTECTED_PODMAN
lifeos ALL=(root) !LIFEOS_PROTECTED_SYSTEMD
```

**Ventaja del pattern `lifeos-*`:** containers nuevos del sistema quedan automáticamente protegidos sin tocar sudoers. Solo enforce el naming convention.

### Capa 3 — systemd auto-recovery

Cada Quadlet del sistema tiene la config estándar (definida en Sección 5b):

```ini
[Service]
Restart=always
RestartSec=5s
WatchdogSec=60s
```

Si alguien logra matar un container por señal directa (sin pasar por podman), systemd lo restablece en 5s. Para borrarlo permanentemente hay que detener el systemd unit, lo cual está bloqueado en Capa 2.

### Capa 4 — Image cache pinning (`lifeos-image-guardian`)

Servicio dedicado que garantiza que las imágenes críticas siempre existan localmente:

```ini
# /etc/systemd/system/lifeos-image-guardian.service (en bootc image)
[Unit]
Description=LifeOS — ensure all system container images are present
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/lifeos-ensure-images

[Install]
WantedBy=multi-user.target
```

```bash
# /usr/local/bin/lifeos-ensure-images (read-only /usr en bootc)
#!/bin/bash
set -e
# Source of truth: lista de imágenes requeridas por los Quadlets del sistema
mapfile -t REQUIRED < <(grep -h '^Image=' /etc/containers/systemd/lifeos-*.container | cut -d= -f2)
for img in "${REQUIRED[@]}"; do
  if ! podman image exists "$img"; then
    echo "[image-guardian] Re-pulling missing image: $img"
    podman pull "$img"
  fi
done
```

Y cada Quadlet incluye `ExecStartPre`:

```ini
[Container]
# ...
ExecStartPre=/usr/local/bin/lifeos-ensure-images
```

Si alguien logra `podman rmi`, antes de que el container falle al restart la imagen se re-baja del registro.

### Capa 5 — Axi `run_command` blocklist (CRÍTICO para AI safety)

En `daemon/src/axi_tools.rs`, todo comando que pase por `run_command` se valida contra patterns prohibidos:

```rust
const SYSTEM_PROTECTION_BLOCKLIST: &[&str] = &[
    // Container destruction
    "podman rm",
    "podman rmi",
    "podman system prune",
    "podman volume rm",
    "podman pod rm",
    "podman kill",
    // Service shutdown of LifeOS system
    "systemctl stop lifeos-",
    "systemctl disable lifeos-",
    "systemctl mask lifeos-",
    "systemctl kill lifeos-",
    // Filesystem destruction de paths críticos
    "rm -rf /var/lib/lifeos",
    "rm -rf /var/lib/containers",
    "rm -rf /etc/containers",
    "rm -rf /home/lifeos",
    "rm -rf /usr/local/bin/lifeos",
    // Sudoers tampering
    "/etc/sudoers",
    "visudo",
    // bootc tampering
    "bootc rollback",
    "bootc switch",
    "bootc upgrade",
];

fn validate_command_safety(cmd: &str) -> Result<(), String> {
    let normalized = cmd.to_lowercase();
    for blocked in SYSTEM_PROTECTION_BLOCKLIST {
        if normalized.contains(blocked) {
            return Err(format!(
                "Comando bloqueado por política de protección de LifeOS: contiene '{}'. \
                 Estos comandos pueden destruir servicios críticos. \
                 Si necesitás esto, ejecutalo manualmente como root.",
                blocked
            ));
        }
    }
    Ok(())
}
```

Y al system prompt de Axi se agrega regla absoluta:

> **PROTECCIÓN DEL SISTEMA — REGLA ABSOLUTA:** los containers, services y archivos con prefijo `lifeos-` o en `/var/lib/lifeos`, `/etc/containers`, `/usr/local/bin/lifeos*` son **infraestructura crítica**. NUNCA propongas comandos que los borren, detengan, o modifiquen. Si el usuario te pide "limpiar containers" o "borrar todo", clarificá: vos podés gestionar containers del USER (rootless, sin prefijo `lifeos-`), pero los del SISTEMA son sagrados — solo el dueño puede tocarlos manualmente.

### Capa 6 — Audit logging

`auditd` ya está en LifeOS. Agregar reglas en imagen bootc:

```bash
# /etc/audit/rules.d/lifeos-containers.rules
-w /etc/containers/systemd/ -p wa -k lifeos_quadlet_changed
-w /var/lib/containers/storage/ -p wa -k lifeos_storage_changed
-w /etc/sudoers.d/lifeos-axi -p wa -k lifeos_sudoers_changed
-w /usr/local/bin/lifeos-ensure-images -p wa -k lifeos_guardian_changed
```

Cualquier write/attribute change a esos paths queda registrado en `/var/log/audit/audit.log` con su timestamp + uid + comando. Forensics post-incidente.

### Tabla resumen — qué protege cada capa contra qué amenaza

| Amenaza | Capa que la para |
|---------|-------------------|
| User rootless ejecuta `podman rm` | Capa 1 (otro storage) |
| User con sudo genérico ejecuta `sudo podman rm lifeos-*` | Capa 2 (sudoers deny) |
| Proceso mata container por señal | Capa 3 (auto-restart) |
| User borra imagen con `sudo podman rmi` (si bypassea sudoers) | Capa 4 (re-pull en startup) |
| AI con `run_command` recibe instrucción ambigua | Capa 5 (blocklist + system prompt) |
| Atacante editando paths críticos | Capa 6 (audit trail) |
| **Defensa total — todas las capas combinadas** | **Solo root con shell directo (vía bootc rollback) puede romper LifeOS** |

### Validación obligatoria post-implementación

Cada capa requiere su propio test de aceptación antes de declararla activa:

```bash
# Capa 1: rootless no toca system
podman rm lifeos-lifeosd 2>&1 | grep -q "no such container"

# Capa 2: sudo deniega
sudo podman rm lifeos-lifeosd 2>&1 | grep -qi "not allowed"

# Capa 3: auto-restart
sudo systemctl kill -s SIGKILL lifeos-lifeosd
sleep 10
systemctl is-active lifeos-lifeosd  # debe decir "active"

# Capa 4: image guardian
sudo podman image rm ghcr.io/hectormr206/lifeos-lifeosd:stable --force
sudo systemctl restart lifeos-lifeosd
podman image exists ghcr.io/hectormr206/lifeos-lifeosd:stable  # debe ser true

# Capa 5: Axi blocklist
# Test unitario en axi_tools.rs validando que validate_command_safety rechaza patterns

# Capa 6: audit log
sudo touch /etc/containers/systemd/test.container
sudo ausearch -k lifeos_quadlet_changed | grep test.container
```

---

## 6. Plan de migración por fases

**Principio:** containerizar el servicio MÁS FÁCIL primero, sentir el ciclo, ir subiendo dificultad. Si algo se rompe en una fase, sólo afecta UN servicio.

### Fase 0 — Fundación (1 semana)

**Objetivo:** habilitar Quadlet en imagen actual + setup defense in depth + dev workflow, sin migrar ningún servicio todavía.

- [ ] Agregar a Containerfile: `nvidia-container-toolkit` + verificar systemd Quadlet generator activo (Fedora bootc 43 lo trae)
- [ ] Setup `distrobox` en imagen actual con Fedora 43 + nvidia
- [ ] Build local de un container Hello-World con GPU pasada vía CDI para validar el toolkit
- [ ] **Defense in depth (Sección 5e) — implementar TODAS las capas antes de containerizar el primer servicio:**
  - [ ] Capa 2: `/etc/sudoers.d/lifeos-axi` extendido con denylist `LIFEOS_PROTECTED_*`
  - [ ] Capa 4: `/usr/local/bin/lifeos-ensure-images` + `lifeos-image-guardian.service` instalados en imagen bootc
  - [ ] Capa 5: `validate_command_safety()` en `daemon/src/axi_tools.rs` + tests unitarios + system prompt actualizado
  - [ ] Capa 6: `/etc/audit/rules.d/lifeos-containers.rules` instalado
  - [ ] Tests de aceptación de las 6 capas pasando (ver Sección 5e final)
- [ ] Setup VPS registry para tags `:dev` (con cron de garbage collect 72h)
- [ ] Documentar el inner loop en `docs/contributor/quadlet-dev-workflow.md`

**Criterio de salida Fase 0:** poder lanzar un container Hello-World Quadlet rootful con GPU funcionando, Y todas las protecciones de Sección 5e validadas. Ningún servicio LifeOS containerizado todavía — solo la infra para que la migración sea segura desde Fase 1.

### Fase 1 — TTS containerizado (1 semana)

**Objetivo:** primera victoria en target fácil. CPU-only, aislado, bajo riesgo.

- [ ] Crear `containers/lifeos-tts/Containerfile` con Kokoro-82M
- [ ] Crear Quadlet `lifeos-tts.container` con `Network=host` y bind mount de modelos
- [ ] CI workflow `containers-tts.yml` que builda y pushea a `ghcr.io/hectormr206/lifeos-tts:stable`
- [ ] Modificar Containerfile principal: remover Kokoro install, agregar copia del Quadlet a `/etc/containers/systemd/`
- [ ] Build imagen, deploy via VPS, reboot, validar TTS sigue funcionando
- [ ] Test: cambiar el container TTS sin tocar imagen → `podman pull lifeos-tts:dev` + `systemctl restart` + verificar

**Criterio de éxito:** poder updatear TTS sin rebuild de imagen ni reboot.

### Fase 2 — llama-embeddings (1 semana)

Mismo patrón que Fase 1. CPU, fácil. Validamos que el patrón se replica.

### Fase 3 — lifeosd (2 semanas, riesgo medio)

**Objetivo:** containerizar el daemon Rust principal. Requiere bind mounts de DBs.

- [ ] Containerfile multi-stage para Rust release build
- [ ] Bind mounts: `/var/lib/lifeos/` (rw,Z), `/var/lib/lifeos/models/` (ro,Z)
- [ ] Verificar que sqlite-vec se cargue dentro del container (libsqlite3 + extension)
- [ ] Verificar que session_store, memory_plane, embeddings funcionen contra el bind mount
- [ ] Migration test: una vez containerizado, validar SimpleX → Axi → save_health_fact → DB.health_facts (el smoke test que falló hoy 2026-04-29)
- [ ] Diseñar fallback: poder volver al binario en imagen bootc rollback de 1 click

### Fase 4 — llama-server con GPU (2 semanas, riesgo alto)

**Objetivo:** la pieza más compleja. CDI, Vulkan, Secure Boot.

- [ ] Containerfile con build de llama.cpp Vulkan-enabled (mismo Containerfile actual, pero como container independiente)
- [ ] Quadlet con `AddDevice=nvidia.com/gpu=all`
- [ ] Validar: `nvidia-smi` desde dentro del container, `vulkaninfo` muestra device
- [ ] Test funcional: `curl localhost:8082/v1/chat/completions` desde host hace inferencia GPU
- [ ] Stress test: ctx 131072 + 99 GPU layers, comparar tokens/sec con baseline pre-migración
- [ ] Mitigación de bug crítico: si CDI rootless falla (issue #17539 de podman), correr el container rootful

### Fase 5 — Bridges (1 semana)

SimpleX, Telegram (en lifeosd), dashboard. Containers livianos. Cierra la migración.

### Fase 6 — Endurecimiento (1 semana)

Una vez todos los servicios containerizados:

- Migrar de `Network=host` a red podman privada `lifeos-net` con DNS interno (lifeosd llama a `http://llama-server:8082`). Mejor aislamiento, requiere actualizar URLs hardcoded.
- Activar `AutoUpdate=registry` en Quadlets pinned a `:stable` para auto-update sin intervención.
- Cosign signing de cada container (extender pendiente `project_pending_image_signing_cosign`).
- Documentar el patrón completo en `docs/architecture/quadlet-architecture.md`.

---

## 7. Validación VM-first con bootc-image-builder

**Cambio cultural mandatory:** **NUNCA más probar imagen nueva instalando en laptop.** VM primero.

### Workflow

```bash
# 1. Build imagen bootc (en VPS o local)
podman build -t localhost/lifeos:test -f image/Containerfile .

# 2. Convertir a qcow2 con bootc-image-builder
sudo podman run --rm -it --privileged \
  -v $(pwd)/output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/lifeos:test

# 3. Bootear VM
virt-install --name lifeos-test --memory 16384 --vcpus 6 \
  --disk path=output/qcow2/disk.qcow2,format=qcow2 \
  --import --os-variant fedora43 \
  --network bridge=virbr0

# 4. Validar dentro de VM (sin afectar laptop):
#    - lifeosd arranca?
#    - GPU passthrough? (si VM la tiene)
#    - SimpleX bridge conecta?
#    - Memory persistence funciona?
```

GitHub Action `osbuild/bootc-image-builder-action` permite hacer esto en CI también, pero el VPS runner ya cubre eso.

### Eliminar la pregunta "se rompió en laptop después del deploy"

Si la VM bootea y los smoke tests pasan, deploy a laptop con confianza. Si la VM falla, fix en branch sin tocar laptop.

---

## 8. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|--------------|---------|------------|
| **CDI rootless falla con NVIDIA + Vulkan** | Media | Alto | Plan B: container rootful con `User=lifeos` interno. Plan C: rollback Fase 4 al binario en imagen bootc. |
| **bind mount de SQLite con WAL corrupts DB** | Baja | Crítico | Validación exhaustiva en VM antes de Fase 3. SELinux `:Z` correcto. fsync semantics validados. Smoke test post-restart violento (SIGKILL). |
| **Networking host introduce conflictos de puertos** | Baja | Bajo | Network=host actual ya funciona; sólo containerizamos lo que ya está en localhost. Migración a red privada en Fase 6. |
| **Quadlet generator bug en Fedora bootc 43** | Baja | Medio | systemd 254+ tiene Quadlet maduro. Test temprano en Fase 0. |
| **Layer caching del podman explota disco en VPS o laptop** | Media | Medio | Cron `podman system prune -af --filter "until=72h"` en VPS. Para laptop, prune semanal. Monitorear `/var/lib/containers/storage`. |
| **Container muere y systemd no lo restablece** | Baja | Alto | Validación HA explícita en cada fase: SIGKILL + verificar restart automático + state intacto. Si falla, fase queda bloqueada. |
| **Promotion :dev → :stable accidental con bug** | Media | Medio | Tag manual explícito (no auto-promote). Smoke tests obligatorios en laptop antes de promote. Rollback rápido vía retag. |
| **Hector descubre que necesita un tool del bootc image que no está en container** | Media | Bajo | Cada Quadlet puede instalar tools que necesite en su Containerfile, sin tocar imagen base. |
| **Loss of containerized state on rollback** | Baja | Alto | DBs en bind mount sobreviven. Container layer es desechable. State persiste. |

---

## 9. Métricas de éxito

| Métrica | Baseline (hoy) | Target post-migración |
|---------|----------------|------------------------|
| Tiempo edit-to-running para `lifeosd` (Rust) | 30-40 min | < 5 min |
| Tiempo edit-to-running para `lifeos-tts` | 30-40 min | < 3 min |
| Tamaño descomprimido de imagen bootc | ~14GB | < 4GB |
| Frecuencia de reboots por dev iteration | 1 por iter | 0 (sólo cambio de imagen base) |
| Tiempo de "validar imagen nueva pre-laptop" | manual, no existe | 5-10 min vía VM |
| Updates de IA sin tocar OS | 0% | 100% |
| Time-to-rollback de un servicio individual roto | reboot + bootc rollback (~5 min + reboot) | `systemctl restart` con tag previo (~10s) |
| % de bugs descubiertos en VM antes de laptop | 0% | > 70% |

---

## 10. Decisiones que mantenemos vs revisitamos

### Mantenemos sin cambios

- **bootc como filosofía de OS**: la imagen sigue siendo inmutable, atomic, rollback-able. La diferencia es que ahora es delgada.
- **VPS como builder**: el self-hosted runner sigue construyendo imágenes y containers. La carga de trabajo se redistribuye pero el patrón funciona.
- **GHCR como registro principal**: tanto la imagen bootc como cada container van a `ghcr.io/hectormr206/lifeos-*`.
- **WireGuard + scripts de deploy**: siguen aplicando para imagen base. Para containers individuales, podman pull directo desde el registro de VPS o GHCR.
- **Privacy-first**: Network=host inicialmente, red privada después. Cero exposición externa.
- **Modelos GGUF en `/var/lib/lifeos/models/`**: ya está bien donde está. Bind mount read-only desde containers.

### Revisitamos en este PRD

- **NVIDIA driver layer**: pasa de "responsabilidad de Hector" a "responsabilidad de UBlue" (si Fase 6 va).
- **`docker.yml` workflow**: probablemente se elimina; cada container tiene su propio CI workflow más chico.
- **`release-channels.yml`**: queda para imagen base (cambia poco). Versiona la imagen bootc.
- **Convención de versionado**: agregamos versionado independiente por container (`lifeos-tts:v0.4.2`, `lifeos-llama-server:v1.0.0`, etc) además del version de imagen base.

---

## 11. Open questions (a resolver en Fase 0)

1. **¿`sqlite-vec` funciona correctamente con bind mount + SELinux `:Z` + WAL?** A validar en VM antes de Fase 3 con un smoke test que incluya SIGKILL + restart + verify integridad.
2. **¿Cuántos containers concurrentes podemos correr antes de saturar 16GB RAM del laptop?** Audit de memoria por servicio post-Fase 3.
3. **Estructura del repo:** mantener `image/Containerfile` único o partirlo? Recomendación: `image/Containerfile` para bootc base (delgado), `containers/<servicio>/Containerfile` por cada Quadlet. Cada uno con su propio CI workflow.
4. **¿Cómo gestionar el `lifeos-base` shared layer?** Versionar (`lifeos-base:1`, `:2`) y publicar a GHCR. Cada container hijo pinea a una versión específica para evitar breaking changes silenciosos.
5. **Auto-update via `AutoUpdate=registry` en Quadlets, o pull manual orquestado?** Recomendación: pull manual durante migración (Fases 1-5), auto-update con pinning a `:stable` desde Fase 6.
6. **Cosign signing de containers individuales:** extender `project_pending_image_signing_cosign` a cada container nuevo. Decidir keyless OIDC (preferido) vs KMS.
7. **VPS registry hardening:** ¿agregar TLS y auth básico al `10.66.66.1:5001`?  Hoy está sobre WG (red privada) sin auth — funciona pero menos prolijo. Diferido.

---

## 12. Cronograma estimado (con margen para imprevistos)

| Fase | Trabajo | Duración | Acumulado |
|------|---------|----------|-----------|
| 0 | Fundación + decisión Bluefin | 1 semana | 1 sem |
| 1 | TTS containerizado | 1 semana | 2 sem |
| 2 | llama-embeddings | 1 semana | 3 sem |
| 3 | lifeosd containerizado | 2 semanas | 5 sem |
| 4 | llama-server GPU | 2 semanas | 7 sem |
| 5 | Bridges (SimpleX, etc) | 1 semana | 8 sem |
| 6 | Pivot a Bluefin (opcional) | 1 semana | 9 sem |

**Total: 8-9 semanas** trabajando ~50% del tiempo en esto (Hector tiene otras responsabilidades). En tiempo dedicado full-time: ~4 semanas.

---

## 13. Referencias

### Containerización + GPU
- [Setting up Ollama with CUDA on Podman Quadlets | Brandon Rozek](https://brandonrozek.com/blog/ollama-cuda-podman-quadlets/) — patrón Quadlet GPU funcional con CDI
- [Support for Container Device Interface — NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html) — CDI spec oficial
- [CDI rootless issue #17539](https://github.com/containers/podman/issues/17539) — gotcha histórico, verificar versión actual
- [Podman 5.0 NVIDIA device issue #26761](https://github.com/containers/podman/issues/26761) — issue específico de versión

### bootc + VM testing
- [bootc-image-builder | osbuild](https://osbuild.org/docs/bootc/) — qcow2 generation
- [bootc-image-builder-action | osbuild](https://github.com/osbuild/bootc-image-builder-action) — GitHub Action wrapper
- [Modernizing Linux Deployments with OSTree and Bootc | UBOS](https://ubos.tech/news/modernizing-linux-deployments-with-ostree-and-bootc/) — patrón general

### Container size optimization
- [Distroless container images | Google](https://github.com/GoogleContainerTools/distroless) — base images mínimas
- [Multi-stage builds | Docker docs](https://docs.docker.com/build/building/multi-stage/) — patrón general (aplica a Containerfile/Podman)

### Decisión descartada (registrada para auditabilidad)
- Pivot a Bluefin-nvidia-open evaluado y descartado 2026-04-30. Razones documentadas en Sección 4.
- Migración a unikernels evaluada y descartada 2026-04-30. Ver pendiente futuro `project_pending_unikernel_eval_tinyagents` para reevaluación cuando madure el ecosistema.

---

## 14. Aprobación

- [x] Visión general aprobada por Hector (2026-04-30)
- [x] Decisión "Fedora bootc puro + lifeos-nvidia, NO Bluefin" confirmada (2026-04-30)
- [x] Decisión "containers, NO unikernels" confirmada (2026-04-30)
- [x] Fase 1 = TTS confirmada (2026-04-30)
- [ ] Próximo paso: arrancar Fase 0 con `/sdd-new pivot-fundacion-quadlet`
