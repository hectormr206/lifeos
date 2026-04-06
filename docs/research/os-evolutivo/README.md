# OS Evolutivo — Investigacion profunda

> Documento de investigacion para Fase BH (Vision Futura).
> Resumen ejecutivo en `docs/strategy/fase-bh-os-evolutivo.md`.

## Pregunta de partida

Que hace falta, tecnicamente, para que LifeOS pase de "tiene supervisor +
agentes + skills + rollback bootc" a "se construye y se repara a si mismo
sin romperse"? Esta carpeta documenta el analisis de:

1. La arquitectura propuesta (capa por capa)
2. Los modos de fallo conocidos en sistemas auto-modificables
3. El prior art (que ya existe afuera y que aprende cada uno)
4. El plan de validacion incremental (que probar primero, en que orden)
5. Los criterios de "no-go" (cuando abortamos y volvemos al modelo
   tradicional de updates)

Esta es **investigacion**, no implementacion. No hay codigo aqui, solo
mapas tecnicos y trade-offs. La regla del repo (`project_phase_types.md`)
dice que las fases de vision futura viven en research hasta que el spike
de validacion las desbloquee.

## 1. Arquitectura propuesta — el modelo "Semilla → Sandbox → Promocion"

### 1.1 Las tres capas

```
┌─────────────────────────────────────────────────────────────┐
│  Capa Promovida (bootc current)                             │
│  El sistema que el usuario ve. Inmutable, firmada, con      │
│  rollback automatico al kernel anterior si no arranca.      │
└─────────────────────────────────────────────────────────────┘
                            ▲
                            │ bootc commit + sign + upgrade
                            │ solo si smoke tests pasan
                            │
┌─────────────────────────────────────────────────────────────┐
│  Capa Sandbox (overlay descartable)                         │
│  Una copia funcional del sistema donde el patch engine      │
│  aplica cambios y los valida. Si los smoke tests fallan,    │
│  se descarta sin tocar la capa promovida. Implementacion    │
│  candidata: composefs overlay + systemd-nspawn con bind     │
│  mounts read-write a /var/lib/lifeos/sandbox.               │
└─────────────────────────────────────────────────────────────┘
                            ▲
                            │ patch engine genera receta
                            │ declarativa (Containerfile snippet,
                            │ drop-in systemd, sysctl, etc.)
                            │
┌─────────────────────────────────────────────────────────────┐
│  Patch Engine (proceso del daemon)                          │
│  Recibe una "intencion del sistema" desde el supervisor:    │
│   - "falta codec ffmpeg para reproducir mp4"                │
│   - "pipewire reinicia 5 veces por minuto"                  │
│   - "vm.swappiness=10 esta hurting esta workload"           │
│  Decide si la sabe resolver, genera la receta, dispara el   │
│  flujo sandbox → smoke tests → promocion.                   │
└─────────────────────────────────────────────────────────────┘
                            ▲
                            │ supervisor escala intenciones
                            │ que reglas precompiladas no
                            │ resuelven
                            │
┌─────────────────────────────────────────────────────────────┐
│  Supervisor (lifeosd)                                       │
│  Monitorea journalctl, dmesg, metricas de aplicaciones, y   │
│  uso del usuario. Cuando detecta una anomalia, intenta      │
│  resolverla con reglas determministas primero. Si no, la    │
│  escala al patch engine.                                    │
└─────────────────────────────────────────────────────────────┘
```

**Por que tres capas y no dos:** la capa sandbox es la barrera entre "el
LLM imagino algo que se ve bien" y "el sistema real lo ejecuta". Sin esa
barrera, la primera alucinacion sistemica te brica la maquina.

### 1.2 La regla de oro: el motor no depende del LLM que parcha

El componente que decide "promover o no promover" **NO** puede ser un LLM.
Tiene que ser un sistema deterministico:

- Smoke tests precompilados que devuelven 0 o non-zero
- Reglas de threshold (CPU, memoria, latencia) con valores fijos
- Timeouts duros

El LLM solo participa en la **generacion** de la receta, no en su
validacion. Si el LLM genera basura, la capa sandbox detecta el fallo y
descarta sin que ningun otro LLM tenga que opinar. Asi se rompe el bucle
de la muerte.

## 2. Modos de fallo conocidos

### 2.1 Bucle de la muerte

**Sintoma:** El parche que aplica el LLM rompe la propia capacidad del
LLM de operar. Ejemplos: rompe la red, rompe llama-server, rompe el
daemon, rompe systemd.

**Mitigaciones obligatorias:**

1. La capa sandbox **siempre** se prueba antes de promocionar.
2. Los smoke tests incluyen "el daemon arranca" y "llama-server responde
   en :8082" como tests duros.
3. Si tres ciclos consecutivos fallan los smoke tests, el patch engine
   entra en modo `observe` automaticamente y notifica al usuario.
4. El supervisor tiene una conexion BYOK opcional a un LLM remoto
   (Cerebras / Groq / OpenRouter) **solo** para casos donde el LLM local
   no responde y hay que generar un parche de recuperacion. Es opt-in.

### 2.2 Alucinaciones sistemicas

**Sintoma:** El LLM inventa un flag de `sysctl`, una opcion de systemd, un
nombre de paquete, una ruta de archivo. La receta se ve plausible pero
tecnicamente no compila o explota en runtime.

**Mitigaciones:**

1. La receta se genera en formato declarativo restringido (no codigo
   Python/Bash arbitrario): drop-in systemd, sysctl entry, Containerfile
   snippet con `RUN dnf install -y <package>`. Estos formatos se validan
   sintacticamente antes de aplicar al sandbox.
2. La lista de paquetes que el patch engine puede instalar esta en una
   allowlist mantenida por LifeOS, no abierta a "lo que el LLM diga".
3. Cualquier `RUN` que no sea `dnf install`, `systemctl`, o `cp` esta
   prohibido en V1. Codigo arbitrario solo se desbloquea cuando el sistema
   pase 30 dias sin un single brick.
4. El smoke test "el sandbox arranca y `systemctl is-system-running`
   devuelve `running` o `degraded` pero no `failed`" es eliminatorio.

### 2.3 Supply chain compromise

**Sintoma:** Un atacante inyecta un prompt malicioso via un email, un
archivo descargado, o un mensaje de Telegram. El sistema interpreta ese
prompt como instruccion y modifica `sshd_config` o instala un backdoor.

**Mitigaciones obligatorias:**

1. **El patch engine NO recibe inputs externos como instrucciones.** Solo
   acepta señales internas: codigos de salida, contadores de errores en
   journalctl, metricas del kernel. Nada que venga de "fuera" del sistema
   se interpreta como peticion de auto-modificacion.
2. Los promts del usuario via Telegram/voz **pueden** disparar
   intenciones, pero solo desde una lista cerrada de verbos permitidos
   (`instalar codec`, `aumentar volumen`, `reportar metrica X`). Verbos
   peligrosos (`reescribir sshd`, `desactivar firewall`) requieren
   confirmacion explicita en el dashboard, con MFA si esta configurado.
3. Cada capa promovida se firma con una clave del usuario almacenada en
   TPM o en disco encriptado con la contraseña del usuario. Si la clave no
   esta disponible (usuario no logged in), no hay promocion posible.
4. Audit trail completo y replicado fuera del propio sistema (Telegram, o
   un export periodico al dispositivo del usuario).

### 2.4 Drift incontrolable

**Sintoma:** El sistema muta tantas veces que el usuario ya no entiende
que tiene instalado, y las mutaciones interactuan entre si de formas
imprevistas.

**Mitigaciones:**

1. Cada N dias (configurable), el sistema regenera una "imagen base" desde
   cero y re-aplica solo los parches que siguen siendo relevantes. Es el
   equivalente a un GC de capas.
2. El usuario ve una vista resumen en el dashboard: "tienes 23 parches
   acumulados, los 5 mas recientes son: ...".
3. El usuario puede pedir "revertir todos los parches del ultimo mes" en
   un click.

### 2.5 Confianza vs autonomia

**Sintoma:** El usuario no se siente comodo con un OS que cambia bajo sus
pies sin avisar. Aunque tecnicamente todo este bien, el efecto psicologico
mata la adopcion.

**Mitigaciones:**

1. Tres modos opt-in: `observe` (default), `propose`, `apply`.
2. En modo `observe`, el patch engine genera la receta pero no la ejecuta
   — solo le muestra al usuario "esto es lo que haria si me dejaras".
3. En modo `propose`, el patch engine ejecuta hasta el sandbox y le
   muestra al usuario el diff + smoke test results. El usuario aprueba o
   rechaza.
4. En modo `apply`, el patch engine ejecuta hasta promocionar
   automaticamente, pero notifica al usuario via Telegram + dashboard
   despues de cada cambio.
5. El nivel actual se ve siempre en el tray. Subir de nivel requiere
   confirmacion explicita.

## 3. Prior art — quien ya intento esto

| Proyecto | Que hace | Que aprende LifeOS |
|---|---|---|
| **NixOS** | Configuracion declarativa reproducible. Todo el sistema es una funcion pura de un archivo. | Modelo declarativo + rollback es viable a escala. Pero NixOS NO es self-modifying — el usuario edita el archivo. |
| **Fedora bootc / OSTree** | Imagen inmutable con rollback transaccional al kernel anterior. | Es la base ideal para la capa promovida. Ya lo usamos. |
| **GNU Guix System** | Como NixOS pero con foco en reproducibilidad y bootstrap desde fuentes minimas. | Lecciones sobre "construir el sistema desde una semilla minima". |
| **Karpathy autoresearch** | 630 lineas de Python que corren ML experiments autonomamente y proponen mejoras. | El loop "propon → corre → mide → aprende" es viable. Pero esta en espacio de usuario, no toca el sistema. |
| **Genode OS** | Microkernel con capabilities estrictas. Cada componente esta aislado por diseño. | El modelo de capabilities es la respuesta correcta a "como evito que el patch engine se exceda". |
| **Self-healing en Kubernetes** | Operators que detectan fallos y aplican recetas declarativas. | El patron operator es exactamente lo que necesita el patch engine. |
| **CoreOS / Flatcar** | Auto-update transaccional con rollback. | Lecciones de operacion en flotas grandes — fallos comunes y sus mitigaciones. |
| **OpenWRT failsafe boot** | Si el sistema no arranca tres veces, entra en modo recuperacion minimo. | Modelo de kill switch jerarquico que ya funciona en producto real. |

**Conclusion del prior art:** ningun proyecto une los cinco ingredientes
(declarative + inmutable + LLM-driven + sandbox + transactional) en un
solo OS. LifeOS tiene la oportunidad de ser el primero, pero **solo si
respeta las lecciones de cada uno** — especialmente el modelo de
capabilities de Genode y el failsafe boot de OpenWRT.

## 4. Plan de validacion incremental — que probar primero

La regla es: **cada paso tiene que ser validable por separado y
descartable sin tocar el siguiente**. Si BH.1 no funciona, no tiene
sentido empezar BH.2.

### 4.1 BH.1 — Sandbox interno (mes 1)

**Objetivo:** Tener una capa overlay funcional donde aplicar cambios
arbitrarios sin tocar el sistema real, y descartarla limpiamente.

**Como validar:**

1. Crear `/var/lib/lifeos/sandbox/<uuid>` con composefs overlay + bind
   mounts a partes selectivas del sistema real.
2. `systemd-nspawn` arrancando el sandbox como contenedor aislado.
3. Aplicar `dnf install ffmpeg` dentro del sandbox.
4. Verificar que `which ffmpeg` dentro del sandbox lo encuentra.
5. Verificar que `which ffmpeg` fuera del sandbox **no** lo encuentra.
6. Borrar el sandbox. Verificar que `df` muestra el espacio liberado y
   que no quedan artefactos en el sistema real.

**Criterio go/no-go:** si despues de 100 ciclos de crear/probar/borrar el
sistema real sigue intacto y no hay leaks de espacio, BH.1 esta listo.

### 4.2 BH.2 — Smoke test suite (mes 1)

**Objetivo:** Tener un set deterministicos de tests que validen "el
sistema esta vivo" en menos de 60 segundos.

**Tests obligatorios:**

| Test | Que valida |
|---|---|
| `systemctl is-system-running` | Systemd arranca y no esta en `failed` |
| `systemctl is-active lifeosd llama-server` | Servicios criticos vivos |
| `curl -fs http://127.0.0.1:8081/api/v1/health` | Daemon API responde |
| `curl -fs http://127.0.0.1:8082/v1/models` | llama-server responde |
| `nmcli connectivity` | Red funciona |
| `journalctl -p err --since "5 minutes ago" \| wc -l` | Errores recientes bajo umbral |
| `ps -e \| grep -v grep \| wc -l` | Numero de procesos en rango sano |

**Criterio go/no-go:** si los tests pasan en el sistema real promovido y
fallan ruidosamente en un sandbox al que se le borro `lifeosd`, BH.2 esta
listo.

### 4.3 BH.3 — Patch engine de juguete (mes 2)

**Objetivo:** Una primera version del patch engine que **solo** sepa
resolver UNA intencion: "instalar codec faltante para abrir un archivo".

**Restricciones de V1:**

- Solo recibe intenciones de la lista cerrada `[ "install_codec" ]`.
- Solo genera recetas en formato `dnf install <pkg>` desde una allowlist
  fija (`ffmpeg`, `gstreamer1-plugins-good`, `libdvdread`).
- No usa LLM para generar la receta — usa una tabla hardcoded.
- No promociona — solo aplica al sandbox y reporta resultado.

**Criterio go/no-go:** si BH.3 + BH.1 + BH.2 corren 30 dias en una VM y no
hay un single brick, avanzamos a BH.4.

### 4.4 BH.4 — Promocion transaccional (mes 3)

**Objetivo:** Que el patch engine pueda commitear la capa sandbox como
nueva capa promovida via `bootc commit` + `bootc upgrade --apply`, con
rollback automatico al kernel anterior si no arranca.

**Validaciones:**

- 100 promociones consecutivas en VM, todas con smoke tests OK.
- 10 promociones donde el smoke test falla → verificar que el rollback
  ocurre automaticamente.
- 1 promocion donde el kernel no arranca → verificar que `bootc rollback`
  trae el kernel anterior.

**Criterio go/no-go:** 0 bricks en 100 ciclos. Si hay 1 solo brick,
volvemos a BH.3.

### 4.5 BH.5 — LLM en la generacion de recetas (mes 4)

**Objetivo:** Permitir que el LLM proponga la receta dentro del formato
declarativo restringido, y que la receta pase por validacion sintactica
antes del sandbox.

**Restricciones:**

- La receta sigue restringida a la allowlist de paquetes y comandos.
- Si el LLM propone algo fuera de la allowlist, se rechaza sin enviar al
  sandbox.
- Cada receta queda firmada con el hash del prompt + version del LLM en
  el audit trail.

**Criterio go/no-go:** 30 dias en VM con 100% de los rechazos justificados
en logs. 0 bricks.

### 4.6 BH.6+ — Modos opt-in, audit trail, kill switch

A partir de aqui ya es ingenieria de producto, no investigacion. Cada uno
con su mes de validacion.

## 5. Criterios de no-go (cuando abortamos)

Hay escenarios donde detenemos esta investigacion y volvemos al modelo
tradicional de updates. Listarlos por adelantado evita la trampa del
"sunk cost":

1. **Si BH.1 hace leak de mas de 100MB por ciclo despues de 100
   iteraciones**, abortamos. La capa sandbox no es viable a escala.
2. **Si BH.2 da falsos positivos mas del 1% de las veces** (smoke test
   falla cuando el sistema en realidad funciona), abortamos. La barrera
   de validacion no es deterministica.
3. **Si BH.3 brica la VM mas de una vez en 30 dias** (incluso con la
   logica mas conservadora), abortamos. El modelo no es seguro.
4. **Si encontramos que el LLM local genera recetas con allowlist
   correcta pero efectos secundarios indeseados mas del 5% del tiempo**,
   abortamos BH.5 y nos quedamos con tablas hardcoded para siempre.
5. **Si el usuario en feedback dice mas del 30% del tiempo "esto da
   miedo"**, paramos y reevaluamos UX antes de avanzar.

## 6. Por que esto es vision futura y no fase consecutiva

Por la regla de `project_phase_types.md`:

- Una fase consecutiva se implementa en menos de 2 semanas por una
  persona.
- BH.1 solo (la capa sandbox) son **al menos 2 semanas** de un developer
  con experiencia en composefs/nspawn, mas otras 2 semanas de validacion
  en VM.
- BH.1 + BH.2 + BH.3 son ~2 meses minimo.
- El programa completo (BH.1-BH.8) son ~6 meses minimo, asumiendo que
  ningun criterio no-go se dispara.
- Y nada de esto desbloquea valor para el usuario hasta que BH.4 este
  validado, porque hasta entonces solo es un sandbox que no toca el
  sistema real.

Por todo lo anterior, esta fase queda en **Vision Futura** del
`unified-strategy.md` hasta que:

1. `self_improving` (Fase U) este 100% verde
2. `reliability` (Fase W) este 100% verde
3. Tengamos un developer dedicado a esto al menos 6 meses
4. Tengamos hardware de test (VM dedicada con snapshots) para 100+ ciclos
   por dia

Mientras tanto, la fase existe documentada para que cuando lleguemos al
punto de poder hacerla, no empecemos desde cero.

## 7. Que SI podemos hacer hoy sin cerrar el ciclo completo

Mientras BH no esta listo, hay piezas pequeñas que podemos avanzar como
parte de las fases existentes y que **no requieren** auto-modificacion
del sistema:

- **Skill generator** (existente, Fase U): generar skills de espacio de
  usuario, no del sistema. Bajo riesgo.
- **Shadow mode** (parcial, Fase W): correr workflows en dry-run y
  mostrar diffs. Bajo riesgo.
- **Confidence scoring** (existente, Fase W): escalar a humano cuando la
  confianza es baja. Bajo riesgo.
- **Auto-tuning de configs del usuario** (no del sistema): el supervisor
  puede ajustar `~/.config/lifeos/*.toml` y cosas similares sin tocar el
  sistema. Bajo riesgo.
- **Recetario de parches manuales pre-aprobados:** una lista de "si pasa
  X, ofrece al usuario hacer Y" donde Y son acciones cerradas y bien
  testeadas. Esto no es auto-modificacion, es automation con supervision
  humana. Es lo mas cerca que podemos estar de BH sin BH.

Estas piezas son una buena practica anyway, y cuando BH se desbloquee, ya
estarian listas como ingredientes.

## 8. Notas finales

- Este documento se actualiza cada vez que aprendemos algo nuevo del prior
  art o de un experimento.
- Si alguien empieza un spike (aunque sea exploratorio), debe documentar
  resultados aqui antes de tocar el codigo del repo.
- La regla "no commitear codigo BH al main hasta que el spike valide BH.1
  + BH.2" es absoluta.
