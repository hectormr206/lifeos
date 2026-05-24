# PRD — LifeOS / Axi · Nano-Agents (v1.1 — reality update)

> **Authored**: 2026-05-20
> **Last revised**: 2026-05-22 (v1.1 reality update — see §0.1 and §13)
> **Owner**: Héctor Martínez
> **Status**: PARTIALLY IMPLEMENTED · awaiting empirical decision (continue / archive) once post-fix metrics accumulate
> **Companion to**: [PRD-life-companion-v1.md](./PRD-life-companion-v1.md) (completed; Phases P0-P6.2 in production)

---

## 0. TL;DR

Hoy LifeOS usa **un solo modelo grande** (Qwen3.6 35B-A3B en GPU + CPU) para todo lo que requiera razonamiento. Funciona, pero:

- Latencia de chat ~2-5s por call al brain.
- Cualquier tarea ambigua (extracción de entidades de frases en español, clasificación de intención, sentiment) pasa por el modelo grande aunque sea trabajo mecánico.
- Cuando la regex de los ingestion paths falla, cae al brain → costo en tokens + latencia.

**Esta fase** introduce **nano-agentes**: modelos chicos (500M-1.5B params, ≤300 MB en disco con Q4) especializados en UNA tarea, corriendo en CPU/RAM, orquestados por Axi.

**Visión clave**: en una conferencia (ref. citada por Héctor) se demostró que un nano-agente especializado puede **ganarle** a un LLM de frontera en su nicho específico, porque el prompt está optimizado y el modelo no se distrae con la generalidad.

**Lo que NO hace este PRD**: reemplazar Qwen3.6 35B-A3B. El brain grande sigue siendo el orquestador para tareas cross-domain (purchase consult, retros, conversación abierta). Los nano-agentes son **herramientas** que el brain llama.

---

## 0.1 Reality update — 2026-05-22

Esta sección refleja lo que **realmente se construyó y lo que falló de las premisas originales** desde que el PRD se redactó (2026-05-20). Es la verdad operacional al día de hoy. El resto del documento queda como intención de diseño original; donde una afirmación quedó desmentida por la realidad, se agrega un bloque **[REALITY 2026-05-22]:** inline.

### Qué se construyó

- **N0 Foundation**: ✅ `lifeos.agents.runtime.call_nano()` (HTTP client al nano llama-server). Endpoint default `127.0.0.1:8090`, timeout 5s, `disable_thinking=True`, `max_tokens=800` (valores menores producen content vacío en Qwen3.5-0.8B).
- **N2 Entity extractor**: ✅ `lifeos.agents.extractor.extract()`. Few-shot prompt curado con reglas estrictas anti-FP en `people` y reglas DOMAIN para que ejercicio gane sobre relationships cuando hay actividad física. Wirear en `axi/src/axi/dashboard.py:_try_nano_extract()` como fallback ANTES del brain cuando ninguna regex matchea.
- **Servicio runtime**: ✅ `llama-nano.service` (port 8090) corriendo Qwen3.5-0.8B-Q4_K_M en **CPU-only** garantizado vía `CUDA_VISIBLE_DEVICES=""` + `-ngl 0`. MemoryMax=2G. Separado del brain (`llama-server.service`, port 8080, GPU).

### Qué se saltó / desvió del plan original

- **N1 Intent classifier saltado**. El PRD §6 lo recomendaba como "primer slice" porque toca el 100% de los chat calls. En la práctica se fue directo a N2 (entity extractor) — decisión no documentada en su momento.
- **Runtime ≠ Ollama**. El PRD §4.1 recomendaba Ollama (multi-model hot-swap, LRU eviction). Se implementó con un segundo `llama-server` dedicado a un único modelo. Trade-off: ✅ aislamiento de hardware (CUDA hidden), ✅ stack conocido; ❌ no hay hot-swap, escalar nano-agentes implica más servicios o compartir prompt con el mismo modelo.
- **Modelo ≠ Qwen3-0.6B**. El PRD §3 recomendaba Qwen3-0.6B. Se usa **Qwen3.5-0.8B-Q4_K_M** por preferencia explícita del owner: SIEMPRE el modelo más actual de su familia, no bajar a versiones previas por latencia.
- **Eval harness no existe**. `agents/eval/`, `golden_sets/`, `bootstrap.py` del §4.3/§5 → no se construyeron.

### Premisa principal del PRD **REFUTADA por mediciones**

El PRD §1.2 prometía nano-agente a **50-200ms** en CPU vs 2-5s del brain. Datos reales (129 calls de chat instrumentados en `lifeos.metrics.fastpath_metrics`):

| Etapa | n | p50 | Observación |
|---|---|---|---|
| brain (Qwen 35B en GPU) | 44 | **2332 ms** | mucho más rápido de lo asumido (MoE A3B en GPU) |
| nano_* (Qwen 0.8B en CPU) | 54 | **2000-3900 ms** | ~igual o peor que el brain |
| regex health/finance/relationships | 15 | **14-33 ms** | sí cumple su rol |

**Conclusión empírica**: el nano Qwen3.5-0.8B en CPU con `-t 4` y outputs JSON de 800 tokens **NO** entrega la ventaja de latencia que el PRD asumía. La ventaja real, si la hay, es **accuracy** (capturar variantes que la regex no agarra) y/o **persistencia automática** (el nano no solo entiende, también escribe al store correspondiente — cosa que el brain no hace). No latencia.

### Bug encontrado y fixeado (2026-05-22)

- **30 de 129 calls (23%)** fueron clasificadas como `nano_spirituality` con un avg de **4 caracteres** de input. Causa: (a) el caller no tenía guard de longitud mínima → cualquier input vacío iba al nano; (b) el wire de spirituality en `_try_nano_extract` carecía de la quality guard que sí tenían los otros dominios (finance exige `amount`, exercise exige `duration_minutes`, etc.). El modelo defaulteaba a "spirituality" para inputs ambiguos y el wire persistía cualquier basura como reflexión.
- **Fix aplicado**: (1) `dashboard.py:2532` ahora skipea el nano si `len(text.strip()) < 12`. (2) `dashboard.py:1958` exige `result.title || result.kind || len(text.strip()) >= 20` antes de persistir spirituality.
- Después del fix, hay que reacumular datos limpios (~24-48h) antes de decidir continue / archive.

### Decisión pendiente (próximo viaje al PRD)

Con la baseline contaminada + premisa de latencia refutada, las opciones son:

- **A. Continue — pivot rationale**: aceptar que el nano NO da ganancia de latencia, defender su existencia por accuracy + persistencia. Construir el eval harness de §4.3 con golden sets y MEDIR si el nano agarra cosas que la regex y el brain pierden. Si <30% de las nano_* calls hubieran sido brain "no-action" igual → no vale.
- **B. Continue — N1 intent classifier**: el PRD original lo recomendaba precisamente porque toca el 100% de calls. Pero implementarlo con Qwen3.5-0.8B en CPU agregaría 2-4s a TODAS las calls. Mata el caso de uso salvo que se acelere drásticamente (que no podemos sin bajar a un modelo más viejo, vetado por el owner).
- **C. Archive honestamente**: vivir solo con regex + brain directo. Apagar `llama-nano.service`, liberar 2GB de RAM. El extractor queda en código por si en el futuro se quiere reactivar con otro modelo.

**Recomendación honesta del orquestador**: si los datos post-fix no muestran que el nano "salva" >30% de calls que de otro modo irían al brain con resultado equivalente, ir directo a **C**. Si sí salva, **A** con eval harness.

---

## 1. Vision (the "why")

### 1.1 El problema concreto

Actualmente el chat fast-path de LifeOS tiene 8 regex parsers en serie + 1 brain fallback:

```
purchase consult → events → learning → spirituality → exercise → relationships → health → finance → reminders → brain
```

Cada regex es **alta precisión, baja recall**. Captura solo frases con estructura clara:
- ✓ "compré una laptop por 18000"
- ✗ "ayer me gasté como diez y nueve mil en la lap nueva"
- ✓ "hablé con María"
- ✗ "estuve hablando con la chica del lunes"

Los misses caen al brain → 2-5s + tokens consumidos para extracción trivial.

### 1.2 La promesa de nano-agentes

Modelos de 500M-1.5B params, quantizados a Q4 (~200-300MB en disco), corriendo en CPU pueden:

- **Latencia**: 50-200 ms por inferencia en CPU moderno (vs 2-5s del brain)
- **Especialización**: prompt+fine-tune en una sola tarea → accuracy alta en ese nicho
- **Composabilidad**: el orquestador (Qwen 35B) puede llamar varios nano-agentes en paralelo o secuencialmente
- **Costo marginal**: agregar un nano-agente = 300MB en disco + prompt iteration

> **[REALITY 2026-05-22]**: el bullet de "latencia 50-200ms" es **falso** con Qwen3.5-0.8B Q4 en CPU + outputs JSON ~800 tokens + `-t 4`. Medición real: **p50 = 2000-3900 ms**, ~igual o peor que el brain Qwen 35B-A3B en GPU. La ventaja, si existe, es accuracy + persistencia automática — no latencia. Ver §0.1.

### 1.3 Lo que NO mejora con nano-agentes

Ser honesto desde el principio:

- ✗ Conversación abierta, razonamiento abstracto, ironía, humor → necesita brain grande
- ✗ Decisiones cross-domain ("¿puedo comprar X?") → necesita contexto largo + síntesis
- ✗ Tareas con world knowledge profunda → nano-agentes son ralos en facts
- ✗ Multimodal (vision) → modelos de visión chicos pierden mucha calidad
- ✗ Tareas con context >4K tokens → la mayoría de nano-agentes tienen 4-8K

---

## 2. Concrete use cases (priorizado)

### Tier 1 — alto valor, validación rápida

1. **Intent classifier** — input: texto del usuario; output: dominio (health/finance/relationships/.../chat). Reemplaza la cadena secuencial de 8 regex con UNA llamada. Si el classifier dice "finance", solo corremos el regex de finance.
2. **Entity extractor (Spanish)** — input: texto; output: JSON con personas, fechas, montos, lugares, productos. Maneja variantes que la regex no agarra. Reemplaza varios regex en cada dominio.
3. **Sentiment / mood classifier** — input: una interacción o reflexión; output: mood_pre/mood_post inferido (1-10). Hoy el usuario los pone manual; el nano-agente los infiere por defecto y el usuario corrige.
4. **Symptom classifier** — input: "me duele la garganta y tengo flema"; output: kind + location + (opcional) severity 1-10 + estructura para `health.entries`.
5. **Spanish summarizer** — input: una entry larga o un día de actividad; output: resumen breve. Para insights digest, retros, condensar prose.

### Tier 2 — útil pero más complejo

6. **Question router / decomposer** — divide una consulta multi-step en sub-preguntas que se pueden delegar.
7. **Goal extractor** — de reflexiones espirituales, identifica goals implícitos.
8. **Translator es↔en** — ya tenemos `axi-translate` pero pesa mucho; un nano-translator chico podría reemplazarlo para snippets.
9. **Code-name normalizer** — "mi vieja" → "Mamá" si "Mamá" ya existe en relationships; resuelve apodos y referencias coloquiales.

### Tier 3 — explorar después

10. **Sleep/exercise plan generator** — dada la última semana, propone un plan.
11. **Conflict deescalator** — dada una pelea con X, sugiere 3 cosas que dijeron en pasados conflictos resueltos bien.

---

## 3. Model candidates (May 2026)

Investigación de hoy (2026-05-20). Foco: ≤1.5B params, Spanish-capable, GGUF disponible, license permisivo.

| Modelo | Params | Size Q4 | Idiomas | License | Razonamiento | Por qué |
|---|---|---|---|---|---|---|
| **Qwen3-0.6B** | 600M | ~350MB | 100+ | Apache 2.0 | Thinking/non-thinking modes | Mejor balance Spanish + tooling + ecosistema |
| **Gemma 3 1B** | 1B | ~500MB | 140+ | Gemma terms | Sí | Multilingüe muy fuerte, Google calibrado |
| **SmolLM3-1.7B** | 1.7B | ~900MB | EN + parcial | Apache 2.0 | Sí | Más fuerte pero excede tu budget de 300MB |
| **TinyLlama 1.1B** | 1.1B | ~700MB | Mayormente EN | Apache 2.0 | No | Liviano pero Spanish flojo |
| **DeepSeek-R1 Distill 1.5B** | 1.5B | ~800MB | EN + chino | MIT | CoT nativo | Reasoning fuerte pero Spanish secundario |
| **Phi-4-mini 3.8B** | 3.8B | ~2.4GB | EN+ES | MIT | Sí | Excede budget |

**Pick recomendado**: **Qwen3-0.6B** para la mayoría de tier 1, **Gemma 3 1B** si necesitamos más capacidad. Ambos caben en 300MB Q4 y manejan Spanish nativamente.

> **[REALITY 2026-05-22]**: el modelo en prod es **Qwen3.5-0.8B-Q4_K_M**, no Qwen3-0.6B. Decisión explícita del owner: SIEMPRE el más actual de la familia, aunque cueste algo más de latencia/RAM. Si Qwen libera 3.6-0.X o equivalente, migrar. Ver memoria #194 (`preferences/model-currency`).

---

## 4. Architecture

### 4.1 Runtime — cómo corren los nano-agentes

Opciones evaluadas:

| Opción | Pros | Cons | Veredicto |
|---|---|---|---|
| Un llama-server por agente (Unix sockets) | Aislamiento, mismo stack que tenemos | RAM × N agentes siempre cargados, gestión de N services | **Descartado** — overhead alto |
| **llama-server único con multi-model + slot eviction** | Reusa infra existente, hot-swap automático | Latencia de swap entre modelos diferentes | **Candidato fuerte** |
| llama-cpp-python in-process | Más control, sin RPC | Más código nuestro, GIL | Posible v2 |
| Ollama daemon | Multi-modelo nativo, eviction automática | Yet another service | **Candidato fuerte** |

**Recomendación**: **Ollama** corriendo en `127.0.0.1:11434`, dedicado a los nano-agentes. Razones:

- Nativamente maneja loading/eviction. Si 5 agentes caben en RAM, los mantiene warm; si no, hace LRU.
- API HTTP simple (`POST /api/generate`).
- No interfiere con llama-server (que sigue con Qwen 35B en 8080).
- Trivial de actualizar y monitorear.
- Si queremos cambiar después, la abstracción `lifeos.agents.runtime` esconde el backend.

> **[REALITY 2026-05-22]**: NO se implementó con Ollama. Se montó un **segundo `llama-server` dedicado** (`llama-nano.service` en port 8090) con un único modelo cargado, `CUDA_VISIBLE_DEVICES=""` para aislamiento absoluto. Trade-offs aceptados: gana stack conocido + aislamiento de hardware más explícito; pierde hot-swap multi-modelo y eviction LRU. Si se necesita multi-agente concurrente con modelos distintos, esta decisión hay que reabrirla. Ver §0.1 y memoria #193 (`architecture/nano-agents`).

### 4.2 Orquestación — cuándo se llama a quién

**Patrón orchestrator-worker** (industria-validado en 2026):

```
                   ┌────────────────────┐
                   │  Axi (Qwen 35B)    │
                   │   orquestador      │
                   └─────────┬──────────┘
                             │ decide qué nano-agente llamar
        ┌────────────────────┼────────────────────┐
        │                    │                    │
   ┌────▼────┐         ┌─────▼─────┐         ┌────▼────┐
   │ intent  │         │ entity    │         │ sentiment│
   │ classify│         │ extract   │         │ classify │
   └─────────┘         └───────────┘         └──────────┘
   Qwen3-0.6B          Qwen3-0.6B            Gemma 3 1B
```

Dos niveles de delegación:

**A. Reglas-based (rápido, determinístico)** — para tasks con trigger claro:
- Chat fast-path: input → **intent_classifier** (nano) → dispatch al regex de ese dominio
- Posture scan → **vision classifier** (futuro nano vision)

**B. Brain-delegated (flexible, costoso)** — el brain decide qué nano llamar:
- "Resumime mi semana" → brain delega a **summarizer** + **pattern_detector** + sintetiza
- "¿Cómo me sentí esta semana?" → brain delega a **sentiment_aggregator** + **mood_trend**

### 4.3 Prompt engineering pipeline

Para CADA nano-agente:

1. **Bootstrap del prompt**: Héctor define la tarea en lenguaje natural. Un script usa Qwen 35B (frontier local) para generar 3-5 variantes de prompts candidatos.
2. **Golden set**: Héctor anota 30-50 ejemplos reales (input → output esperado).
3. **Eval harness**: corre cada prompt contra el golden set, mide accuracy/F1 per class.
4. **Iteración**: mejor prompt + tweaks manuales hasta llegar a ≥95% accuracy.
5. **Si no llega**: ya consideramos **fine-tuning** (LoRA en el nano-agente con los golden examples).

Tooling propuesto: `lifeos/agents/eval/` con:
- `golden_sets/<agent>.jsonl` — input + expected_output
- `eval.py` — corre N prompts × M examples → tabla de accuracy
- `bootstrap.py` — genera prompts candidatos pidiéndoselos al brain local

### 4.4 Cuándo fine-tunear (no aplica de entrada)

- Prompt iteration sostenida >2 semanas y accuracy <95%
- O tarea hyper-específica al dominio (jerga personal de Héctor que ningún base entiende)

**Fine-tuning costoso pero feasible**: LoRA en Qwen3-0.6B con ~500 ejemplos cabe en tu RTX 5070 Ti 12GB. ~30 min de training. Workflow standard con HuggingFace `peft`. Pero **default es prompt engineering**, no fine-tuning.

---

## 5. New components

| Componente | Path | Función |
|---|---|---|
| `lifeos.agents.runtime` | `lifeos/agents/runtime.py` | Wrapper sobre Ollama HTTP API |
| `lifeos.agents.<name>` | `lifeos/agents/<name>.py` | Cada nano-agente: prompt + parser de respuesta + golden set |
| `lifeos.agents.eval` | `lifeos/agents/eval.py` | Corre golden sets, mide accuracy |
| `lifeos.agents.bootstrap` | `lifeos/agents/bootstrap.py` | Genera prompt candidates con Qwen 35B |
| `tests/agents/` | tests/agents/ | Tests por agente, usan golden sets |
| Service `ollama` | systemd --user | Daemon de inferencia para nano-agentes |
| Dashboard `/agents` | `templates/agents.html` | UI para ver agentes activos, latencias, accuracy histórica |

---

## 6. Phased rollout

### **N0 — Foundation** (1-2 sesiones)
**Goal**: poder llamar a UN nano-agente desde Python.
- Instalar Ollama (`pacman -S ollama`).
- Bajar Qwen3-0.6B (`ollama pull qwen3:0.6b`).
- Smoke test: prompt simple desde Python.
- `lifeos.agents.runtime.AgentClient` — wrapper HTTP.

### **N1 — Intent classifier** (1-2 sesiones) ← **primer slice** · **[REALITY 2026-05-22]: SALTADO — se fue directo a N2.**
**Goal**: reemplazar la cadena lineal de 8 regex con UN classify call.
- Definir la tarea: input → domain ∈ {health, finance, relationships, exercise, spirituality, learning, events, reminders, chat}
- Bootstrap del prompt
- Golden set de 50 ejemplos reales (frases que Héctor ha tipado)
- Eval harness corre y mide
- Wirear al chat fast-path: si confidence ≥0.7, dispatch directo al regex del dominio; si no, continuar con la cadena actual.

### **N2 — Entity extractor** · **[REALITY 2026-05-22]: IMPLEMENTADO** — único nano-agente en prod hoy. Wireado en `dashboard.py:_try_nano_extract`. Bug `nano_spirituality` (4-char inputs catch-all) detectado en métricas, fixeado en `dashboard.py:2532` y `dashboard.py:1958` el 2026-05-22. Falta el harness de eval con golden sets (§4.3) para validar accuracy.
**Goal**: capturar variantes que las regex no agarran.
- Output structured JSON: `{people: [...], amounts: [{value, currency}], dates: [...], locations: [...]}`
- Wirear como fallback antes del brain (cuando ningún regex de dominio matcheó).
- Eval especialmente sobre las frases que hoy caen al brain.

### **N3 — Sentiment / mood**
**Goal**: inferir mood_pre/mood_post automáticamente en interactions + reflexiones.
- Output: int 1-10 + confidence
- Wirear en relationships.ingestion + spirituality.ingestion como auto-fill (user puede corregir)

### **N4 — Symptom classifier**
**Goal**: parsear "me duele la garganta y tengo flema desde anoche" → structured health entry.

### **N5 — Summarizer**
**Goal**: condensar texto largo para digests y retros.

### **N6 — Eval pipeline + dashboard**
**Goal**: monitorear accuracy histórica de cada nano-agente, alertar si baja.

### **N7+** — Tier 2/3 agentes según necesidad real.

---

## 7. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Spanish quality de un nano-agente flojo | M | H | Eval contra golden set ANTES de wirear. Si <85% accuracy, no shipear. |
| Maintenance burden de N agentes | H | M | Empezar con UN agente (N1). Reglas claras de "cuándo agregar". |
| Mantener prompts cuando aparezca un model nuevo | M | M | Versionar prompts en el repo. Re-correr eval con el nuevo modelo antes de migrar. |
| Latencia agregada (varios calls vs uno) | M | M | Medir end-to-end; si nano-agent + dispatch tarda más que solo regex, no se justifica. |
| RAM consumption con N agentes loaded | L | L | Ollama hace eviction. 4-5 modelos a la vez caben en 32-64GB. |
| Fine-tuning rotation (modelos base cambian) | M | M | Documentar el script de re-train. LoRA es barato (~30min). |
| Premature optimization | M | H | **Validar N1 con métricas reales antes de N2+.** Si intent classifier no muestra mejora medible, repensar. |

---

## 8. Honest scope check — ¿esto vale la pena?

Antes de gastar tiempo en N0+, hay que responder esto con números:

### Métricas para validar N1 (intent classifier) merece existir:

- **Hoy**: cuánto del chat fast-path hace fallback al brain? Si <10% de calls, el ROI es bajo.
- **Hoy**: cuál es la latencia media del fast-path? Si la cadena de 8 regex tarda <5ms, agregar 100-200ms de classify no acelera.
- **Hoy**: cuántas frases reales del Héctor mensajean al brain que un classifier+regex podría agarrar?

**Acción concreta antes de empezar**: instrumentar el dashboard con métricas por call:
- ¿En qué etapa del fast-path se resolvió? (Health regex / Finance regex / .../ brain)
- Latencia total
- Volumen mensual

Si en 1-2 semanas vemos que >30% de calls caen al brain por extracción que un nano podría agarrar, el N1 vale. Si <10%, repensar prioridades.

---

## 9. Open questions for Héctor

1. **Runtime**: ¿OK con Ollama como segundo daemon? Alternativa: extender `llama-server` actual para multi-modelo (más invasivo). Recomiendo Ollama.
2. **Métricas primero**: ¿hacemos 1 sesión de instrumentación + observación antes de N0? Yo voto SÍ — evita construir en blanco.
3. **Primer agente**: ¿intent classifier (N1, mi recomendación) o entity extractor (más complejo pero más impactful por call)?
4. **Golden set**: ¿anotás 50 ejemplos vos en 30min, o querés que yo proponga + vos corregís?
5. **Fine-tuning desde día 1**: ¿OK con default "solo prompt engineering, FT si falla"? O preferís encarar FT temprano?
6. **Scope de v1**: ¿1 agente al inicio (N1) o batch de 3 (N1+N2+N3 en paralelo)?

---

## 10. Out of scope for v1

- Multi-agente en paralelo coordinado por LLM (CrewAI/AutoGen style) — la complejidad no se paga para el caso single-user.
- Tool-use complejo entre nano-agentes — keep them as pure functions: input → output.
- Vision nano-agentes — el actual Qwen mmproj funciona para postura; mover a vision chico es proyecto aparte.
- Sharing de nano-agentes entre múltiples usuarios — sigue siendo single-user.

---

## 11. Success metrics

Para que esta fase se considere "exitosa" en 3 meses:

- **N1 (intent classifier) tiene ≥92% accuracy** en golden set + mejora medible vs brain fallback.
- **Latencia mediana del chat fast-path** baja al menos 30% para frases ambiguas (medido pre/post N2).
- **≥3 nano-agentes en producción** con golden sets versionados.
- **Tiempo de iteración de un prompt** (cambio → eval → deploy) <10 min con el harness.
- Héctor reporta subjetivamente que "Axi entiende mejor lo que le digo".

---

## 12. Next concrete action

Si greenlight:

```
sesión 1: instrumentar el chat fast-path con métricas — 1 hora
sesión 2: observar 3-5 días de uso real con métricas activas — pasivo
sesión 3: revisar datos. SI vale → /sdd-new lifeos-agents-n0
                          SI no vale → archivar este PRD honestamente
```

Si no querés instrumentar primero y preferís arrancar con N0+N1 sobre la fe:

```
/sdd-new lifeos-agents-n1
```

Mi recomendación HONESTA: instrumentación primero. Es 1 hora bien gastada que puede ahorrar 2 semanas de construir en el aire.

> **[REALITY 2026-05-22]**: la instrumentación se construyó (`lifeos.metrics.fastpath_metrics`) y se observó. El "construir en el aire" sucedió igual: N0+N2 se implementaron antes de mirar números, y los números desmintieron la premisa de latencia. Lección: instrumentar NO ALCANZA — hay que LEER los datos antes de buildear la siguiente fase. Ver §0.1 y §13.

---

## 13. Changelog

### v1.1 — 2026-05-22 (reality update)

- Status: DRAFT → PARTIALLY IMPLEMENTED, awaiting empirical decision.
- §0.1 nueva — verdad operacional al día de hoy: qué se construyó, qué se desvió, premisa de latencia refutada, bug fixeado, opciones de decisión (continue / archive).
- §1.2 — bullet de "latencia 50-200ms" marcado como falso con números reales.
- §3 — modelo en prod corregido a Qwen3.5-0.8B-Q4_K_M (no Qwen3-0.6B).
- §4.1 — runtime real: segundo `llama-server`, no Ollama. Trade-offs explícitos.
- §6 — N1 marcado SALTADO; N2 marcado IMPLEMENTADO con referencia al bug fixeado.
- §12 — nota de "instrumentar no alcanza, hay que LEER los datos".
- Memorias relacionadas: #192 (`architecture/llama-servers`), #193 (`architecture/nano-agents`), #194 (`preferences/model-currency`), #195 (`bugfix/axi-lifeos-path-dep`).

### v1.0 — 2026-05-20 (initial draft)

- Original DRAFT por Héctor Martínez. Visión completa, fases N0-N7, candidates de modelos, eval pipeline propuesto. Recomendaba Ollama + Qwen3-0.6B + N1 como primer slice.

---

*Fin del PRD. La próxima vez que se abra este documento, comparar el snapshot de métricas post-fix (≥24h después del 2026-05-22 13:09) y decidir entre A, B, C de §0.1. NO buildear más nano-agentes hasta tomar esa decisión.*
