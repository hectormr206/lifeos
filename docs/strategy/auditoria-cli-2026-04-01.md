# Auditoria Profunda: CLI `life`

**Fecha de corte:** `2026-04-01`  
**Entradas principales:** [cli/src/main.rs](../../cli/src/main.rs), [cli/src/commands/](../../cli/src/commands/)

## Resumen

La CLI de LifeOS ya es amplia y real.

En esta pasada se observaron:

- `43` archivos de comando en [cli/src/commands/](../../cli/src/commands/)
- una superficie grande de subcomandos en [main.rs](../../cli/src/main.rs)
- `27` archivos de comando que consumen `daemon_client`
- `12` archivos de comando con `std::process::Command::new(...)`

Eso sugiere que la CLI ya cumple tres papeles a la vez:

- cliente del daemon
- herramienta local del sistema
- capa de producto para usuario avanzado

## Lo mas fuerte de la CLI

### 1. Superficie amplia y bien organizada

Hay subcomandos para:

- status, update, doctor, audit
- AI, assistant, voice, overlay
- memory, agents, skills, intents
- browser, computer-use, workflow
- theme, visual-comfort, accessibility
- onboarding, config, capsule, portal, lab

### 2. No es pura fachada

Se ve claramente que la CLI:

- habla con la API del daemon cuando conviene
- hace verificaciones locales del sistema cuando conviene
- mezcla ambos enfoques segun el tipo de comando

Ejemplos:

- [doctor.rs](../../cli/src/commands/doctor.rs)
  - cliente de `/api/v1/health`
- [memory.rs](../../cli/src/commands/memory.rs)
  - wrapper serio sobre endpoints de memoria
- [status.rs](../../cli/src/commands/status.rs)
  - usa checks locales de salud/bootc/config
- [init.rs](../../cli/src/commands/init.rs)
  - ejecuta comandos del sistema como `bootc`, `systemctl`, `podman`, `nvidia-smi`

## Lo que aun se ve mixto

### 1. Taxonomia difusa

No siempre esta claro para el usuario si un comando es:

- local puro
- wrapper del daemon
- combinacion de ambos
- baseline aun parcial

Eso no es un bug por si solo, pero dificulta:

- documentacion limpia
- debugging
- expectativas de soporte

### 2. Algunas promesas siguen por debajo del nombre del comando

Ejemplo claro:

- [doctor.rs](../../cli/src/commands/doctor.rs)
  - `--repair` aun no implementa reparacion automatica real

Esto conviene resolver de una de dos formas:

- implementar el comportamiento
- o bajar claramente la promesa del flag/comando

### 3. Tamaño de superficie vs narrativa publica

La CLI ya tiene una presencia de “sistema completo”, pero no todos los subcomandos equivalen a una experiencia final cerrada.

## Lo que yo diria hoy de la CLI

- **Repo:** fuerte
- **Imagen:** fuerte, porque `life` se compila y empaqueta en la imagen default
- **Host:** razonablemente usable, pero con madurez desigual por comando

## Recomendaciones

### P0

- clasificar comandos por madurez:
  - `stable`
  - `repo-integrated`
  - `experimental`
  - `wrapper-only`

### P1

- revisar nombres/promesas de comandos con mayor riesgo de sobreventa:
  - `doctor`
  - `safe-mode`
  - `audit`
  - `workflow`
  - `agents`

### P2

- documentar por familia si dependen del daemon, del host o de ambos

## Conclusión

La CLI `life` ya es una interfaz potente del sistema.  
La mejora mas importante ya no es agregar mas subcomandos, sino hacer mas clara su taxonomia y cerrar mejor las expectativas de cada uno.
