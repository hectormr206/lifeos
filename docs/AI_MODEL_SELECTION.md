# Seleccion del Modelo Fundacional de LifeOS

> Documento tecnico de justificacion para la seleccion del modelo de IA por defecto en LifeOS.
> Enlace desde: `docs/lifeos-ai-distribution.md` seccion 26.

## Veredicto

**Qwen3-VL-4B-Instruct** es el modelo fundacional por defecto de LifeOS.

| Propiedad               | Valor                                                 |
| ----------------------- | ----------------------------------------------------- |
| Parametros              | 4B                                                    |
| Cuantizacion            | Q4_K_M (pesos) + Q8_0 (vision projector)              |
| Archivo modelo          | `Qwen3VL-4B-Instruct-Q4_K_M.gguf` (~2.5GB)            |
| Archivo mmproj          | `mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf` (~454MB)       |
| Origen                  | https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF |
| Contexto maximo         | 256,000 tokens (configurado a 131,072)                |
| RAM estimada (128K ctx) | ~6.1GB (pesos Q4_K_M + KV cache Q4_0)                 |
| Motor de inferencia     | llama.cpp (llama-server)                              |
| Multimodal              | Si — vision nativa (GUI grounding, OCR, screenshots)  |
| Audio                   | No — delegado a whisper.cpp (pipeline separado)       |

## Requisitos del agente LifeOS

1. **Multimodalidad nativa** — ver la interfaz grafica, interpretar screenshots, localizar botones
2. **Contexto >100K tokens** — mantener sesiones largas, logs, documentacion
3. **Function calling** — invocar herramientas del sistema (shell, mouse, filesystem)
4. **CPU-only** — funcionar sin GPU dedicada en portatiles estandar (8-16GB RAM)
5. **<5B parametros** — caber en el presupuesto de memoria junto con el OS
6. **Soporte estable en llama.cpp** — GGUF + mmproj funcionando en produccion

## Modelos evaluados

### Qwen3-VL-4B-Instruct (seleccionado)

- **Contexto:** 256K tokens
- **GUI Grounding (ScreenSpot):** 92.9% — el mejor en su clase para automatizacion de escritorio
- **OCR:** Superior gracias a arquitectura DeepStack
- **Soporte llama.cpp:** Maduro y estable (GGUF + mmproj oficial)
- **Debilidad:** No procesa audio (requiere whisper.cpp como companero)

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

| Metrica           | Qwen3-VL-4B | Gemma 3 4B    | Gemma 3n E4B  | Phi-4-Mini |
| ----------------- | ----------- | ------------- | ------------- | ---------- |
| Contexto          | 256K        | 128K          | 32K           | 128K       |
| ScreenSpot (GUI)  | 92.9%       | N/A           | N/A           | N/A        |
| MMLU              | 81.5%       | ~75%          | ~72%          | 84.8%      |
| MathVista         | 79.5%       | 50.0%         | N/A           | N/A        |
| Vision nativa     | Si          | Si            | Si            | No         |
| Audio nativo      | No          | No            | Si            | No         |
| llama.cpp estable | Si          | Si            | No            | Parcial    |
| Licencia          | Apache 2.0  | Gemma License | Gemma License | MIT        |

## Matematicas de viabilidad en CPU

### Sin optimizacion (FP16, inviable)

| Componente             | RAM         |
| ---------------------- | ----------- |
| Pesos estaticos        | ~8.0GB      |
| Buffer overhead        | ~0.6GB      |
| KV cache (128K tokens) | ~9.5GB      |
| **Total**              | **~18.1GB** |

### Con optimizacion (Q4_K_M + KV Q4_0, viable)

| Componente                  | RAM        |
| --------------------------- | ---------- |
| Pesos estaticos Q4_K_M      | ~2.3GB     |
| mmproj Q8_0                 | ~0.5GB     |
| Buffer overhead             | ~0.6GB     |
| KV cache Q4_0 (128K tokens) | ~3.2GB     |
| **Total**                   | **~6.6GB** |

La reduccion de 18.1GB a 6.6GB es posible gracias a:

- Cuantizacion de pesos: Q4_K_M (~0.57 bytes/parametro)
- Cuantizacion del KV cache: `--cache-type-k q4_0 --cache-type-v q4_0`
- Flash Attention: `--flash-attn` (reduce pico de RAM y latencia)

## Configuracion en LifeOS

### Archivo de entorno: `/etc/lifeos/llama-server.env`

```
LIFEOS_AI_MODEL=Qwen3VL-4B-Instruct-Q4_K_M.gguf
LIFEOS_AI_MMPROJ=mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf
LIFEOS_AI_CTX_SIZE=131072
LIFEOS_AI_CACHE_TYPE_K=q4_0
LIFEOS_AI_CACHE_TYPE_V=q4_0
LIFEOS_AI_FLASH_ATTN=1
LIFEOS_AI_THREADS=4
LIFEOS_AI_GPU_LAYERS=0
LIFEOS_AI_HOST=127.0.0.1
LIFEOS_AI_PORT=8082
```

### Comando equivalente de llama-server

```bash
llama-server \
    --model /var/lib/lifeos/models/Qwen3VL-4B-Instruct-Q4_K_M.gguf \
    --mmproj /var/lib/lifeos/models/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf \
    --ctx-size 131072 \
    --cache-type-k q4_0 \
    --cache-type-v q4_0 \
    --flash-attn \
    --threads 8 \
    --host 127.0.0.1 \
    --port 8082
```

## Arquitectura de audio (futuro)

El procesamiento de voz se delega a **whisper.cpp** como daemon systemd separado:

- Modelo: Whisper-Base (~74MB RAM, <200MB total)
- Funcion: Speech-to-Text continuo desde microfono
- Comunicacion: Socket local hacia llama-server API
- Ventaja: Desacoplado del modelo principal, sin punto unico de fallo

## Ruta de upgrade

Cuando el usuario tenga hardware mas potente (GPU o >32GB RAM), puede cambiar a modelos mayores editando `/etc/lifeos/llama-server.env`:

| Hardware           | Modelo recomendado           | Contexto |
| ------------------ | ---------------------------- | -------- |
| 8GB RAM, CPU only  | Qwen3-VL-4B Q4_K_M (default) | 128K     |
| 16GB RAM, CPU only | Qwen3-VL-4B Q8_0             | 128K     |
| 32GB+ RAM o GPU    | Qwen3-VL-8B Q4_K_M           | 256K     |
