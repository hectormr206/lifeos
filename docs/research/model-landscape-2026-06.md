# Local LLM Landscape — June 2026
### LifeOS Brain-Selection Research

> Research date: 2026-06-05. Cutoff: model announcements through early June 2026.
> All sizes are Q4_K_M GGUF unless noted. VRAM figures assume full GPU offload + 8K context.
> "GGUF ✓" means community GGUF builds exist on HuggingFace; "llama.cpp ✓" means confirmed working inference.

---

## TL;DR Recommendation Table

| Tier | Current LifeOS Pick | Top Pick (June 2026) | Runner-Up | Upgrade? |
|---|---|---|---|---|
| **Large** 24 GB+ VRAM | Qwen3.6-35B-A3B MoE | **Qwen3.6-35B-A3B** (keep) | Qwen3.6-27B dense | No clear winner — keep current |
| **Large-Omni** 24 GB+ (audio+vision) | — | **Qwen3-Omni-30B-A3B** | — | Add as audio variant |
| **Medium** 8–16 GB VRAM | — | **GPT-OSS-20B** (MoE) | Apriel-1.6-15B-Thinker | Add tier |
| **Small** 4–6 GB VRAM | Gemma 4 E4B / E2B | **Qwen3.5-9B** (vision) | Gemma 4 E4B | Swap primary |
| **Tiny / Android** ≤4 GB | Gemma 4 E2B | **Gemma 4 E2B** (keep) | MiniCPM-V 4.6 | Keep + add vision alt |
| **Nano-agent** ≤1.5B | — | **Granite 4.0-H-1B** | LFM2-1.2B-Extract | Add tier |

---

## Tier 1 — Large / High-End (24 GB+ VRAM, 24 GB+ RAM CPU)

### Current anchor: Qwen3.6-35B-A3B (MoE)

**Verdict: still the best single-GPU 24 GB pick.** No model released through June 2026 clearly beats it at this VRAM budget. The main challenge comes from Qwen3.6-27B dense, which trades speed for higher peak reasoning on some tasks.

---

### Qwen3.6-35B-A3B ⭐ TOP PICK

| Property | Value |
|---|---|
| Parameters | 35B total / 3B active per token |
| Q4 GGUF size | ~20 GB |
| VRAM (64K ctx) | 24.2 GB (KV cache q8_0, full GPU) |
| Multimodal | Yes — vision via `--mmproj` in llama.cpp |
| Context | 256K native |
| llama.cpp / GGUF | ✓ Full support; requires CUDA ≤12.x (CUDA 13.2 causes gibberish) |
| License | Apache 2.0 |
| Speed | ~101 t/s short, ~80 t/s long (RTX 4090 class) |
| Why | Best quality-per-VRAM at the 24 GB ceiling; vision support; proven MoE efficiency via `--n-cpu-moe` or KV-cache quantization |

**Known issues:** CUDA 13.2 incompatibility (use 12.x). Ollama not supported due to multimodal architecture — llama.cpp only. Use `--cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on`.

---

### Qwen3.6-27B (dense) — Runner-Up

| Property | Value |
|---|---|
| Parameters | 27B dense |
| Q4 GGUF size | ~16 GB |
| VRAM (64K ctx) | 19.8 GB |
| Multimodal | No (text only) |
| Context | 256K |
| llama.cpp / GGUF | ✓ Full support; native MTP via PR #22673 |
| License | Apache 2.0 |
| Why | Slightly lower VRAM headroom, simpler config, no MoE routing overhead; pick if you need text-only and simpler setup |

**Benchmark note:** Intelligence Index 45.8 vs 43.5 for the 35B-A3B — a narrow reasoning advantage for the dense model, but at significantly lower throughput (~12 t/s at 64K context vs ~65 t/s for MoE).

---

### Qwen3-Omni-30B-A3B — Audio+Vision Specialist

| Property | Value |
|---|---|
| Parameters | 30B total / 3B active |
| Q4 GGUF size | ~19 GB |
| Multimodal | Yes — text + images + audio + video |
| Context | 128K |
| llama.cpp / GGUF | ✓ Vision confirmed; audio support experimental/partial in llama.cpp |
| License | Apache 2.0 |
| Speed | ~44 t/s at 24K context via RPC across multiple GPUs |
| Why | The only sub-24 GB model with real omnimodal capabilities (audio, vision, video); ideal if LifeOS adds voice input |

**Caveat:** Audio encoder integration in llama.cpp is listed as "experimental" in the official multimodal.md. Vision is confirmed stable. Audio may require latest llama.cpp builds.

---

### Nemotron-Cascade-2-30B-A3B — Strong Reasoning Alternative

| Property | Value |
|---|---|
| Parameters | 30B total / 3B active |
| Q4 GGUF size | ~19–22 GB (IQ4_XS ≈ ~18 GB) |
| Multimodal | No |
| Context | 1M tokens |
| Architecture | Hybrid Mamba-2 SSM + Transformer |
| llama.cpp / GGUF | ✓ (bartowski GGUF; community i1-GGUF available) |
| License | NVIDIA Open Model License (permissive, allows commercial) |
| Speed | 187 t/s at IQ4_XS on RTX 3090 at 625K context |
| Why | Best-in-class long-context efficiency; 1M token window; Mamba-2 SSM layers make very long context cheap |

**Note:** Released March 19, 2026. Intelligence Index 28.4 — weaker on pure reasoning benchmarks vs Qwen3.6, but unbeatable on ultra-long-context tasks (summarizing logs, long codebases).

---

### Mistral Small 4 (119B-A? MoE) — Multi-GPU Only

| Property | Value |
|---|---|
| Parameters | 119B total / active count not publicly disclosed (128 experts, top-4 active) |
| VRAM | Requires multi-GPU (3×24 GB or 2×48 GB minimum for Q4) |
| Multimodal | Yes — image + text input |
| Context | 128K |
| llama.cpp / GGUF | ✓ (Unsloth GGUF published) |
| License | Apache 2.0 |
| Why | Best quality for teams with multi-GPU infra; multimodal; Apache 2.0 |

**Note:** GGUF Q4 fits on RTX 4090 (24 GB) only with aggressive quantization and context limits — not practical for single-GPU unless running Q3 or below with quality degradation.

---

### What about DeepSeek V4-Flash?

DeepSeek V4-Flash (284B total / 13B active, MIT license) is **not viable for the LifeOS 24 GB target**. The Q4 GGUF floor is ~170 GB on disk; minimum practical hardware is 2×48 GB. Community GGUF builds exist (Unsloth, persadian on HF) but require multi-node or extreme unified-memory setups (Mac Studio M3 Ultra at 192 GB+). Skip unless LifeOS adds a datacenter tier.

---

## Tier 2 — Medium (8–16 GB VRAM)

> This tier is currently not formally tracked in LifeOS. These are the best options if a mid-range machine joins the fleet.

### GPT-OSS-20B ⭐ TOP PICK

| Property | Value |
|---|---|
| Origin | OpenAI open-weights release |
| Parameters | 20.9B total / 3.6B active (32 experts, top-4 per token) |
| Q4 GGUF size | ~13.7 GB |
| VRAM | 12.1–13.7 GB depending on context |
| Multimodal | No (text only) |
| Context | 128K |
| llama.cpp / GGUF | ✓ Official GGUF from ggml-org; excellent support |
| License | Not fully Apache — OpenAI terms; check for redistribution |
| Speed | 42 t/s on 16 GB cards |
| AI Index | 52.1% |
| Why | Fastest model in tier by 2.8×; MoE efficiency; MXFP4 quantized weights natively |

**License caveat:** Unlike Qwen/Gemma, GPT-OSS uses OpenAI's model release terms rather than Apache 2.0. Verify redistribution permissions before bundling in LifeOS catalog.

---

### Apriel-1.6-15B-Thinker — Vision + Reasoning

| Property | Value |
|---|---|
| Origin | ServiceNow AI |
| Parameters | 15B |
| Q4 GGUF size | ~9.5 GB |
| VRAM | 9.9 GB @ 4K ctx |
| Multimodal | Yes — image + text (131K context) |
| llama.cpp / GGUF | ✓ (community GGUF; eaddario and mradermacher on HF) |
| License | Check HF card — ServiceNow research license |
| AI Index | 57% (matches Qwen-235B-A22B at 15× smaller size) |
| Why | Best multimodal reasoning in 8–16 GB tier; excellent instruction following; strongest on knowledge/reasoning benchmarks |

**License caveat:** ServiceNow license — verify commercial redistribution terms.

---

### Qwen3 14B — Safe Apache Alternative

| Property | Value |
|---|---|
| Parameters | 14B dense |
| Q4 GGUF size | ~10 GB |
| VRAM | 9.2 GB @ 4K ctx |
| Multimodal | No (use Qwen3.5-9B VLM for vision) |
| Context | 32K |
| llama.cpp / GGUF | ✓ |
| License | Apache 2.0 |
| Speed | ~15 t/s on 16 GB GPU |
| Why | Apache 2.0 safe harbor; fully battle-tested |

---

### Qwen3.5-9B — Best 8 GB Option

| Property | Value |
|---|---|
| Parameters | 9B dense |
| Q4 GGUF size | ~5.1 GB |
| VRAM | ~6.5 GB @ 8K ctx |
| Multimodal | Yes — vision via mmproj (llama.cpp 0.17.4+) |
| Context | 262K native |
| llama.cpp / GGUF | ✓ (Gated DeltaNet architecture requires llama.cpp 0.17.4+) |
| License | Apache 2.0 |
| Speed | 54–58 t/s on RTX 4060 |
| AI Index | 32.4 (best 8 GB score) |
| Why | Best quality-per-VRAM at 8 GB; 262K context; vision support |

**Note:** Requires llama.cpp ≥ 0.17.4 for Gated DeltaNet. Older builds will fail to load.

---

## Tier 3 — Small (4–6 GB VRAM)

### Assessment vs current LifeOS picks (Gemma 4 E2B / E4B)

Gemma 4 E4B remains excellent, but **Qwen3.5-9B now fits this tier on 6 GB cards** and outperforms Gemma 4 E4B on most benchmarks while matching multimodal coverage. The recommendation is to **add Qwen3.5-9B as primary** and keep Gemma 4 E4B as the 4 GB ceiling fallback.

---

### Qwen3.5-9B ⭐ TOP PICK (6 GB cards)

See Tier 2 for full specs. At Q4_K_M ~5.1 GB weights + ~1–2 GB KV cache, it fits on 6 GB VRAM with 8K context. Degrades gracefully on 4 GB with CPU offload.

---

### Gemma 4 E4B — Runner-Up (4 GB cards)

| Property | Value |
|---|---|
| Parameters | 4B effective (MoE-like architecture) |
| Q4 GGUF size | ~2.5 GB |
| VRAM | ~3–4 GB |
| Multimodal | Yes — vision + audio input, function calling |
| Context | 128K |
| llama.cpp / GGUF | ✓ Full support including mmproj for vision |
| License | Gemma Terms of Use (permissive; allows derivatives, commercial use subject to usage policy) |
| Speed (mobile) | 12–20 t/s on Snapdragon 8 Gen 3 |
| Why | Best multimodal quality per GB at 4 GB ceiling; proven; audio support is production-ready |

---

### GLM-4.6V-Flash — Strong Multimodal Alternative

| Property | Value |
|---|---|
| Origin | Zhipu AI / THUDM |
| Parameters | 9B |
| Q4 GGUF size | ~6.17 GB |
| Multimodal | Yes — vision + text |
| Context | 128K |
| llama.cpp / GGUF | ✓ (bartowski, Mungert GGUF on HF) |
| License | MIT |
| Why | MIT license (cleanest redistribution); strong visual understanding; native function calling; best licensed vision model in the 6–8 GB range |

**Note:** AI Index 23.5% — weaker than Qwen3.5-9B on pure reasoning, but MIT license is the cleanest redistribution story.

---

### Gemma 4 E2B — Ultra-Low Footprint

| Property | Value |
|---|---|
| Parameters | ~2B effective |
| Q4 GGUF size | ~1.3 GB |
| VRAM | ~2 GB |
| Multimodal | Yes — vision + audio |
| Context | 128K |
| llama.cpp / GGUF | ✓ (unsloth/gemma-4-E2B-it-GGUF) |
| License | Gemma Terms of Use |
| Why | Lowest viable multimodal model; fits on severely constrained hardware |

---

## Tier 4 — Tiny / Android (2–4 GB usable, Pixel 7 Pro class)

### Critical hardware constraint: Pixel 7 NPU inaccessible to third-party apps

Google's Tensor NPU is not accessible to third-party inference apps on any Pixel phone. All local LLM apps — including llama.cpp-based apps and LiteRT-LM — run **CPU-only** on Pixel 7/8/9 series. Practical speed is 10–15 tokens/second. Snapdragon-based phones (Samsung Galaxy S25, OnePlus) can use NPU via MLC Chat at 22+ t/s.

**LiteRT-LM** (Google AI Edge, graduated to production in March 2026) is the recommended runtime for first-party/integrated Android use. For llama.cpp-based apps, GGUF models work but with CPU-only inference.

---

### Gemma 4 E2B ⭐ TOP PICK (keep current)

See Tier 3 for specs. Best default for Pixel 7: ~1.3 GB on disk, audio + vision, 128K context, CPU-at-15 t/s. Stays as the primary recommendation.

**LiteRT-LM MTP bonus:** LiteRT-LM v0.10.1 (April 2026) added Multi-Token Prediction delivering >2× decode speed on mobile GPUs, making Gemma E2B even faster on Snapdragon devices.

---

### MiniCPM-V 4.6 — Vision-Focused Alternative

| Property | Value |
|---|---|
| Parameters | 1.3B (SigLIP2-400M vision encoder + Qwen3.5-0.8B LM) |
| Q4 GGUF size | ~1.0–1.5 GB |
| VRAM / RAM | 2–3 GB with quantization; CPU via llama.cpp |
| Multimodal | Yes — image + video understanding; **no audio** |
| Context | Unspecified (Qwen3.5-0.8B backbone) |
| llama.cpp / GGUF | ✓ Dedicated llama.cpp cookbook; `mmproj-MiniCPM-V-4.6-F16.gguf` |
| License | Apache 2.0 |
| Mobile platforms | Android, iOS, HarmonyOS |
| Why | Apache 2.0 (cleanest license); beats Gemma 4 E2B on OCRBench and dense document understanding; best for visual-extraction-heavy workflows |

**Weakness vs Gemma 4 E2B:** No audio input; smaller LM backbone means weaker reasoning.

---

### Phi-4-mini (3.8B) — Reasoning on Constrained Devices

| Property | Value |
|---|---|
| Parameters | 3.8B |
| Q4 GGUF size | ~3.5 GB |
| Multimodal | Phi-4-multimodal exists but **llama.cpp vision not fully supported** yet |
| Context | 128K |
| llama.cpp / GGUF | ✓ Text model fully supported; multimodal pending |
| License | MIT |
| Speed (mobile) | ~22 t/s on Snapdragon via MLC NPU |
| Why | Best reasoning at 3.8B; MIT license; 128K context; good for pure text agent tasks |

**GGUF multimodal caveat:** As of June 2026, the Phi-4-multimodal model's vision support in llama.cpp is listed as "community support requested" — not officially merged. Text-only Phi-4-mini works fine.

---

### Qwen3.5-2B / 4B — Capable Small Models

| Model | Q4 GGUF | Multimodal | Context | License |
|---|---|---|---|---|
| Qwen3.5-2B | ~1.5 GB | Yes (text+image) | 262K | Apache 2.0 |
| Qwen3.5-4B | ~2.5 GB | Yes (text+image) | 262K | Apache 2.0 |

Both support vision via mmproj in llama.cpp 0.17.4+. Strong choices for the 2–4 GB Android budget with the Apache 2.0 license advantage. Qwen3.5-2B is the closest Apache-licensed alternative to Gemma 4 E2B.

---

## Tier 5 — Nano-Agent / Structured Extraction (≤1.5B, CPU)

These models are for fast on-CPU extraction, classification, and function calling where latency matters more than quality. Target: sub-second response on modern CPU.

---

### Granite-4.0-H-1B ⭐ TOP PICK

| Property | Value |
|---|---|
| Origin | IBM Granite |
| Parameters | ~1.5B (hybrid-SSM / Mamba-2 architecture) |
| Q4 GGUF size | ~900 MB – 1 GB |
| Architecture | Hybrid SSM + Transformer (faster on CPU than pure Transformer) |
| llama.cpp / GGUF | ✓ (ibm-granite official GGUF, unsloth GGUF) |
| License | Apache 2.0 |
| Function calling | Outperforms similarly-sized models on BFCLv3 and IFEval |
| Why | Best tool-calling accuracy at ≤1.5B; Apache 2.0; official GGUF from IBM; hybrid architecture improves CPU efficiency |

---

### LFM2-1.2B-Extract — Extraction Specialist

| Property | Value |
|---|---|
| Origin | Liquid AI |
| Parameters | 1.2B |
| Q4 GGUF size | ~796 MB |
| Architecture | Liquid Foundation Model (state-space hybrid) |
| llama.cpp / GGUF | ✓ Official GGUF from LiquidAI on HF |
| License | Check LiquidAI model card (CC-BY-4.0 for some variants) |
| Function calling | Native JSON function definitions; OpenAI-compatible tool spec |
| CPU speed | 2× faster decode/prefill vs Qwen3 at same size |
| Why | Purpose-built for extraction/RAG/agentic; fastest CPU decode in the tier; dedicated `-Extract` checkpoint |

**LFM2.5-1.2B-Thinking** is also available (May 2026) with chain-of-thought capability at the same size.

---

### Granite-4.0-H-350M — Ultra-Nano

| Property | Value |
|---|---|
| Parameters | 350M |
| Q4 GGUF size | ~220 MB |
| llama.cpp / GGUF | ✓ |
| License | Apache 2.0 |
| Why | Fits in browser/Raspberry Pi; function calling with OpenAI schema; production GGUF from IBM |

---

### SmolLM3-3B — Lightweight Capable Model

| Property | Value |
|---|---|
| Origin | HuggingFace |
| Parameters | 3B (note: no 1B variant in this series) |
| Q4 GGUF size | ~2 GB |
| llama.cpp / GGUF | ✓ (ggml-org and community GGUF) |
| License | Apache 2.0 |
| Why | Fully open (training data, evals, weights); outperforms Phi-3.5-mini on many tasks; reliable for extraction at 3B if more capacity needed |

**Note:** If you need ≤1.5B, use Granite 4.0 Nano or LFM2 instead. SmolLM3 is 3B minimum.

---

## Notable Families — Full Status Summary

| Family | Key 2026 Models | GGUF+llama.cpp | Vision | Audio | License | Notes |
|---|---|---|---|---|---|---|
| **Qwen3.6** | 27B, 35B-A3B | ✓ | ✓ (mmproj) | ✗ | Apache 2.0 | Current-gen flagship |
| **Qwen3.5** | 0.8B–397B MoE | ✓ (≥0.17.4) | ✓ (mmproj) | ✗ | Apache 2.0 | Gated DeltaNet; all sizes multimodal |
| **Qwen3-Omni** | 30B-A3B | ✓ vision; audio experimental | ✓ | ⚠️ exp. | Apache 2.0 | Only omni-modal at 24 GB |
| **Gemma 4** | E2B, E4B, 26B-A4B, 31B | ✓ | ✓ | ✓ (E2B/E4B) | Gemma ToU | Production-grade all sizes |
| **Llama 4** | Scout (109B), Maverick (402B) | ✓ (dynamic GGUF) | ✓ | ✗ | Llama Community | Scout 1.78-bit fits 24 GB; Maverick needs 2×48 GB |
| **GPT-OSS** | 20B MoE | ✓ (ggml-org official) | ✗ | ✗ | OpenAI terms | Fast; license check needed for redistribution |
| **Phi-4** | 14B, mini (3.8B) | ✓ text; ✗ vision | ✗ (pending) | ✗ | MIT | Phi-4-multimodal vision not in llama.cpp yet |
| **Mistral Small 4** | 119B MoE | ✓ | ✓ | ✗ | Apache 2.0 | Needs multi-GPU |
| **DeepSeek V4** | Flash (284B), Pro (1.6T) | ⚠️ community only | ✗ | ✗ | MIT | ~170 GB floor; not consumer-viable |
| **Nemotron Cascade 2** | 30B-A3B | ✓ (bartowski GGUF) | ✗ | ✗ | NVIDIA Open | 1M context; Mamba-2 hybrid |
| **Apriel 1.6** | 15B-Thinker | ✓ (community GGUF) | ✓ | ✗ | ServiceNow | Best reasoning+vision in 16 GB tier |
| **GLM-4.6V-Flash** | 9B | ✓ (bartowski, Mungert) | ✓ | ✗ | MIT | MIT vision model at 6 GB |
| **MiniCPM-V 4.6** | 1.3B | ✓ (official + cookbook) | ✓ | ✗ | Apache 2.0 | Best Apache vision at <2 GB |
| **Granite 4.0** | 350M, 1B, 3B, 3B-Vision | ✓ (IBM official) | ✓ (3B-Vision) | ✗ | Apache 2.0 | Enterprise extraction |
| **LFM2 / LFM2.5** | 350M, 700M, 1.2B, 2.6B | ✓ (LiquidAI official) | ✗ | ✗ | CC-BY-4.0 / check | 2× CPU speed; extraction specialist |
| **SmolLM3** | 3B | ✓ (ggml-org) | ✗ | ✗ | Apache 2.0 | Minimum size is 3B |
| **Moondream2** | ~1.8B | ✓ | ✓ | ✗ | Apache 2.0 | Tiny vision; listed in llama.cpp multimodal.md |
| **InternVL 3** | 1B–14B | ✓ | ✓ | ✗ | Apache 2.0 | Listed in llama.cpp multimodal.md; strong for visual tasks |

---

## What to Change in LifeOS's Hardware Tier Table

### Tier: Large / High-End (24 GB+ VRAM)
- **Keep** Qwen3.6-35B-A3B as primary brain — still the best single-GPU 24 GB pick.
- **Add** Qwen3-Omni-30B-A3B as an audio-capable variant slot — for LifeOS audio input feature.
- **Add** Nemotron-Cascade-2-30B-A3B to catalog for long-context tasks (1M tokens, Mamba-2 efficiency).
- **Keep** Gemma 4 26B-A4B in catalog — good secondary for vision-only tasks with simpler config.
- **Add** Qwen3.6-27B to catalog for users who want text-only with simpler MoE-free setup.

### Tier: Medium (NEW — 8–16 GB VRAM)
- **Add this tier** to LifeOS config.
- **Primary:** GPT-OSS-20B (fastest, MoE efficiency) — flag OpenAI license for redistribution check.
- **Multimodal/vision:** Apriel-1.6-15B-Thinker — best vision + reasoning in the tier.
- **Apache-safe fallback:** Qwen3 14B or Qwen3.5-9B.

### Tier: Small (4–6 GB VRAM)
- **Swap primary** from Gemma 4 E4B to **Qwen3.5-9B** for 6 GB cards (better reasoning, 262K context, Apache 2.0).
- **Keep** Gemma 4 E4B as fallback for 4 GB ceiling (audio support, proven stability).
- **Add** GLM-4.6V-Flash to catalog as MIT-licensed vision alternative.

### Tier: Tiny / Android
- **Keep** Gemma 4 E2B as primary — proven, audio support, best LiteRT-LM integration.
- **Add** MiniCPM-V 4.6 as Apache 2.0 alternative for document/OCR tasks.
- **Add** Qwen3.5-2B as Apache 2.0 alternative with 262K context.
- **Document** Pixel 7 NPU limitation — CPU-only inference; set expectations accordingly.

### Tier: Nano-Agent (NEW — ≤1.5B structured extraction)
- **Add this tier** for fast on-CPU tool-calling / JSON extraction.
- **Primary:** Granite-4.0-H-1B (Apache 2.0, best BFCLv3 at size, official IBM GGUF).
- **Extraction specialist:** LFM2-1.2B-Extract (2× CPU speed, dedicated extraction checkpoint).
- **Ultra-nano:** Granite-4.0-H-350M for RPi / browser contexts.

---

## Licensing / Redistribution Notes

| License | Models | Redistribution |
|---|---|---|
| **Apache 2.0** | Qwen3.x, Qwen3.5, Qwen3.6, Gemma 4 E4B*, Granite 4.0, SmolLM3, MiniCPM-V 4.6, InternVL 3, Nemotron Cascade 2† | ✓ Redistribute freely; must retain license notice |
| **MIT** | Phi-4 (text), GLM-4.6V-Flash, DeepSeek V4-Flash | ✓ Most permissive; include license text |
| **Gemma Terms of Use** | Gemma 4 E2B, E4B, 26B, 31B | ✓ Commercial allowed; no impersonation of Google products |
| **Llama Community License** | Llama 4 Scout/Maverick | ✓ for <700M MAU; requires attribution |
| **OpenAI terms** | GPT-OSS-20B | ⚠️ Verify redistribution rights — not standard Apache/MIT |
| **ServiceNow research** | Apriel 1.6 | ⚠️ Verify commercial/redistribution rights before bundling |
| **CC-BY-4.0** | LFM2 series (most variants) | ✓ Attribution required |
| **NVIDIA Open** | Nemotron Cascade 2† | ✓ Commercial with attribution |

*Gemma 4 E4B is Apache 2.0 according to some HF cards; confirm per-model.
†Nemotron Cascade 2 uses NVIDIA's Open Model License, similar in permissiveness to Apache.

**Redistribution recommendation:** For LifeOS bundled catalog with potential redistribution, prefer Apache 2.0 (Qwen3.x, Granite, MiniCPM-V, InternVL) and MIT (GLM-4.6V-Flash, Phi-4). Flag OpenAI (GPT-OSS) and ServiceNow (Apriel) as "check before redistribution."

---

## Sources

1. [Best Local LLMs for 24GB VRAM: Performance Analysis 2026 | LocalLLM.in](https://localllm.in/blog/best-local-llms-24gb-vram)
2. [Local AI in 2026: The Best Models (Qwen, Mistral, Llama) | AI Magicx](https://www.aimagicx.com/blog/local-ai-models-2026-qwen-mistral-llama-hardware-guide)
3. [Best Qwen Models Ranked: Which to Run Locally (May 2026) | InsiderLLM](https://insiderllm.com/guides/qwen-models-guide/)
4. [Qwen3.6 on 24GB VRAM: Benchmark, Config | Amine Raji, PhD](https://aminrj.com/posts/llamacpp-qwen36-35b/)
5. [Gemma 4 E2B vs E4B: Edge Models Guide | MindStudio](https://www.mindstudio.ai/blog/gemma-4-e2b-e4b-edge-models-phone-local)
6. [Gemma 4 — Google DeepMind](https://deepmind.google/models/gemma/gemma-4/)
7. [DeepSeek V4 GGUF Status: What Runs Locally and What Doesn't](https://allthings.how/deepseek-v4-gguf-status-what-runs-locally-and-what-doesnt/)
8. [Running DeepSeek V4 Locally: VRAM Estimates | knightli.com](https://knightli.com/en/2026/05/01/deepseek-v4-local-vram-quantization-table/)
9. [DeepSeek V4 Flash — unsloth/DeepSeek-V4-Flash | HuggingFace](https://huggingface.co/unsloth/DeepSeek-V4-Flash)
10. [Llama 4 Guide: Running Scout and Maverick Locally (2026) | InsiderLLM](https://insiderllm.com/guides/llama-4-guide-scout-maverick/)
11. [Mistral Small 4: Open-Source MoE | Ten Invent Blog](https://teninvent.ro/en/blog/mistral-small-4-open-source-moe)
12. [Mistral Small 4 GGUF | unsloth/Mistral-Small-4-119B-2603-GGUF](https://huggingface.co/unsloth/Mistral-Small-4-119B-2603-GGUF)
13. [Nemotron Cascade 2: 30B Open MoE, One GPU | Awesome Agents](https://awesomeagents.ai/news/nvidia-nemotron-cascade-2-open-moe-30b/)
14. [Nemotron Cascade 2 GGUF | bartowski/nvidia_Nemotron-Cascade-2-30B-A3B-GGUF](https://huggingface.co/bartowski/nvidia_Nemotron-Cascade-2-30B-A3B-GGUF)
15. [Apriel-1.6-15B-Thinker: Cost-efficient Frontier Multimodal | HuggingFace Blog](https://huggingface.co/blog/ServiceNow-AI/apriel-1p6-15b-thinker)
16. [Best Local LLMs for 16GB VRAM: Practical Performance 2026 | LocalLLM.in](https://localllm.in/blog/best-local-llms-16gb-vram)
17. [Best LLM Models for 8GB VRAM in 2026 | InferenceRig](https://inferencerig.com/models/best-llm-models-for-8gb-vram-in-2026-tested-and-ranked/)
18. [GPT-OSS Inference with llama.cpp | DebuggerCafe](https://debuggercafe.com/gpt-oss-inference-with-llama-cpp/)
19. [GPT-OSS GGUF | ggml-org/gpt-oss-20b-GGUF | HuggingFace](https://huggingface.co/ggml-org/gpt-oss-20b-GGUF)
20. [Best Local LLM Apps for Android in 2026 | PromptQuorum](https://www.promptquorum.com/power-local-llm/best-local-llm-apps-android-2026)
21. [LiteRT-LM NPU Guide | Google AI Edge](https://ai.google.dev/edge/litert/next/litert_lm_npu)
22. [On-device GenAI with LiteRT-LM | Google Developers Blog](https://developers.googleblog.com/on-device-genai-in-chrome-chromebook-plus-and-pixel-watch-with-litert-lm/)
23. [MiniCPM-V 4.6 | ProductCool](https://www.productcool.com/product/minicpm-v-4-6-7)
24. [MiniCPM-V 4.6 llama.cpp Cookbook | OpenSQZ/MiniCPM-V-CookBook](https://github.com/OpenSQZ/MiniCPM-V-CookBook/blob/main/deployment/llama.cpp/minicpm-v4_6_llamacpp.md)
25. [GLM-4.6V-Flash GGUF | bartowski/zai-org_GLM-4.6V-Flash-GGUF](https://huggingface.co/bartowski/zai-org_GLM-4.6V-Flash-GGUF)
26. [LFM2-1.2B Official GGUF | LiquidAI/LFM2-1.2B-GGUF](https://huggingface.co/LiquidAI/LFM2-1.2B-GGUF)
27. [LFM2.5: Next Generation On-Device AI | Liquid AI Blog](https://www.liquid.ai/blog/introducing-lfm2-5-the-next-generation-of-on-device-ai)
28. [Granite 4.0 Nano: Just How Small Can You Go? | IBM Granite HF Blog](https://huggingface.co/blog/ibm-granite/granite-4-nano)
29. [IBM Granite 4.0 3B Vision Release | MarkTechPost](https://www.marktechpost.com/2026/04/01/ibm-releases-granite-4-0-3b-vision-a-new-vision-language-model-for-enterprise-grade-document-data-extraction/)
30. [SmolLM3-3B GGUF | ggml-org/SmolLM3-3B-GGUF](https://huggingface.co/ggml-org/SmolLM3-3B-GGUF)
31. [llama.cpp Multimodal Documentation | ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md)
32. [Qwen3-Omni 30B at 44 t/s via RPC | llama.cpp Discussion #18273](https://github.com/ggml-org/llama.cpp/discussions/18273)
33. [Qwen3.5-9B License | Qwen/Qwen3.5-9B HuggingFace](https://huggingface.co/Qwen/Qwen3.5-9B)
34. [Phi-4 Local Setup | LocalAI Master](https://localaimaster.com/blog/phi-4-local-setup)
35. [Phi-4-multimodal llama.cpp support discussion | HuggingFace](https://huggingface.co/microsoft/Phi-4-multimodal-instruct/discussions/7)
