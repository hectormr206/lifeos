# Instalación del runtime de LifeOS — CachyOS

**Estado:** Guía completa (Fase 3 del PRD, v1).
**Host de referencia:** CachyOS (rolling). Otros perfiles de distribución son trabajo futuro, no promesas actuales.

LifeOS no reemplaza tu distro. Es una capa de runtime de IA personal que corre
encima de Linux. Esta guía cubre la instalación reproducible de ese runtime
en CachyOS con GPU NVIDIA.

---

## Tabla de contenidos

1. [Requisitos previos](#1-requisitos-previos)
2. [Build e instalación de paquetes](#2-build-e-instalación-de-paquetes)
3. [Configuración de CDI para NVIDIA](#3-configuración-de-cdi-para-nvidia)
4. [Primera ejecución — `life init`](#4-primera-ejecución--life-init)
5. [Validación V1](#5-validación-v1)
6. [Troubleshooting](#6-troubleshooting)
7. [Respaldo de `memory.db`](#7-respaldo-de-memorydb)
8. [Desinstalación](#8-desinstalación)

---

## 1. Requisitos previos

### Hardware mínimo

| Componente | Mínimo | Recomendado |
|------------|--------|-------------|
| GPU NVIDIA | VRAM 4 GB | 8 GB (para Qwen3.5-9B) |
| RAM | 8 GB | 16 GB |
| Almacenamiento | 80 GB libres | 150 GB NVMe |

### Sistema base

| Requisito | Versión mínima | Verificación |
|-----------|----------------|--------------|
| CachyOS | Rolling (kernel ≥ 6.10) | `uname -r` |
| Driver NVIDIA (`nvidia-dkms`) | ≥ 550.x | `nvidia-smi` |
| `podman` | ≥ 5.0 | `podman --version` |
| `systemd` | ≥ 254 | `systemctl --version` |
| `nvidia-container-toolkit` | ≥ 1.16.0 | `nvidia-ctk --version` |

### Instalar `nvidia-container-toolkit` desde AUR

```bash
paru -S nvidia-container-toolkit
```

Si el build de AUR falla por desajuste con el driver instalado, usá la
variante binaria como alternativa:

```bash
paru -S nvidia-container-toolkit-bin
```

Verificación:

```bash
nvidia-ctk --version
nvidia-smi
podman --version
```

Los tres comandos deben salir sin error. Si `nvidia-smi` no responde, el
driver no está cargado — revisá `dmesg | grep nvidia` antes de continuar.

---

## 2. Build e instalación de paquetes

### Clonar el repositorio

```bash
git clone https://github.com/hectormr206/lifeos
cd lifeos
```

### Orden de instalación (dependencias entre paquetes)

Los PKGBUILDs están en `packaging/cachyos/`. Se deben construir e instalar
en este orden exacto:

```
1. lifeos-cli
2. lifeos-daemon
3. lifeos-desktop
4. lifeos-containers
5. lifeos-runtime   ← meta-paquete, instala las dependencias del sistema
```

### Build por paquete

Para cada directorio bajo `packaging/cachyos/`:

```bash
cd packaging/cachyos/lifeos-cli
makepkg -si
```

Salida esperada al terminar:

```
==> Instalando lifeos-cli con pacman -U ...
[sudo] contraseña para <tu_usuario>:
cargando paquetes...
resolviendo dependencias...
buscando conflictos entre paquetes...
Paquetes (1) lifeos-cli-0.X.Y-1
Tamaño total de instalación: X.XX MiB
:: ¿Continuar con la instalación? [S/n] S
==> lifeos-cli instalado exitosamente.
```

Repetí el mismo paso (`makepkg -si`) en cada carpeta, en el orden indicado.
El meta-paquete `lifeos-runtime` al final instala `podman` y
`nvidia-container-toolkit` si aún no están presentes.

### Alternativa con paru (un solo paso por paquete)

Si preferís gestionar todo desde paru:

```bash
# Desde cada directorio de PKGBUILD:
paru -U ./*.pkg.tar.zst   # si ya compilaste con makepkg
# o directamente:
cd packaging/cachyos/lifeos-cli && paru -U .
```

### Verificar instalación

```bash
life --version
lifeosd --version
```

Ambos deben imprimir la versión sin error.

---

## 3. Configuración de CDI para NVIDIA

CDI (Container Device Interface) permite que los contenedores rootless de
podman accedan a la GPU NVIDIA sin privilegios adicionales.

### Generar la especificación CDI

Este comando requiere sudo (escribe en `/etc/cdi/`):

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

### Verificar que la especificación se generó

```bash
ls -la /etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

La salida de `cdi list` debe incluir `nvidia.com/gpu=all`.

### Probar acceso a la GPU desde un contenedor rootless

```bash
podman run --rm \
  --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.0.0-base-ubi9 \
  nvidia-smi
```

Salida esperada: la tabla de `nvidia-smi` con el modelo de GPU, versión del
driver, y VRAM disponible. Si el contenedor falla con
`Error: setting up CDI devices`, revisá la sección 6.1 de troubleshooting.

### Actualización automática del CDI

El paquete `lifeos-containers` instala un watcher de systemd en el host que
regenera `/etc/cdi/nvidia.yaml` automáticamente cuando se actualiza el driver:

```bash
systemctl status lifeos-cdi-refresh.path
```

Estado esperado: `active (waiting)`. No requiere intervención manual tras
actualizaciones de kernel o driver.

---

## 4. Primera ejecución — `life init`

`life init` realiza la inicialización completa del runtime: detecta el sistema
operativo, valida los requisitos previos, verifica la pertenencia al grupo
`lifeos`, despliega los Quadlets de usuario automáticamente, crea los
directorios de estado, activa los servicios de systemd --user, e inicia los
contenedores Quadlet.

### Ejecutar `life init`

```bash
life init
```

### Salida esperada (flujo exitoso)

```
[1/7] Detectando sistema operativo... OK (CachyOS)
[2/7] Validando requisitos previos...
  podman 5.3.1              OK
  nvidia-smi (driver 560.x) OK
  nvidia-ctk 1.16.2         OK
  /etc/cdi/nvidia.yaml      OK
[3/7] Verificando pertenencia al grupo...
  ✓ group membership OK
[4/7] Desplegando Quadlets...
  ✓ Quadlets deployed   ← o "already-present" si ya estaban instalados
[5/7] Verificando sistema de archivos...
  /var/lib/lifeos/          OK
  /run/lifeos/              OK
[6/7] Activando servicios...
  lifeosd.service           habilitado + activo
  lifeos-llama-server       habilitado + activo
  lifeos-llama-embeddings   habilitado + activo
  lifeos-tts                habilitado + activo
  lifeos-simplex-bridge     habilitado + activo (sin cuenta SimpleX aún)
[7/7] Verificando salud (TCP fan-out)...
  lifeosd     :8081  HEALTHY
  llama-server :8082  HEALTHY
  embeddings  :8083  HEALTHY
  tts         :8084  HEALTHY
  simplex-bridge activo (no hay TCP check)

Dashboard: http://127.0.0.1:8081/dashboard?token=<bootstrap_token>
```

### Flags disponibles

| Flag | Efecto |
|------|--------|
| `--no-containers` | Solo activa `lifeosd`; omite los contenedores Quadlet |
| `--json` | Salida en formato JSON machine-readable |

### Sobre SimpleX

Si `lifeos-simplex-bridge` está activo pero sin cuenta pareada, `life init`
imprime un aviso con el comando de pairing. Completar el pairing es opcional
para el funcionamiento del resto del sistema.

### Segundo `life init` (idempotente)

Si ejecutás `life init` en un sistema ya inicializado, re-valida el estado y
re-imprime la URL del dashboard. No deshabilita ni reinicia servicios que ya
estén corriendo.

### Defaults de privacidad en primera instalación

LifeOS no captura el micrófono ni dispara notificaciones de escritorio sin tu
consentimiento explícito. En la primera ejecución, ambas funciones están **OFF
por defecto**.

| Feature | Default | Cómo activar |
|---------|---------|--------------|
| Captura de voz / wake word | **OFF** | Dashboard → Sistema → Voz, o `LIFEOS_ENABLE_VOICE=1` en `/etc/lifeos/daemon.toml` (`voice_enabled = true`) |
| Notificaciones de escritorio | **OFF** | Dashboard → Sistema → Notificaciones, o `LIFEOS_DESKTOP_NOTIFICATIONS=1` (`proactive_notifications_enabled = true`) |

Las comprobaciones de salud del sistema (disco, RAM, temperatura, etc.) **siguen
corriendo** en segundo plano y sus alertas son visibles en el panel del
dashboard (`/api/v1/security/alerts`). Lo único que se suprime con estos
defaults es el pop-up de escritorio (`notify-send`).

Para activar ambas funciones permanentemente, editá `/etc/lifeos/daemon.toml`:

```toml
voice_enabled = true
proactive_notifications_enabled = true
```

O via variables de entorno al iniciar el servicio:

```ini
# /etc/systemd/system/lifeosd.service.d/override.conf
[Service]
Environment=LIFEOS_ENABLE_VOICE=1
Environment=LIFEOS_DESKTOP_NOTIFICATIONS=1
```

---

## 5. Validación V1

Usá el script de validación para verificar los cinco escenarios de aceptación:

```bash
make validate-cachyos
# o directamente:
bash scripts/validate-cachyos.sh
```

Modo JSON para automatización:

```bash
bash scripts/validate-cachyos.sh --json
```

### 5.1 — B1: Instalación aceptada

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "x-bootstrap-token: $LIFEOS_BOOTSTRAP_TOKEN" \
  http://127.0.0.1:8081/api/v1/health
```

Salida esperada: `200`

### 5.2 — B2: Dashboard accesible

Abrí `http://127.0.0.1:8081/dashboard?token=<bootstrap_token>` en el
navegador. El dashboard debe cargar sin errores de consola y mostrar el
estado del daemon (conectado, uptime visible).

Verificación por línea de comandos:

```bash
curl -s http://127.0.0.1:8081/dashboard?token=$LIFEOS_BOOTSTRAP_TOKEN | grep -c "LifeOS"
```

Salida esperada: `1` o más (el título del SPA aparece en el HTML).

### 5.3 — B3: Bucle de memoria (`health_fact_add`)

Enviá un hecho de salud a Axi por el dashboard y verificá que persiste:

```bash
# Enviar el mensaje (reemplazá <token> con tu bootstrap token)
curl -s -X POST http://127.0.0.1:8081/api/v1/overlay/chat \
  -H "Content-Type: application/json" \
  -H "x-bootstrap-token: $LIFEOS_BOOTSTRAP_TOKEN" \
  -d '{"message": "soy alérgico a la lactosa"}'
```

Esperá ~30 segundos para que el LLM invoque la herramienta `health_fact_add`.
Luego verificá la persistencia directamente en la base de datos:

```bash
DB_PATH="${LIFEOS_DATA_DIR:-/var/lib/lifeos}/memory.db"
[ -f "$DB_PATH" ] || DB_PATH="$HOME/.local/share/lifeos/memory.db"

sqlite3 "$DB_PATH" \
  "SELECT id, label, created_at FROM health_facts WHERE label LIKE '%lactosa%' LIMIT 5;"
```

Salida esperada: al menos una fila con contenido sobre lactosa.

**Prueba de persistencia tras reinicio:**

```bash
systemctl --user restart lifeosd.service
# Esperar que suba (life init re-valida o ver journalctl)
sqlite3 "$DB_PATH" \
  "SELECT label FROM health_facts WHERE label LIKE '%lactosa%';"
```

El registro debe seguir presente.

### 5.4 — B4: Bucle remoto SimpleX

> Requiere que SimpleX esté pareado. Ver aviso de pairing en la salida de
> `life init`.

1. Enviá un mensaje desde tu cuenta SimpleX al contacto de Axi.
2. Axi debe responder dentro de 30 segundos.
3. Si el intercambio previo mencionó la alergia a la lactosa, la respuesta
   debe referenciarla.

Verificación por journal:

```bash
journalctl --user -u lifeos-simplex-bridge.service --since "5 minutes ago" -n 20
```

### 5.5 — B5: GPU Game Guard

> Requiere GPU NVIDIA con Qwen3.5-9B activo.

**Si tenés hardware compatible:**

```bash
# Verificar que el perfil activo es 9B GPU antes de lanzar el juego
journalctl --user -u lifeosd.service --since "10 minutes ago" | grep "profile"

# Lanzar un juego desde Steam y esperar ~10 segundos
# Luego verificar el swap a 4B CPU:
journalctl --user -u lifeosd.service --since "2 minutes ago" | grep "game guard"
```

Línea esperada en el journal: `game guard: swap to 4B CPU`

Cuando el juego cierra:

```bash
journalctl --user -u lifeosd.service --since "2 minutes ago" | grep "game guard"
```

Línea esperada: `game guard: restore to 9B GPU`

**Si no tenés hardware validable:** Game Guard permanece marcado como
`experimental` en el README hasta que se complete la validación en hardware
real. Ver advertencia en la sección de badges del README.

---

## 6. Troubleshooting

### 6.1 — Desajuste de versión en `nvidia-container-toolkit`

**Síntoma:** `podman run --device nvidia.com/gpu=all` falla con error sobre
librerías NVIDIA no encontradas.

**Diagnóstico:**

```bash
nvidia-ctk --version
nvidia-smi
# Compará la versión del toolkit vs la del driver instalado
pacman -Qi nvidia-container-toolkit
pacman -Qi nvidia-utils
```

**Solución:**

```bash
# Regenerar la especificación CDI con las rutas actualizadas
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Si sigue fallando, actualizar el toolkit:
paru -Syu nvidia-container-toolkit
```

Si el AUR build falla, usar la variante binaria:

```bash
paru -S nvidia-container-toolkit-bin
```

### 6.2 — Usuario no está en el grupo `lifeos`

**Síntoma:** `life init` sale con código 2 y:

```
✗ user not in 'lifeos' group — /var/lib/lifeos/ requires it
  Fix: sudo usermod -aG lifeos $USER  (then logout/login)
```

**Causa:** El daemon escribe estado en `/var/lib/lifeos/` que tiene permisos
`drwxrwx--- lifeos:lifeos`. El usuario necesita pertenecer al grupo `lifeos`.

**Solución:**

```bash
sudo usermod -aG lifeos $USER
# Luego hacé logout/login (o newgrp lifeos para la sesión actual)
```

Después volvé a ejecutar `life init`.

### 6.3 — `/run/lifeos/` o `/var/lib/lifeos/` faltante

**Síntoma:** `life init` imprime:

```
Error: /run/lifeos/ no existe. Ejecutá:
  sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/lifeos.conf
```

**Causa:** `systemd-tmpfiles --create` no se ejecutó durante la instalación
del paquete (puede pasar si instalaste sin `makepkg -si` y saltaste los hooks
de post-install).

**Solución:**

```bash
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/lifeos.conf
```

### 6.4 — `lifeosd` no responde en 30 segundos

**Síntoma:** `life init` sale con código 1 y:

```
lifeosd no se volvió saludable en 30s — revisá: journalctl --user -u lifeosd.service
```

**Diagnóstico:**

```bash
journalctl --user -u lifeosd.service -n 50
systemctl --user status lifeosd.service
```

Causas comunes:
- **Puerto 8081 ocupado:** `ss -tlnp | grep 8081`
- **Modelo no descargado:** el daemon espera `llama-server` en `:8082`; si el
  modelo GGUF no está en `/var/lib/lifeos/models/`, el contenedor no levanta.
  Ver `journalctl --user -u lifeos-llama-server.service`.
- **CDI no configurado:** `lifeos-llama-server` necesita acceso GPU. Ver 6.1.

**Solución rápida:**

```bash
systemctl --user daemon-reload
systemctl --user restart lifeosd.service
# Esperar 30s y verificar
systemctl --user is-active lifeosd.service
```

### 6.5 — Advertencias de SELinux o `rpm -V` en el journal

**Síntoma:** El journal de `lifeosd` muestra alertas sobre SELinux o `rpm -V`.

**Causa:** El daemon incluye checks de seguridad diseñados para Fedora (donde
`rpm -V` y SELinux son estándar). En CachyOS, ambas herramientas están
ausentes, lo que antes generaba alertas falsas.

**Estado en la versión actual:** desde Fase 3 (PR-1), el daemon detecta
automáticamente que está en un host Arch-based y marca esos checks como
`no aplica` en lugar de emitir alertas. Si ves estas advertencias en la
versión instalada, actualizá al build más reciente.

### 6.6 — `life init` imprime la URL del dashboard sin `?token=…`

**Síntoma:** Al final de un `life init` exitoso, ves:

```
Dashboard: http://127.0.0.1:8081/dashboard
⚠ bootstrap token not found — set LIFEOS_BOOTSTRAP_TOKEN or read it from
  $XDG_RUNTIME_DIR/lifeos/bootstrap.token
```

Abrir esa URL en el browser devuelve `401 Unauthorized` — el daemon exige el
token de bootstrap para servir `/dashboard` y `/api/v1/*`.

**Causa:** `life init` resuelve el token en este orden:

1. Variable de entorno `LIFEOS_BOOTSTRAP_TOKEN`
2. `$XDG_RUNTIME_DIR/lifeos/bootstrap.token`
3. `$HOME/.local/state/lifeos/runtime/bootstrap.token`
4. `/run/lifeos/bootstrap.token`

Si ninguno está disponible (primer arranque antes de que el daemon escriba
el archivo, o sesión sin `XDG_RUNTIME_DIR` exportado), `life init` imprime
la URL sin token y avisa.

**Solución:**

```bash
# Esperá a que el daemon escriba el token (suele tardar < 1s)
ls -la "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lifeos/bootstrap.token"

# Leelo y armá la URL completa:
TOKEN="$(< "${XDG_RUNTIME_DIR}/lifeos/bootstrap.token")"
echo "http://127.0.0.1:8081/dashboard?token=${TOKEN}"
```

O exportá la variable antes de re-ejecutar `life init`:

```bash
export LIFEOS_BOOTSTRAP_TOKEN="$(< "${XDG_RUNTIME_DIR}/lifeos/bootstrap.token")"
life init
```

### 6.6 — `lifeosd` no arranca después de restart: "UDS bind failed ... refusing to remove"

**Síntoma:** El journal de `lifeosd` muestra:

```
ERROR lifeosd::api] UDS bind failed at /run/lifeos/lifeosd.sock
(/run/lifeos/lifeosd.sock is owned by uid=1000 (expected root); refusing to remove);
daemon will not start
```

**Causa (resuelto en versiones recientes):** verificación de propiedad del socket era system-scope only. El daemon en user-scope se creó el socket previo como tu usuario, pero la siguiente instancia rechazaba removerlo porque "esperaba root". Bug clásico de cuando LifeOS migró de system-scope (bootc) a user-scope (runtime pivot).

**Solución temporal (si seguís en una versión vieja):**

```bash
systemctl --user stop lifeosd
rm -f /run/lifeos/lifeosd.sock
systemctl --user start lifeosd
```

**Solución permanente:** actualizar al build más reciente — la verificación ahora distingue user-scope (acepta socket propio) vs system-scope (mantiene la check anti-substitution).

---

## 7. Respaldo de `memory.db`

La base de datos de memoria es el activo más valioso del runtime. Respaldala
regularmente:

```bash
DB_PATH="${LIFEOS_DATA_DIR:-/var/lib/lifeos}/memory.db"
[ -f "$DB_PATH" ] || DB_PATH="$HOME/.local/share/lifeos/memory.db"

# Respaldo con fecha
cp "$DB_PATH" "$HOME/lifeos-memory-$(date +%Y%m%d).db"
```

Para un respaldo consistente mientras el daemon está corriendo, usá el
checkpoint de WAL:

```bash
sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);"
cp "$DB_PATH" "$HOME/lifeos-memory-$(date +%Y%m%d).db"
```

---

## 8. Desinstalación

Usá `life uninstall` para remover el runtime de forma guiada e idempotente.
El comando detiene servicios, elimina los Quadlets del usuario, imprime el
comando de pacman para ejecutar manualmente, y te pregunta si querés borrar
los datos persistentes.

### Uso básico

```bash
life uninstall
```

Salida esperada (flujo interactivo):

```
[1/4] Stopping services...
  ✓ stopped lifeosd.service
  ✓ stopped lifeos-llama-server.service
  ⊘ lifeos-desktop.service not installed
  ...
[2/4] Removing Quadlet files...
  ✓ Quadlet files removed
[3/4] Package removal...
  → Run this command manually to remove all LifeOS packages:
sudo pacman -Rsn lifeos-runtime lifeos-containers lifeos-desktop lifeos-daemon lifeos-cli
[4/4] State directory...
  ¿Borrar también /var/lib/lifeos/ (memoria persistente, configs, vitales)? [y/N]
  > N
  ✓ /var/lib/lifeos/ preserved (use --purge to delete)
```

### Flags disponibles

| Flag | Efecto |
|------|--------|
| `--purge` | Borra `/var/lib/lifeos/` sin preguntar (elimina memoria + configs) |
| `--keep-data` | Preserva `/var/lib/lifeos/` sin preguntar |
| `--with-pacman` | Ejecuta `pacman -Rsn` automáticamente (requiere sudo) |
| `--json` | Salida machine-readable en JSON |

`--purge` y `--keep-data` son mutuamente excluyentes. Si se pasan juntos,
el comando sale con código 2.

### Política de datos persistentes

Por defecto, `life uninstall` **preserva** `/var/lib/lifeos/` para evitar
pérdida accidental de `memory.db` (historial de Axi, hechos de salud,
configuración). El directorio sobrevive a la desinstalación de paquetes.

Para eliminar todo incluyendo los datos:

```bash
life uninstall --purge
```

> **Atención:** `--purge` borra `memory.db` de forma permanente.
> Hacé un respaldo antes si querés conservar el historial de Axi
> (ver §7 Respaldo de `memory.db`).

### Modo JSON

```bash
life uninstall --keep-data --json
```

La salida incluye un objeto con campos: `services`, `quadlets_removed`,
`pacman_command`, `pacman_executed`, `state_decision`, `state_removed`,
`exit_code`.

### Códigos de salida

| Código | Significado |
|--------|-------------|
| 0 | Éxito completo |
| 1 | Parcial — algunos servicios no pudieron detenerse, limpieza continuó |
| 2 | Abortado — flags inválidas o error de argumento |

### Desinstalación manual (fallback)

Si `life uninstall` no está disponible (paquete ya removido), podés hacerlo
manualmente paso a paso:

```bash
# 1. Detener servicios
systemctl --user stop lifeosd.service \
  lifeos-llama-server.service lifeos-llama-embeddings.service \
  lifeos-tts.service lifeos-simplex-bridge.service

# 2. Remover Quadlets
lifeos-quadlet-uninstall
# o manualmente:
rm -f ~/.config/containers/systemd/lifeos-*.container
systemctl --user daemon-reload

# 3. Remover paquetes
sudo pacman -Rsn lifeos-runtime lifeos-containers lifeos-desktop lifeos-daemon lifeos-cli

# 4. Limpiar estado (opcional)
rm -rf /var/lib/lifeos ~/.config/lifeos
```

---

## 9. Actualización

`life host update` actualiza el runtime desde el código fuente del repositorio.
Es el camino de actualización para instalaciones CachyOS nativas (via `makepkg`),
a diferencia de `life update` que gestiona actualizaciones OTA por imagen bootc.

### ¿Qué hace?

1. **Pre-flight**: verifica árbol git limpio y rama `main`.
2. **Git pull**: `git fetch origin --quiet` + `git pull --ff-only origin main`.
   Si el SHA antes y después son iguales, sale con "ya estás al día".
3. **Detección de paquetes**: diff entre el SHA anterior y el nuevo. Cualquier
   archivo bajo `cli/`, `daemon/`, `desktop/`, `containers/`, o
   `packaging/cachyos/<pkg>/` marca el paquete correspondiente para rebuild.
   `lifeos-runtime` siempre se incluye cuando hay algún cambio.
4. **Rebuild en orden de dependencias**:
   ```
   lifeos-cli → lifeos-daemon → lifeos-desktop → lifeos-containers → lifeos-runtime
   ```
   Para cada paquete ejecuta:
   ```bash
   cd <repo>/packaging/cachyos/<pkgname>
   makepkg -si --noconfirm
   ```
   `makepkg -si` pide contraseña sudo para instalar — el usuario la provee
   interactivamente igual que en la instalación inicial.
5. **Restart de servicios** (solo los afectados):
   - `lifeos-daemon` → `systemctl --user restart lifeosd.service`
   - `lifeos-desktop` → `systemctl --user restart lifeos-desktop.service`
   - `lifeos-containers` → reinicia los 4 Quadlets de contenedores
6. **Health fanout**: verifica puertos y servicios, igual que `life init`.

### Uso

```bash
# Actualización completa
life host update

# Dry run — muestra qué se reconstruiría sin hacerlo
life host update --check

# Salida JSON (para automatización)
life host update --json

# Override del directorio del repo
life host update --repo /ruta/al/repo/lifeos
```

### Variables de entorno

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LIFEOS_REPO_DIR` | `~/dev/lifeos` | Directorio raíz del repo de LifeOS |

### Códigos de salida

| Código | Significado |
|--------|-------------|
| `0` | Éxito o no-op (ya al día) |
| `1` | Fallo parcial (algún paquete no compiló o servicio no reinició) |
| `2` | Pre-flight fallido (árbol sucio, rama incorrecta, repo no encontrado) |
