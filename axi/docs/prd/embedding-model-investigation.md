# Embedding Model Investigation — Axi "embed" slot

Status: research only (no downloads, no runs). Date: 2026-07-18.

## Goal

Pick the best text-embedding model for the LifeOS/Axi semantic memory / RAG "embed"
slot. Hard constraints:

- **Spanish-first** (Rioplatense/neutral) with some English → multilingual / strong-Spanish
  retrieval quality is the primary axis, not English-only MTEB.
- Served via **llama.cpp** → must be **GGUF-compatible** with working llama.cpp embedding support.
- Runs **CPU-only** today (`ngl 0`) so the RTX 5070 Ti 12GB stays free for the brain.
  Hardware: i9-13900HX, 94GB RAM. CPU latency per embed matters for interactive RAG.
- **Matryoshka / truncatable dims** is a plus — the slot truncates to **512** today.
- Use case: short-to-medium personal records, notes, conversations.

## Current slot (provisional)

`config/active_embed_model.json`: `qwen3-embedding-4b`, Q4_K_M GGUF, ctx 512, ngl 0 (CPU),
pooling `last`, dim 512. The file `_note` says "truncation from 2048/1024" — that is imprecise:
**Qwen3-Embedding-4B native dim is 2560** (0.6B = 1024, 8B = 4096). 512 is still a valid MRL
truncation, just from 2560.

## Candidate comparison

| Model | Params | Native dim (MRL) | Max ctx | Pooling | GGUF + llama.cpp | Multilingual / Spanish standing | CPU feasibility (this laptop) |
|---|---|---|---|---|---|---|---|
| **Qwen3-Embedding-0.6B** | 0.6B | 1024 (MRL ✓, any dim) | 32k | last (instruction-aware) | ✅ Official Qwen GGUF | MMTEB-R ≈ 64.6; best-in-class small model, only trails Gemini-Embedding | Excellent — small, fast per-embed on CPU |
| **Qwen3-Embedding-4B** (current) | 4B | 2560 (MRL ✓) | 32k | last | ✅ Official Qwen GGUF | MMTEB multi mean ≈ 69.4 | OK but heavy — ~2.5GB Q4_K_M, slowest per embed |
| **Qwen3-Embedding-8B** | 8B | 4096 (MRL ✓) | 32k | last | ✅ Official Qwen GGUF | #1 MTEB multilingual Jun-2025, 70.58 | Poor for CPU-only interactive use (too slow) |
| **BGE-M3** | 568M | 1024 (no MRL) | 8192 | cls | ✅ Widely available; dense head works on stock llama.cpp (sparse/ColBERT heads need a fork) | Very strong multilingual + Spanish (MIRACL); community RAG default | Excellent — fast, long context |
| **multilingual-e5-large-instruct** | 560M | 1024 (no MRL) | **512** | mean | ✅ Since llama.cpp XLM-R support (Aug-2024) | 94 langs, solid Spanish (MIRACL); needs `query:`/`passage:` prefixes | Excellent — but 512 ctx cap is limiting |
| **Jina embeddings v3** | 570M | 1024 (MRL ✓ to 32) | 8192 | mean | ⚠️ Poor — LoRA-adapter arch; GGUF conversion problematic on stock llama.cpp | Frontier multilingual, strong Spanish | Good size, but llama.cpp path is unreliable → avoid |
| **Jina embeddings v4** | 3.8B | 2048 (MRL ✓ to 128) | 32k | mean | ✅ Official Jina GGUF + llama.cpp fork (text + multimodal) | Multimodal multilingual retrieval (qwen2.5-vl-3b base) | Heavy (~3.8B), overkill for text-only CPU RAG |
| **Nomic-embed-text v2 (MoE)** | ~475M (MoE) | 768 (MRL ✓ to 256) | 512 (typical) | mean | ✅ MoE support merged in llama.cpp | ~100 langs, competitive with 2x-size models | Excellent — but 768→256 MRL, and short ctx |
| **GTE-multilingual-base** | 305M | 768 (MRL ✓) | 8192 | cls/mean | ✅ (encoder arch) | Strong multilingual; backbone of Arctic-m-v2.0 | Excellent — smallest strong option |
| **Snowflake Arctic-embed-l-v2.0** | 568M | 1024 (MRL ✓) | 8192 | cls | ✅ GGUF available (Casual-Autopsy, limcheekin) | Excellent multilingual (MIRACL + CLEF), English not compromised; needs `query:` prefix | Excellent — fast, long ctx, MRL |
| Arctic-embed-m-v2.0 | 305M | 768 (MRL ✓) | 8192 | cls | ✅ | On GTE-multilingual-base | Excellent |
| Llama-Embed-Nemotron-8B (NVIDIA, Oct-2025) | 8B | — | — | — | ⚠️ unclear/none | #1 MMTEB Borda (Oct-2025) | Poor for CPU-only (8B) |
| KaLM-Embedding-Gemma3-12B (Tencent) | 12B | 3840 | — | — | ⚠️ none practical | #1 MMTEB Jul-2026 (72.32) | Not viable on CPU |
| Gemini-Embedding (Google) | API | — | — | — | ❌ proprietary, cloud | Reference SOTA | Not local — excluded |

Notes on newest arrivals: the current MMTEB toppers (Llama-Embed-Nemotron-8B, KaLM-Gemma3-12B)
are 8B–12B and/or lack a practical GGUF path — irrelevant for a CPU-only local slot. MTEB v2/2026
scores are not directly comparable to v1, so treat cross-board numbers as directional.

## Recommendation (Spanish-first, CPU-only, llama.cpp)

**Top pick: Qwen3-Embedding-0.6B.**
Best speed/quality tradeoff for a CPU-only interactive RAG slot. It keeps the *same family and
`pooling: "last"` behavior* as the current 4B (drop-in, minimal surprise), has clean **MRL so
512-dim truncation from native 1024 is well-supported**, ships an **official Qwen GGUF**, handles
**32k context**, and is a top-ranked *small* multilingual model (only trails Gemini-Embedding).
Versus the current 4B it loses ~5 MMTEB points overall but gains a large CPU-latency win — the
right call for a daily-driver local memory that embeds constantly.

**Runner-up: BGE-M3.**
Choose it if Spanish-retrieval robustness and long documents matter more than same-family
consistency or MRL. 568M, **8192 ctx**, battle-tested rock-solid llama.cpp dense-head support,
and one of the strongest multilingual/Spanish retrievers in the open-weights RAG world (MIRACL).
Caveat: **no Matryoshka** — truncating its 1024 dim to 512 is not MRL-trained, so keep dim=1024
(or accept some quality loss). Switch pooling to `cls`.

**Honorable mention: Snowflake Arctic-embed-l-v2.0** — 568M, MRL ✓ to 512, 8192 ctx, excellent
multilingual (MIRACL+CLEF). The best "BGE-M3 but with Matryoshka" option; needs `query:` prefix
and `cls` pooling. Worth a bake-off against Qwen3-0.6B if you want MRL + a non-Qwen encoder.

**Keep the 4B only if** embedding latency is a non-issue and you want maximum retrieval quality;
otherwise 0.6B is the better daily driver.

Suggested Slice-0 Spanish eval order: Qwen3-0.6B vs BGE-M3 vs Arctic-embed-l-v2.0 (all CPU-cheap),
on your own Spanish records, before committing.

## How to swap (one-file change)

Swapping is a single edit to `config/active_embed_model.json` — no code change. Fields:

- **`id`** — logical name / model dir key.
- **`gguf`** — path to the GGUF file (e.g. `~/LifeOS/models/<id>/<file>.gguf`).
- **`ctx`** — context length. Keep ≥ your chunk size. 512 is fine for short records; raise to
  1024–2048 for BGE-M3/Arctic if you chunk larger (they support 8192).
- **`ngl`** — GPU layers. Keep **0** (CPU-only) to leave VRAM for the brain.
- **`port`** — llama.cpp embedding server port (currently 8091). Unchanged.
- **`pooling`** — **model-specific, critical**:
  - Qwen3-Embedding (0.6B/4B/8B): `last`
  - BGE-M3, Arctic-embed-v2.0: `cls`
  - multilingual-e5, Nomic-v2, GTE, Jina: `mean`
- **`dim`** — output dim. Only truncate below native on **MRL models** (Qwen3, Arctic, Jina, Nomic,
  GTE). For non-MRL models (BGE-M3, e5) use the native dim (1024). Keep 512 for Qwen3-0.6B.
- **`extra_args`** — llama.cpp flags. Current: `["-t","4","--no-mmap"]`. Keep `-t` = physical-core
  budget you want to give embedding; `--no-mmap` is fine on 94GB RAM.

Prompt/prefix gotchas to mirror in the embedding call layer (not in this file):
- **e5** requires `query:` / `passage:` prefixes; **Arctic-embed-v2.0** requires a `query:` prefix
  on queries; **Qwen3** uses an instruction on the *query* side only; **BGE-M3** needs no prefix.
- Verify the GGUF's `pooling_type` metadata matches the `pooling` value above, or pass
  `--pooling <type>` explicitly in `extra_args`.

Example (top pick):

```json
{
  "id": "qwen3-embedding-0.6b",
  "gguf": "~/LifeOS/models/qwen3-embedding-0.6b/Qwen3-Embedding-0.6B-Q4_K_M.gguf",
  "ctx": 512,
  "ngl": 0,
  "port": 8091,
  "pooling": "last",
  "dim": 512,
  "extra_args": ["-t", "4", "--no-mmap"]
}
```

## Sources

- Qwen3-Embedding blog / paper — https://qwenlm.github.io/blog/qwen3-embedding/ , https://arxiv.org/html/2506.05176v1
- Qwen3-Embedding GGUF — https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF , https://huggingface.co/Qwen/Qwen3-Embedding-8B-GGUF
- BGE-M3 GGUF / llama.cpp — https://huggingface.co/lm-kit/bge-m3-gguf , https://github.com/ggml-org/llama.cpp/issues/25109 , https://bge-model.com/bge/bge_m3.html
- multilingual-e5-large-instruct GGUF — https://huggingface.co/intfloat/multilingual-e5-large-instruct , https://huggingface.co/Ralriki/multilingual-e5-large-instruct-GGUF
- Jina v3 / v4 — https://jina.ai/models/jina-embeddings-v3/ , https://jina.ai/news/multimodal-embeddings-in-llama-cpp-and-gguf/ , https://github.com/jina-ai/jina-embeddings-v4-gguf , https://github.com/ggml-org/llama.cpp/issues/9585
- Nomic-embed-text-v2-moe — https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe-GGUF , https://github.com/ggml-org/llama.cpp/pull/12466 , https://simonwillison.net/2025/Feb/12/nomic-embed-text-v2/
- GTE-multilingual / Arctic-embed 2.0 — https://arxiv.org/html/2412.04506v2 , https://huggingface.co/Snowflake/snowflake-arctic-embed-l-v2.0 , https://huggingface.co/limcheekin/snowflake-arctic-embed-l-v2.0-GGUF
- MMTEB leaderboard context — https://arxiv.org/html/2502.13595v1 , https://huggingface.co/blog/nvidia/llama-embed-nemotron-8b , https://www.codesota.com/benchmarks/mteb
