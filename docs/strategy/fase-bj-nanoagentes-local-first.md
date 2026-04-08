# Fase BJ — NanoAgentes Local-First

> Inspirado por la charla "NanoAgentes, el poder de la IA en tu mochila"
> (T3chFest 2026), pero aterrizado como implementacion propia para LifeOS.
> La tesis no es "usar el modelo mas grande posible", sino "usar modelos
> pequenos bien orquestados, con contexto inteligente, perfiles por hardware
> y privacidad local por defecto".

## Estado

**Activa para revision.**

Hay baseline parcial ya implementado en repo:

- `Qwen3.5-4B-Q4_K_M.gguf` como modelo local default
- perfil persistido de runtime por hardware
- tuning de `parallel`, `batch` y `ubatch` en `llama-server`
- `Game Guard` condicionado por soporte real de GPU
- prompting estructurado ya presente en Telegram, supervisor y roles
- compaction parcial de sesiones y resumen de memoria ya cableados
- `PromptEvolution` existe como observabilidad/sugerencia, no como optimizador autonomo real

Lo que falta no es la idea, sino cerrar el backlog para que esta direccion se
convierta en comportamiento de producto consistente y medible.

**Decision operativa (2026-04-07):**

Esta fase absorbe todo lo que impacta **ahora** a la calidad de los modelos
locales pequenos:

- prompting estructurado por ruta
- budgets de contexto
- output schemas
- routing directo a especialistas
- evaluacion de prompts como release gate

Queda explicitamente fuera de BJ cualquier loop tipo GEPA continuo, distillation
de modelos grandes, DPO y lineup amplio de modelos fine-tuned. Eso se difiere a
fases futuras para no desviar tiempo de lo que mas mueve la UX local hoy.

## Problema que resuelve

Si LifeOS sigue creciendo sin una politica clara para modelos pequenos y
agentes locales, aparecen cinco degradaciones:

1. El modelo local termina sobredimensionado para hardware medio.
2. La UX en CPU-only se vuelve pobre o impredecible.
3. Los agentes generalistas consumen demasiado contexto y se vuelven fragiles.
4. La privacidad se erosiona por fallback remotos o tool use sin disciplina.
5. La orquestacion compite con el modelo en vez de amplificarlo.

Esta fase convierte esas decisiones en reglas tecnicas estables.

## Tesis operativa

### BJ.1 — Modelo pequeno por defecto

- LifeOS mantiene un modelo local pequeno como baseline universal.
- El default actual es `4B`.
- Modelos mas grandes son opt-in segun hardware, no el punto de partida del producto.

### BJ.2 — Optimizacion por hardware

- El mismo modelo base debe correr con perfiles distintos segun CPU/RAM/GPU.
- No existe una sola configuracion universal de inferencia.
- La primera experiencia debe adaptarse al hardware real y persistirse.

### BJ.3 — Agentes especializados

- Axi no debe resolver todo con un solo agente generalista.
- Los small models funcionan mejor cuando cada agente tiene una tarea mas estrecha.
- La orquestacion debe decidir quien actua, no meter todo en el mismo contexto.

### BJ.4 — Contexto comprimido e inteligente

- El contexto es un presupuesto, no un buffer infinito.
- Los SLMs necesitan crop, resumen, recuperacion selectiva y control explicito
  del espacio disponible.

### BJ.5 — Privacidad local

- Todo lo sensible debe resolverse localmente por defecto.
- Remoto solo con consentimiento, etiquetas claras y politica ZDR estricta.

### BJ.6 — Orquestacion por encima de tamano bruto

- La calidad del sistema depende mas de la orquestacion, el contexto y los
  datos correctos que de subir parametros sin control.

## Lo ya aterrizado en repo

### Runtime local

- [x] Modelo local default `4B` en `llama-server.env`
- [x] Runtime profile persistido por hardware
- [x] Override env para `parallel`, `batch` y `ubatch`
- [x] `Game Guard` deshabilitable automaticamente si no hay GPU dedicada util
- [x] Fallback CPU de `Game Guard` como perfil completo, no solo `GPU_LAYERS=0`

### Base de agentes

- [x] Router multi-provider
- [x] Roles de agente
- [x] Supervisor + task queue + memoria
- [x] Tool use, voz, vision, Telegram, browser y dashboard
- [x] System prompts estructurados por superficie (`telegram_tools`, supervisor, roles)
- [x] Compaction de sesiones y resumen de clusters de memoria como baseline
- [x] Prompt evolution parcial como capa de sugerencias, no de optimizacion automatica

### Gaps abiertos

- [ ] Trigger formal de benchmark desde first boot / upgrade / hardware change
- [ ] Prompting del producto como politica transversal para SLMs
- [ ] Prompt packs cortos por ruta y por especialista
- [ ] Output schemas y validacion sistematica de respuestas
- [ ] Routing directo a especialistas en vez de sobreusar orquestador general
- [ ] Politica de privacidad mas dura para herramientas y modelos remotos
- [ ] Metricas de calidad y regresion para small-model UX
- [ ] Harness de evaluacion de prompts antes de promotion a produccion

## No-negociables

### BJ.7 — Lo que NO vamos a hacer

- No usar unified memory como estrategia principal de rendimiento.
- No subir el modelo default solo porque una laptop concreta lo aguante.
- No depender de un agente monolitico con contexto gigante.
- No mandar memoria, screenshots o contexto sensible a remoto por fallback silencioso.
- No introducir fine-tuning como escape prematuro antes de cerrar runtime y orquestacion.
- No montar un loop tipo GEPA corriendo dentro del producto en tiempo real.
- No entrenar varios modelos pequenos especializados antes de validar que prompting, contexto y routing ya quedaron bien cerrados.

## Resultado esperado

Si esta fase se ejecuta bien, LifeOS deberia poder decir:

> "Axi usa un modelo local pequeno por defecto, optimizado para tu hardware.
> Si tu equipo tiene GPU, acelera; si no, sigue siendo usable en CPU+RAM.
> La calidad viene de la orquestacion, del contexto correcto y de agentes
> especializados, no de inflar el modelo sin control."

## Plan tecnico por fases

### Fase 1 — Runtime Universal Local-First

**Objetivo:** que el modelo default se adapte automaticamente al hardware
del usuario y quede persistido como perfil de runtime.

#### Backlog

- [ ] BJ.1.1 — Lanzar benchmark automaticamente en primer arranque si falta perfil
- [ ] BJ.1.2 — Re-lanzar benchmark si cambia CPU, RAM, GPU, backend o version del runtime
- [ ] BJ.1.3 — Exponer `runtime-profile.json` y su estado en API/CLI/dashboard
- [ ] BJ.1.4 — Agregar comando manual `life ai benchmark --force`
- [ ] BJ.1.5 — Validar que `Game Guard` no existe en maquinas sin GPU dedicada soportada
- [ ] BJ.1.6 — Agregar estado `benchmark_pending`, `benchmark_stale`, `cpu_only`, `gpu_fast`, `game_guard_fallback`

#### Criterios de aceptacion

- Una maquina nueva obtiene perfil local sin intervencion manual.
- Un cambio de hardware invalida el perfil y vuelve a optimizar.
- En CPU-only, `Game Guard` aparece como no soportado.
- El runtime activo queda visible para usuario y logs.

### Fase 2 — Context Engineering y Prompting para SLMs

**Objetivo:** hacer que los small models fallen menos por saturacion de contexto.

#### Backlog

- [ ] BJ.2.1 — Definir budget formal: `system`, `memory`, `tools`, `body`, `output`
- [ ] BJ.2.2 — Definir prompt packs cortos por ruta: `chat`, `tool_agent`, `planner`, `summarizer`, `ocr_docs`, `browser_ops`
- [ ] BJ.2.3 — Exigir output schemas por tarea critica (JSON/shape fijo, tags o formatos verificables)
- [ ] BJ.2.4 — Introducir thresholds de compactacion por tipo de tarea
- [ ] BJ.2.5 — Agregar resumidor de contexto como worker especializado
- [ ] BJ.2.6 — Implementar "cherry-picking" de contexto: recuperar solo trozos relevantes
- [ ] BJ.2.7 — Conectar memory retrieval a presupuestos de tokens y no solo a similitud
- [ ] BJ.2.8 — Medir y registrar `context_overflow`, `context_compaction_count`, `summary_latency`, `schema_valid_rate`

#### Criterios de aceptacion

- Las tareas largas dejan de romperse por overflow silencioso.
- Los prompts base del `4B` son mas cortos, especificos y predecibles por superficie.
- Las rutas criticas devuelven formatos validables en vez de texto libre fragil.
- El supervisor puede continuar una tarea larga sin perder coherencia.
- El sistema sabe cuando resumir, cuando recortar y cuando recuperar.

### Fase 3 — Agentes Especializados y Routing Directo

**Objetivo:** que Axi use small models como especialistas coordinados, no como
un solo cerebro saturado.

#### Backlog

- [ ] BJ.3.1 — Definir especialistas minimos: `router`, `coder`, `retriever`, `ocr_docs`, `browser_ops`, `summarizer`
- [ ] BJ.3.2 — Si la intencion es clara, saltarse el orquestador general y llamar al especialista directo
- [ ] BJ.3.3 — Aislar contexto por especialista
- [ ] BJ.3.4 — Dar a cada especialista su propio prompt pack y schema de salida
- [ ] BJ.3.5 — Permitir subagentes paralelos solo si el perfil de hardware lo soporta
- [ ] BJ.3.6 — Medir costo de orquestacion contra llamada directa
- [ ] BJ.3.7 — Introducir politicas por tarea: `single-shot`, `graph`, `orchestrated`, `parallel`

#### Criterios de aceptacion

- Las tareas directas responden sin sobrecarga de orquestacion innecesaria.
- Los flujos largos usan especialistas sin compartir todo el contexto.
- El throughput en hardware fuerte mejora sin degradar CPU-only.

### Fase 4 — Privacidad Local y Politica de Escape Remoto

**Objetivo:** que el crecimiento del sistema no rompa la promesa local-first.

#### Backlog

- [ ] BJ.4.1 — Etiquetar cada modelo y cada herramienta con `local`, `remote`, `zdr`, `sensitive_ok`, `requires_opt_in`
- [ ] BJ.4.2 — Bloquear por defecto memoria privada en llamadas remotas
- [ ] BJ.4.3 — Bloquear por defecto screenshots, OCR sensible y contexto del sistema en remoto
- [ ] BJ.4.4 — Requerir consentimiento explicito por clase de dato, no solo por provider
- [ ] BJ.4.5 — Registrar audit trail de cada "escape remoto"
- [ ] BJ.4.6 — Añadir vista de dashboard: "que datos puede sacar este flujo fuera del host"

#### Criterios de aceptacion

- El default del producto sigue siendo local y privado.
- Ningun fallback remoto mueve datos sensibles sin señal visible y auditable.
- El usuario puede entender por que una tarea fue local o remota.

### Fase 5 — Benchmarks, Observabilidad y Release Gate

**Objetivo:** que esta estrategia se mantenga con datos y no se degrade por intuicion.

#### Backlog

- [ ] BJ.5.1 — Metricas minimas: `ttft`, `tokens_per_sec`, `p95_latency`, `ram_peak`, `vram_peak`, `restart_time`
- [ ] BJ.5.2 — Metricas de small-agent UX: `router_overhead`, `context_compaction_rate`, `subagent_parallelism`, `schema_valid_rate`
- [ ] BJ.5.3 — Corpus de evaluacion para prompt packs y tareas cortas del `4B`
- [ ] BJ.5.4 — Judge opcional para desarrollo/release gate: preferentemente local o remoto explicito, nunca fallback silencioso de producto
- [ ] BJ.5.5 — Casos de prueba CPU-only, GPU media, laptop gamer con `Game Guard`
- [ ] BJ.5.6 — Gate de release: no subir defaults ni prompt packs si empeoran CPU-only o hardware medio
- [ ] BJ.5.7 — Reporte comparativo antes/despues de cada cambio fuerte en runtime o prompting

#### Criterios de aceptacion

- Cualquier cambio de inferencia puede medirse.
- Las regresiones quedan visibles antes de llegar a usuarios.
- LifeOS optimiza por evidencia, no por sensacion.

## Dependencias con otras fases

### Ya existentes

- `Fase G` — Game Guard y asistencia de juego
- `Fase AY` — Control plane del OS
- `Fase BE` — actividad real del usuario
- `Fase AQ` — personalizacion
- `Fase AR` — custom training

### Regla de secuencia

- BJ debe cerrarse antes de subir el modelo local default por encima de `4B`.
- BJ debe cerrar contexto y orquestacion antes de empujar fine-tuning como solucion general.
- BJ debe endurecer privacidad antes de ampliar catalogo remoto experimental.
- BJ debe cerrar prompting estructurado y evaluacion antes de considerar GEPA-like optimization o distillation.

## Metricas de exito

### Producto

- `TTFT local` percibido menor en hardware optimizado
- `CPU-only usability` sin GPU dedicada
- `Game Guard` inexistente o desactivado cuando no aporta valor
- `Specialist routing` mayor que uso del agente general en tareas claras
- `Schema-valid outputs` altos en rutas criticas del `4B`

### Plataforma

- menos overflows de contexto
- menos reinicios manuales de `llama-server`
- menos degradacion al cambiar entre juego y trabajo
- mas tareas resueltas localmente sin escalar a remoto
- menos prompts gigantes reutilizados fuera de su contexto correcto

## Preguntas de revision

Antes de marcar BJ como aprobada, revisar:

1. ¿Seguimos comprometidos con `4B` como default universal?
2. ¿El benchmark por hardware es parte del producto o solo una optimizacion opcional?
3. ¿Axi debe priorizar especialista directo cuando la tarea ya esta clara?
4. ¿Vamos a tratar el contexto como presupuesto formal en todo el stack?
5. ¿El local-first sigue siendo una regla de producto o solo una preferencia?
6. ¿GEPA-like prompt optimization sigue diferido hasta que BJ ya tenga corpus y release gates?

## Decision recomendada

**Si.**

La direccion correcta para LifeOS es:

- modelo pequeno por defecto
- optimizacion por hardware
- agentes especializados
- contexto comprimido e inteligente
- privacidad local
- orquestacion por encima del tamano bruto del modelo

BJ formaliza esa direccion y la convierte en backlog ejecutable.
