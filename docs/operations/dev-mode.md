# PRD: LifeOS Dev Mode — Dual-Image Architecture

**Version:** 1.0
**Fecha:** 2026-04-11
**Estado:** Propuesta — espera aprobacion del desarrollador

---

## La metafora guia

> "LifeOS se cura solo como los Axolotes — pero ese poder solo es del desarrollador que se apoya de IA para mejorar todos los errores. Los usuarios reciben un sistema cerrado, predecible, inmutable."

LifeOS Dev Mode es la encarnacion de esa idea: dos variantes del **mismo codigo base** construidas con flags distintos en build time, que dan al desarrollador autonomia total asistida por IA en su laptop, mientras que los usuarios finales siempre reciben un sistema locked-down.

---

## Problema

Hoy, cualquier cambio que la IA quiera probar en LifeOS requiere intervencion manual del desarrollador para cada operacion sudo (copiar archivos a `/etc/`, reiniciar services, hacer `bootc switch`, etc.). Esto crea dos problemas:

1. **Friccion de desarrollo**: cada iteracion "fix → test → verify" involucra copiar/pegar comandos sudo. Un dia de desarrollo es 60% coordinacion de shell y 40% trabajo real.

2. **La IA no puede cerrar el loop de diagnostico → fix → verify → commit**. Necesita al humano para operar el sistema real, lo cual hace imposible que la IA aprenda directamente de los fallos observados en runtime.

Al mismo tiempo, NO podemos darle esa misma autonomia a los usuarios finales:

- Los usuarios no tienen un contrato de confianza con la IA que pilotea el sistema.
- La superficie de ataque de "IA con sudo" es enorme si no esta cuidadosamente enmarcada.
- LifeOS vende "AI-native con privacidad y seguridad por defecto" — romper eso en los builds publicos es inaceptable.

---

## Vision

**Dos imagenes bootc construidas del mismo Containerfile, diferenciadas por un build argument:**

| Imagen | Build Arg | Destinatario | Poder de la IA | Donde vive |
|--------|-----------|--------------|----------------|-----------|
| **Release** | `LIFEOS_BUILD_MODE=release` (default) | Usuarios finales | IA tiene las mismas restricciones que un usuario cualquiera — sudo con password para todo | `ghcr.io/hectormr206/lifeos:{stable,candidate,edge}` |
| **Dev** | `LIFEOS_BUILD_MODE=dev` (opt-in explicito) | Solo el desarrollador (esta laptop) | IA tiene sudo NOPASSWD sobre un whitelist narrow de operaciones de desarrollo | `localhost/lifeos:dev` — **nunca** pusheado a ningun registry |

El desarrollador puede **bootc switch** entre las dos imagenes cuando quiera, y **bootc rollback** siempre esta disponible como safety net — si la IA hace algo catastrofico en dev mode, un reboot al deployment anterior arregla el estado del /usr.

---

## Goals

1. **Autonomia operacional de la IA** en el laptop del desarrollador, dentro de un whitelist auditable y revocable.
2. **Cero leak de dev affordances** a imagenes de produccion — garantizado por invariantes en build time y CI.
3. **Simetria total del codigo fuente**: ambas imagenes salen del mismo repo, del mismo commit, del mismo Containerfile. La unica diferencia es el valor del BUILD_ARG.
4. **Transicion trivial entre modos**: un solo `bootc switch` + reboot cambia de dev a release o viceversa.
5. **Rollback preservado**: bootc y btrfs snapshots siguen funcionando en ambos modos.
6. **Auditabilidad**: cada operacion sudo que la IA haga deja rastro en `journalctl` para post-incident review.

## Non-goals

- **NO** es un modo "permitir cualquier cosa". El whitelist es explicito y narrow.
- **NO** reemplaza el modelo de seguridad de LifeOS — es una extension opcional solo en laptops de desarrollo.
- **NO** incluye `reboot`, `dnf install`, `rpm-ostree`, `bootc upgrade --apply`, o escritura a paths arbitrarios — esas siempre requieren decision consciente del humano.
- **NO** expone SSH, puertos publicos, ni relaja el firewall.
- **NO** cambia el comportamiento del daemon ni del CLI en release mode — dev mode es un superset, no una ruta alternativa.

---

## Alternativas consideradas y rechazadas

### Alt 1 — Runtime env var (`LIFEOS_DEV_MODE=1`)

Una sola imagen, el modo se activa al arranque con una variable de entorno.

**Rechazada porque**: el archivo de sudoers estaria fisicamente presente en todas las imagenes, solo "desactivado" por convencion. Un proceso comprometido podria setear la env var y activarlo. Viola defensa en profundidad — el archivo **no debe existir** en release.

### Alt 2 — Containerfile separado (`Containerfile` + `Containerfile.dev`)

Dos archivos, el dev extiende el production.

**Rechazada porque**: duplicacion de 1200+ lineas, drift inevitable entre los dos, hard to maintain. En 6 meses los dos archivos se desincronizan y los usuarios reciben build bugs que solo existian en release porque el dev no los probaba.

### Alt 3 — Post-build OCI overlay

Release image es siempre la misma, dev mode es una capa OCI encima.

**Rechazada porque**: bootc no soporta layering transparente de ese modo hoy, complicaria el rollback (¿rollback a dev o a la base?), y el toolchain de podman/buildah no tiene primitives claros para esto.

### Alt 4 — Rust feature flag solo (`dev-mode` en daemon/Cargo.toml)

Usar feature flags de Cargo para gate codigo dev-only en el daemon, pero sin cambiar la imagen base.

**Rechazada como solucion UNICA** — resuelve el problema del codigo Rust pero no da acceso a sudoers ni a system services. Se adopta como **complemento** a Alt 5 para futuro codigo dev-only en el daemon (ej: endpoints de introspeccion).

### Alt 5 — Build-time BUILD_ARG ✅ **seleccionada**

Un solo `Containerfile`, un `ARG LIFEOS_BUILD_MODE` con valores `release` (default) o `dev`. Los pasos que dan poder dev (instalar sudoers, instalar helper, etc.) son gateados por `RUN if [ "${LIFEOS_BUILD_MODE}" = "dev" ]; then ...`.

**Por que es correcta**:
- Un solo archivo fuente, cero duplicacion
- Default seguro: olvidarse del flag da release
- El CI enforce-block al final del Containerfile valida que release **fisicamente no tiene** los archivos dev — si alguno se filtra, el build falla en build time
- Precedente: ya existe `LIFEOS_IMAGE_VARIANT` para el split AMD/NVIDIA y `LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64` para secure boot — la familia `LIFEOS_BUILD_MODE` encaja
- Standard en la industria: exactamente como Debian maneja `-dbg` packages, Windows maneja Checked vs Free builds, y Chromium maneja release vs developer builds

---

## Arquitectura

### 1. Containerfile — build arg + condicionales

```dockerfile
# Near the top, con los otros ARGs globales:
ARG LIFEOS_BUILD_MODE=release

# ... resto de los stages ...

# Dev-mode artifacts — copied to staging unconditionally, installed OR deleted
# based on build mode. Release builds MUST NOT contain these files.
COPY image/files/etc/sudoers.d/lifeos-dev /tmp/lifeos-dev-sudoers-staging

RUN if [ "${LIFEOS_BUILD_MODE}" = "dev" ]; then \
        install -m 440 -o root -g root \
            /tmp/lifeos-dev-sudoers-staging \
            /etc/sudoers.d/lifeos-dev && \
        visudo -c -f /etc/sudoers.d/lifeos-dev && \
        echo "[build] DEV MODE — AI sudo whitelist installed"; \
    fi && \
    rm -f /tmp/lifeos-dev-sudoers-staging

# ... resto de los RUN de packages, configs, etc ...

# FINAL verification block (just before the [Install] directive).
# This is the hard guarantee that dev files never leak to release.
RUN if [ "${LIFEOS_BUILD_MODE}" = "release" ]; then \
        test ! -f /etc/sudoers.d/lifeos-dev || \
            (echo "FATAL: dev sudoers leaked into release build" && exit 1); \
        test ! -x /usr/local/bin/lifeos-dev-helper || \
            (echo "FATAL: dev helper leaked into release build" && exit 1); \
        echo "[build] release integrity verified (no dev affordances)"; \
    elif [ "${LIFEOS_BUILD_MODE}" = "dev" ]; then \
        test -f /etc/sudoers.d/lifeos-dev || \
            (echo "FATAL: dev sudoers missing from dev build" && exit 1); \
        echo "[build] dev integrity verified (sudo whitelist active)"; \
    else \
        echo "FATAL: LIFEOS_BUILD_MODE must be 'release' or 'dev', got '${LIFEOS_BUILD_MODE}'" && exit 1; \
    fi
```

### 2. El sudoers file — `image/files/etc/sudoers.d/lifeos-dev`

```
# LifeOS Developer Sudoers Policy
# ═══════════════════════════════════════════════════════════════════════
# ONLY installed when LIFEOS_BUILD_MODE=dev at image build time.
# Release images do NOT contain this file — enforced by the final
# verification block in image/Containerfile.
#
# This file grants passwordless execution of a narrow set of development
# operations to the `lifeos` user. It is intended to let an AI assistant
# (Claude Code) close the diagnose → fix → verify loop without human
# intervention for every sudo call.
#
# REVOCATION (emergency):
#     sudo rm /etc/sudoers.d/lifeos-dev
#     sudo bootc switch --transport containers-storage localhost/lifeos:release
#     sudo reboot
#
# AUDIT:
#     sudo journalctl _COMM=sudo | grep lifeos
#
# SCOPE — what is GRANTED:
#   - systemctl lifecycle on LifeOS system services
#   - install(1) into /etc/systemd/system/ from the lifeos repo checkout
#   - bootc switch to localhost/lifeos:{dev,release} only
#   - bootc rollback and bootc status
#   - journalctl read access for LifeOS services
#
# SCOPE — what is DENIED (intentionally, never add these):
#   - reboot / shutdown / halt
#   - bootc upgrade --apply  (touches production deployment state)
#   - bootc switch to any registry other than localhost containers-storage
#   - dnf / rpm / rpm-ostree  (package installation)
#   - Arbitrary file writes (cp, mv, tee, dd) to /etc, /usr, /boot
#   - chmod / chown of system files
#   - systemctl enable / disable / mask
#   - journalctl --vacuum-* / --flush / --rotate
#   - su / sudo to other users
#   - mount / umount of anything
#   - Any shell redirection via `sudo tee` or `sudo sh -c`
# ═══════════════════════════════════════════════════════════════════════

# Service lifecycle — start/stop/restart/reset-failed of known units
Cmnd_Alias LIFEOS_DEV_SVC_LIFECYCLE = \
    /usr/bin/systemctl daemon-reload, \
    /usr/bin/systemctl start llama-embeddings.service, \
    /usr/bin/systemctl stop llama-embeddings.service, \
    /usr/bin/systemctl restart llama-embeddings.service, \
    /usr/bin/systemctl reset-failed llama-embeddings.service, \
    /usr/bin/systemctl start llama-server.service, \
    /usr/bin/systemctl stop llama-server.service, \
    /usr/bin/systemctl restart llama-server.service, \
    /usr/bin/systemctl reset-failed llama-server.service, \
    /usr/bin/systemctl start nvidia-persistenced.service, \
    /usr/bin/systemctl stop nvidia-persistenced.service, \
    /usr/bin/systemctl restart nvidia-persistenced.service, \
    /usr/bin/systemctl start whisper-stt.service, \
    /usr/bin/systemctl stop whisper-stt.service, \
    /usr/bin/systemctl restart whisper-stt.service, \
    /usr/bin/systemctl reset-failed whisper-stt.service

# Read-only status queries — any service
Cmnd_Alias LIFEOS_DEV_SVC_STATUS = \
    /usr/bin/systemctl status *, \
    /usr/bin/systemctl list-units --state=failed, \
    /usr/bin/systemctl list-units --state=*, \
    /usr/bin/systemctl is-active *, \
    /usr/bin/systemctl is-failed *

# File install — ONLY from the repo checkout, ONLY to /etc/systemd/system/
# This is pinned to the absolute path of the repo so the AI cannot install
# files from arbitrary locations.
Cmnd_Alias LIFEOS_DEV_INSTALL = \
    /usr/bin/install -m 644 /var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/etc/systemd/system/*.service /etc/systemd/system/, \
    /usr/bin/install -m 644 /var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files/etc/systemd/system/*.conf /etc/systemd/system/

# bootc operations — ONLY local containers-storage, NO registry pulls
Cmnd_Alias LIFEOS_DEV_BOOTC = \
    /usr/bin/bootc switch --transport containers-storage localhost/lifeos\:dev, \
    /usr/bin/bootc switch --transport containers-storage localhost/lifeos\:release, \
    /usr/bin/bootc rollback, \
    /usr/bin/bootc status

# journalctl — read access for LifeOS services, no management flags
Cmnd_Alias LIFEOS_DEV_JOURNAL = \
    /usr/bin/journalctl -u llama-embeddings.service *, \
    /usr/bin/journalctl -u llama-server.service *, \
    /usr/bin/journalctl -u nvidia-persistenced.service *, \
    /usr/bin/journalctl -u lifeosd.service *, \
    /usr/bin/journalctl -u whisper-stt.service *, \
    /usr/bin/journalctl -b --no-pager -n *, \
    /usr/bin/journalctl -b -u * --no-pager

# Grant to the lifeos user only, NOPASSWD for the above aliases
lifeos ALL=(root) NOPASSWD: \
    LIFEOS_DEV_SVC_LIFECYCLE, \
    LIFEOS_DEV_SVC_STATUS, \
    LIFEOS_DEV_INSTALL, \
    LIFEOS_DEV_BOOTC, \
    LIFEOS_DEV_JOURNAL

# Log every NOPASSWD invocation to the audit trail for post-incident review
Defaults:lifeos log_output
Defaults:lifeos !lecture
Defaults:lifeos logfile=/var/log/lifeos/sudo-dev.log
```

### 3. Makefile — dos targets explicitos

```makefile
# Default is release — matches CI, never accidentally dev
docker-build: docker-build-release

docker-build-release:
	@echo "Building LifeOS RELEASE image (locked down, matches CI)"
	podman build \
	    --build-arg LIFEOS_BUILD_MODE=release \
	    --build-arg BUILD_DATE="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	    --build-arg VCS_REF="$$(git rev-parse --short HEAD)" \
	    -t localhost/lifeos:release \
	    -f image/Containerfile .

docker-build-dev:
	@echo ""
	@echo "⚠️  Building LifeOS DEV image"
	@echo "⚠️  This image contains an AI sudo whitelist at /etc/sudoers.d/lifeos-dev"
	@echo "⚠️  DO NOT push this image to any registry"
	@echo "⚠️  DO NOT share this image"
	@echo ""
	podman build \
	    --build-arg LIFEOS_BUILD_MODE=dev \
	    --build-arg BUILD_DATE="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	    --build-arg VCS_REF="$$(git rev-parse --short HEAD)-dev" \
	    -t localhost/lifeos:dev \
	    -f image/Containerfile .
	@echo ""
	@echo "Dev image built: localhost/lifeos:dev"
	@echo "To activate on this laptop:"
	@echo "    sudo bootc switch --transport containers-storage localhost/lifeos:dev"
	@echo "    sudo reboot"
	@echo ""
	@echo "To return to release mode:"
	@echo "    sudo bootc switch --transport containers-storage localhost/lifeos:release"
	@echo "    sudo reboot"
```

### 4. CI guard — workflows never build dev

En cada workflow que hace `podman build` o `docker build` (principalmente `docker.yml`, `release-channels.yml`, `nightly.yml`), agregamos un guard explicito:

```yaml
- name: Assert release build mode
  run: |
    # Fail CI loudly if someone accidentally sets dev mode in a workflow
    grep -r "LIFEOS_BUILD_MODE=dev" .github/workflows/ && \
        (echo "FATAL: dev mode must never be used in CI workflows" && exit 1)
    echo "CI build mode check passed"
```

Y en el comando de build:
```yaml
- name: Build LifeOS image
  run: |
    podman build \
        --build-arg LIFEOS_BUILD_MODE=release \
        ...
```

Pinear `release` explicitamente es mas defensive que confiar en el default.

### 5. Tag guard — never push `:dev`

En `release-channels.yml` y `docker.yml`, antes del push step:

```yaml
- name: Reject dev tags
  run: |
    for tag in $TAGS; do
      if echo "$tag" | grep -qE '(^|[-:])dev([-:]|$)'; then
        echo "FATAL: refusing to push dev-tagged image: $tag"
        exit 1
      fi
    done
```

### 6. Pre-commit hook (opcional pero recomendado)

En `.pre-commit-config.yaml` agregamos un hook local que busca `LIFEOS_BUILD_MODE=dev` en archivos de CI:

```yaml
- repo: local
  hooks:
    - id: reject-dev-mode-in-ci
      name: Reject LIFEOS_BUILD_MODE=dev in CI workflows
      entry: bash -c 'if grep -r "LIFEOS_BUILD_MODE=dev" .github/workflows/; then echo "dev mode must not be in CI workflows" && exit 1; fi'
      language: system
      files: '^\.github/workflows/.*\.ya?ml$'
      pass_filenames: false
```

---

## Invariantes de seguridad (la parte crítica)

Los siete invariantes que garantizan que dev mode **nunca** se escape a usuarios finales:

1. **Default seguro**: `ARG LIFEOS_BUILD_MODE=release` en el Containerfile. Olvidar el flag produce release.

2. **Build-time verification**: El RUN final del Containerfile comprueba que release builds **fisicamente no contienen** el archivo `/etc/sudoers.d/lifeos-dev`. Si esta, el build **falla**. Es imposible producir un release image con dev affordances.

3. **CI explicit pinning**: Cada workflow de CI pasa `--build-arg LIFEOS_BUILD_MODE=release` explicitamente. No depende del default.

4. **CI workflow scanner**: Un step de CI escanea `.github/workflows/` buscando `LIFEOS_BUILD_MODE=dev` y falla si encuentra. Un PR malicioso que intente activar dev mode en CI se rechaza automaticamente.

5. **Tag naming enforcement**: Los workflows rechazan push de cualquier tag que contenga `dev`. `localhost/lifeos:dev` **fisicamente no puede** llegar a `ghcr.io`.

6. **User scoping**: El sudoers file otorga NOPASSWD solo al usuario `lifeos`, no a ningun grupo ni `ALL`. Otros usuarios del sistema no heredan el poder.

7. **Comando scoping**: Las entradas del whitelist son operaciones especificas, no wildcards abiertos. `systemctl restart llama-embeddings.service` esta permitido; `systemctl restart <arbitrary>` no. `install <repo-path>/*.service /etc/systemd/system/` esta permitido; `install <arbitrary>` no.

Los invariantes 1-5 son **verificados por maquina**. 6-7 son **verificados por review manual** del sudoers file — y el archivo esta en el repo, auditable, con comentarios explicitos sobre lo que hace.

---

## Flujo de trabajo diario (desarrollador)

### Setup inicial (una vez)

```bash
# 1. Buildear la dev image
cd /var/home/lifeos/personalProjects/gama/lifeos/lifeos
make docker-build-dev

# 2. Switch a la dev image
sudo bootc switch --transport containers-storage localhost/lifeos:dev
sudo reboot

# 3. Verificar que dev mode esta activo
test -f /etc/sudoers.d/lifeos-dev && echo "DEV MODE ACTIVE" || echo "NOT dev mode"
sudo -l  # lista los comandos NOPASSWD disponibles
```

A partir de ahi, Claude Code puede operar sobre el scope del whitelist directamente — reiniciar services, instalar service files fixeados, switch entre imagenes, leer journals — todo sin pedirte cada vez.

### Ciclo de desarrollo normal

```
┌─ Claude lee el bug report
│
├─ Claude explora el codigo (no necesita sudo)
│
├─ Claude escribe el fix (no necesita sudo)
│
├─ Claude hace build local del daemon: make build-daemon (no necesita sudo)
│
├─ Claude instala el fix en runtime:
│     sudo install -m 644 .../image/files/etc/systemd/system/X.service /etc/systemd/system/
│     sudo systemctl daemon-reload
│     sudo systemctl restart X.service
│
├─ Claude verifica:
│     sudo systemctl status X.service
│     sudo journalctl -u X.service -n 50
│
├─ Si pasa → Claude corre local-ci.sh y commitea
│
└─ Si falla → Claude itera (volver al paso 3)
```

Todo esto sin interrumpirte cada 30 segundos.

### Testing del "user experience"

Cuando queres verificar que tu experiencia = la del usuario final:

```bash
make docker-build-release
sudo bootc switch --transport containers-storage localhost/lifeos:release
sudo reboot
```

Ahora tu laptop corre **exactamente** la imagen que los usuarios tendran. Sin sudoers whitelist, sin helpers dev, nada. Testas first-boot, UX, todo. Cuando terminas:

```bash
sudo bootc switch --transport containers-storage localhost/lifeos:dev
sudo reboot
```

Y volves a dev mode.

### Emergencia — algo se rompio

```bash
sudo bootc rollback && sudo reboot
```

Volves al deployment anterior (dev o release). Cero trabajo perdido — solo reverti lo ultimo.

Si el dev mode mismo esta causando problemas y queres deshabilitarlo **sin rebuild**:

```bash
sudo rm /etc/sudoers.d/lifeos-dev
```

Esto revoca el whitelist pero mantiene el resto de la imagen dev. Claude vuelve a necesitarte para cada sudo. Para restaurar: `sudo bootc rollback && sudo reboot` (vuelve a la imagen dev con el file).

---

## Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|--------------|---------|-----------|
| PR malicioso agrega `LIFEOS_BUILD_MODE=dev` a un workflow CI | Baja | Alto | CI workflow scanner + tag guard + review de PRs en .github/ |
| Alguien bindmounta `/etc/sudoers.d/lifeos-dev` en un container publico | Muy baja | Alto | Build-time verification (release builds no tienen el file) |
| Claude descubre una escalada via `install(1)` a `/etc/systemd/system/` | Media | Medio | El paso de `daemon-reload` + `restart` aun requiere el comando estar en el whitelist; una service unit maliciosa con `ExecStart=/bin/sh -c ...` seria detectable en PR review |
| Claude es prompt-injectado via un bug report y corre sudo | Baja | Medio | El whitelist limita el blast radius; btrfs snapshots + bootc rollback recuperan; audit log en `/var/log/lifeos/sudo-dev.log` permite forense |
| El archivo sudoers tiene un typo y bloquea sudo por completo | Baja | Bajo | `visudo -c -f` corre en build time — un syntax error hace fallar el build |
| Desarrollador olvida que esta en dev mode y asume release behaviour | Media | Bajo | `systemctl status` o `test -f /etc/sudoers.d/lifeos-dev` lo revelan en segundos; el dashboard podria mostrar un badge "DEV MODE" futuro |
| Update del ghcr.io/:edge pisa el dev mode sin querer | Baja | Bajo | Auto-updates de bootc estan masked por default en LifeOS; updates son operator-driven |

El punto mas delicado es el tercero — un Claude prompt-injectado que instala una service unit maliciosa. La mitigacion real es **PR review manual** de todo lo que toca `image/files/etc/systemd/system/` antes de que llegue a main. Dev mode asume buena fe del AI y humano-in-loop a traves de commits.

---

## Plan de implementacion (fases)

### Fase 1 — Estructura (1-1.5 h)

1. Crear `image/files/etc/sudoers.d/lifeos-dev` con el contenido del PRD.
2. Agregar `ARG LIFEOS_BUILD_MODE=release` al `image/Containerfile`.
3. Agregar el COPY de staging + RUN condicional de install.
4. Agregar el RUN final de verification.
5. Agregar targets `docker-build-release` y `docker-build-dev` al Makefile.
6. `make docker-build` (sin args) → validar que produce release mode correctamente.
7. `make docker-build-dev` → validar que produce dev mode correctamente.

### Fase 2 — CI guards (30 min)

1. Agregar tag guard al `release-channels.yml` y `docker.yml`.
2. Agregar workflow scanner que rechaza `LIFEOS_BUILD_MODE=dev` en cualquier workflow.
3. Pinear `LIFEOS_BUILD_MODE=release` explicitamente en cada workflow que buildea.
4. Opcional: pre-commit hook local.

### Fase 3 — Activacion en la laptop del desarrollador (manual, 1 comando)

1. El desarrollador corre `make docker-build-dev` (primera vez, ~30-60 min de build).
2. El desarrollador corre `sudo bootc switch --transport containers-storage localhost/lifeos:dev`.
3. El desarrollador hace `sudo reboot`.
4. Verifica que `sudo -l` muestra el whitelist.

Despues de este paso, la IA puede operar autonomo dentro del scope.

### Fase 4 — Documentacion y recovery (30 min)

1. Commit del PRD (este archivo).
2. Actualizar `docs/operations/local-dev-workflow.md` para mencionar dev mode.
3. Documentar recovery paths en `docs/operations/recovery.md` (si no existe, crearlo).
4. Entry en `CHANGELOG.md` marcando "LifeOS 0.4.1: introduced dev-mode dual-image architecture".

### Fase 5 — Evolucion futura (fuera de scope hoy)

- `lifeos-dev-helper` binario con subcomandos de alto nivel (`reinstall-unit`, `tail-journal`, etc.) — reduce el surface del sudoers.
- `#[cfg(feature = "dev-mode")]` endpoints en el daemon para introspeccion runtime.
- Badge visible "DEV MODE" en el dashboard cuando dev mode esta activo.
- Metricas de cuantos comandos sudo corrio la IA por sesion, para tracking.

---

## Open questions — necesitan decision tuya antes de implementar

1. **¿El scope del whitelist es correcto?** Revisa la lista en la seccion "El sudoers file". Comandos que faltan, o comandos que NO queres que la IA corra aunque esten en mi lista.

2. **¿Agregamos `lifeos-dev-helper` en Fase 1 o lo dejamos para Fase 5?** Mi voto: dejarlo para despues. Empezamos simple con sudoers puro.

3. **¿Dev mode incluye algo mas?** Ej:
   - `RUST_LOG=debug` default en `lifeosd` en dev mode
   - Dashboard `/dev/state` endpoint (Rust feature flag)
   - SSH daemon habilitado (mi voto: no)
   - Hot-reload de config sin restart

4. **¿Pre-commit hook si o no?** Mi voto: si. Pequeño costo, cacha errores antes de llegar a CI.

5. **¿El audit log va a `/var/log/lifeos/sudo-dev.log` o a `journalctl` solo?** Mi voto: a ambos. journalctl es lo estandar, el file dedicado facilita grep.

6. **¿Queremos que dev mode muestre un badge "DEV" visible en el dashboard?** Mi voto: si, para que el desarrollador no olvide en que modo esta. Pero puede ir en Fase 5.

---

## Criterios de exito

Considerar el sistema completo cuando:

- [ ] `make docker-build-dev` produce `localhost/lifeos:dev` con `/etc/sudoers.d/lifeos-dev` instalado.
- [ ] `make docker-build-release` produce `localhost/lifeos:release` **sin** el archivo (verificado por el RUN final del Containerfile).
- [ ] `make docker-build` (sin target explicito) es equivalente a `make docker-build-release`.
- [ ] En el laptop con dev image, `sudo -l` lista el whitelist y comandos fuera del whitelist siguen pidiendo password.
- [ ] CI workflow scanner rechaza un PR que agrega `LIFEOS_BUILD_MODE=dev` a un workflow.
- [ ] `release-channels.yml` rechaza un tag que contiene `dev`.
- [ ] `sudo bootc switch` entre dev y release funciona en ambas direcciones.
- [ ] `sudo bootc rollback` funciona en ambas direcciones.
- [ ] Claude Code puede correr las operaciones del whitelist sin pedir password al desarrollador.
- [ ] Claude Code **no puede** correr operaciones fuera del whitelist (siguen pidiendo password).
- [ ] Audit log en `/var/log/lifeos/sudo-dev.log` registra cada invocacion de la IA.

---

## Referencias

- **Precedentes de la industria**: Debian `-dbg` packages, Windows Checked vs Free builds, Chromium developer builds, Android userdebug vs user builds.
- **Archivos del repo relacionados**:
  - `image/Containerfile` — build stages y args actuales
  - `image/files/etc/sudoers.d/lifeos-axi` — sudoers precedente (least-privilege, referencia del estilo)
  - `docs/operations/local-dev-workflow.md` — PRD del workflow local-ci.sh
  - `docs/operations/pending-items-roadmap.md` — roadmap que dev mode viene a destrabar
- **Memoria relacionada**: `reference_sudo_policy.md` en la memoria del proyecto — "LifeOS sudo policy and rules: least privilege model, specific commands only in /etc/sudoers.d/lifeos-axi".

---

## Cierre

Este PRD propone una arquitectura que le da a LifeOS la capacidad auto-regenerativa del axolote **solo en la estacion de trabajo del desarrollador**, manteniendo la imagen publica tan locked-down como hoy. La simetria entre las dos imagenes es total al nivel del codigo fuente, y la asimetria al nivel del sistema vivo es producida por un solo flag de build — auditable, revocable, y protegido por invariantes en build time y CI.

Si lo apruebas, arranco con Fase 1.
