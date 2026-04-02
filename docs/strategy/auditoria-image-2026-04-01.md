# Auditoria Profunda: Imagen y Shipping Real

**Fecha de corte:** `2026-04-01`  
**Entradas principales:** [image/Containerfile](../../image/Containerfile), [image/files/](../../image/files/)

## Resumen

La imagen de LifeOS ya representa una parte sustancial del producto.

No solo empaqueta binarios:

- construye `life` y `lifeosd`
- compila `llama-server`
- compila `whisper-cli`
- instala modelos/runtime auxiliares
- aplica branding y temas
- habilita servicios y timers
- agrega hardening de seguridad
- deja wiring para first-boot, maintenance, updates y AI runtime

## Lo mas fuerte de la imagen

### 1. Build de sistema real, no mock

La imagen:

- usa `Fedora bootc`
- construye componentes desde el propio repo
- integra runtime local de IA y STT/TTS
- produce artefactos para `iso`, `raw`, `qcow2`, `vmdk`

Esto esta claramente respaldado por:

- [image/Containerfile](../../image/Containerfile)
- [scripts/build-iso.sh](../../scripts/build-iso.sh)
- [docs/operations/build-iso.md](../operations/build-iso.md)

### 2. Shipping default bien definido

La imagen default compila `lifeosd` con:

`dbus,http-api,ui-overlay,wake-word,speaker-id,telegram,tray`

Eso permite hablar con precision sobre lo que realmente forma parte de la experiencia default.

### 3. Servicios, seguridad y mantenimiento

Se observan capas reales para:

- `llama-server`
- `whisper-stt`
- `first-boot`
- `sentinel`
- `security-baseline`
- `update-check`
- `AIDE`
- snapshots / cleanup
- smart charge / battery

### 4. First boot con logica real

En [lifeos-first-boot.sh](../../image/files/usr/local/bin/lifeos-first-boot.sh) hay trabajo concreto para:

- preparar directorios
- forzar cambio de password al usuario default cuando aplica
- configurar remotes de Flatpak
- crear config de providers
- inicializar thresholds de bateria
- colocar modelos de wake word
- detectar/configurar GPU

## Lo que aun requiere atencion

### 1. Complejidad alta de shipping

La imagen ya hace muchas cosas, y eso vuelve importante:

- ownership claro de servicios user/system
- defaults consistentes
- migraciones de config
- validacion host despues de cada cambio sensible

### 2. Sentinel y self-healing siguen siendo baseline en algunas rutas

El sentinel es real y util, pero en [lifeos-sentinel.sh](../../image/files/usr/local/bin/lifeos-sentinel.sh) todavia se nota una capa simple y conservadora:

- health check por HTTP
- restart
- `life doctor --repair`
- alerta por Telegram

Eso esta bien como base, pero no conviene venderlo como self-healing “omnisciente”.

### 3. Repo vs imagen sigue siendo la distincion critica

Hay modulos y channels en repo que no forman parte de la imagen default.  
La imagen es el arbitro real de shipping.

## Lo que yo diria hoy de la imagen

- **Repo:** muy fuerte
- **Imagen:** muy fuerte
- **Host:** buena base, pero siempre requiere validacion en hardware real cuando tocamos runtime, GPU, services u ownership

## Recomendaciones

### P0

- mantener tabla clara de features compiladas por default del daemon
- seguir validando ownership correcto de `lifeosd` y servicios relacionados

### P1

- documentar mejor la diferencia entre:
  - presente en repo
  - compilado en imagen
  - habilitado por default

### P2

- mantener una mini auditoria recurrente de first-boot, updates y recovery despues de cambios de imagen

## Conclusión

La imagen de LifeOS ya es una de las capas mas maduras del proyecto.  
El riesgo principal no es falta de shipping, sino que la complejidad del sistema vuelva borrosa la historia real de que se entrega, como arranca y con que defaults.
