# PRD — TinyAgent Swarm (Enjambre de Nanoagentes Especializados)

**Status:** Draft · 2026-04-26
**Author:** Hector + Claude
**Inspiración:** [NVIDIA "Small Language Models are the Future of Agentic AI" (2026)](https://arxiv.org/pdf/2506.02153), [Hybrid AI Routers (arXiv 2504.10519)](https://arxiv.org/html/2504.10519v1), Google Gemma 3 270M
**Predecesor:** Plan original LifeOS de "1 modelo grande Qwen3.5-9B con 128K"

---

## 1. Visión

LifeOS debe correr en **cualquier laptop de 8-12GB RAM**, sin GPU obligatoria, manteniendo **privacidad 100% local**. Para lograrlo:

> **Reemplazar (donde sea posible) el modelo monolítico grande por un enjambre de tinyagentes especializados (<512MB cada uno) corriendo en CPU+RAM, donde cada uno hace UNA tarea muy bien y muy rápido.**

El modelo grande (Qwen3.5-9B) **NO desaparece** — se reserva para razonamiento profundo y queries complejas verdaderamente novedosas. Se vuelve un **co-procesador** que se invoca solo cuando ningún tinyagent puede resolver la query.

### Por qué esta dirección

1. **Privacidad real para cualquier hardware:** no requiere VRAM, todo en RAM
2. **Paralelismo verdadero:** cada tinyagent es un proceso independiente, no comparten contexto ni KV cache
3. **Sin degradación por concurrencia:** 5 tinyagents trabajando simultáneamente = 5x throughput, no division de recursos
4. **Costo bajo de inferencia:** un 270M Q4 en CPU corre a 50-100 tok/s, latencia <100ms
5. **Industria validada:** Gartner predice 3x más adopción de SLMs vs LLMs generalistas para 2027

---

## 2. Restricciones duras (no negociables)

| Restricción | Razón |
|-------------|-------|
| **Cada tinyagent ≤ 512MB en disco/RAM (Q4_K_M)** | Caben varios en 8GB RAM con margen para sistema |
| **CPU-only inference por default** | LifeOS para todos, no asume GPU |
| **Latencia de invocación < 200ms** | Para que UI/Axi se sientan instantáneos |
| **Tinyagent solo necesita su prompt + input → output** | No requiere context histórico (ese lo da el orchestrator) |
| **Apache 2.0 / MIT solamente** | Comercial sin trabas |
| **Funciona offline** | Privacidad 100% |

**Tope total RAM del enjambre completo:** 4GB (deja margen en laptop de 8GB para sistema + dashboard + memoria + browser).

---

## 3. Catálogo de modelos candidatos (validados)

### Tier 1: Ultra-tiny (<300MB Q4) — para tareas mecánicas

| Modelo | Tamaño Q4 | Velocidad CPU | Especialidad ideal |
|--------|-----------|---------------|---------------------|
| **Gemma-3-270M** | ~180MB | 80-150 tok/s | Clasificación, routing, NER, extracción estructurada (Google lo diseñó EXACTAMENTE para esto) |
| **SmolLM2-135M** | ~90MB | 150-250 tok/s | Triage muy rápido, intent detection |
| **SmolLM2-360M** | ~250MB | 60-100 tok/s | Resumen corto, reescritura |

### Tier 2: Tiny (300-700MB Q4) — para tareas con algo de razonamiento

| Modelo | Tamaño Q4 | Velocidad CPU | Especialidad ideal |
|--------|-----------|---------------|---------------------|
| **Qwen2.5-0.5B** | ~350MB | 50-80 tok/s | Function-calling, multilingual ES |
| **TinyLlama-1.1B** | ~600MB | 30-50 tok/s | Conversación corta general |
| **Llama-3.2-1B** | ~700MB | 25-40 tok/s | Resumen estructurado, instrucciones |

### Tier 3: Small (700MB-1GB Q4) — para tareas complejas pero acotadas

| Modelo | Tamaño Q4 | Velocidad CPU | Especialidad ideal |
|--------|-----------|---------------|---------------------|
| **Qwen2.5-1.5B** | ~900MB | 20-35 tok/s | Razonamiento simple, JSON estructurado, multilingual |

### Tier 4 (escape hatch): Modelo grande on-demand

- **Qwen3.5-9B Q4** (5.5GB, GPU si disponible, sino offload) — solo invocado cuando **ningún tinyagent puede manejar la query**

---

## 4. Casos de uso priorizados — por dónde empezar

### Sprint 1 (alto valor, bajo riesgo): **Router tinyagent**

**Tarea:** clasificar cada query entrante en una de N categorías → decide qué procesador usar.

- **Modelo:** Gemma-3-270M fine-tuneado (o zero-shot inicialmente)
- **Input:** texto del usuario + metadata (origen: chat / Telegram / dashboard / tool)
- **Output:** JSON `{"category": "summarization|email|coding|chat|memory_query|…", "confidence": 0.95}`
- **Latencia objetivo:** <50ms
- **Reemplaza:** lógica hardcoded actual en `llm_router.rs`

### Sprint 2: **Resumen de reuniones (background)**

**Tarea:** mientras Whisper transcribe en tiempo real, un tinyagent resume cada chunk de 5min.

- **Modelo:** Gemma-3-270M fine-tuneado en summarization (o Llama-3.2-1B sin fine-tune)
- **Input:** transcript de los últimos 5min
- **Output:** 3-5 bullet points + temas emergentes
- **Latencia objetivo:** <2s por chunk
- **Beneficio crítico:** **libera al Qwen-9B para que vos puedas chatear con Axi en paralelo mientras grabás reunión** — hoy esto NO es posible

### Sprint 3: **Categorizador de correos**

**Tarea:** clasificar correo entrante en (urgente / importante / spam / newsletter / personal / trabajo).

- **Modelo:** Gemma-3-270M fine-tuneado con tus correos históricos (privacy-preserving)
- **Input:** subject + primeros 500 chars del body + sender
- **Output:** `{"category": "...", "priority": 1-5, "needs_response": bool}`
- **Latencia:** <100ms
- **Reemplaza:** workflow n8n actual con Ollama+Gemma 4 (más rápido, local)

### Sprint 4: **Extractor de entidades para memoria**

**Tarea:** cuando Axi recibe un mensaje, extraer entidades (personas, fechas, lugares, montos) para alimentar el knowledge graph.

- **Modelo:** Gemma-3-270M fine-tuneado en NER multilingual ES/EN
- **Input:** texto natural
- **Output:** JSON estructurado con entidades + relaciones
- **Latencia:** <100ms
- **Reemplaza:** prompts complejos al Qwen-9B que hoy hacen esto

### Sprint 5: **Function-call selector**

**Tarea:** dado que Axi tiene ~150 tools, elegir las 3-5 más relevantes para esta query (reduce contexto que se manda al LLM principal).

- **Modelo:** Qwen2.5-0.5B (mejor en JSON estructurado)
- **Input:** query + lista de tools disponibles (resumen 1-line cada uno)
- **Output:** JSON `{"selected_tools": ["mem_search", "freelance_cliente_get", ...]}`
- **Latencia:** <150ms
- **Beneficio:** menos tokens al LLM grande → más rápido + más barato

### Sprint 6+: **Tareas adicionales (lista abierta)**

- Traductor ES↔EN (Llama-3.2-1B)
- Reescritor de mensajes para diferentes tonos (formal / casual / corto)
- Extractor de TODOs en notas
- Detector de urgencia en SimpleX
- Generador de títulos para conversaciones
- Rewriter de queries para FTS5 (genera 3 reformulaciones)

---

## 5. Arquitectura técnica propuesta

### 5.1 Componentes

```
┌─────────────────────────────────────────────────────────┐
│  Orchestrator (parte de lifeosd)                        │
│  - Decide qué tinyagent invocar para qué                │
│  - Gestiona pool de procesos                            │
│  - Mide latencia + tasa de error                        │
└────────────────┬────────────────────────────────────────┘
                 │
       ┌─────────┼─────────┬─────────┬─────────┐
       ▼         ▼         ▼         ▼         ▼
   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
   │Router  │ │Resumer │ │Mailer  │ │NER     │ │Tool-   │
   │270M    │ │270M FT │ │270M FT │ │270M FT │ │Picker  │
   │CPU     │ │CPU     │ │CPU     │ │CPU     │ │0.5B CPU│
   │180MB   │ │180MB   │ │180MB   │ │180MB   │ │350MB   │
   └────────┘ └────────┘ └────────┘ └────────┘ └────────┘

Total RAM: ~1.1GB para los 5 tinyagents principales
                 │
                 ▼ (escape hatch para queries complejas)
   ┌──────────────────────────────────────────┐
   │  Qwen3.5-9B (GPU si disponible, sino    │
   │  offload). Solo invocado cuando router   │
   │  decide "esto requiere razonamiento     │
   │  profundo".                              │
   └──────────────────────────────────────────┘
```

### 5.2 Cómo se ejecutan los tinyagents

**Opción A — Pool de procesos llama-server (recomendado):**
- Cada tinyagent = una instancia llama-server en puerto distinto (8090, 8091, 8092, …)
- Carga en boot del daemon, queda residente
- HTTP API simple para invocar
- Pro: aislado, robusto, no comparte estado, ya tenés llama-server
- Con: 5 procesos = ~50MB overhead de runtime

**Opción B — Llama embedded (vía `llama-cpp-rs` u `ort`):**
- Modelos cargados dentro del proceso lifeosd
- Inferencia directa, sin HTTP
- Pro: latencia mínima, menos overhead
- Con: si un modelo crashea el daemon entero cae

**Decisión:** **Opción A** para MVP (más estable, debug fácil), evaluar Opción B post-validación.

### 5.3 systemd

Una unidad por tinyagent:
```
lifeos-tinyagent-router.service       (puerto 8090)
lifeos-tinyagent-summarizer.service   (puerto 8091)
lifeos-tinyagent-mailer.service       (puerto 8092)
lifeos-tinyagent-ner.service          (puerto 8093)
lifeos-tinyagent-tool-picker.service  (puerto 8094)
```

Permite habilitar/deshabilitar individualmente. Usuario en laptop chico desactiva los que no usa.

### 5.4 Invocación desde el daemon

Nuevo módulo `daemon/src/tinyagent/`:
```rust
pub struct TinyAgentClient {
    name: String,
    endpoint: String,
    timeout_ms: u64,
}

impl TinyAgentClient {
    pub async fn invoke(&self, input: TinyAgentInput) -> Result<TinyAgentOutput>;
}

pub struct TinyAgentRegistry {
    router: TinyAgentClient,
    summarizer: TinyAgentClient,
    // ...
}
```

`llm_router.rs` se simplifica: primero pregunta al `router` tinyagent, después dispatch.

---

## 6. Fine-tuning — pipeline local + comunidad

### 6.1 Buena noticia: la laptop estándar SÍ aguanta (con QLoRA + Unsloth)

Hardware referencia (Hector): 12GB VRAM + 32GB RAM. Validado:

| Modelo | Método | VRAM | Tiempo (1500 ejemplos) | Viable |
|--------|--------|------|------------------------|--------|
| **Gemma-3-270M** | QLoRA + Unsloth | ~2-3GB | **30-60 min** | ✅ trivial |
| **SmolLM2-360M** | QLoRA + Unsloth | ~3GB | 45-90 min | ✅ trivial |
| **Qwen2.5-0.5B** | QLoRA + Unsloth | ~3-4GB | 1-2 hrs | ✅ trivial |
| **Llama-3.2-1B** | QLoRA + Unsloth | ~5-6GB | 2-4 hrs | ✅ overnight |
| **Qwen2.5-1.5B** | QLoRA + Unsloth | ~7-9GB | 4-8 hrs | ⚠️ overnight, enchufada |
| Modelos > 3B | cualquier método | >12GB | — | ❌ no en laptop |

**Claves técnicas:**
- **QLoRA** = base cuantizado a 4-bit congelado + adapters de ~1% del modelo entrenables → VRAM baja 5-8x
- **Unsloth** (open-source) = optimización extra, otro 50-70% menos VRAM y 2x más rápido
- **Output:** archivo `.safetensors` de 10-50MB que se carga sobre el modelo base (no duplica el peso)

### 6.2 Restricción para el PRD

Tinyagent swarm asume fine-tuning local **solo para Tier 1 + Tier 2 (≤700MB)**. Si una tarea requiere un 1.5B fine-tuneado, ese modelo se entrena UNA vez (en laptop de Hector u otro contributor) y se publica para que el resto descargue.

### 6.3 Estrategia escalonada

**Etapa A — Zero-shot inicial (sprint 1-2):**
- Empezar usando modelos sin fine-tune (Gemma-3-270M instruction-tuned ya viene con buen following)
- Funcionalidad inmediata, validar arquitectura
- Logear todas las queries + respuestas del usuario (consentido, local-only)

**Etapa B — Fine-tune con datos sintéticos (sprint 3+):**
- Generar dataset usando Qwen-9B local (NO sale del laptop)
- Ejemplo: "Genera 500 ejemplos de clasificación de correos con estos labels: …"
- Entrenar Gemma-3-270M con ese dataset → tinyagent v1

**Etapa C — Fine-tune con datos reales del usuario (continua):**
- Después de N semanas de uso, hay queries reales con outcomes validados
- Re-fine-tune el tinyagent con datos reales → tinyagent v2 (mejor)
- **Knowledge distillation pasiva:** queries que se escalaron a Qwen-9B + sus respuestas → entrenan al tinyagent para no escalar la próxima vez
- **Mejora continua sin intervención manual**

**Etapa D — Compartir modelos comunitarios (opt-in):**
- Si Hector entrena un tinyagent que es genéricamente útil (ej: categorizador de correos en español), opcionalmente publicarlo en HuggingFace
- LifeOS descarga modelos comunitarios al instalarse → usuario nuevo arranca con tinyagents pre-entrenados, no en zero-shot

### 6.4 Pipeline técnico

**CLI nuevo:**
```bash
# Generar dataset (sintético, local)
life tinyagent dataset generate \
  --task email-categorizer \
  --source ~/.local/lifeos/email_history.db \
  --size 1500 \
  --teacher qwen-9b

# Entrenar (local, QLoRA, Unsloth)
life tinyagent train \
  --model gemma-3-270m \
  --task email-categorizer \
  --dataset ~/datasets/email-cat.jsonl \
  --epochs 3
# → libera Qwen-9B durante el entrenamiento
# → al terminar reactiva Qwen-9B

# Validar
life tinyagent test email-categorizer --against test-set.jsonl

# Deploy
life tinyagent deploy email-categorizer
# → reemplaza el modelo en producción + reinicia el systemd unit

# Compartir (opcional)
life tinyagent publish email-categorizer --to huggingface
```

**Módulo nuevo:** `daemon/src/tinyagent/training/` envuelve Unsloth (Python) vía subprocess (Rust no tiene buen training stack).

### 6.5 Privacidad

| Caso | Garantía |
|------|----------|
| Generación de dataset sintético | 100% local — Qwen-9B genera, datos nunca salen |
| Entrenamiento | 100% local — Unsloth corre en GPU del usuario |
| Datos reales del usuario para re-fine-tune | 100% local — base SQLite cifrada, jamás se exporta |
| Modelo entrenado | LOCAL por default. Publicación a HuggingFace es **explícita opt-in** con confirmación + diff de qué datos influyeron |
| Modelos descargados de HuggingFace | Verificación de checksum + Apache 2.0/MIT only |

### 6.6 Lo que NO hacemos

- ❌ Mandar datos del usuario a APIs cloud para fine-tune (rompe privacy)
- ❌ Pre-training desde cero (ridículo en laptop)
- ❌ Full fine-tune de modelos >500M (no entra en VRAM consumer)
- ❌ Auto-publicar modelos sin consentimiento explícito del usuario

---

## 7. Métricas de éxito

| Métrica | Baseline (hoy) | Target post-implementación |
|---------|----------------|----------------------------|
| RAM ocupada por inferencia idle | 5.5GB (Qwen-9B residente) | <1.5GB (5 tinyagents) |
| Latencia media de query simple | 800-1500ms (Qwen-9B) | <200ms (tinyagent directo) |
| Throughput Axi en paralelo (queries simultáneas) | 1 (bloquea Qwen) | 5+ (cada tinyagent independiente) |
| Hardware mínimo requerido | 12GB RAM + 8GB VRAM ideal | 8GB RAM, sin GPU |
| % de queries resueltas por tinyagent (sin invocar Qwen-9B) | 0% | >70% objetivo |
| Tiempo cold-start del daemon | ~15s | <8s (modelos chicos cargan rápido) |

---

## 8. Plan de migración por fases

### Fase 0 (pre-trabajo, ~2 semanas wall-clock)
- Telemetría: logear todas las queries actuales a Qwen-9B con su tipo
- Análisis: clasificar manualmente 500 queries → cuántas son "simples" (candidatas a tinyagent)
- **Decision gate:** si >60% son simples → seguir. Si <40% → repensar.

### Fase 1 (~10-15h): Infraestructura
- Módulo `daemon/src/tinyagent/` (cliente + registry)
- Systemd template para tinyagents
- 1 tinyagent piloto: el **Router** (Gemma-3-270M zero-shot)
- Métricas: latencia, accuracy del router

### Fase 2 (~8-10h): Resumer de reuniones
- Tinyagent summarizer (Gemma-3-270M zero-shot inicial)
- Integración con whisper-server para chunks
- UI: mostrar resumen incremental en dashboard
- Validar: **podés chatear con Axi mientras Whisper+Summarizer corren**

### Fase 3 (~10h): Categorizador correos
- Reemplaza workflow n8n actual
- Fine-tune con tus correos históricos en VPS
- Backfill de correos pasados re-categorizados

### Fase 4 (~8h): NER + Tool-picker
- Acelera memoria + reduce tokens al LLM grande

### Fase 5 (~ongoing): Más tinyagents según demanda
- Cada tarea repetitiva = candidato

### Fase 6 (~6h): Knowledge distillation pasiva
- Pipeline para mejorar tinyagents con uso real

---

## 9. Riesgos honestos

| Riesgo | Probabilidad | Mitigación |
|--------|--------------|------------|
| Fine-tuning local resulta inviable sin GPU | Alta | Empezar zero-shot; fine-tune en VPS (CPU lento pero gratis) |
| Tinyagents tienen accuracy insuficiente para producción | Media | Decision gate por tarea: si <85% → no migrar esa tarea |
| Orchestrator se vuelve cuello de botella | Baja | Latencia HTTP local <5ms, despreciable |
| Mantenimiento de N modelos = N veces más bugs | Media | Cada tinyagent es trivial (1 prompt + 1 task), bug surface chica |
| Usuarios se confunden con tantos servicios systemd | Baja | Dashboard les muestra como "AI workers", no como servicios |
| Modelos pre-fine-tuneados no existen para tareas en español | Media | Fine-tune local con datasets sintéticos generados por Qwen-9B |
| 270M no entiende español rioplatense bien | Media | Validar con casos reales antes de comprometerse |

---

## 10. Lo que NO se cambia

- **Qwen3.5-9B sigue como modelo principal** — solo se reduce la frecuencia de invocación
- **Modo Privacidad** sigue funcionando — todo es local
- **APIs cloud (Claude, GPT-4)** siguen disponibles para usuarios que opten — el enjambre no las reemplaza, las complementa
- **Dashboard, SimpleX, n8n** no se tocan — solo cambia qué consume detrás
- **Memoria, encripción, knowledge graph** intactos

---

## 11. Estimación total

| Fase | Esfuerzo |
|------|----------|
| Fase 0 (telemetría + análisis) | 4h código + 2 semanas wall-clock |
| Fase 1 (infra + router piloto) | 10-15h |
| Fase 2 (summarizer reuniones) | 8-10h |
| Fase 3 (categorizador correos) | 10h |
| Fase 4 (NER + tool-picker) | 8h |
| Fase 5+ (más tinyagents) | 4-6h por tinyagent adicional |
| Fase 6 (distillation passive) | 6h |
| **Fase 7 (training pipeline local)** | **15-20h** (CLI `life tinyagent train`, módulo Unsloth wrapper, validación) |
| **Fase 8 (model sharing comunitario)** | **8-10h** (publish/download flow, checksum, verificación licencia) |

**Total Fases 0-4: ~40-50h** + 2 semanas validación. Fases 5-8 incrementales (~30-40h adicionales para el pipeline completo de fine-tuning).

---

## 12. Decisiones pendientes (para charlar antes de empezar)

- [ ] ¿Empezamos zero-shot o invertimos en fine-tuning desde el día 1?
- [ ] ¿Aceptamos correr fine-tunes en el VPS (CPU lento pero privacy-safe) o usamos un servicio cloud para entrenar UNA vez los modelos base?
- [ ] ¿Cuántos tinyagents máximo en la imagen base de LifeOS? (5 default + opt-in para más?)
- [ ] ¿Usuarios pueden agregar tinyagents propios? (UX para "instalar tinyagent")
- [ ] ¿Métricas de fine-tune son privadas (local) o se exportan opcionalmente?

---

## 13. Próximos pasos

1. **Aprobar este PRD** (Hector ✅ — pending)
2. **NO empezar antes de:**
   - Terminar deploy actual (Life Areas v1)
   - Ejecutar PRD Memory Simplification (FTS5 first) — son pre-requisito para algunos tinyagents
3. **Crear change** vía `/sdd-new tinyagent-swarm` cuando esté listo
4. **Sprint Fase 0 primero** — datos antes que opiniones

---

## Apéndice A — Referencias

- [NVIDIA: Small Language Models are the Future of Agentic AI (2026)](https://arxiv.org/pdf/2506.02153)
- [Survey: SLMs for Agentic Systems (arXiv 2510.03847)](https://arxiv.org/abs/2510.03847)
- [Hybrid AI Routers — Super Agent System (arXiv 2504.10519)](https://arxiv.org/html/2504.10519v1)
- [Google: Introducing Gemma 3 270M](https://developers.googleblog.com/en/introducing-gemma-3-270m/)
- [Own your AI: Fine-tune Gemma 3 270M on-device](https://developers.googleblog.com/own-your-ai-fine-tune-gemma-3-270m-for-on-device/)
- [Best Small AI Models 2026 — Local AI Master](https://localaimaster.com/blog/small-language-models-guide-2026)
- [SmolLM2 model family (HuggingFace)](https://huggingface.co/HuggingFaceTB)
- [Qwen2.5-0.5B specifications](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct)

---

## Apéndice B — Hardware target validado

| Hardware | RAM disponible para AI | Tinyagents que caben |
|----------|------------------------|----------------------|
| Laptop 8GB RAM | ~3GB | 5 tinyagents (Router 180MB + Summarizer 180MB + Mailer 180MB + NER 180MB + Tool-picker 350MB = 1.1GB, queda margen) |
| Laptop 12GB RAM (estándar 2026) | ~5GB | 8-10 tinyagents + Qwen3.5-9B compartido CPU/GPU |
| Workstation 32GB RAM | ~20GB | enjambre completo + Qwen-9B + Qwen3.6-35B-A3B opt-in |

**LifeOS funciona en TODO el rango sin cambios de arquitectura.**
