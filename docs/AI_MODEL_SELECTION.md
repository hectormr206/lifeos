# Seleccion del Modelo Fundacional de LifeOS

> Documento tecnico de justificacion para la seleccion del modelo de IA por defecto en LifeOS.
> Enlace desde: `docs/lifeos-ai-distribution.md` seccion 26.

## Veredicto

**Qwen3.5-4B** es el modelo fundacional por defecto de LifeOS.

| Propiedad               | Valor                                                 |
| ----------------------- | ----------------------------------------------------- |
| Parametros              | 4B                                                    |
| Arquitectura            | Hibrida: Gated DeltaNet (75%) + Full Attention (25%)  |
| Cuantizacion            | Q4_K_M (pesos) + F16 (vision projector)               |
| Archivo modelo          | `Qwen3.5-4B-Q4_K_M.gguf` (~2.74GB)                   |
| Archivo mmproj          | `Qwen3.5-4B-mmproj-F16.gguf` (~672MB)                 |
| Origen                  | https://huggingface.co/unsloth/Qwen3.5-4B-GGUF        |
| Contexto nativo         | 262,144 tokens (extensible a 1,010,000 con YaRN)      |
| Contexto configurado    | 16,384 tokens (por defecto, ajustable)                 |
| RAM estimada (16K ctx)  | ~5.5GB (segun Unsloth: 4B Q4 = 5.5GB)                 |
| Motor de inferencia     | llama.cpp (llama-server, build estatico)               |
| Multimodal              | Si — vision nativa (GUI grounding, OCR, screenshots)   |
| Audio                   | No — delegado a whisper.cpp (pipeline separado)        |
| Licencia                | Apache 2.0                                             |

## Contexto por defecto: 16K

Aunque Qwen3.5-4B soporta hasta 262K tokens nativos, LifeOS configura **16,384 tokens por defecto** (recomendado por Unsloth). Razones:

1. **RAM**: Segun Unsloth, 4B Q4 necesita ~5.5GB total — viable en maquinas de 8GB
2. **Latencia**: Contextos mas cortos = menor tiempo de prefill y generacion mas rapida en CPU
3. **Uso real**: La mayoria de interacciones (preguntas, comandos, capturas) caben en 16K
4. **Gated DeltaNet**: 75% de las capas usan atencion lineal con estado constante, el KV cache solo crece en el 25% de capas con atencion completa
5. **Escalable**: El usuario puede subir a 32K, 65K, 128K o 262K editando `LIFEOS_AI_CTX_SIZE` en `/etc/lifeos/llama-server.env`

### Estimaciones de RAM por cuantizacion (fuente: Unsloth)

| Cuantizacion | RAM total (4B) | RAM total (9B) |
| ------------ | -------------- | -------------- |
| 3-bit        | ~4.5GB         | ~5.5GB         |
| 4-bit (Q4)   | ~5.5GB         | ~6.5GB         |
| 6-bit        | ~7.0GB         | ~9.0GB         |
| 8-bit        | ~10.0GB        | ~13.0GB        |
| BF16         | ~14.0GB        | ~19.0GB        |

> Nota: Estas cifras incluyen modelo + contexto estandar. Aumentar el contexto incrementa la RAM proporcionalmente en las capas de atencion completa (25% del modelo).

## Requisitos del agente LifeOS

1. **Multimodalidad nativa** — ver la interfaz grafica, interpretar screenshots, localizar botones
2. **Contexto largo** — soporte nativo >100K tokens (escalable por el usuario)
3. **Function calling** — invocar herramientas del sistema (shell, mouse, filesystem)
4. **CPU-only** — funcionar sin GPU dedicada en portatiles estandar (8-16GB RAM)
5. **<5B parametros** — caber en el presupuesto de memoria junto con el OS
6. **Soporte estable en llama.cpp** — GGUF + mmproj funcionando con llama-server

## Por que Qwen3.5 sobre Qwen3-VL

Qwen3.5 representa un cambio generacional respecto a Qwen3-VL:

| Aspecto                 | Qwen3-VL-4B                 | Qwen3.5-4B                        |
| ----------------------- | --------------------------- | --------------------------------- |
| Contexto nativo         | 256K                        | 262K (extensible a 1M)            |
| Arquitectura            | Full Attention              | Hibrida DeltaNet + Attention      |
| KV cache (128K)         | ~3.2GB (Q4_0)               | ~2.0GB (75% linear, estado fijo)  |
| MMLU-Redux              | 81.5%                       | 88.8%                             |
| MathVista               | 79.5%                       | 85.1%                             |
| MMMU                    | —                           | 77.6%                             |
| ScreenSpot Pro          | N/A                         | 60.3%                             |
| OSWorld-Verified        | N/A                         | 35.6%                             |
| AndroidWorld            | N/A                         | 58.6%                             |
| Function calling        | Basico                      | Nativo (qwen3_coder parser)       |
| Thinking mode           | No                          | Si (activable)                    |
| Vision integrada        | Via mmproj separado          | Via mmproj (early fusion)         |
| Licencia                | Apache 2.0                  | Apache 2.0                        |

**Mejoras clave:**
- **+7.3 puntos MMLU** — mejor comprension general
- **+5.6 puntos MathVista** — mejor razonamiento visual-matematico
- **Benchmarks de GUI agent** (ScreenSpot Pro 60.3%, OSWorld 35.6%, AndroidWorld 58.6%) — validacion directa para automatizacion de escritorio
- **Thinking mode** — razonamiento paso a paso activable para tareas complejas
- **Arquitectura hibrida** — KV cache mas eficiente para contextos largos

## Modelos evaluados

### Qwen3.5-4B (seleccionado)

- **Contexto:** 262K tokens (extensible a 1M)
- **GUI Grounding (ScreenSpot Pro):** 60.3%
- **OSWorld-Verified:** 35.6% — benchmark de automatizacion de escritorio real
- **AndroidWorld:** 58.6% — benchmark de agente movil
- **MMLU-Redux:** 88.8%
- **OCR:** CC-OCR 76.7%, OCRBench 85.0%
- **Soporte llama.cpp:** GGUF + mmproj (unsloth)
- **Debilidad:** No procesa audio (requiere whisper.cpp)

### Qwen3-VL-4B-Instruct (modelo anterior)

- **Contexto:** 256K tokens
- **GUI Grounding (ScreenSpot):** 92.9% (benchmark mas antiguo, no comparable con ScreenSpot Pro)
- **MMLU:** 81.5%
- **Soporte llama.cpp:** Maduro (GGUF + mmproj oficial)
- **Limitaciones:** Full attention = KV cache grande, sin thinking mode, benchmarks de agente no publicados

### Gemma 3 4B (Google DeepMind)

- **Contexto:** 128K tokens
- **Vision:** SigLIP con Pan & Scan, competente pero inferior en GUI grounding
- **Debilidad fatal para LifeOS:** La variante optimizada Gemma 3n solo soporta 32K tokens de contexto

### Gemma 3n E4B (Google DeepMind)

- **Multimodal nativo:** Texto + imagen + video + audio directo (USM encoder)
- **Debilidad fatal:** Contexto limitado a 32,000 tokens — insuficiente
- **Debilidad fatal:** Soporte mmproj fragmentado en llama.cpp

### Phi-4-Mini 3.8B (Microsoft Research)

- **Contexto:** 128K tokens
- **Razonamiento matematico:** Superior (GSM8k, MATH)
- **Debilidad:** Solo texto, sin vision nativa
- **Debilidad:** Phi-4-Multimodal (5.6B) tiene soporte inestable en llama.cpp

### FunctionGemma 270M (Google)

- **Function calling:** 85% BFCL, 250 tok/s en CPU
- **Debilidad fatal:** Sin vision, sin capacidad conversacional
- **Uso potencial:** Modelo satelite para enrutamiento de funciones (futuro)

## Comparativa critica

| Metrica           | Qwen3.5-4B  | Qwen3-VL-4B  | Gemma 3 4B    | Gemma 3n E4B  | Phi-4-Mini |
| ----------------- | ----------- | ------------- | ------------- | ------------- | ---------- |
| Contexto          | 262K (1M)   | 256K          | 128K          | 32K           | 128K       |
| MMLU-Redux        | 88.8%       | 81.5%         | ~75%          | ~72%          | 84.8%      |
| MathVista         | 85.1%       | 79.5%         | 50.0%         | N/A           | N/A        |
| MMMU              | 77.6%       | N/A           | N/A           | N/A           | N/A        |
| ScreenSpot Pro    | 60.3%       | N/A           | N/A           | N/A           | N/A        |
| OSWorld           | 35.6%       | N/A           | N/A           | N/A           | N/A        |
| Vision nativa     | Si          | Si            | Si            | Si            | No         |
| Audio nativo      | No          | No            | No            | Si            | No         |
| Thinking mode     | Si          | No            | No            | No            | No         |
| KV cache eficiente| Si (hybrid) | No            | No            | No            | No         |
| llama.cpp estable | Si          | Si            | Si            | No            | Parcial    |
| Licencia          | Apache 2.0  | Apache 2.0    | Gemma License | Gemma License | MIT        |

## Matematicas de viabilidad en CPU

### Configuracion por defecto (Q4_K_M + 32K ctx)

| Componente                   | RAM        |
| ---------------------------- | ---------- |
| Pesos estaticos Q4_K_M       | ~2.74GB    |
| mmproj F16                   | ~0.67GB    |
| Buffer overhead              | ~0.5GB     |
| KV cache (32K, hibrido)      | ~0.6GB     |
| **Total**                    | **~4.5GB** |

### Configuracion extendida (Q4_K_M + 128K ctx)

| Componente                   | RAM        |
| ---------------------------- | ---------- |
| Pesos estaticos Q4_K_M       | ~2.74GB    |
| mmproj F16                   | ~0.67GB    |
| Buffer overhead              | ~0.5GB     |
| KV cache (128K, hibrido)     | ~2.5GB     |
| **Total**                    | **~6.4GB** |

### Sin optimizacion (BF16, inviable)

| Componente                   | RAM         |
| ---------------------------- | ----------- |
| Pesos estaticos              | ~8.4GB      |
| mmproj                       | ~0.67GB     |
| Buffer overhead              | ~0.6GB      |
| KV cache (128K tokens)       | ~8.0GB      |
| **Total**                    | **~17.7GB** |

La reduccion de 17.7GB a ~5.5GB (configuracion por defecto) es posible gracias a:

- Cuantizacion de pesos: Q4_K_M (~0.57 bytes/parametro)
- Arquitectura hibrida: 75% Gated DeltaNet (estado fijo) + 25% full attention (KV cache)
- Contexto conservador: 16K por defecto (suficiente para uso interactivo)
- Escalable: El usuario sube `LIFEOS_AI_CTX_SIZE` segun su RAM disponible

## Configuracion en LifeOS

### Archivo de entorno: `/etc/lifeos/llama-server.env`

```
LIFEOS_AI_MODEL=Qwen3.5-4B-Q4_K_M.gguf
LIFEOS_AI_MMPROJ=Qwen3.5-4B-mmproj-F16.gguf
LIFEOS_AI_CTX_SIZE=16384
LIFEOS_AI_THREADS=4
LIFEOS_AI_GPU_LAYERS=0
LIFEOS_AI_HOST=127.0.0.1
LIFEOS_AI_PORT=8082
LIFEOS_AI_ALIAS=lifeos
```

### Comando equivalente de llama-server

```bash
llama-server \
    --model /var/lib/lifeos/models/Qwen3.5-4B-Q4_K_M.gguf \
    --mmproj /var/lib/lifeos/models/Qwen3.5-4B-mmproj-F16.gguf \
    --alias lifeos \
    --ctx-size 16384 \
    --threads 4 \
    --host 127.0.0.1 \
    --port 8082 \
    --jinja
```

### Flags importantes (fuente: Unsloth)

| Flag | Proposito |
| ---- | --------- |
| `--jinja` | Requerido para parsing correcto de tool calling y chat templates |
| `--alias` | Nombre del modelo en respuestas de la API OpenAI-compatible |
| `--mmproj` | Proyector de vision multimodal (F16 para maxima calidad) |
| `--ctx-size` | 16384 por defecto (262K maximo nativo) |

## Ciclo de vida recomendado para modelos pesados

- El canal normal de LifeOS debe traer preinstalados los runtimes y assets pequenos de voz, no todos los LLM pesados.
- Los modelos pesados deben gestionarse como contenido del usuario en `/var/lib/lifeos/models`.
- La seleccion por defecto debe persistirse en `/etc/lifeos/llama-server.env`, y `life ai select <modelo>` debe mantener sincronizados `LIFEOS_AI_MODEL` y `LIFEOS_AI_MMPROJ`.
- El roster inicial del selector visual debe priorizar `Qwen3.5-4B`, `Qwen3.5-9B` y `Qwen3.5-27B`, cada uno con su `mmproj` dedicado.
- Si el usuario elimina un modelo pesado, una actualizacion del sistema no debe reinstalarlo automaticamente sin una accion explicita del usuario.

### Parametros de sampling recomendados (Unsloth)

Para uso general (non-thinking, instruct mode):
```
temperature=0.7, top_p=0.8, top_k=20, min_p=0.0, presence_penalty=1.5
```

Para tareas de razonamiento o thinking mode:
```
temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5
```

Para coding preciso:
```
temperature=0.6, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0
```

> Nota: Los parametros de sampling se configuran por request en la API, no en el servicio.

### Thinking mode

En Qwen3.5 Small (4B), el thinking mode esta **desactivado por defecto**. Para activarlo, agregar al ExecStart:

```
--chat-template-kwargs '{"enable_thinking":true}'
```

O activarlo por request individual via la API:
```json
{"enable_thinking": true}
```

> Referencia: https://unsloth.ai/docs/models/qwen3.5

## Arquitectura de audio (futuro)

El procesamiento de voz se delega a **whisper.cpp** como daemon systemd separado:

- Modelo: Whisper-Base (~74MB RAM, <200MB total)
- Funcion: Speech-to-Text continuo desde microfono
- Comunicacion: Socket local hacia llama-server API
- Ventaja: Desacoplado del modelo principal, sin punto unico de fallo

## Ruta de upgrade

Cuando el usuario tenga hardware mas potente (GPU o >32GB RAM), puede cambiar a modelos mayores editando `/etc/lifeos/llama-server.env`:

| Hardware           | Modelo recomendado              | Contexto recomendado |
| ------------------ | ------------------------------- | -------------------- |
| 8GB RAM, CPU only  | Qwen3.5-4B Q4_K_M (default)    | 32K                  |
| 16GB RAM, CPU only | Qwen3.5-4B Q4_K_M              | 128K                 |
| 16GB RAM, CPU only | Qwen3.5-9B Q4_K_M              | 32K                  |
| 32GB+ RAM o GPU    | Qwen3.5-9B Q4_K_M              | 128K                 |
| GPU 24GB VRAM      | Qwen3.5-27B Q4_K_M             | 65K                  |

## Historial de cambios

| Fecha      | Modelo anterior        | Modelo nuevo  | Razon                                    |
| ---------- | ---------------------- | ------------- | ---------------------------------------- |
| 2026-03-02 | Qwen3-VL-4B-Instruct  | Qwen3.5-4B    | Upgrade generacional: mejor MMLU (+7.3), GUI agent benchmarks, thinking mode, arquitectura hibrida con KV cache eficiente |
