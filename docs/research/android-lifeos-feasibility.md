# LifeOS on Android — Feasibility Research

**Target hardware:** Google Pixel 7 Pro (Tensor G2 SoC)
**Research date:** June 2026
**Scope:** Documentation / go-no-go analysis. No application code is produced here.

---

## Executive Summary

Building LifeOS on Android is **technically feasible** but requires a significant, focused engineering effort and demands realistic expectations about what the Pixel 7 Pro hardware can sustain.

The core tension is this: the PC version of LifeOS relies on a relatively unconstrained environment — dedicated CPU/GPU, no OS-level process killing, no thermals budget. The Pixel 7 Pro is a capable phone but it is not a desktop. Sustained LLM inference will thermal-throttle within 60–90 seconds of heavy use, background execution is fundamentally constrained by Android's power management, and the Tensor G2's GPU (Mali-G710) is a poor LLM accelerator with current software stacks.

**Recommendation: GO — but with a narrowed MVP scope and a clear-eyed limitations table.**

The recommended path is a **native Kotlin/Jetpack Compose app** embedding **Google LiteRT-LM** (formerly MediaPipe LLM Inference API) with **Gemma 3n E4B** as the primary brain, supplemented by **whisper.cpp** for STT and **Piper/Kokoro** for TTS, on top of **SQLCipher** for the encrypted life-data store. This stack is production-proven, entirely on-device, and gives the best balance of performance and integration depth on the Pixel 7 Pro specifically.

### Top 3 Limitations

1. **Thermal throttling caps sustained throughput.** After ~90 seconds of continuous generation, the Tensor G2 will throttle and may cut token rate by 40–60% or more. The Android OS may forcibly terminate GPU inference (as documented on the S24 Ultra at 78°C). LifeOS interactions must be designed for short, bursty inference, not marathon reasoning sessions.

2. **Mali-G710 GPU is not a viable LLM accelerator with current open-source stacks.** llama.cpp's Vulkan backend is 14–17× slower than CPU on Mali GPUs. MLC-LLM uses OpenCL (not Vulkan) on Mali but is not well-maintained for Android 2025+. LiteRT-LM uses proprietary optimized kernels and is the only stack with credible GPU acceleration on Tensor G2 — and even then, the Tensor TPU is limited to Google's own model pipeline and is not accessible for arbitrary custom models without experimental SDK access.

3. **Background execution is structurally restricted.** Android 15+ limits `dataSync` and `mediaProcessing` foreground services to **6 hours per 24-hour window**. An always-on assistant paradigm is not realizable the same way it is on a desktop. The platform must shift to a notification-driven, on-demand activation model.

---

## Section 1 — Target Hardware: Pixel 7 Pro / Tensor G2

### SoC Configuration

| Component | Specification |
|-----------|--------------|
| Chip | Google Tensor G2 (5nm Samsung) |
| CPU | 2× Cortex-X1 @ 2.85 GHz + 2× Cortex-A78 @ 2.35 GHz + 4× Cortex-A55 @ 1.8 GHz |
| GPU | Mali-G710 MP7 (7 shader cores) |
| TPU | Tensor EdgeTPU (3rd gen) — tightly coupled to Google's pipeline |
| RAM | 12 GB LPDDR5 |
| Storage | 128/256/512 GB UFS 3.1 |
| Memory bandwidth | ~51.2 GB/s (LPDDR5 theoretical) |
| Android (2026) | Android 16 (confirmed; 5-year support commitment by Google) |

### Memory Bandwidth Context for LLM Inference

The theoretical ceiling for autoregressive decode is set by memory bandwidth. A Q4_K_M 3B model reads approximately 1.6–2.0 GB of weights per output token. At 51 GB/s theoretical LPDDR5 bandwidth (realistic effective bandwidth closer to 30–40 GB/s after memory controller overhead and OS contention), the absolute ceiling is roughly **15–25 tokens/second on CPU** for a well-quantized 3B model. This aligns with empirical data from the Pixel 8 (same Tensor G3 family): 12–15 tok/s at Q4_K_M for a 3B model ([MVP Factory, 2025](https://mvpfactory.io/blog/on-device-llm-inference-via-kmp-and-llama-cpp-memory-mapped-model-loading-ane)).

### The Tensor TPU: What It Can and Cannot Do

The Tensor G2 TPU is designed for Google's camera, speech, and first-party ML pipeline — not as a general-purpose LLM accelerator. Google has announced an experimental **Tensor ML SDK** (sign-up access as of late 2025) that exposes TPU inference for Pixel phones, but as of June 2026 this remains experimental and is restricted to a curated model garden. Arbitrary custom models (llama.cpp GGUF, Python weights) cannot be loaded into the Tensor TPU without conversion through this experimental SDK pipeline. **Do not plan around TPU acceleration for LifeOS v1.** It is a future optimization opportunity, not a current capability.

Sources: [NotebookCheck Tensor G2 details](https://www.notebookcheck.net/Google-Tensor-G2-Chipset-details-revealed-following-Pixel-7-and-Pixel-7-Pro-launches.660056.0.html), [Android Authority Tensor G2](https://www.androidauthority.com/google-tensor-g2-explained-3216087/), [Google Tensor ML SDK](https://ai.google.dev/edge/litert/next/tensor_ml_sdk)

---

## Section 2 — On-Device LLM Runtimes for Android

### 2.1 Runtime Comparison Matrix

| Runtime | GPU Backend on Mali | Tensor TPU | License | Embedding in Native App | Production Readiness (2026) |
|---------|--------------------|-----------:|---------|------------------------|----------------------------|
| **LiteRT-LM** (Google) | Proprietary GPU kernels | Partial (experimental) | Apache 2.0 | AAR / Kotlin & C++ APIs | ✅ Production (powers Pixel Watch, Chrome) |
| **llama.cpp** | Vulkan (poor on Mali) | ❌ | MIT | Via JNI / NDK (multiple wrappers) | ✅ for CPU, ⚠️ Vulkan on Mali |
| **MLC-LLM** | OpenCL (not Vulkan) | ❌ | Apache 2.0 | Android AAR available | ⚠️ Maintained but slower iteration |
| **ExecuTorch** | Vulkan, NNAPI | ❌ | BSD | AAR / C++ | ✅ Production (Meta apps, billions of inferences) |
| **ONNX Runtime GenAI** | NNAPI / GPU EP | ❌ | MIT | AAR / Java API | ✅ Solid, broad model support |
| **picoLLM** | CPU-optimized | ❌ | Commercial | Native SDK | ✅ but proprietary model format |
| **mllm** | CPU (ARM NEON) | ❌ | Apache 2.0 | AAR (Go in-app server) | ⚠️ Research-grade, November 2025 rewrite |

### 2.2 Deep Dive: LiteRT-LM (Recommended)

LiteRT-LM is Google's production-ready, open-source inference framework announced in 2025 and is described as "the battle-tested infrastructure powering Gemini Nano deployment across Google products." It supersedes the MediaPipe LLM Inference API (which Google now recommends migrating away from).

**Capabilities:**
- Supports Gemma, Llama, Phi-4, Qwen, and more
- GPU and NPU (experimental) acceleration
- Multi-token prediction (MTP) drafters for up to 2.2× speedup (Gemma 4)
- Session cloning: can fork a conversation's KV-cache state for parallel tasks
- Swift, JavaScript, Kotlin, and C++ APIs
- Powers Gemma 4 12B on laptops; on Android targets Gemma 3n / Gemma 4 E2B class models

**Benchmark (Samsung S26 Ultra, Gemma 4 E2B, LiteRT-LM):**
- GPU prefill: 3,808 tk/s
- GPU decode: 52 tk/s

The Pixel 7 Pro will perform below this (older SoC, Mali-G710 vs Xclipse), but the framework itself is the right foundation. Expect 25–40 tk/s decode on Gemma 3n E2B on the Pixel 7 Pro.

Sources: [LiteRT-LM GitHub](https://github.com/google-ai-edge/LiteRT-LM), [LiteRT-LM Overview](https://developers.google.com/edge/litert-lm/overview), [InfoQ LiteRT-LM Gemma 4 MTP](https://www.infoq.com/news/2026/06/google-litertlm-gemma4/)

### 2.3 Deep Dive: llama.cpp on Android

llama.cpp has solid Android support via the NDK and multiple Kotlin wrappers (KotlinLlamaCpp, Llamatik, Ai-Core AAR). CPU inference (ARM NEON + SVE) is well-optimized and is the practical compute path on the Pixel 7 Pro.

**The Vulkan problem on Mali:** Community testing shows llama.cpp with Vulkan backend on Mali GPUs is 14–17× slower than CPU. The root causes are mismatched memory access patterns and lack of Mali-specific operator optimizations. The llama.cpp maintainers have acknowledged this but Mali is not a primary optimization target. **On the Pixel 7 Pro, always use CPU (NEON) with llama.cpp, not Vulkan.**

**JNI embedding:** Mature, with multiple AAR options. The `kotlinllamacpp` library wraps the llama.cpp JNI layer with robust UTF-8 buffering for streaming tokens. Memory-mapped model loading (mmap) is well-supported and critical for avoiding OOM kills.

Sources: [llama.cpp Android docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md), [Vulkan Mali performance issue](https://github.com/ggml-org/llama.cpp/discussions/9464), [KotlinLlamaCpp](https://github.com/ljcamargo/kotlinllamacpp), [MVP Factory KMP article](https://mvpfactory.io/blog/on-device-llm-inference-via-kmp-and-llama-cpp-memory-mapped-model-loading-ane)

### 2.4 Deep Dive: ExecuTorch

PyTorch's production-proven inference runtime, powering billions of daily inferences in Meta's apps (Instagram, WhatsApp). 50KB base footprint, supports Vulkan, NNAPI, and ARM backends. Well-suited for embedding; supports Llama 3.2/3.1. Less tightly integrated with the Google/Pixel ecosystem but a credible alternative to LiteRT-LM for developers who want PyTorch lineage.

Source: [ExecuTorch at Meta](https://engineering.fb.com/2025/07/28/android/executorch-on-device-ml-meta-family-of-apps/)

### 2.5 MLC-LLM Status

MLC-LLM uses OpenCL on Android (not Vulkan), which works on both Adreno and Mali GPUs. The Callstack engineering team documented decent OpenCL performance on Adreno; Mali results are less well-documented. Vulkan support for Android is confirmed "not yet supported" as of late 2025. Development cadence has slowed compared to LiteRT-LM and llama.cpp. Not recommended as the primary runtime for a new 2026 project.

Source: [Callstack MLC-LLM OpenCL](https://www.callstack.com/blog/profiling-mlc-llms-opencl-backend-on-android-performance-insights), [MLC-LLM Vulkan issue](https://github.com/mlc-ai/mlc-llm/issues/3372)

---

## Section 3 — What Models Actually Run Well

### 3.1 RAM Budget

The Pixel 7 Pro has 12 GB RAM. Android itself consumes roughly 3–4 GB at idle. Active foreground apps, kernel, and LifeOS platform overhead will consume another 1–2 GB. A realistic **available budget for the LLM is 5–7 GB**.

With memory-mapped loading, the model file sits on storage and the kernel pages in only what is accessed. This is critical: a Q4_K_M 3B model (~1.9 GB on disk) does not need 1.9 GB of resident heap — only the currently accessed layers are paged in. However, the KV cache lives in heap and grows with context length.

**KV cache math for a 3B model:**
`KV cache size = 2 × num_layers × num_heads × head_dim × context_length × sizeof(dtype)`

For Llama 3.2 3B at 2048 context, FP16 KV cache ≈ 256 MB. At 4096 context ≈ 512 MB. Quantizing the KV cache to Q4 reduces this by ~4×.

### 3.2 Recommended Models

| Model | Params | Q4_K_M Size | Est. RAM (peak) | Est. tok/s (CPU, Pixel 7 Pro) | Quality notes |
|-------|--------|------------|-----------------|-------------------------------|---------------|
| **Gemma 4 E2B-it** | 2.3B effective (5.1B w/ emb) | ~2.0 GB (Q4) | ~2.5–3 GB | 60+ (edge) | **Newest (2026), purpose-built for on-device**: multimodal (text/image/audio), 128K context, native function calling, configurable thinking modes. ~2 GB Q4 / 3 GB BF16, runs CPU-only. **New leading candidate** |
| **Gemma 3n E2B** | 2B effective | ~1.5 GB | ~2.5 GB | 30–45 | Mobile-optimized; MatFormer; multimodal (audio batch); best-in-class for size; strong fallback |
| **Gemma 3n E4B** | 4B effective | ~2.5 GB | ~3.5 GB | 20–30 | Higher quality, fits comfortably; first sub-10B to exceed 1300 LMArena score |
| **Llama 3.2 3B Q4_K_M** | 3B | ~1.9 GB | ~2.5 GB | 12–15 | Solid generalist; well-tested on mobile |
| **Qwen 2.5 3B Q4_K_M** | 3B | ~1.9 GB | ~2.5 GB | 12–15 | Strong reasoning per size; resilient to quantization |
| **Phi-4 Mini Q4_K_M** | 3.8B | ~2.5 GB | ~3.0 GB | 10–18 | Best MMLU (73%) for this param count; good for structured extraction |
| **SmolLM2 1.7B Q4_K_M** | 1.7B | ~1.1 GB | ~1.6 GB | 20–30 | Lightest viable option; use for nano-agent tasks |
| **Qwen2.5-1.5B-Instruct** | 1.5B | ~1.0 GB | ~1.6 GB | 25–35 | Strong small instruct model; resilient to Q4; good lightweight extractor / nano-agent |
| **DeepSeek-R1-Distill-Qwen-1.5B** | 1.5B | ~1.1 GB | ~1.7 GB | 20–30 | R1-distilled reasoning in 1.5B: strong math/logic per size, but verbose (emits thinking traces) — best for a "thinking" nano-agent, not chat |
| **Gemma 3 1B** | 1B | ~0.5 GB | ~1.0 GB | 40–60 | Fast, low quality; suitable for classification/routing only |
| **Qwen 2.5 7B Q4_K_M** | 7B | ~4.3 GB | ~5.5 GB | 6–10 | Maximum sensible size; borderline for 12 GB device; risk of OOM under pressure |

**Verdict on 7B models:** A 7B Q4_K_M model at ~4.3 GB weights plus KV cache and system overhead is borderline. It can work but leaves little headroom. Under memory pressure (incoming notification, background sync, OS activity), the LMK (Low Memory Killer) will target it. **Not recommended for the main brain on a 12 GB device.**

**Primary recommendation: Gemma 4 E2B-it (step up to E4B for more quality headroom) via LiteRT-LM.** Google's Gemma 4 E2B/E4B are the current on-device-first models (successors to Gemma 3n), purpose-built for smartphones: multimodal (text/image/audio — ideal for on-device STT and vision), 128K context, native function calling for the agent loop, and a ~2 GB Q4 footprint that leaves real headroom on a 12 GB phone at ~60 tok/s on edge hardware. E2B is the safe default for the Pixel 7 Pro's thermal/RAM budget; use E4B when quality matters more than headroom. For "thinking" nano-agent tasks, **DeepSeek-R1-Distill-Qwen-1.5B** is a strong tiny reasoner and **Qwen2.5-1.5B-Instruct** a solid lightweight extractor. (Gemma 3n E2B/E4B remain valid fallbacks where Gemma 4 is not available in the chosen runtime; the earlier first-party Pixel optimization and PLE memory technique carry over to the Gemma 4 line.)

### 3.3 Parallel Conversations and Context

A single-threaded autoregressive LLM on 12 GB RAM cannot serve multiple *simultaneous* streaming conversations without time-slicing — the KV cache for each conversation must reside in RAM. Two parallel contexts at 2048 tokens each roughly doubles the KV cache overhead.

**Practical strategy for LifeOS:**
- Run one "main" Axi conversation at a time (the user's active thread)
- For background domain agents (health extractor, finance classifier, reminder parser), use a single smaller model (Gemma 3 1B or SmolLM2 1.7B) with structured prompting rather than separate model instances
- LiteRT-LM's session cloning can fork a KV-cache state, enabling fast context reuse for related tasks without full prefill cost

Sources: [LiteRT-LM KV cache docs](https://kednaik.medium.com/deploying-llm-models-on-mobile-device-using-google-litert-c0ec5be4bab9), [RAM tier guide](https://dev.to/engineeredai/run-a-local-llm-on-android-what-ram-tier-you-need-and-which-models-actually-work-2nkp), [Mobile LLM comparison 2026](https://www.promptquorum.com/power-local-llm/mobile-llm-models-phi4-gemma-smollm)

---

## Section 4 — Nano-Agents on Phone

### 4.1 The Nano-Agent Question

On the PC, LifeOS uses small specialized models for fast structured extraction (health data parser, finance categorizer, reminder extractor). On Android, the question is whether to:

**(a) Run a tiny separate model (SmolLM2 1.7B / Gemma 3 1B) alongside the main model**
**(b) Reuse the main model with structured prompting (JSON mode, tool-use format)**

### 4.2 RAM and Thermal Budget for Two Models

Loading a second model alongside the main brain requires keeping both resident (or thrashing between them from storage, which is slow). With Gemma 3n E4B (~3.5 GB peak) as the main brain and SmolLM2 1.7B Q4 (~1.6 GB) as a nano-agent:

- Combined RAM footprint: ~5.1 GB model weights + KV caches + system = pushing 7–8 GB
- This leaves ~4–5 GB for the OS and LifeOS platform on a 12 GB device
- Thermal: running two models sequentially (not simultaneously) is feasible but sustained back-to-back inference deepens the thermal hole quickly

### 4.3 Recommendation: Single Model, Structured Prompting

**Use the main model (Gemma 3n E4B) for structured extraction tasks via constrained decoding / JSON mode.** LiteRT-LM supports function calling and structured output. The quality difference between a dedicated nano-agent and the main model for simple extraction tasks (pulling a blood pressure reading from a diary entry, categorizing a purchase as food/transport/entertainment) is negligible at 3–4B parameters.

Reserve a separate tiny model (Gemma 3 1B via LiteRT-LM) *only* if the main model is occupied in an active user conversation and a background extraction task cannot wait. This is a queue-and-serialize approach, not true parallelism.

**Do not attempt to keep two models in GPU VRAM simultaneously** — the Mali-G710 has shared-memory architecture and will not have enough high-bandwidth headroom.

---

## Section 5 — Voice and Vision On-Device

### 5.1 Speech-to-Text (STT)

**whisper.cpp on Android** is the primary option. Key findings:

- Batch processing: ~1–2 seconds to transcribe 5 seconds of audio (fast and accurate)
- Live streaming mode: 5–7 seconds to process 1 second of new audio — **unusable for real-time UX**
- A high-performance Android AAR variant now supports IQ-quants, KV cache quantization, speculative decoding, VAD streaming, and thermal-aware threading
- The `whisper.base` and `whisper.small` GGUF models are appropriate for a Pixel 7 Pro (~75–150 MB)

**Practical UX pattern for LifeOS:** Use push-to-talk or end-of-utterance VAD detection, then batch-process the audio chunk. Do not attempt real-time streaming word-by-word transcription — the latency is unacceptable on this hardware.

**Alternative:** Google's on-device speech recognition (via `SpeechRecognizer` API) is fast and accurate on Pixel phones, uses the Tensor TPU pipeline, and requires zero implementation work. The tradeoff is it may send data to Google for certain query types (it is not fully documented as 100% offline). For strict privacy requirements, use whisper.cpp.

Source: [whisper.cpp Android discussion](https://github.com/ggml-org/whisper.cpp/discussions/3567), [Edge transcription guide](https://www.ionio.ai/blog/running-transcription-models-on-the-edge-a-practical-guide-for-devices)

### 5.2 Text-to-Speech (TTS)

**Piper** via **VoxSherpa** (Android TTS system integration, May 2026) is the recommended baseline — offline, neural quality, integrates with Android's system TTS voice picker so it works across apps. The `amy_low` voice is 63 MB and bundled.

**Kokoro TTS** (82M params, 82MB) generates speech rated above Google WaveNet and Amazon Polly in blind tests. VoxSherpa supports Kokoro voices, but the article notes "long pauses before playback reduce usability for narration" — acceptable for LifeOS "insight delivery" use cases but not ideal for rapid back-and-forth dialogue.

**Android built-in TTS** (`TextToSpeech` API) is an acceptable fallback — always available, zero storage overhead, but robotic quality.

**Recommendation for LifeOS MVP:** Use Android built-in TTS for v1 (zero complexity), then upgrade to Piper voices in v2.

Sources: [VoxSherpa Piper TTS Android](https://speechcentral.net/2026/05/03/android-piper-tts-voxsherpa-brings-offline-neural-voices-to-system-text-to-speech/), [NekoSpeak Kokoro Android](https://github.com/siva-sub/NekoSpeak), [Kokoro TTS guide](https://www.offlinetts.com/blog/kokoro-tts-complete-guide/)

### 5.3 Vision / Camera Q&A

Gemma 3n is multimodal and supports image + text prompts through the LiteRT-LM API. This is the on-device path for "describe what I'm seeing" or "extract text from this receipt" use cases. Performance for image understanding on the Pixel 7 Pro will be slower than text-only (additional vision encoder pass), but feasible for non-real-time use cases.

For document OCR specifically, Android's built-in ML Kit Text Recognition (runs on-device via Tensor pipeline) is faster and more accurate for pure OCR than using a general-purpose VLM.

---

## Section 6 — Platform Layer

### 6.1 Encrypted Data Store

**SQLCipher for Android** is the clear recommendation:

- AES-256 encryption with key stored in Android Keystore
- Full compatibility with SQLite APIs — Room database can use it transparently
- As of June 2025, sqlcipher-android 4.6.1 adds mandatory 16KB page size support required by Google's new Play Store mandate
- The old `android-database-sqlcipher` package is deprecated (EOL 2023); use `sqlcipher-android` as the replacement
- Well-suited for LifeOS's structured life-domain data (health metrics, finance records, relationship notes, reminders)

**ObjectBox** is a fast alternative but as of 2025 has limited full-database encryption support (field-level only via AES workarounds). Not recommended for LifeOS's security model.

Sources: [SQLCipher 16KB support](https://www.zetetic.net/blog/2025/06/26/sqlcipher-for-android-16kb-page-size-support/), [Room + SQLCipher integration](https://proandroiddev.com/how-to-encrypt-your-room-database-in-android-using-sqlcipher-0bce78328bd6)

### 6.2 Vector Store for Memory/Recall

The PC version uses SQLite for memory. On Android, a lightweight in-process vector store is needed for semantic recall (the Axi memory layer). Options:

- **sqlite-vec** (SQLite extension with vector search) — lightest option, stays within the SQLCipher database
- **Chroma** embedded (Python — not usable in a native Android app without a bundled server)
- **Custom FAISS / Annoy embedding index** — feasible but complex

**Recommendation:** Start with sqlite-vec embedded in the SQLCipher database. Embed vectors as BLOB columns with a cosine similarity search implemented via a simple dot-product query or a small native extension.

### 6.3 Background Execution: The Hard Truth

Android's background execution model is the most structurally disruptive difference from the PC platform.

| Service Type | Time Limit | Notes |
|-------------|-----------|-------|
| `mediaPlayback` foreground service | Unlimited | Requires visible notification with media controls |
| `location` foreground service | Unlimited | Requires location permission justification |
| `dataSync` foreground service | **6 hours / 24 hours** | Android 15+ hard limit |
| `mediaProcessing` foreground service | **6 hours / 24 hours** | Android 15+ hard limit |
| `WorkManager` background task | System-scheduled | No real-time guarantees; Doze mode applies |
| Broadcast receivers | Short bursts only | Cannot start services from background (Android 12+) |

**Implication for LifeOS:** An "always-on" AI assistant running continuous inference in the background is **not permissible** on Android 15/16 without a persistent foreground notification. Even with that notification, sustained LLM inference will trigger OS-level thermal and battery interventions.

**The LifeOS Android model must be event-driven, not always-on:**
- User taps Axi → foreground service starts → inference runs → user dismisses → service stops
- Scheduled "daily digest" → WorkManager task triggered at user-defined time → brief inference burst → notification delivered
- Reminders → Alarm Manager exact alarms (requires `SCHEDULE_EXACT_ALARM` permission from Android 12+)
- Background memory ingestion (diary parsing, health data extraction) → WorkManager with expedited tasks, run when charging and idle

Sources: [Android foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout), [Background execution 2025 guide](https://medium.com/@codewithparas/background-execution-in-android-2025-the-only-guide-you-need-cf7d4180c58d)

### 6.4 Play for On-Device AI (Model Distribution)

Google has a first-party system for distributing AI model weights via Play Store called **Play for On-device AI** (beta). Models are packaged as "AI packs" in Android App Bundle format and distributed separately from the APK, supporting install-time, fast-follow, and on-demand delivery. This is the right mechanism for distributing a Gemma 3n model (2–3 GB) without bundling it in the APK itself.

Source: [Play for On-device AI](https://developer.android.com/google/play/on-device-ai)

---

## Section 7 — App Architecture Options

### Option A: Termux + Existing Python/llama.cpp Stack

**Approach:** Ship the existing PC-side Python stack into Termux. Use a local HTTP server for the Android UI to call.

| Aspect | Assessment |
|--------|-----------|
| Effort | Low to start, high to productize |
| UX | Poor — Termux is a terminal emulator, not an app |
| Performance | CPU only; Python overhead on top of llama.cpp |
| Reliability | Fragile — Termux processes are among the first killed under memory pressure |
| Distribution | Cannot be distributed via Play Store |
| Maintenance | Every Android OS update risks breaking the environment |
| Privacy | High — same as PC |

**Verdict: Acceptable for personal prototyping only. Not a shippable product path.**

### Option B: Native Kotlin/Jetpack Compose + LiteRT-LM (or llama.cpp JNI)

**Approach:** Build a proper Android app from scratch. Use Android AAR libraries for inference (LiteRT-LM or kotlinllamacpp). Jetpack Compose for UI. Room + SQLCipher for data. Foreground service for inference sessions.

| Aspect | Assessment |
|--------|-----------|
| Effort | High (6–12 months to a solid MVP) |
| UX | Best possible — native Android feel |
| Performance | Best — direct JNI/native calls, mmap loading, GPU acceleration via LiteRT-LM |
| Reliability | Best — proper Android lifecycle management |
| Distribution | Play Store (with AI packs for model) or sideload |
| Privacy | High — no cloud, all on-device |

**Verdict: Highest effort but the right long-term architecture. Recommended.**

### Option C: Hybrid — Native Shell + Bundled Local Server

**Approach:** Native Kotlin shell app for UI/UX/permissions/lifecycle. Bundled Go or Rust server (like mllm's in-app Go server architecture) for inference orchestration. React Native or WebView for rapid UI iteration.

| Aspect | Assessment |
|--------|-----------|
| Effort | Medium — avoids full native UI rewrite |
| UX | Medium — WebView introduces latency and less native feel |
| Performance | Medium — server IPC overhead on top of inference |
| Reliability | Medium — two process boundary to manage |
| Distribution | Play Store compatible |
| Privacy | High |

**Verdict: Viable shortcut for faster time-to-demo. Consider for Phase 1 if the team is more backend-oriented.**

### Recommendation

**Option B (native Kotlin + LiteRT-LM) is the target architecture.** Option C is an acceptable Phase 1 shortcut if the team needs to demonstrate the concept faster, with the explicit intent to migrate UI to Jetpack Compose by Phase 2.

---

## Section 8 — Hard Limitations and Risks

### 8.1 Thermal Throttling

The most important operational constraint. Published benchmarks:

- **iPhone 16 Pro:** Peaks at 40 tok/s, throttles to 22 tok/s (−44%) within 8 iterations, sustaining "hot" thermal state for 65% of benchmark ([arXiv 2603.23640](https://arxiv.org/html/2603.23640))
- **Samsung S24 Ultra:** Reaches 78.3°C GPU temperature at iteration 6, OS enforces a hard frequency floor dropping from 680 MHz to 231 MHz, GPU frequency collapses, benchmark terminates
- The Pixel 7 Pro Tensor G2 runs hotter than Snapdragon equivalents (Samsung 5nm process vs TSMC)

**Mitigation pattern (adaptive throttling):**
```
Thermal state → Action
Normal         → No delay between tokens
Fair (warning) → 15ms delay between tokens
Serious        → 50ms delay + reduce max_predict to 128 tokens
Critical       → Suspend generation, notify user
```

### 8.2 No CUDA Equivalent

There is no CUDA on Android. The compute hierarchy is: CPU NEON/SVE > OpenCL (Adreno/Mali) > Vulkan (Adreno only, Mali poor) > NNAPI (fragmented). The Tensor TPU is not accessible for arbitrary models. Accept CPU inference as the primary compute path.

### 8.3 OOM Kills

Android's LMK (Low Memory Killer) will terminate background processes — including inference tasks — when RAM is under pressure. Mitigation:
- Use mmap-based model loading (kernel evicts pages rather than killing the process)
- Keep foreground service alive during active sessions
- Serialize model loading; do not attempt to keep the 7B model resident when not in use

### 8.4 Play Store Policy and Sideloading

- From September 2026: Google requires developer identity verification for sideloaded apps (initially Brazil, Indonesia, Singapore, Thailand; global from 2027)
- AI model weights in Play Store must use the AI packs mechanism (not bundled in APK)
- AI packs can only contain model weights — no Java/Kotlin libraries
- For personal/hobbyist distribution: Google introduced a "limited-distribution account" path
- Model licensing: Gemma 3n is licensed under the Gemma Terms of Use (permissive for on-device use, but not relicensable for redistribution in certain contexts — review carefully)

Sources: [Play for On-device AI docs](https://developer.android.com/google/play/on-device-ai), [Sideloading policy 2026](https://www.medianama.com/2025/08/223-google-blocks-android-apk-sideloading-2026/)

### 8.5 Battery

- The S24 Ultra consumed ~1% battery per 5 inference iterations
- The Pixel 7 Pro has a 5,000 mAh battery with a less efficient SoC (Samsung 5nm vs newer TSMC nodes)
- Sustained LLM sessions (10+ minutes) will measurably drain the battery and generate significant heat
- LifeOS interactions must be kept short (ideally <2 minutes continuous generation per session)

### 8.6 Context Length

Most mobile-optimized models ship with a practical context window of 2K–8K tokens in LiteRT-LM on mobile. The PC version may rely on longer context for memory/recall. On Android, this must be compensated by the RAG/memory layer (SQLite vector search → inject relevant summaries) rather than raw context window.

---

## Section 9 — Recommended Stack for Pixel 7 Pro

### Core Components

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| **App framework** | Kotlin + Jetpack Compose | Native Android, best performance/UX |
| **LLM runtime** | Google LiteRT-LM | Production-proven, best GPU support on Tensor G2, Gemma 3n integration |
| **Primary brain model** | Gemma 3n E4B (Q4/INT4) | Mobile-first MatFormer architecture, multimodal, fits in 3.5 GB |
| **Nano-agent tasks** | Main model via structured prompting (JSON mode) | Avoid loading second model; use constrained generation |
| **Light routing/classification** | Gemma 3 1B (LiteRT-LM, on-demand load) | Fast classification when main model is busy |
| **STT** | whisper.cpp (base/small GGUF) via Android AAR | Batch mode; private, no cloud |
| **TTS** | Android built-in TTS → Piper (v2) | Zero complexity for MVP; upgrade path clear |
| **Encrypted store** | Room + SQLCipher (sqlcipher-android 4.6.1+) | AES-256, Android Keystore integration |
| **Vector memory** | sqlite-vec extension in SQLCipher DB | Minimal dependency, in-process |
| **Background work** | WorkManager (expedited tasks) + Foreground Service | Correct Android lifecycle primitives |
| **Model distribution** | Play for On-device AI (AI packs) | Correct Play Store mechanism for 2–3 GB model |

### Architecture Diagram (conceptual)

```
┌─────────────────────────────────────────────────────────────────┐
│  LifeOS Android App                                             │
│                                                                 │
│  ┌─────────────┐   ┌──────────────────┐   ┌─────────────────┐  │
│  │  Jetpack    │   │  Axi Service     │   │  Platform       │  │
│  │  Compose UI │──▶│  (ForegroundSvc) │   │  (WorkManager)  │  │
│  │             │   │                  │   │                 │  │
│  │  - Chat     │   │  LiteRT-LM       │   │  - Daily digest │  │
│  │  - Domains  │   │  ┌────────────┐  │   │  - Memory ingest│  │
│  │  - Insights │   │  │Gemma 3n E4B│  │   │  - Reminders    │  │
│  └─────────────┘   │  └────────────┘  │   └─────────────────┘  │
│                    │                  │                         │
│                    │  whisper.cpp STT │                         │
│                    │  Android TTS     │                         │
│                    └──────────────────┘                         │
│                              │                                  │
│              ┌───────────────▼──────────────┐                   │
│              │  SQLCipher + sqlite-vec       │                   │
│              │  Life domains (health,        │                   │
│              │  finance, relationships,      │                   │
│              │  reminders, memory/recall)    │                   │
│              └──────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Section 10 — Phased Path

### Phase 1 — MVP (3–5 months)

**Goal:** Axi voice + text on Android. Core life-data store. Local, private, installable.

- [ ] LiteRT-LM integrated with Gemma 3n E4B (download via AI packs)
- [ ] Jetpack Compose chat UI (text input/output)
- [ ] Foreground service for inference session management
- [ ] SQLCipher database with core schemas (health, finance, notes, reminders)
- [ ] whisper.cpp integration (batch STT, push-to-talk pattern)
- [ ] Android built-in TTS for voice output
- [ ] WorkManager daily digest task
- [ ] Exact alarm reminders (AlarmManager)
- [ ] Adaptive thermal throttling (token delay based on thermal state)
- [ ] mmap-based model loading with OOM-safe patterns

**Excluded from MVP:** Vision/image Q&A, nano-agents, vector memory search, Piper TTS, relationship domain, cross-device sync.

### Phase 2 — Full Platform (3–6 months post-MVP)

- [ ] sqlite-vec integration for semantic memory recall (Axi "remembers")
- [ ] Gemma 3n multimodal: camera/photo analysis for health (food logging, label reading)
- [ ] Piper TTS voices via VoxSherpa integration
- [ ] Structured extraction pipeline: domain-specific parsers using JSON mode
- [ ] Relationship domain (contacts + interaction history)
- [ ] Richer insights UI (charts, trends from SQLite data)
- [ ] Widget + home screen quick-access to Axi
- [ ] Tensor ML SDK integration (experimental TPU acceleration, as SDK matures)

### Phase 3 — Optimization and Polish

- [ ] KV cache quantization (Q4 KV) for longer effective context
- [ ] Model update mechanism (AI packs update pipeline)
- [ ] Power-efficient inference scheduling (run when charging/idle via WorkManager constraints)
- [ ] Explore Gemma 4 E2B when LiteRT-LM support matures on Pixel 7 Pro class hardware
- [ ] Evaluate picoLLM or ExecuTorch as alternative runtimes if LiteRT-LM shows limitations

---

## Section 11 — Limitations Summary Table

| Limitation | Severity | Mitigation |
|-----------|---------|-----------|
| Thermal throttling caps sustained throughput at ~60–90s | **High** | Adaptive token delay; design for short sessions |
| Mali-G710 GPU not viable for llama.cpp Vulkan | **High** | Use LiteRT-LM (proprietary GPU kernels) or CPU mode |
| No access to Tensor TPU for custom models | **High** | Accept CPU/GPU inference; revisit with Tensor ML SDK |
| Android 15+ limits background services to 6h/24h | **High** | Event-driven model; WorkManager for background tasks |
| 7B models borderline on 12 GB (OOM risk) | **Medium** | Cap at 3–4B effective; use Gemma 3n E4B |
| Parallel model instances not feasible | **Medium** | Single model + structured prompting for nano-agent tasks |
| whisper.cpp real-time streaming 5–7× slower than audio | **Medium** | Push-to-talk batch mode; not real-time streaming |
| Context window constrained to 2K–8K on mobile | **Medium** | RAG/memory layer with vector search |
| Battery drain during sustained inference | **Medium** | Short sessions; WorkManager runs when charging |
| Play Store sideloading restrictions tightening (2026+) | **Low–Medium** | Use Play for On-device AI + developer verification |
| Model licensing (Gemma Terms of Use) | **Low** | Review redistribution clauses; Gemma is permissive for on-device use |
| MLC-LLM / llama.cpp Mali GPU support still poor | **Low** | Mitigated by choosing LiteRT-LM as primary runtime |

---

## Sources and Citations

1. [LiteRT-LM Overview — Google AI Edge](https://developers.google.com/edge/litert-lm/overview)
2. [LiteRT-LM GitHub Repository](https://github.com/google-ai-edge/LiteRT-LM)
3. [Google LiteRT-LM Speeds Up Inference 2.2x with Gemma 4 MTP — InfoQ](https://www.infoq.com/news/2026/06/google-litertlm-gemma4/)
4. [LLM Inference guide for Android — Google AI Edge](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference/android)
5. [Google AI Edge Gallery: Now with audio and on Google Play — Google Developers Blog](https://developers.googleblog.com/google-ai-edge-gallery-now-with-audio-and-on-google-play/)
6. [Gemma 3 on mobile and web with Google AI Edge — Google Developers Blog](https://developers.googleblog.com/ko/gemma-3-on-mobile-and-web-with-google-ai-edge/)
7. [Introducing Gemma 3n: The developer guide — Google Developers Blog](https://developers.googleblog.com/en/introducing-gemma-3n-developer-guide/)
8. [Gemma 3n model overview — Google AI for Developers](https://ai.google.dev/gemma/docs/gemma-3n)
9. [Google Tensor G2 Chipset details — NotebookCheck](https://www.notebookcheck.net/Google-Tensor-G2-Chipset-details-revealed-following-Pixel-7-and-Pixel-7-Pro-launches.660056.0.html)
10. [Google Tensor G2 explained — Android Authority](https://www.androidauthority.com/google-tensor-g2-explained-3216087/)
11. [Google Tensor ML SDK — Google AI Edge (experimental)](https://ai.google.dev/edge/litert/next/tensor_ml_sdk)
12. [llama.cpp Android documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md)
13. [llama.cpp Vulkan Mali GPU poor performance — GitHub Discussion #9464](https://github.com/ggml-org/llama.cpp/discussions/9464)
14. [Performance of llama.cpp with Vulkan — GitHub Discussion #10879](https://github.com/ggml-org/llama.cpp/discussions/10879)
15. [KotlinLlamaCpp — GitHub](https://github.com/ljcamargo/kotlinllamacpp)
16. [On-Device LLM Inference via KMP and llama.cpp — MVP Factory](https://mvpfactory.io/blog/on-device-llm-inference-via-kmp-and-llama-cpp-memory-mapped-model-loading-ane)
17. [How to Run LLMs Offline on Android Using Kotlin — DEV Community](https://dev.to/ferranpons/how-to-run-llms-offline-on-android-using-kotlin-407g)
18. [MLC-LLM GitHub Repository](https://github.com/mlc-ai/mlc-llm)
19. [Profiling MLC-LLM OpenCL on Android — Callstack](https://www.callstack.com/blog/profiling-mlc-llms-opencl-backend-on-android-performance-insights)
20. [MLC-LLM Android Vulkan Support Issue #3372](https://github.com/mlc-ai/mlc-llm/issues/3372)
21. [ExecuTorch — On-Device AI Powered by PyTorch](https://executorch.ai/)
22. [ExecuTorch at Meta Engineering](https://engineering.fb.com/2025/07/28/android/executorch-on-device-ml-meta-family-of-apps/)
23. [ONNX Runtime GenAI — GitHub](https://github.com/microsoft/onnxruntime-genai)
24. [picoLLM Inference Engine — Picovoice](https://picovoice.ai/picollm/)
25. [mllm — Fast Multimodal LLM on Mobile — GitHub](https://github.com/UbiquitousLearning/mllm)
26. [LLM Inference at the Edge: Mobile, NPU, and GPU Performance — arXiv 2603.23640](https://arxiv.org/html/2603.23640)
27. [Understanding LLMs in Your Pocket: Performance Study — arXiv 2410.03613](https://arxiv.org/html/2410.03613v3)
28. [Best Mobile LLM Models 2026: Phi-4 Mini vs Gemma 3 vs SmolLM — PromptQuorum](https://www.promptquorum.com/power-local-llm/mobile-llm-models-phi4-gemma-smollm)
29. [Phi-4 Mini benchmark guide — Local AI Master](https://localaimaster.com/models/phi-4-mini)
30. [Qwen 2.5 7B VRAM requirements — Medium](https://medium.com/@marketing_novita.ai/qwen-2-5-7b-vram-tips-every-dev-should-know-932303373ff0)
31. [whisper.cpp — GitHub Repository](https://github.com/ggml-org/whisper.cpp)
32. [whisper.cpp Android streaming latency — Discussion #3567](https://github.com/ggml-org/whisper.cpp/discussions/3567)
33. [Running Transcription Models on Edge Devices — ionio.ai](https://www.ionio.ai/blog/running-transcription-models-on-the-edge-a-practical-guide-for-devices)
34. [Android Piper TTS via VoxSherpa — SpeechCentral](https://speechcentral.net/2026/05/03/android-piper-tts-voxsherpa-brings-offline-neural-voices-to-system-text-to-speech/)
35. [NekoSpeak — Kokoro/Piper TTS for Android — GitHub](https://github.com/siva-sub/NekoSpeak)
36. [Kokoro TTS Complete Guide — OfflineTTS](https://www.offlinetts.com/blog/kokoro-tts-complete-guide/)
37. [SQLCipher for Android 16KB Page Size Support — Zetetic](https://www.zetetic.net/blog/2025/06/26/sqlcipher-for-android-16kb-page-size-support/)
38. [Room + SQLCipher encryption — ProAndroidDev](https://proandroiddev.com/how-to-encrypt-your-room-database-in-android-using-sqlcipher-0bce78328bd6)
39. [Android Foreground Service Timeouts — Android Developers](https://developer.android.com/develop/background-work/services/fgs/timeout)
40. [Background Execution in Android 2025 — Medium](https://medium.com/@codewithparas/background-execution-in-android-2025-the-only-guide-you-need-cf7d4180c58d)
41. [Play for On-Device AI — Android Developers](https://developer.android.com/google/play/on-device-ai)
42. [Google Moves to Block APK Sideloading by 2026 — MediaNama](https://www.medianama.com/2025/08/223-google-blocks-android-apk-sideloading-2026/)
43. [Deploying LLM Models on Mobile with Google LiteRT — Medium](https://kednaik.medium.com/deploying-llm-models-on-mobile-device-using-google-litert-c0ec5be4bab9)
44. [Run a Local LLM on Android: RAM Tiers and Models — DEV Community](https://dev.to/engineeredai/run-a-local-llm-on-android-what-ram-tier-you-need-and-which-models-actually-work-2nkp)
45. [On-Device AI Chat & Translate on Android — Towards AI](https://pub.towardsai.net/on-device-ai-chat-translate-on-android-qualcomm-genie-mlc-webllm-your-phone-your-llm-49594aff3b9f)
46. [Systematic Evaluation of On-Device LLMs — arXiv 2505.15030](https://arxiv.org/html/2505.15030v5)
47. [Building AI-Powered Mobile Apps 2025 Guide — Medium](https://medium.com/@stepan_plotytsia/building-ai-powered-mobile-apps-running-on-device-llms-in-android-and-flutter-2025-guide-0b440c0ae08b)
48. [Google Pixel 7 Pro Android 16 update status — androidupdatetracker.com](https://www.androidupdatetracker.com/p/google-pixel-7-pro)
