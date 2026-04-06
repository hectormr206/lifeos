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

## Que NO va a hacer (para que quede claro)

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

## Estado

- Investigacion: [`docs/research/os-evolutivo/README.md`](../research/os-evolutivo/README.md)
- Spike inicial: pendiente — empezar por BH.1 + BH.2 en una VM aislada.
- Fecha objetivo: sin fecha. Esto se desbloquea cuando `self_improving`
  (Fase U) y `reliability` (Fase W) esten 100% verde, no antes.
- Posicion en `unified-strategy.md`: **Vision Futura** — no entra al
  consecutivo hasta que el spike BH.8 valide que es seguro avanzar.
