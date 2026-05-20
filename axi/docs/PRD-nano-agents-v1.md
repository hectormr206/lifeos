# PRD — LifeOS / Axi · Nano-Agents (v1)

> **Authored**: 2026-05-20
> **Owner**: Héctor Martínez
> **Status**: DRAFT — awaiting review and phase greenlight
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

### **N1 — Intent classifier** (1-2 sesiones) ← **primer slice**
**Goal**: reemplazar la cadena lineal de 8 regex con UN classify call.
- Definir la tarea: input → domain ∈ {health, finance, relationships, exercise, spirituality, learning, events, reminders, chat}
- Bootstrap del prompt
- Golden set de 50 ejemplos reales (frases que Héctor ha tipado)
- Eval harness corre y mide
- Wirear al chat fast-path: si confidence ≥0.7, dispatch directo al regex del dominio; si no, continuar con la cadena actual.

### **N2 — Entity extractor**
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

---

*Fin del PRD. Decisiones pendientes están en §9. Cuando revises, marca lo que querés cambiar y desde ahí seguimos.*
