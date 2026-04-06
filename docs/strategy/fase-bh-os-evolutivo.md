# Fase BH — OS Evolutivo (Self-Building, Self-Healing)

> Visión futura. NO implementable en el corto plazo.
> Requiere investigación profunda antes de tocar código del sistema.
> Detalles tecnicos completos en `docs/research/os-evolutivo/README.md`.

## Premisa en una linea

Un sistema operativo que arranca con un **kernel + base minima**, y a partir
de ahi se construye, configura y repara a si mismo de forma autonoma usando
los componentes que LifeOS ya tiene (supervisor, agentes, memoria, modelos
locales) — sin que el usuario tenga que pedirlo, y sin romperse en el
proceso.

No es ciencia ficcion: es la frontera de lo que ya tenemos a medias.

## Premisa extendida — la vision real (el "BH federado")

La premisa de arriba es la version single-machine. La vision completa es
mas grande y resuelve un problema concreto del proyecto:

> **LifeOS lo desarrolla un solo developer + LLMs.** Hector tiene su laptop
> y la hace funcionar al 100%. Pero los usuarios que instalan LifeOS en
> hardware distinto (otra laptop, una PC, un VPS, una Raspberry Pi, una
> maquina virtual, eventualmente un celular) tienen combinaciones de
> hardware que el desarrollador principal nunca va a poder testear todas.
> El cuello de botella del proyecto es **compatibilidad de hardware** —
> no features ni ideas.

La idea es convertir cada instalacion consentida de LifeOS en un **nodo de
compatibilidad federado**:

1. El usuario instala LifeOS y, si quiere, se inscribe como contribuidor
   de compatibilidad (**opt-in explicito**, jamas por defecto).
2. LifeOS corre periodicamente una **lista de checks de salud y
   compatibilidad** sobre ese hardware: arranque, audio, red, GPU, voz,
   wake word, llama-server, dashboard, sensores, camera, microfono, etc.
3. Antes de hacer NADA, el sistema **consulta el ultimo release oficial y
   la lista de issues abiertos** para no duplicar trabajo: si el bug ya
   esta corregido en `edge` o ya existe un PR upstream, el nodo se entera
   y ofrece al usuario actualizar en vez de "inventar" un fix.
4. Para los checks que sigan fallando despues del paso 3, LifeOS le
   pregunta al usuario: *"En tu hardware el modulo X no funciona. Quieres
   que intente desarrollar una correccion usando tu propio LLM (local o
   BYOK)?"* — El usuario decide en cada caso.
5. Si el usuario acepta, el patch engine genera el fix dentro del modelo
   BH (sandbox + smoke tests + promocion transaccional). El fix queda
   aplicado en SU maquina primero. Solo cuando funciona en su maquina, se
   ofrece (otra vez con permiso) submitirlo upstream como contribucion.
6. Upstream recibe miles de pequeños fixes especificos de hardware, los
   filtra/valida, y los integra. La matriz de compatibilidad de LifeOS
   crece **organicamente** al ritmo de su comunidad, no al ritmo de un
   solo developer.

El resultado: LifeOS deja de depender de que Hector tenga una RTX 3070 +
intel i7 + un microfono especifico. Cada nodo aporta su propio hardware al
sistema inmunologico colectivo, **siempre con consentimiento del usuario y
siempre con su propio LLM** (asi cada quien controla privacidad y costo).

Esto es lo que hace que la idea sea "open source de verdad" en vez de
"opensource de fachada": los usuarios no solo reportan bugs — el sistema
les ofrece resolverlos en sitio y devolver el fix.

## Por que esto es estrategico

LifeOS hoy cubre el 80% del camino:

| Pieza necesaria | Estado actual |
|---|---|
| Filesystem inmutable + rollback | bootc (Fedora) — listo |
| Supervisor con tareas y reintentos | `supervisor.rs` — listo |
| Agentes autonomos | `agent_runtime` + `autonomous_agent` — listo |
| Memoria persistente y semantica | `memory_plane` + `knowledge_graph` — listo |
| Generador de skills | `skill_generator` — listo |
| Auto-tuning de configs del sistema | `self_improving` (Fase U) — parcial |
| Confidence scoring + retry alternativo | `reliability` (Fase W) — parcial |

Lo que **falta** es el ultimo 20% que cierra el bucle: que LifeOS pueda
**escribir codigo del propio sistema, validarlo en aislamiento, y promoverlo
de forma transaccional** sin romperse y sin pedirle confianza ciega al
usuario.

## Riesgos criticos (esto es lo que da miedo)

Antes de prometer nada, los riesgos a mitigar:

1. **Bucle de la muerte:** Si Axi compila un parche que rompe llama-server,
   no puede pedirle al LLM como arreglarlo porque el LLM ya no responde. El
   motor de auto-reparacion **NUNCA** puede depender del LLM local que esta
   parchando — necesita un fallback offline determinista (rollback bootc +
   reglas precompiladas) o un LLM remoto BYOK.
2. **Alucinaciones sistemicas:** Un LLM proponiendo flags de `sysctl` o
   cambios de servicio inventa cosas el 5-10% del tiempo. Eso en codigo de
   aplicacion es molesto; en `/etc/systemd/system/` es un brick. Mitigacion
   obligatoria: shadow mode.
3. **Supply chain compromise:** Un sistema que reescribe su propio codigo
   es el sueño de un atacante. Inyectarle un prompt via un email o un
   archivo descargado podria convencerlo de "parchar" sshd. Mitigacion: el
   motor **nunca** lee inputs no firmados como instrucciones; solo señales
   internas.
4. **Confianza vs autonomia:** Los usuarios no quieren un OS que cambia
   bajo sus pies sin avisar. Mitigacion: opt-in con tres niveles —
   `observe`, `propose`, `apply`.

## Como se veria si funcionara

1. Axi detecta que el usuario abrio un `.mp4` y faltan codecs. Ya no es una
   skill que el usuario instala — Axi escribe la receta de capa, la prueba
   en un overlay descartable, valida que video, audio y dashboard siguen
   vivos, firma la nueva capa con la clave del usuario, y la promueve via
   `bootc`. El usuario solo ve "instale ffmpeg para que abrieras ese video,
   reinicia cuando quieras".
2. Una actualizacion externa rompe `pipewire`. Axi detecta el fallo en
   journalctl, busca en su memoria semantica (Fase BA) si vio algo asi
   antes, propone una correccion, la prueba en overlay, y revierte si los
   smoke tests no pasan.
3. El supervisor nota que `vm.swappiness=10` esta hurting workloads
   especificos del usuario en horarios especificos. Genera una variacion,
   la prueba 24h en sombra, mide, y promueve solo si la metrica mejora.

## Lo que falta para cerrar el ciclo

Esto NO es una fase consecutiva implementable en 2 semanas. Es un programa
de varias fases, cada una con su propia validacion. Como mapa grueso:

- [ ] **BH.1 — Sandbox interno:** Una capa overlay descartable donde la IA
  aplica cambios y los valida antes de tocar el sistema real. Tecnicamente:
  `bootc` + `composefs` o `systemd-nspawn` con bind mounts. Ver research.
- [ ] **BH.2 — Smoke test suite:** Scripts deterministas precompilados que
  validan que red, audio, llama-server, dashboard, daemon y arranque siguen
  vivos despues de un parche. Sin LLM en el camino — todo regla fija.
- [ ] **BH.3 — Patch engine:** Componente que recibe una "intencion del
  sistema" (codec faltante, servicio caido, config subóptima), genera una
  receta declarativa (Containerfile snippet, drop-in systemd, sysctl), la
  aplica al overlay BH.1, ejecuta BH.2, y solo si pasa, firma + promueve.
- [ ] **BH.4 — Transactional bootc commit:** Proceso autonomo que crea una
  nueva capa firmada con la clave del usuario, la commitea via `bootc
  commit`, y queda lista para `bootc upgrade --apply` con rollback
  automatico al kernel anterior si no arranca.
- [ ] **BH.5 — Kill switch jerarquico:** 3 fallos consecutivos de smoke
  tests → modo `observe` forzado → notificacion al usuario por Telegram +
  dashboard. La maquina se niega a evolucionar hasta que el usuario
  inspecciona y reset manual.
- [ ] **BH.6 — Modos opt-in (`observe` / `propose` / `apply`):** Por
  defecto `observe`. Solo el usuario sube el nivel desde el dashboard, y
  cada nivel se puede revertir en cualquier momento.
- [ ] **BH.7 — Audit trail consultable:** Cada cambio queda con: quien lo
  propuso (que LLM, que prompt), por que (señal que lo disparo), que
  cambio, smoke tests, resultado, hash de firma. Consultable desde
  dashboard y desde Telegram (`/historia bootc`).
- [ ] **BH.8 — Spike de validacion:** Implementar BH.1 + BH.2 + un patch
  engine de juguete que solo sepa "instalar codec faltante" como prueba de
  concepto. Si funciona en una VM por 30 dias sin brick, avanzar.

### Capa federada (BH.9 - BH.13) — solo despues de BH.8

Estas piezas existen porque la vision de LifeOS es **federada**, no
single-machine. NO se empiezan hasta que BH.1-BH.8 hayan validado que el
modelo single-machine es seguro. Cada una respeta los mismos principios:
opt-in explicito, consentimiento por accion, privacidad por defecto.

- [ ] **BH.9 — Compatibility check suite:** Una bateria extendida de
  smoke tests que cubre cada subsistema de LifeOS (arranque, red, audio,
  GPU, llama-server, voz, wake word, vision, dashboard, sensores, camera,
  microfono, bluetooth, sleep/resume, batteria) y reporta resultados
  estructurados: `[ { "check": "wake_word", "status": "fail", "detail":
  "...", "hardware_signature": "..." } ]`. Corre localmente y por defecto
  no envia nada — solo mostrar al usuario que esta roto en SU maquina.
- [ ] **BH.10 — Compatibility federation registry:** Un servicio upstream
  donde un usuario puede inscribirse como **contribuidor de compatibilidad**.
  Opt-in explicito, con un email o un identificador anonimo + consent
  string que vive en `/etc/lifeos/federation.toml`. Se puede dar de baja
  en un click. Estado por defecto: **NO inscrito**. Al inscribirse, el
  usuario decide que datos comparte (hardware fingerprint anonimizado, OS
  version, lista de checks fallidos — sin contenido del usuario, jamas).
- [ ] **BH.11 — Upstream-first lookup:** ANTES de generar cualquier fix
  local, el patch engine consulta el upstream registry y la lista de
  issues/PRs en `github.com/hectormr206/lifeos`: "este check fallido en
  este hardware, alguien ya lo reporto? alguien ya lo arreglo? esta en la
  release siguiente?". Si existe, le ofrece al usuario actualizar /
  esperar / aplicar el patch propuesto en vez de generar uno nuevo. Esto
  es lo que evita que 1000 nodos generen 1000 fixes para el mismo bug.
- [ ] **BH.12 — Local fix-with-permission flow:** Para los checks que
  fallan y NO tienen fix upstream, LifeOS muestra al usuario:
  *"En tu hardware el modulo X no funciona. Detalles: ... Quieres que
  intente desarrollar una correccion usando tu LLM local? Esto NO subira
  nada a internet — el fix se aplica solo en tu maquina."* El usuario
  acepta o rechaza por check. Si acepta, todo el flujo BH.1-BH.7 corre
  para generar y validar el fix en sandbox. El fix queda en su maquina.
- [ ] **BH.13 — Opt-in upstream contribution:** Si el fix de BH.12
  funciona en su maquina (smoke tests + uso real durante N dias), LifeOS
  pregunta una segunda vez: *"El fix que aplicamos para X funciona bien.
  Quieres ofrecerlo upstream para que otros usuarios con tu mismo
  hardware se beneficien? Antes de subir veras exactamente que se sube y
  que metadata."* Si acepta, el daemon firma el fix con la clave del
  usuario, lo empaqueta con la info anonimizada del hardware, y lo envia
  como un PR/issue al repo upstream. Upstream tiene su propia capa de
  validacion humana antes de mergear (Hector o maintainers revisan).
  **Este paso es siempre opcional, jamas automatico.**

## Que NO va a hacer (para que quede claro)

### Single-machine (BH.1-BH.8)

- **No** va a reescribir el kernel.
- **No** va a tocar el bootloader.
- **No** va a deshabilitar el rollback de bootc.
- **No** va a eliminar la opcion de "snapshots manuales del usuario".
- **No** va a aplicar cambios sin que pase smoke tests.
- **No** va a aceptar inputs externos (email, web, archivos descargados)
  como instrucciones de auto-modificacion.
- **No** va a correr sin que el usuario haya elegido el modo conscientemente.
- **No** va a depender del LLM local que esta parchando — siempre fallback
  determinista o LLM externo.

### Federacion (BH.9-BH.13)

- **No** va a inscribir nadie por defecto. La inscripcion al registry de
  compatibilidad es **opt-in explicito** desde el dashboard, jamas
  silenciosa.
- **No** va a enviar contenido del usuario, jamas. Ni archivos, ni
  conversaciones, ni memorias, ni capturas, ni metadata privada. Solo lo
  que el usuario apruebe en el preview de cada submision.
- **No** va a enviar nada antes de mostrar al usuario **exactamente** que
  se va a enviar (preview JSON completo + diff del fix + identificador
  anonimo).
- **No** va a enviar fixes upstream sin que el usuario apruebe cada
  submision. Cero auto-submit, cero "background sync de fixes".
- **No** va a aceptar fixes de otros nodos automaticamente. Cualquier fix
  que llegue del upstream pasa por el mismo BH.1-BH.5 (sandbox + smoke
  tests + aprobacion del usuario local) antes de tocar nada.
- **No** va a reactivar la federacion despues de que el usuario la
  desactive. Es un kill-switch unidireccional hasta que el usuario lo
  vuelva a activar conscientemente.
- **No** va a usar telemetria pasiva. Cada envio es un evento discreto y
  consciente, no un stream.

## Estado

- Investigacion: [`docs/research/os-evolutivo/README.md`](../research/os-evolutivo/README.md)
- Spike inicial: pendiente — empezar por BH.1 + BH.2 en una VM aislada.
- Fecha objetivo: sin fecha. Esto se desbloquea cuando `self_improving`
  (Fase U) y `reliability` (Fase W) esten 100% verde, no antes.
- Posicion en `unified-strategy.md`: **Vision Futura** — no entra al
  consecutivo hasta que el spike BH.8 valide que es seguro avanzar.
