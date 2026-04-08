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

## 8. Federacion de compatibilidad — extension multi-nodo

Las primeras 7 secciones de este documento describen BH como problema
single-machine: una sola laptop que se construye y se repara a si misma.
Pero la vision real de LifeOS es **federada**: cada instalacion consentida
contribuye a la matriz de compatibilidad global. Esta seccion documenta
esa extension.

### 8.1 Por que la federacion es necesaria, no opcional

LifeOS lo desarrolla **una persona + LLMs**. Hector tiene su laptop con su
combinacion especifica de hardware (CPU Intel/AMD, GPU NVIDIA o no, audio
PipeWire con su tarjeta especifica, microfono X, camara Y, sensores Z).
LifeOS funciona al 100% en esa laptop porque ahi se desarrolla.

Cualquier otro usuario que instale LifeOS tendra una combinacion que el
desarrollador principal **nunca** podra testear. Las posibles fallas de
compatibilidad son combinatoriamente intratables para un solo developer:

- 5 fabricantes de CPU × 8 GPUs × 12 chipsets de audio × 20 sensores × 3
  estados de SecureBoot × N kernels × ... = millones de combinaciones.
- Cada combinacion fallida significa un usuario que prueba LifeOS y dice
  "no me funciona, abandono el proyecto".

La federacion convierte ese problema en una ventaja: cada instalacion
consentida es un nodo de testing real, con hardware real, y con un LLM
real (el del propio usuario) capaz de proponer fixes. La matriz de
compatibilidad crece organicamente al ritmo de la comunidad, no del
mantenedor unico.

Esta es la diferencia entre "open source de fachada" (publicas el codigo y
esperas PRs) y **"open source de verdad"** (la herramienta facilita que
los usuarios contribuyan sin ser developers).

### 8.2 Arquitectura federada — quien hace que

```
┌──────────────────────────────────────────────────────────────────┐
│  Nodo upstream (github.com/hectormr206/lifeos + servicio ligero) │
│  ───────────────────────────────────────────────────────────     │
│  - Recibe fixes propuestos via PR/issue                          │
│  - Mantiene el "compatibility registry" (lista de fixes          │
│    aceptados, indexados por hardware fingerprint)                │
│  - Hector / maintainers revisan y mergean (gate humano)          │
│  - Publica el registry como JSON firmado en el repo              │
└──────────────────────────────────────────────────────────────────┘
                            ▲                      │
              fix submission│                      │ registry pull
              (con consent) │                      │ (publico, anonimo)
                            │                      ▼
┌──────────────────────────────────────────────────────────────────┐
│  Nodo cliente (cada laptop / VPS / RPi con LifeOS instalado)     │
│  ───────────────────────────────────────────────────────────     │
│  1. Compatibility check suite (BH.9) corre periodicamente        │
│  2. Para cada check fallido:                                     │
│     a. Lookup en registry upstream (BH.11)                       │
│     b. Si existe fix → ofrecer aplicar (con permiso)             │
│     c. Si NO existe fix → ofrecer generar uno local (BH.12)      │
│  3. Generar fix con LLM local del usuario, validar con BH.1-BH.5 │
│  4. Si funciona N dias en uso real → ofrecer submit (BH.13)      │
│  5. Submit pasa por preview explicito antes de salir             │
└──────────────────────────────────────────────────────────────────┘
```

**Tres componentes nuevos** sobre BH single-machine:

1. **Compatibility check suite** (BH.9) — bateria de tests por subsistema.
2. **Registry upstream** — servicio ligero (idealmente: solo el repo
   GitHub + un JSON firmado en una rama dedicada, sin servidor adicional
   en V1) que indexa fixes aceptados por hardware fingerprint.
3. **Federation client** dentro del daemon — la pieza local que consulta
   el registry, ofrece fixes, y envia submissions con permiso.

Notar que el registry upstream **no es un servidor de telemetria**. Es un
indice publico de fixes humanos-validados. La pull es anonima (cualquiera
puede leer el JSON sin identificarse), y la push es opt-in con preview
explicito de cada envio.

### 8.3 Modelo de privacidad — que sale del dispositivo y que NO

**Por defecto: NADA sale del dispositivo.** La compatibility check suite
de BH.9 corre 100% local y solo le muestra al usuario que esta roto. El
usuario tiene que elegir conscientemente compartir algo.

Cuando el usuario activa el modo "contribuidor de compatibilidad", la
unica metadata que LifeOS **propone** subir (con preview, con aprobacion
por envio) es:

| Dato | Que es | Por que es necesario |
|---|---|---|
| Hardware fingerprint anonimizado | Hash de `lspci`+`lscpu`+`lsusb` salida normalizada, sin identificadores unicos del dispositivo | Para indexar el fix a "este combo de hardware tiene este problema" |
| LifeOS version + bootc commit | String publica del release | Para saber contra que version testear el fix |
| Lista de checks fallidos | Resultados del BH.9 (`{check, status, exit_code, stderr_first_3_lines}`) | Para reproducir el fallo upstream |
| Fix propuesto | El diff o la receta declarativa generada por el LLM local | Es lo que se va a mergear |
| Identificador del contribuidor | Email o pseudonimo elegido por el usuario al inscribirse | Para credito y para poder rechazar fixes maliciosos |

**Lo que NUNCA sale**, jamas, ni con permiso, ni en preview, ni en logs:

- Contenido de archivos del usuario
- Conversaciones con Axi, memorias de `memory_plane`, knowledge_graph
- Capturas de pantalla, audio, video
- Direcciones MAC, serial numbers, hostnames, IPs
- Tokens de API, claves SSH, certificados
- Listado de paquetes instalados fuera de los relevantes al fix
- Cualquier path bajo `/home`

La regla es: **datos del sistema necesarios para reproducir el fallo**, y
nada mas. Si una pieza de informacion no es estrictamente necesaria para
que upstream entienda y valide el fix, no se envia.

El preview que el usuario ve antes de cada submission muestra **el JSON
completo y exacto** que se va a enviar, sin opciones ocultas.

### 8.4 Modos de fallo unicos de la federacion

#### 8.4.1 Submission spam / poisoning

**Sintoma:** Un actor malicioso se inscribe como contribuidor y empieza a
enviar fixes maliciosos disfrazados de fixes de compatibilidad.

**Mitigaciones:**

1. **Gate humano upstream:** ningun fix se mergea automaticamente.
   Hector o maintainers revisan cada PR. El registry solo se actualiza
   tras merge.
2. **Reputation system simple:** cada contribuidor empieza en `untrusted`.
   Despues de 5 fixes mergeados sin issues, sube a `trusted`. Despues de
   un fix reportado como malicioso, baja a `banned`.
3. **Diff size limits:** un fix de compatibilidad legitimo es pequeño
   (allowlist + drop-in systemd + sysctl). Cualquier PR que toque mas de
   N lineas o salga del formato declarativo restringido se cierra
   automaticamente.
4. **Static analysis:** todos los fixes pasan por linters automaticos
   antes de llegar al review humano (no comandos arbitrarios, no rutas
   absolutas fuera de allowlist, no `curl | sh`, no escritura en `/home`,
   etc.).

#### 8.4.2 Fix que funciona en una maquina y rompe en otra

**Sintoma:** El usuario A genera un fix para su NVIDIA RTX 3070 que
incluye un flag especifico. El fix se mergea. El usuario B con una RTX
3060 lo recibe via registry y le rompe el driver.

**Mitigaciones:**

1. **Hardware fingerprint matching estricto:** un fix se ofrece solo a
   nodos cuyo fingerprint **coincide** en las dimensiones relevantes
   (modelo de GPU, version de driver, etc.). Si el fingerprint no
   coincide al 100%, el fix no aparece en el registry para ese nodo.
2. **Cada fix recibido pasa por BH.1-BH.5 local antes de aplicarse:** el
   nodo B no aplica el fix de A directamente — lo mete en su sandbox,
   corre sus propios smoke tests, y solo promueve si pasan.
3. **Reporte de regresion automatico:** si un fix se aplico y luego los
   smoke tests del nodo empiezan a fallar, el daemon revierte
   automaticamente y reporta upstream "este fix me rompio". Upstream
   marca el fix como `regression-suspected` y lo retira del registry
   hasta nueva validacion.

#### 8.4.3 Privacidad accidental

**Sintoma:** Un usuario submitea un fix y, sin querer, incluye una ruta
absoluta con su username, o un hostname, o un fragmento de archivo.

**Mitigaciones:**

1. **Sanitizer determinista** que se ejecuta sobre cada submission antes
   del preview: scrub de `/home/<user>` → `/home/$USER`, scrub de
   hostnames, scrub de IPs, scrub de MACs, scrub de tokens conocidos.
2. **Preview destacado** que pinta en rojo cualquier string que parezca
   un email, un IP, una ruta absoluta de home, o cualquier secret
   pattern. El usuario lo ve antes de aprobar.
3. **Audit retroactivo:** si despues del merge upstream descubre que
   algo se filtro, hay un proceso de purge: borrar el commit del
   historico, contactar al contribuidor, mejorar el sanitizer.
4. **Caso "no submit":** el usuario siempre puede aplicar el fix solo en
   su maquina sin compartir, indefinidamente. La federacion es opt-in
   por **fix**, no por instalacion.

#### 8.4.4 Cuello de botella en el review humano

**Sintoma:** 1000 nodos generan 200 submissions por dia. Hector no puede
revisar 200 PRs diarios. El registry se queda atras y los usuarios
nuevos no reciben fixes.

**Mitigaciones:**

1. **Auto-approval condicional:** fixes que (a) estan en formato
   declarativo restringido, (b) tocan solo paquetes en la allowlist, (c)
   pasan todos los linters, y (d) vienen de contribuidores `trusted` con
   N+ fixes mergeados, pueden auto-mergearse al registry sin review
   humano. Esto reduce la carga al ~10% real de los PRs.
2. **Maintainers community:** despues del primer año de federacion, el
   sistema de reputacion permite que contribuidores `trusted` sean
   promovidos a `reviewer`, con permiso de aprobar PRs de otros.
3. **Triaje por urgencia:** el daemon upstream prioriza por "cuantos
   nodos tienen este check fallando". Un fix que afecta 50 nodos sube al
   tope de la cola. Un fix que afecta 1 nodo puede esperar.
4. **CLA + license clarity desde dia 1:** un Contributor License
   Agreement claro evita bloqueos legales que, si llegan tarde, pueden
   forzar a deshacer fixes ya integrados.

#### 8.4.5 Fragmentacion de la base instalada

**Sintoma:** Cada nodo evoluciona en una direccion distinta y termina
con una variante incompatible con los demas. Ya no hay "un LifeOS",
hay 10000 LifeOSes incompatibles.

**Mitigaciones:**

1. **Capa base inmutable garantizada:** la imagen base bootc oficial
   sigue siendo la fuente de verdad. Los fixes federados son **drop-ins
   aditivos** sobre esa base, no rewrites de la base.
2. **GC periodico:** cada N dias el sistema regenera la imagen base
   desde el ultimo release oficial y solo re-aplica los fixes locales
   que siguen siendo necesarios contra esa base. Los fixes que ya estan
   en upstream se descartan localmente porque ya forman parte de la
   base.
3. **Compatibility manifest:** el registry contiene un manifest semver
   de "este fix es compatible con LifeOS >= X.Y.Z". Fixes viejos se
   marcan obsoletos y se purgan.

### 8.5 Prior art especifico de federacion

| Proyecto | Que hace | Que aprende LifeOS |
|---|---|---|
| **Mozilla telemetry / Firefox Health Report** | Telemetria opt-in con dashboards publicos. Sanitiza datos antes de enviar. | Modelo de "preview lo que se envia" + sanitizers automaticos. Falla en hacerlo *opt-in real*: Firefox lo dejo opt-out por mucho tiempo, lo que erosiono confianza. |
| **Linux Hardware Database (linux-hardware.org)** | Usuarios envian salida de `hw-probe`, base de datos publica de compatibilidad por modelo. | Exactamente el caso de uso que necesitamos: hardware fingerprints + compatibility info pública. Pero solo *reporta* problemas, no los *resuelve*. LifeOS lo extiende con resolucion. |
| **Phoronix Test Suite + OpenBenchmarking** | Benchmarks reproducibles que se pueden compartir. Identificador anonimo opcional. | El modelo de "test suite local + opcion de compartir resultados" es muy parecido a BH.9 + BH.13. |
| **Debian popcon (popularity-contest)** | Opt-in: que paquetes tienen los usuarios. | Aprendizaje: opt-in real funciona — popcon tiene millones de usuarios voluntarios. La clave es ser radicalmente transparente sobre que se envia. |
| **Ubuntu whoopsie / apport** | Crash reports con preview detallado. | Modelo de "ventana antes de enviar con todo el contenido visible". Ubuntu lo hizo razonablemente bien, aunque tuvo polemicas iniciales por defecto activado. |
| **NixOS Hydra** | Build farm que valida configs antes de promoverlas a un canal. | Modelo de "validacion centralizada antes de publicar en el canal estable". |
| **Homebrew bottles + analytics opt-in** | Binarios precompilados + telemetria opt-in con preview. | Modelo de auto-approval para fixes triviales y review humano para fixes complejos. |
| **F-Droid build farm** | Reproducible builds + auditoria humana de cada PR de app. | Gate humano funciona si esta bien escalado y la comunidad confia en los maintainers. |

**Conclusion del prior art:** la federacion opt-in funciona en producto
real (Debian popcon, linux-hardware.org, Phoronix). El patron clave es:

1. Opt-in explicito desde el principio, jamas opt-out.
2. Preview total de cada envio.
3. Sanitizer determinista antes del preview.
4. Gate humano para casos no-triviales.
5. Reputation system simple.
6. Hardware fingerprint matching estricto.

Ningun proyecto previo combina los seis ingredientes con un patch engine
que ademas **resuelve** los problemas reportados. LifeOS seria el primero.

### 8.6 Plan de validacion incremental — extension federada

Estos hitos NO se empiezan hasta que BH.1-BH.8 (single-machine) hayan
completado validacion. Cada uno tiene sus propios criterios go/no-go.

#### 8.6.1 BH.9 — Compatibility check suite (mes 5 del programa)

**Objetivo:** Una bateria de checks por subsistema que reporta `pass /
fail / skip` y un `detail` legible. Corre 100% local. No envia nada.

**Tests obligatorios:** todos los smoke tests de BH.2 + checks especificos
para audio (PipeWire), red (NetworkManager), GPU (vendor + driver +
n-layers operacionales), wake word, llama-server con un prompt fijo,
dashboard, sensores, camera (solo deteccion, no captura).

**Criterio go/no-go:** si la suite corre en menos de 90s, no genera
falsos positivos en una maquina sana, y reporta correctamente fallos
inducidos artificialmente, BH.9 esta listo.

#### 8.6.2 BH.10 — Registry stub (mes 6)

**Objetivo:** Un JSON firmado en el repo upstream con la estructura del
registry, vacio al principio. El daemon sabe leerlo (pull anonimo).
Ningun submission todavia.

**Criterio go/no-go:** el daemon hace pull, parsea el JSON, ofrece "no
fixes disponibles para tu hardware" como output esperado.

#### 8.6.3 BH.11 — Lookup integration (mes 7)

**Objetivo:** Cuando BH.9 reporta un check fallido, el daemon consulta
BH.10. Si no hay fix → reporta solo. Si hay fix → muestra preview al
usuario sin aplicar.

**Criterio go/no-go:** se introducen 5 fixes manuales en el registry, se
verifica que el daemon los detecta y ofrece correctamente.

#### 8.6.4 BH.12 — Local fix-with-permission (mes 8)

**Objetivo:** Para checks fallidos sin fix upstream, el daemon usa el
patch engine BH.3 (con LLM local) para generar un fix candidato. Lo
aplica al sandbox. Si los smoke tests pasan, lo muestra al usuario para
aprobar / aplicar / descartar.

**Criterio go/no-go:** 30 dias de uso real con N usuarios voluntarios
internos, 0 bricks, mas del 50% de los fixes generados pasan los smoke
tests.

#### 8.6.5 BH.13 — Submission flow con preview (mes 9)

**Objetivo:** Despues de BH.12, si el fix funciono N dias en uso real, el
daemon ofrece submission. Sanitizer + preview + aprobacion explicita.
Salida: PR/issue al repo upstream. **No auto-merge**.

**Criterio go/no-go:** 100% de los submissions test pasan el sanitizer
sin filtrar PII en preview manual. Hector valida que los PRs llegan en
formato correcto y son revisables.

### 8.7 Criterios de no-go especificos de la federacion

Adicionales a los del modelo single-machine:

1. **Si el sanitizer deja escapar PII en mas del 0.1% de las
   submissions** durante el dogfooding interno, paramos hasta que sea
   imposible.
2. **Si el reputation system no escala mentalmente para Hector** (ej.
   pasa mas de 1h al dia revisando PRs en el primer mes), paramos y
   diseñamos auto-approval mas agresivo antes de seguir.
3. **Si encontramos que los hardware fingerprints generan falsos
   matches en mas del 5%** (un fix se ofrece a hardware donde no aplica),
   paramos y refinamos el fingerprinting.
4. **Si la comunidad reacciona negativamente** ("esto es vigilancia
   disfrazada", "no confio en que el preview muestre todo"), paramos y
   reescribimos el modelo de privacidad antes de seguir tecnicamente.
5. **Si el costo legal de un CLA + revision se vuelve prohibitivo** para
   un mantenedor unico, paramos hasta tener community maintainers.

### 8.8 Por que esto sigue siendo "open source de verdad"

Algunas verificaciones rapidas para que no se nos pierda el norte:

- ¿El usuario puede correr LifeOS sin participar en la federacion?
  **Si.** Modo `observe` + federation off es perfectamente valido.
- ¿El usuario puede inspeccionar todo el codigo de la federacion?
  **Si.** Es parte del repo opensource. Los sanitizers, los preview
  generators, los smoke tests, todo.
- ¿El usuario puede correr su propio registry upstream y apuntar su
  daemon a el? **Si.** El URL del registry es configurable. Esto
  permite forks y federaciones privadas (empresas, comunidades
  cerradas).
- ¿El usuario puede dar de baja todo en un click? **Si.** Kill switch
  unidireccional desde el dashboard.
- ¿LifeOS lucra con los datos? **No.** El registry es publico, los
  fixes son opensource, los contribuidores no se monetizan.
- ¿La federacion convierte a LifeOS en SaaS? **No.** Sigue siendo un
  OS local-first. La federacion es solo un canal opcional de
  contribucion comunitaria.

Si en algun momento alguna de estas respuestas cambia, hay que parar y
reevaluar — porque entonces ya no es lo que prometimos.

## 9. Notas finales

- Este documento se actualiza cada vez que aprendemos algo nuevo del prior
  art o de un experimento.
- Si alguien empieza un spike (aunque sea exploratorio), debe documentar
  resultados aqui antes de tocar el codigo del repo.
- La regla "no commitear codigo BH al main hasta que el spike valide BH.1
  + BH.2" es absoluta.
