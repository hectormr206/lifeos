# PRD: LifeOS Local Development & Testing Workflow

**Version:** 1.2
**Fecha:** 2026-04-11
**Estado:** Aprobado

> **Nota v1.2 (actualizada):** Para configurar la laptop de desarrollo
> (sudo policy, `RUST_LOG=debug`, sentinel), ver
> [`docs/operations/developer-bootstrap.md`](developer-bootstrap.md).
> El flujo aqui descripto aplica cuando corres
> `ghcr.io/hectormr206/lifeos:edge` con el bootstrap instalado.

---

## Problema

El ciclo actual de desarrollo es insostenible:

1. Se hacen modificaciones durante el dia
2. Se pushea a GitHub y CI tarda **6+ horas** para ponerse verde
3. Se itera corrigiendo workflows rotos en GitHub (mas horas)
4. Se actualiza la laptop via `bootc upgrade`
5. La actualizacion viene **rota** — cosas que nunca se probaron localmente
6. Se pierde un dia entero entre desarrollo, CI, y debugging post-update

**Resultado:** Mala experiencia para el desarrollador y riesgo para usuarios finales.

---

## Objetivo

Establecer un flujo donde:

- **Cada cambio se valida localmente** antes de tocar GitHub
- **Los workflows de CI se ejecutan en la laptop** para detectar errores antes del push
- **Se puede construir y probar una actualizacion completa** en local (laptop o VM)
- **A GitHub solo llegan cambios que ya funcionan** — workflows en verde desde el primer push

---

## Analisis: Que se puede probar y que no

### Capa 1 — Testeable EN VIVO en la laptop (sin rebuild)

Todo lo que vive en capas mutables (`/var/`, `/home/`, `/etc/` overrides):

| Componente | Ubicacion | Como probar |
|-----------|-----------|-------------|
| Config COSMIC (wallpaper, panel, dock, tema) | `~/.config/cosmic/` | Editar + cerrar/abrir sesion |
| Config del daemon LifeOS | `~/.config/lifeos/`, `/etc/lifeos/` | Editar + `systemctl --user restart lifeosd` |
| Overrides de systemd | `/etc/systemd/system/*.d/` | Crear dropin + `systemctl daemon-reload` |
| Modelos AI descargados | `/var/lib/lifeos/models/` | Copiar modelo + restart servicio |
| Firefox profile/policies | `~/.mozilla/firefox/lifeos.default/` | Editar user.js + reiniciar Firefox |
| Flatpak apps | `/var/lib/flatpak/` | `flatpak install/update` |
| Polkit rules | `/etc/polkit-1/rules.d/` | Copiar regla (sin restart) |

**NO testeable en vivo:**
- Binarios (`life`, `lifeosd`, `llama-server`, `whisper-cli`)
- Paquetes RPM
- Scripts en `/usr/local/bin/`
- Unit files base en `/usr/lib/systemd/`
- Modelos pre-instalados en `/usr/share/lifeos/models/`
- Containerfile y todo lo que este toque

### Capa 2 — Testeable con BUILD LOCAL (cambios en Rust)

| Componente | Como probar localmente |
|-----------|----------------------|
| CLI (`life`) | `make build-cli` → ejecutar `target/release/life` |
| Daemon (`lifeosd`) | `make build-daemon` → correr el binario manualmente para ver logs |
| Tests | `make test` (cli + daemon + integration) |
| Lint | `make lint` |
| Audit | `make audit` |
| Todo CI | `scripts/local-ci.sh` |

**Trick para probar el daemon local sin tocar el sistema:**

```bash
# Compilar version dev
make build-daemon

# Parar el service oficial
systemctl --user stop lifeosd

# Correr el binario dev en foreground (logs directo a terminal)
RUST_LOG=debug ./daemon/target/release/lifeosd

# Cuando termines, restaurar:
systemctl --user start lifeosd
```

### Capa 3 — Requiere IMAGEN COMPLETA (rebuild + VM o bootc switch)

Cambios que afectan la capa inmutable:

| Componente | Por que requiere rebuild |
|-----------|-------------------------|
| Paquetes RPM (nuevos o actualizados) | Parte del layer OCI |
| Containerfile (estructura de imagen) | Definicion de la imagen |
| Modelos AI embebidos | Copiados al layer inmutable |
| Unit files base en `/usr/lib/systemd/` | Layer inmutable |
| GRUB/Plymouth themes | Boot chain inmutable |
| Kernel modules (NVIDIA) | Requiere signing |
| SKEL files (`/etc/skel/`) | Template para usuarios nuevos, solo aplica en first-boot |

---

## Flujo de Trabajo

### Diagrama de decision

```
¿Que cambie?
  |
  +-- Config/tema/layout → Fase 1 (copiar a ~/.config, reiniciar sesion)
  |
  +-- Codigo Rust (cli/daemon) → Fase 2 (make build + test manual)
  |
  +-- Containerfile / paquetes / scripts /usr → Fase 3 (imagen completa + VM o bootc switch)
  |
  +-- ANTES DE CADA PUSH → scripts/local-ci.sh
```

### Fase 0: Pre-flight local (ANTES de cada push — OBLIGATORIO)

```bash
./scripts/local-ci.sh         # Default: ~3-5 min
./scripts/local-ci.sh quick   # Solo fmt+lint: ~30s
./scripts/local-ci.sh full    # Default + release build + hadolint: ~10 min
```

**Lo que ejecuta internamente:**

| Paso | Replica de | Comando Make |
|------|-----------|--------------|
| 1 | ci.yml fmt-check | `make fmt-check` |
| 2 | ci.yml clippy (all features) | `make lint` |
| 3 | ci.yml CLI tests | `make test-cli` |
| 4 | ci.yml daemon tests | `make test-daemon` |
| 5 | ci.yml integration tests | `make test-integration` |
| 6 | ci.yml security audit | `make audit` |
| 7 | truth-alignment.yml | `scripts/check-truth-alignment.sh` |
| 8 | hadolint (en docker.yml) | `hadolint image/Containerfile` |
| 9 | shellcheck (extra) | `shellcheck` en scripts cambiados |

**Diseno clave:** Cada paso escribe stdout+stderr a un log temporal. Si pasa, no se imprime nada (ruido minimo). Si falla, se imprime el log completo del paso que fallo. **Nunca se ocultan errores.**

Si falla, los logs se preservan en `.local-ci-logs/` para inspeccion posterior.

### Fase 1: Testing de cambios mutables (config, layout, tema)

```bash
# 1. Editar archivos en el repo (por ejemplo config COSMIC en skel)
vim image/files/etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/opacity

# 2. Copiar al sistema
cp image/files/etc/skel/.config/cosmic/com.system76.CosmicPanel.Panel/v1/opacity \
   ~/.config/cosmic/com.system76.CosmicPanel.Panel/v1/opacity

# 3. Cerrar y abrir sesion para ver el cambio

# 4. Si se ve bien → commit + push (con Fase 0 antes)
```

### Fase 2: Testing de cambios en Rust

```bash
# 1. Editar codigo en cli/ o daemon/
vim daemon/src/api/mod.rs

# 2. Pre-flight local
./scripts/local-ci.sh

# 3. Si pasa, build release
make build-daemon

# 4. Probar el daemon local manualmente
systemctl --user stop lifeosd
RUST_LOG=debug ./daemon/target/release/lifeosd
# (probar endpoints, SimpleX, dashboard, etc)
# Ctrl+C cuando termine

# 5. Restaurar service oficial
systemctl --user start lifeosd

# 6. Commit + push
```

### Fase 3: Testing de cambios en imagen inmutable

Requiere build completo de la imagen. Hay **DOS caminos**, el usuario elige segun que quiera validar:

#### Opcion A — VM con ISO (aislado, no toca la laptop)

**Ideal para:** testing de first-boot, scripts de setup, experiencia de instalacion.

```bash
# 1. Pre-flight
./scripts/local-ci.sh

# 2. Build imagen
make docker-build
# Alternativa: podman build -t localhost/lifeos:dev -f image/Containerfile .

# 3. Generar ISO
# (Este comando lo corre el usuario — requiere sudo)
sudo bash scripts/generate-iso-simple.sh --image localhost/lifeos:dev

# 4. Lanzar VM con la ISO
bash scripts/vm-test-reset.sh run --memory 8192 --vcpus 4

# 5. Probar dentro de la VM: first-boot, layout, servicios, etc.
# 6. Si todo OK → commit + push
```

#### Opcion B — `bootc switch` local (testing en el hardware real)

**Ideal para:** testing de NVIDIA, GPU, hardware especifico, actualizacion real.

```bash
# 1. Pre-flight
./scripts/local-ci.sh

# 2. Build imagen
make docker-build

# 3. Cambiar la laptop a la imagen local
# (Este comando lo corre el usuario — requiere sudo)
sudo bootc switch --transport containers-storage localhost/lifeos:dev

# 4. Reiniciar
sudo reboot

# 5. Probar todo en el sistema real

# 6a. Si funciona → commit + push
# 6b. Si algo se rompe → rollback SIEMPRE disponible:
sudo bootc rollback
sudo reboot
```

**Importante:** `bootc rollback` te devuelve al deployment anterior. Nunca te queda tu laptop rota — siempre podes volver atras al estado previo al `switch`.

---

## Proteccion contra resets de COSMIC

**Problema detectado:** los updates de paquetes COSMIC upstream pueden sobreescribir config del usuario (como paso hoy — `plugins_wings`, `opacity`, etc se reescribieron en el boot post-update).

### Solucion: pre-upgrade snapshot de `~/.config/cosmic/`

En vez de intentar detectar "reset vs cambio del usuario" (que es genuinamente dificil), adoptamos una estrategia simple:

1. **ANTES** de cada `bootc upgrade --apply`, el script de update (`scripts/update-lifeos.sh` o el daemon `updates.rs`) debe:
   - Hacer snapshot de `~/.config/cosmic/` → `~/.local/share/lifeos/cosmic-snapshots/pre-upgrade-{timestamp}/`
   - Guardar el SHA de los paquetes COSMIC actuales en un archivo `.cosmic-rpm-versions`

2. **DESPUES** del reboot, en el primer login, un user service (`lifeos-cosmic-post-upgrade.service`) revisa:
   - ¿Cambiaron las versiones de los paquetes COSMIC desde el snapshot?
   - Si cambiaron: notificacion al usuario
     > "LifeOS detecto que COSMIC se actualizo. Si tu configuracion del panel/dock cambio sin querer, podes restaurarla con: `life cosmic restore-snapshot`"
   - Si NO cambiaron: no hacer nada

3. **Comando manual de restore** en el CLI:
   ```bash
   life cosmic list-snapshots              # Listar snapshots disponibles
   life cosmic restore-snapshot <timestamp> # Restaurar uno especifico
   ```

**Por que esta aproximacion es mejor que "detectar resets automaticamente":**
- Distinguir un reset de COSMIC de un cambio legitimo del usuario es imposible sin falsos positivos
- El snapshot + notificacion da al usuario **control** en vez de "magia" que podria revertir cambios deseados
- Es implementable sin heuristicas fragiles

**Archivos a crear** (para futura implementacion, fuera del scope de este PRD):
- `image/files/usr/local/bin/lifeos-cosmic-snapshot.sh` — hacer snapshot
- `image/files/usr/local/bin/lifeos-cosmic-restore.sh` — restaurar snapshot
- `image/files/usr/lib/systemd/user/lifeos-cosmic-post-upgrade.service` — detectar y notificar
- Nuevo subcomando `life cosmic {list-snapshots,restore-snapshot}` en el CLI

---

## Requisitos del entorno

**La laptop ya tiene todo lo necesario** porque LifeOS empaqueta:
- Rust toolchain con `rustup` + `rust-toolchain.toml` pineado a 1.85.1 (auto-switch)
- Podman + buildah (para `make docker-build`)
- QEMU + libvirt (para VMs)
- Todas las `-devel` libraries para compilar el daemon con todas las features
- `cargo-audit` (cuando se hizo `make dev-setup`)

**Opcionales (instalar si no estan):**
- `hadolint` — lint del Containerfile. Instalar via flatpak o binario de GitHub
- `shellcheck` — ya viene en base Fedora, si no: `dnf install shellcheck`

### Espacio en disco

- Build de binarios Rust: ~5 GB (target/ + cache de cargo)
- Build de imagen completa: ~20-30 GB (layers de podman + modelos AI ~4 GB)
- VM de testing: ~50 GB (disco virtual default)
- **Total recomendado libre:** 100 GB para trabajar comodo

### Tiempos estimados

| Operacion | Primera vez | Con cache |
|-----------|-------------|-----------|
| `./scripts/local-ci.sh quick` | 1 min | 30 s |
| `./scripts/local-ci.sh` (default) | 8-10 min | 3-5 min |
| `./scripts/local-ci.sh full` | 15 min | 8-10 min |
| `make build` (cli+daemon) | 5-10 min | 1-2 min |
| `make docker-build` | 30-60 min | 5-15 min |
| ISO generation | 5-10 min | 3-5 min |
| VM boot + test | 2-5 min | 2-5 min |

---

## Resumen ejecutivo

| Situacion actual | Situacion propuesta |
|-----------------|-------------------|
| Push → esperar 6h CI → fix → re-push → esperar | `scripts/local-ci.sh` (5 min) → push → CI verde |
| Update laptop → cosas rotas | Probar en VM o `bootc switch` primero → update seguro |
| No hay forma de probar imagen completa | `make docker-build` + VM o `bootc switch` |
| COSMIC config se rompe en updates | Pre-upgrade snapshot + restore manual via `life cosmic restore-snapshot` |
| Workflows rojos en GitHub, iterar de mas | Solo se pushea lo que paso validacion local |

---

## Prioridades de implementacion

1. **`scripts/local-ci.sh`** ✅ — Creado en este PRD
2. **Adopcion del flujo** — Empezar a correr `local-ci.sh` antes de cada push desde YA
3. **Snapshot de COSMIC** — Implementar en siguiente iteracion (scope aparte)
4. **Integrar `make local-ci`** — Agregar target al Makefile que llame al script

---

## Notas tecnicas

### `bootc switch` vs `bootc upgrade`

- `bootc switch` cambia a una imagen completamente nueva (incluso de otro transport/registry)
- `bootc upgrade` busca nueva version del MISMO origen configurado
- Para testing local, `bootc switch --transport containers-storage localhost/lifeos:dev` es ideal porque usa la imagen local de podman sin subirla a ningun registry
- **SIEMPRE se puede hacer rollback**: `sudo bootc rollback && sudo reboot`

### Sudo y permisos

El usuario corre los comandos `sudo` manualmente (ver CLAUDE.md). Los comandos que requieren sudo son:

- `sudo bash scripts/generate-iso-simple.sh ...`
- `sudo bootc switch ...`
- `sudo bootc rollback`
- `sudo reboot`

Los demas comandos (`make build`, `./scripts/local-ci.sh`, `make docker-build` con podman rootless) NO requieren sudo.

### Flatpak sandbox

Si se esta ejecutando desde un VSCode en Flatpak, los comandos del host necesitan `flatpak-spawn --host`. El Makefile y `local-ci.sh` asumen ejecucion desde la terminal del host — ejecutar desde una terminal normal, no desde el terminal integrado de VSCode Flatpak.
