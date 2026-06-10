# Axi Brain Model Ranking — Canonical Source of Truth

**Date:** 2026-06-10  
**Golden set:** 35 cases (`brain_quality.jsonl`)  
**Subjective cases:** 6 (judged by prod 35B Qwen on port 8080, except 35B itself — see footnotes)  
**Score formula:** `final = 0.7 × deterministic + 0.3 × subjective`

---

## Full Ranking (9 vision-capable models)

| Rank | Model | Params/class | Det | Subj | FINAL (0.7/0.3) | tok/s p50 (CPU) | Idle RSS | Vision | Verdict |
|------|-------|-------------|-----|------|-----------------|-----------------|----------|--------|---------|
| 1 | **qwen35-6-35b-a3b** ★ | ~35B MoE (A3B) | **0.771** | 0.898 † | **0.8092** † | N/A ‡ | 23073 MB ‡ | yes | **CURRENT PROD** |
| 2 | gemma4-26b-a4b-it | ~26B MoE (A4B) | 0.743 | 0.820 | **0.7661** | CPU-only (GPU deferred) | CPU-only | yes | big-tier |
| 3 | gemma4-e2b-it | ~2B MoE (E2B) | 0.657 | 0.795 | **0.6984** | 27.87 tok/s | 4631 MB | yes | keep |
| 4 | gemma4-e4b-it | ~4B MoE (E4B) | 0.600 | 0.817 | **0.6650** | 15.36 tok/s | 6810 MB | yes | keep |
| 5 | nemotron3-nano-omni-30b-a3b | ~30B MoE (A3B) | 0.629 | 0.735 | **0.6608** | CPU-only (GPU deferred) | CPU-only | yes | big-tier |
| 6 | qwen35-4b | 4B dense | 0.571 | 0.738 | **0.6212** | 15.81 tok/s | 4923 MB | yes | keep |
| 7 | qwen35-9b | 9B dense | 0.543 | 0.727 | **0.5981** | 9.29 tok/s | 7961 MB | yes | cut candidate |
| 8 | qwen35-2b | 2B dense | 0.343 | 0.700 | **0.4501** | 32.84 tok/s | 2722 MB | yes | cut candidate |
| 9 | qwen35-0_8b | 0.8B dense | 0.257 | 0.398 | **0.2994** | 58.35 tok/s | 1413 MB | yes | cut |

★ Current production brain (GPU inference, port 8080).  
† Subjective score judged by **gemma4-26b-a4b-it** (cross-family) — NOT the 35B itself. All other models were judged by the 35B. The 30% subjective axis is **not directly comparable** to the other rows. Deterministic (70%) is the clean cross-model comparator.  
‡ CPU-only benchmark only; prod runs on GPU. RSS and tok/s figures are CPU baseline, not prod speed.

---

## Post-decision evaluation: gemma4-12b-it (2026-06-10) — REJECTED

New dense 12B candidate (`unsloth/gemma-4-12b-it-GGUF`, Q4_K_M + vision mmproj) benchmarked on the same golden set.

| Model | Det | Subj | FINAL | tok/s (CPU) | RSS | Notes |
|-------|-----|------|-------|-------------|-----|-------|
| gemma4-12b-it | 0.657 | 0.828 | **0.7084** | **4.3** (dense) | 9376 MB | DENSE 12B, no --cpu-moe |
| gemma4-e2b-it | 0.657 | 0.795 | 0.6984 | 27.9 | 4631 MB | small champ |
| gemma4-26b-a4b-it | 0.743 | 0.820 | 0.7661 | (cpu-moe) | — | big-tier alt |

**Verdict: REJECTED — no niche.** Deterministic is IDENTICAL to gemma4-e2b (both 23/35); the tiny FINAL edge comes entirely from the 6-case subjective sample (noise). It is dominated from both sides: where VRAM exists, gemma4-26b gives better quality (0.766) at similar VRAM via --cpu-moe; where it's tight, gemma4-e2b matches its quality at ~6.5× the CPU speed (27.9 vs 4.3 tok/s) and half the RAM. A dense 12B earns nothing here. Catalog/tiers stay unchanged.

---

## Thinking / Reasoning flags

| Model | Flag used | Leak observed |
|-------|-----------|---------------|
| gemma4-26b-a4b-it | `--reasoning off` | none — clean |
| nemotron3-nano-omni-30b-a3b | `--reasoning off` | none — clean |
| gemma4-e4b-it | `--reasoning off` | none |
| gemma4-e2b-it | `--reasoning off` | none |
| qwen35-{9b,4b,2b,0_8b} | `disable_thinking=True` (chat_template_kwargs) | none |

---

## Cut List (no mmproj — blind, not vision-capable)

| Model | Reason |
|-------|--------|
| granite-4.0-h-1b | No mmproj; blind (text-only); too small for Axi co-pilot quality bar |
| smollm2-360m | No mmproj; 360M is below minimum quality threshold for any task |
| lfm2-1.2b-extract | No mmproj; extraction-only fine-tune, not general assistant |
| lfm2.5-350m | No mmproj; 350M; below quality floor |

---

## Notes

- **Big-tier CPU-only caveat:** gemma4-26b, nemotron-30b, and the prod 35B were all run CPU-only (`-ngl 0`). tok/s and RSS columns are not representative — real inference speed on GPU is deferred. Quality scores are valid regardless of hardware.
- **Judge scale caveat:** The 35B Qwen judge scored all 8 challenger models. The 35B itself was judged by gemma4-26b-a4b-it (cross-family) to avoid self-judging. This means the 35B's subjective score (0.898) and final (0.809) are on a different judge scale than the others — do not directly compare the 30% subjective component across rows.
- **Small subjective sample:** Only 6 of 35 cases have rubrics (subjective). The 0.3 weight on 6 cases introduces variance. Treat subjective scores as directional, not precise.
- **qwen35-2b** is the weakest vision survivor — final 0.4501, deterministic 0.343. Cut candidate unless small-footprint tier is needed.
- **qwen35-9b** scores below qwen35-4b on final despite being 2× larger — 4b has better quality-per-parameter on this eval set.
- **Prod 35B category breakdown** (2026-06-10): conversation 3/4, fluency 1/3 (verbosity failures), hard 3/4, instruction_following 4/4, intent_classification 3/3, reasoning 4/4, refusal 2/3, reminder_time 5/5, summarization 2/5.

---

## Key Findings

### 2026-06-09 — challenger ranking
**YES — gemma4-26b-a4b-it beats the previous leader.** At final=0.7661 it is +6.8 points above gemma4-e2b-it (0.6984). If GPU inference confirms acceptable latency, it is a strong replacement candidate for the brain tier. The surprising result is that gemma4-e2b-it (2B MoE) still outperforms the Nemotron-30B MoE (0.6984 vs 0.6608) — Nemotron's refusal category scored 0/3 which dragged both det and subj down.

### 2026-06-10 — prod brain added to ranking
**NO — gemma4-26b-a4b-it does NOT beat the current prod brain on deterministic quality.**  
Prod 35B det=0.771 vs gemma4-26b det=0.743 — the 35B wins by **+0.028** on the fair (same-scorer) comparator.  
The 35B's deterministic score of 0.771 puts it clearly ahead of all challengers. Main weaknesses: summarization (2/5 — misses exact keywords), fluency (1/3 — verbosity over max_words limit), refusal (2/3).  
**Switching to gemma4-26b would be a regression on deterministic quality.** GPU speed and latency remain the only valid reasons to switch.

---

## VRAM-tier recommendation (2026-06-09)

### GPU Speed Table — full picture (all measured configs)

| Label | Model | ngl | cpu-moe | tok/s p50 | Peak VRAM MiB | Quality FINAL |
|-------|-------|-----|---------|-----------|---------------|---------------|
| qwen35-6-35b-a3b-prod-flags | qwen35-6-35b-a3b | 999 | yes | 27.4 | 5028 | 0.809 † |
| gemma4-26b-a4b-full-gpu | gemma4-26b-a4b-it | 999 | no | OOM | — | 0.766 |
| gemma4-26b-a4b-cpu-moe | gemma4-26b-a4b-it | 999 | yes | 28.2 | 6202 | 0.766 |
| nemotron3-nano-30b-cpu-moe | nemotron-30b-a3b | 999 | yes | 26.0 | 5420 | 0.661 |
| gemma4-e2b-it-full-gpu | gemma4-e2b-it | 999 | no | **193** | 3342 | 0.698 |
| gemma4-e4b-it-full-gpu | gemma4-e4b-it | 999 | no | 108 | 5202 | 0.665 |
| qwen35-4b-full-gpu | qwen35-4b | 999 | no | 109 | 5098 | 0.621 |
| qwen35-6-35b-a3b-cpu-moe-ngl20-4gb | qwen35-6-35b-a3b | 20 | yes | 15.6 | 3546 | 0.809 † |
| gemma4-26b-a4b-it-cpu-moe-ngl12-4gb | gemma4-26b-a4b-it | 12 | yes | 14.4 | 4092 | 0.766 |

† Subjective score from different judge — deterministic (det=0.771) is the reliable cross-model comparator.

### Per-Tier Pick

#### 4 GB VRAM tier
**Pick: qwen35-6-35b-a3b at ngl=20, --cpu-moe**  
- Config: `-ngl 20 --cpu-moe --ctx-size 32768`  
- VRAM: 3546 MiB peak (fits with ~550 MiB headroom)  
- Speed: 15.6 tok/s — usable for async/background use, slow for interactive  
- Quality: det=0.771 — highest quality of any model tested; same brain as current prod  
- Alternative: gemma4-e2b-it at ngl=999 fits in 3342 MiB (more headroom), runs 193 tok/s, but quality is much lower (det=0.657). Only prefer it if interactive latency is critical and quality can be sacrificed.  
- **Verdict:** 4GB is tight for the big models. qwen35-35b at ngl=20 gives best quality at the cost of speed. If speed matters more than quality at this tier, gemma4-e2b is the fast alternative.

#### 8 GB VRAM tier
**Pick: qwen35-6-35b-a3b at ngl=999, --cpu-moe**  
- Config: `-ngl 999 --cpu-moe --ctx-size 32768` (prod flags)  
- VRAM: 5028 MiB peak — fits easily in 8GB  
- Speed: 27.4 tok/s — excellent interactive performance  
- Quality: det=0.771 — best in class; this is current prod  
- Note: gemma4-26b at cpu-moe needs 6202 MiB (also fits), runs 28.2 tok/s, but quality is lower (det=0.743). No reason to pick it over the 35B at this tier.  
- **Verdict:** Clean winner. Full prod config fits with ~3GB headroom.

#### 12 GB VRAM tier
**Pick: qwen35-6-35b-a3b at ngl=999, --cpu-moe** (same as 8GB tier — full offload not needed at 35B scale)  
- Config: identical to 8GB tier  
- VRAM: 5028 MiB peak — 7GB headroom remaining  
- Speed: 27.4 tok/s  
- Quality: det=0.771  
- Note: At 12GB, gemma4-26b full-GPU would be theoretically possible if a smaller quantization existed, but the current Q4_K_M at 26B OOMs on 12GB (tried: no healthy after 240s). Full GPU offload for 26B requires >12GB.  
- The 12GB headroom could be used for larger context windows (increase `--ctx-size`) rather than switching models.  
- **Verdict:** Same pick as 8GB. Extra VRAM gives room for context expansion, not a model upgrade.

### Summary

| VRAM budget | Best model | Config | tok/s | Peak VRAM | Quality (det) |
|-------------|------------|--------|-------|-----------|---------------|
| 4 GB | qwen35-6-35b-a3b | ngl=20, --cpu-moe | 15.6 | 3546 MiB | 0.771 |
| 8 GB | qwen35-6-35b-a3b | ngl=999, --cpu-moe (prod) | 27.4 | 5028 MiB | 0.771 |
| 12 GB | qwen35-6-35b-a3b | ngl=999, --cpu-moe (prod) | 27.4 | 5028 MiB | 0.771 |

The 35B MoE model dominates all three tiers by quality. The only real tradeoff is at 4GB where speed drops to ~16 tok/s; gemma4-e2b (3342 MiB, 193 tok/s, det=0.657) is the speed-first fallback for interactive use at that constraint.
