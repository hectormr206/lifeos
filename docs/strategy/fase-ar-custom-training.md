# Fase AR — Entrenamiento Local de Modelos: Axi Aprende de la Experiencia

> Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](.) para el indice.

**Objetivo:** Que Axi pueda aprender del usuario — su estilo, preferencias, patrones y dominio — mediante fine-tuning local de modelos pequenos, sin enviar datos a la nube.

**Investigacion (2026-03-30):** Analisis de viabilidad tecnica de LoRA/QLoRA en hardware del usuario (RTX 5070 Ti, 16GB VRAM), herramientas actuales (Unsloth, llama.cpp), alternativas sin entrenamiento (RAG, procedural memory, skills), y riesgos de self-modification.

---

## 1. Hardware del Usuario: Que es Posible

| Recurso | Spec | Capacidad de Entrenamiento |
|---|---|---|
| GPU | RTX 5070 Ti, 16GB GDDR7, 896 GB/s, 1406 AI TOPS | QLoRA de modelos hasta ~14B; full LoRA hasta ~7B; full fine-tune hasta ~3B |
| Modelo actual | Qwen3.5-4B (2.7GB en disco, Q4_K_M) | Candidato ideal para QLoRA — cabe modelo + adaptador + gradientes en 16GB |
| CPU/RAM | Suficiente para preprocessing de datasets | Tokenizacion, preparacion de datos, evaluacion offline |

### Conclusion Hardware

**SI es factible.** Con QLoRA (4-bit quantization + LoRA adapters), un modelo de 4B parametros como Qwen3.5-4B cabe comodamente en 16GB VRAM con batch size 4-8 y secuencias de 2048 tokens. Unsloth reduce el uso de VRAM un 70% adicional sobre PyTorch vanilla, haciendo esto aun mas comodo.

---

## 2. Lo Que LifeOS YA Tiene (y No Necesita Entrenamiento)

Antes de entrenar modelos, hay que reconocer que LifeOS ya tiene mecanismos de aprendizaje funcionales que **no requieren GPU training**:

| Subsistema | Que Hace | Archivo |
|---|---|---|
| **Procedural Memory** | Graba workflows exitosos y los replay automaticamente | `memory_plane.rs` (tabla `procedural_memory`) |
| **Knowledge Graph** | Entidades + relaciones con confidence y decay temporal | `memory_plane.rs` (tabla `knowledge_graph`) |
| **Skill Generator** | Crea scripts ejecutables a partir de tareas exitosas | `skill_generator.rs` |
| **Skill Registry** | Hot-reload de skills desde 3 directorios, matching por trigger patterns | `skill_generator.rs` (SkillRegistry) |
| **WorkflowLearner** | Detecta secuencias repetitivas y propone automatizaciones | `self_improving.rs` |
| **PromptEvolution** | Analiza tasa de exito por tipo de accion, sugiere mejoras a prompts | `self_improving.rs` |
| **NightlyOptimizer** | Housekeeping + analisis durante horas idle (2-5 AM) | `self_improving.rs` |
| **Memory Plane + Embeddings** | Busqueda semantica con vec0, context-aware planning | `memory_plane.rs` |
| **Learning Loop** | Consulta memoria antes de planificar — "la ultima vez que hice X..." | Supervisor en `supervisor.rs` |

### Evaluacion Honesta

Estos mecanismos cubren el **80% de lo que la gente imagina cuando dice "AI que aprende"**:
- Recordar preferencias del usuario (knowledge graph + memory plane)
- No repetir errores (learning from failures)
- Automatizar tareas repetitivas (workflow learner + skill generator)
- Mejorar sus propios prompts (prompt evolution)
- Contexto personalizado (embeddings + procedural memory)

Lo que **NO** pueden hacer:
- Cambiar como el modelo genera texto (estilo, tono, formato)
- Aprender patrones complejos que requieren cambios en los pesos del modelo
- Clasificar datos con precision superior a prompting (intent classification, sentiment)
- Generar output en un dominio muy especifico donde el modelo base falla

---

## 3. Que Aportaria el Fine-Tuning Local

### 3.1 Casos de Uso Realistas (alto valor)

| Caso | Metodo | Dataset | Valor |
|---|---|---|---|
| **Estilo de comunicacion del usuario** | QLoRA SFT | ~500 mensajes del usuario (Telegram, commits, docs) | Axi responde como el usuario espera, no como GPT generico |
| **Intent classification personalizado** | QLoRA SFT | ~200 ejemplos etiquetados de intenciones | Entender "hazlo" = "ejecuta el ultimo plan" sin ambiguedad |
| **Dominio tecnico especifico** | QLoRA SFT | ~1000 pares Q&A del proyecto del usuario | Conocer APIs, convenciones, patterns del codebase |
| **Formato de respuesta** | DPO | ~100 pares (buena/mala respuesta) | Bullets vs paragrafos, largo vs corto, con/sin codigo |
| **Embeddings personalizados** | Fine-tune embedding model | Corpus de documentos del usuario | Mejor retrieval en RAG para el dominio especifico |

### 3.2 Casos de Uso Fantasia (no perseguir)

| Fantasia | Realidad |
|---|---|
| "Axi se entrena solo cada noche y amanece mas inteligente" | El fine-tuning necesita datasets curados y validacion humana. Sin supervision, el modelo degrada (catastrophic forgetting) |
| "Axi aprende a programar mejor viendo mi codigo" | Los modelos de codigo de 4B ya son competentes. El valor esta en conocer TU codebase, no en "aprender a programar" — eso es RAG, no fine-tuning |
| "RLHF local para que Axi sea perfect" | RLHF requiere reward model + policy optimization + multiples copias del modelo. Con 16GB no cabe. DPO es la alternativa realista |
| "Entrenar un modelo from scratch" | Requiere millones de ejemplos y miles de GPU-horas. Completamente inviable localmente |

---

## 4. Herramientas y Stack Tecnico

### 4.1 Entrenamiento (Python, no Rust)

El entrenamiento de modelos es un proceso Python. No hay librerias de ML training maduras en Rust. La estrategia es:

```
lifeosd (Rust) → lanza proceso Python → Unsloth fine-tune → exporta GGUF → llama-server lo carga
```

| Herramienta | Rol | Notas |
|---|---|---|
| **Unsloth** | Framework de fine-tuning | 2x mas rapido, 70% menos VRAM. Soporta Qwen, Llama, Gemma. Tiene Unsloth Studio (no-code UI) desde marzo 2026 |
| **QLoRA** | Metodo de fine-tuning | 4-bit NF4 quantization + LoRA. Solo entrena ~1% de parametros |
| **DPO** | Alineacion por preferencias | Alternativa a RLHF sin reward model. 2 copias del modelo, no 4. Cabe en 16GB |
| **llama.cpp** | Conversion e inferencia | Convierte modelo fine-tuned a GGUF para produccion. NO usar para entrenar (muy lento, limitado) |
| **Hugging Face transformers** | Tokenizacion, evaluacion | Preparar datasets, evaluar modelos antes/despues |

### 4.2 Pipeline Propuesto

```
1. Recopilar datos
   - Mensajes de Telegram (memory_plane, ya encriptados)
   - Git history (commits, PRs, code style)
   - Documentos del usuario
   - Interacciones exitosas del supervisor (audit log)

2. Preparar dataset
   - Convertir a formato instruction-tuning (system/user/assistant)
   - Filtrar datos sensibles (privacy_filter.rs ya existe)
   - Minimo 200 ejemplos para SFT, 100 pares para DPO

3. Entrenar (Unsloth)
   - QLoRA: r=16, alpha=32, target_modules=all-linear
   - Learning rate: 2e-4, cosine warmup
   - Epochs: 1-3 (small dataset, no overfit)
   - Tiempo estimado: 15-45 min para 500 ejemplos en RTX 5070 Ti

4. Evaluar
   - Comparar respuestas antes/despues en set de validacion
   - Metricas: perplexity, human preference, task success rate
   - CRITICO: si el modelo entrenado es peor, descartar

5. Exportar y desplegar
   - Merge LoRA adapter → modelo base → quantize a Q4_K_M → GGUF
   - Reemplazar modelo en llama-server (hot-swap)
   - Mantener modelo original como fallback (rollback inmediato)

6. Monitorear
   - Comparar success_rate antes/despues del cambio (PromptEvolution ya lo mide)
   - Si success_rate baja >10%, rollback automatico
```

---

## 5. Knowledge Distillation: Comprimir Inteligencia de Modelos Grandes

Una estrategia especialmente prometedora para LifeOS:

1. Enviar las preguntas dificiles a Cerebras (Qwen3-235B, gratis)
2. Guardar las respuestas de calidad superior
3. Usar esos pares (pregunta, respuesta-de-235B) como dataset de entrenamiento
4. Fine-tune el modelo local de 4B para que responda como el de 235B en esos dominios

**Ejemplo concreto:**
- Axi local no sabe explicar bien como funciona bootc
- Se acumulan 50 preguntas sobre bootc que se enrutaron a Cerebras
- Se entrenan esas 50 respuestas en el modelo local
- Ahora Axi local responde sobre bootc sin necesitar la nube

Esto es exactamente lo que Apple hace con Apple Intelligence (modelo grande en nube → destilacion a modelo on-device) y lo que DeepSeek hizo con R1 (destilaron reasoning a modelos de 1.5B-70B).

---

## 6. Lo Que Falta Construir (Propuesta de Fase)

### AR.1 — Dataset Pipeline (P0)

- [ ] `TrainingDataCollector` struct: recopila datos de memory_plane, audit logs, Telegram
- [ ] Conversor a formato instruction-tuning (Alpaca/ShareGPT)
- [ ] Integracion con privacy_filter.rs para sanitizar antes de entrenar
- [ ] Filtro de calidad: solo incluir interacciones con resultado exitoso
- [ ] CLI: `life train prepare --source telegram --min-examples 200`
- [ ] Tests unitarios

### AR.2 — Unsloth Integration (P0)

- [ ] Script Python embebido: `/var/lib/lifeos/training/train_lora.py`
- [ ] Parametros configurables via TOML: rank, alpha, epochs, learning_rate, model
- [ ] lifeosd lanza training como proceso hijo con progress reporting
- [ ] Output: LoRA adapter en `/var/lib/lifeos/models/adapters/`
- [ ] Merge + quantize automatico a GGUF
- [ ] API: `POST /api/v1/training/start`, `GET /api/v1/training/status`

### AR.3 — Evaluacion y Rollback (P0)

- [ ] Benchmark automatico: set de validacion con N preguntas + respuestas esperadas
- [ ] Comparar perplexity y task accuracy antes/despues
- [ ] Si modelo nuevo es peor: rollback automatico al modelo anterior
- [ ] Mantener historial de adaptadores con metadata (fecha, dataset, metricas)
- [ ] Integracion con PromptEvolution para monitoreo continuo post-deploy
- [ ] Notificacion via Telegram: "Entrene un modelo nuevo. Accuracy: 87% (antes: 82%). Desplegado"

### AR.4 — Knowledge Distillation Pipeline (P1)

- [ ] Guardar respuestas de providers cloud (Cerebras, OpenRouter) con sus preguntas
- [ ] Filtrar por calidad: solo respuestas que el supervisor evaluo como "ok"
- [ ] Dataset acumulativo: se enriquece con cada interaccion cloud
- [ ] Trigger automatico: cuando hay N+ ejemplos nuevos, sugerir re-entrenamiento
- [ ] Metricas: cuantas preguntas que antes iban a cloud ahora se resuelven local

### AR.5 — DPO para Preferencias del Usuario (P1)

- [ ] Recopilar pares de preferencia: cuando el usuario dice "no, asi no" → respuesta mala; cuando acepta → respuesta buena
- [ ] Formato DPO: (prompt, chosen, rejected)
- [ ] Entrenamiento DPO via Unsloth (2 copias del modelo, cabe en 16GB con QLoRA)
- [ ] Trigger: acumular 50+ pares de preferencia → sugerir DPO run

### AR.6 — Modelos Especializados Pequenos (P2)

- [ ] Intent classifier fine-tuned (~100M params, no LLM): clasificar intenciones del usuario
- [ ] Sentiment/frustration detector: modelo BERT-tiny fine-tuned en mensajes del usuario
- [ ] Embedding model personalizado: fine-tune de nomic-embed o similar con documentos del usuario
- [ ] Estos modelos son pequenos (<500MB), rapidos de entrenar (<5 min), y complementan al LLM

### AR.7 — Dashboard de Entrenamiento (P2)

- [ ] Visualizar: datasets disponibles, entrenamientos pasados, metricas comparativas
- [ ] Grafico: success_rate over time, antes/despues de cada fine-tune
- [ ] Control: iniciar/cancelar entrenamiento, seleccionar dataset, configurar parametros
- [ ] Integracion con dashboard existente (Fase AA)

---

## 7. Evaluacion Honesta: Necesitamos Entrenamiento Custom?

### Lo que el usuario quiere: "Que Axi se sienta vivo e inteligente"

La sensacion de "vivo e inteligente" viene de **5 cosas**, ordenadas por impacto:

| # | Factor | Requiere Training? | LifeOS ya lo tiene? |
|---|---|---|---|
| 1 | **Memoria**: recordar conversaciones pasadas, no repetir preguntas | No (RAG + knowledge graph) | **SI** — memory_plane con embeddings |
| 2 | **Proactividad**: sugerir cosas antes de que las pidas | No (patrones + reglas) | **Parcial** — WorkflowLearner detecta patrones, falta AQ.3 |
| 3 | **Personalizacion de tono**: responder como TU esperas | **SI** (o prompt engineering muy bueno) | **No** — AQ.2 esta pendiente |
| 4 | **Aprender de errores**: no cometer el mismo error dos veces | No (procedural memory) | **SI** — learning from failures en supervisor |
| 5 | **Adaptacion**: mejorar con el tiempo, no ser estatico | **Parcial** (fine-tuning ayuda, pero RAG + skills cubren mucho) | **Parcial** — skill generator + prompt evolution |

### Recomendacion

**Prioridad 1 (hacer AHORA, sin training):**
- Completar Fase AQ (personalizacion): User Model, adaptacion de tono via prompt engineering, prediccion proactiva
- Esto da el 70% de la sensacion de "Axi se siente vivo" sin tocar pesos del modelo

**Prioridad 2 (hacer cuando AQ este completo):**
- AR.1-AR.3: Pipeline de datos + integracion Unsloth + evaluacion
- Permite fine-tuning de estilo y dominio, el 30% restante

**Prioridad 3 (optimizacion):**
- AR.4-AR.7: Knowledge distillation, DPO, modelos especializados, dashboard
- Mejora continua una vez que la base funciona

### El Camino Incremental

```
Hoy:          RAG + Skills + Procedural Memory = "Axi recuerda y aprende trucos"
+AQ:          + User Model + Tone Adaptation    = "Axi me conoce y habla como yo quiero"
+AR.1-AR.3:   + Fine-tuned Qwen3.5-4B           = "Axi ES diferente para mi, no es generico"
+AR.4-AR.5:   + Distillation + DPO              = "Axi es experto en MIS temas y mejora con el uso"
+AR.6:        + Modelos especializados           = "Axi clasifica mis intenciones al instante"
```

---

## 8. Sobre el Video de "Entrenar Modelos con JavaScript"

El video probablemente muestra TensorFlow.js o similar para entrenar redes neuronales pequenas (clasificadores, regressores) en el navegador. Esto es **diferente** de fine-tuning de LLMs, pero la idea central es la misma: **modelos que aprenden de tus datos**.

Para LifeOS, el equivalente seria:
- **No JavaScript** — Python con Unsloth para LLMs, Rust para modelos pequenos (rustpotter ya hace esto para wake words)
- **Misma idea**: modelos que se adaptan al usuario especifico
- **Mejor resultado**: en vez de entrenar desde cero (como en JS), usamos transfer learning (QLoRA) sobre modelos que ya saben mucho

---

## 9. Riesgos y Mitigaciones

| Riesgo | Mitigacion |
|---|---|
| **Catastrophic forgetting**: el modelo olvida lo que sabia | LoRA solo modifica ~1% de pesos; evaluacion pre-deploy; rollback automatico |
| **Overfitting a pocos datos**: el modelo memoriza en vez de generalizar | Minimo 200 ejemplos; train/val split; early stopping |
| **Datos sensibles en el training set** | privacy_filter.rs ya existe; sanitizar ANTES de entrenar |
| **Modelo degradado en produccion** | Mantener modelo base como fallback; monitoreo con PromptEvolution; rollback si success_rate baja |
| **Complejidad de mantener Python stack** | Containerizar Unsloth en imagen de entrenamiento; no necesita estar siempre activo |
| **Usuario piensa que Axi "piensa" cuando solo repite patrones** | Transparencia: "Aprendi esto de tus mensajes anteriores" |

---

## Dependencias

```
Requiere completar primero:
  Fase AQ.1 (User Model) — para saber QUE personalizar
  Fase AQ.2 (Comunicacion) — para definir metricas de estilo

Dependencias tecnicas:
  - Python 3.11+ en la imagen (ya existe en Fedora base)
  - pip install unsloth (o container dedicado)
  - ~10GB espacio adicional para adaptadores y checkpoints
```

## Prioridades

```
P0 (sin esto no hay training):
  AR.1 Dataset Pipeline → AR.2 Unsloth Integration → AR.3 Evaluacion/Rollback

P1 (diferenciadores):
  AR.4 Knowledge Distillation → AR.5 DPO Preferencias

P2 (mejora la experiencia):
  AR.6 Modelos Especializados → AR.7 Dashboard
```
