#!/usr/bin/env python3
"""model_audit.py — tune-to-peak model audit harness for LifeOS/Axi.

Philosophy: no model competes until it has been TUNED to its peak. The harness
first FINDS each model's best llama.cpp configuration automatically, saves it
as a recipe, and only then runs the full quality/role evaluation at that peak.

Pipeline per tier (cpu / vram4 / vram8 / vram12):
  Stage A — perf auto-tune (cheap): sweep a PRUNED grid of launch configs on the
            bench port, 2-3 short prompts per cell, measuring decode tok/s +
            TTFT + VRAM delta + RSS. OOM / health-fail cells are recorded as
            failed and skipped. Pareto pick: max decode tok/s subject to the
            tier's VRAM budget (ties: lower TTFT, then earlier cell).
  Stage B — quality tune (moderate): at the Stage-A winner, sweep sampling
            presets (model-card default via --sampling, house default) x
            thinking modes (--thinking-modes), scored on a deterministic FAST
            SUBSET (~12 cases, every 3rd) of brain_quality.jsonl.
  Stage C — full audit at peak: run the FULL role suite at the winning recipe
            and append everything to results/model_audit.jsonl.

Recipes are persisted to results/model_recipes.json; --use-recipe skips
Stages A/B and audits straight at the saved recipe. --quick = reduced Stage-A
grid + skip Stage B.

Roles: speed, brain, extraction (reused from bench_model.py) + domain,
toolcall, vision (needs --mmproj), codereview, embed (needs --embedding),
codegen (writes code, harness EXECUTES it in a sandboxed subprocess),
conversation (judge-scored conversational pleasantness + Spanish checks),
recordsqa (grounded personal-records QA + fabricated-number detector),
narration (digest narration with numeric fidelity + warmth judge),
longsum (long-context meeting/chat summarization with planted atoms),
parsejson (strict JSON/label parsing fallbacks incl. negative traps),
agentic (REAL multi-round tool loop with canned web handlers, <=5 rounds,
forced final JSON synthesis), proactive (autonomous thought quality +
ESPERAR/NADA restraint discipline), visionclass (posture-style strict-JSON
vision classification, needs --mmproj), devplan (self-dev director:
instruction authoring + DONE/NOT DONE goal-satisfaction review),
toolstress (MCP-style tool-protocol robustness: right-tool selection among
~13 confusable tools, exact nested-JSON args, error-retry recovery, and
skill-like procedure following with values threaded between calls).

BUILDS ON bench_model.py — spawn/kill/registry/scorer wiring is imported, not
rewritten. Reuses cpu_sweep.check_deterministic, subjective_judge, and
lifeos.agents.eval.scoring exactly like v1 does.

Safety: candidate servers run ONLY on --port (default 18080; 8080/8081/8082/
8090/8091 are refused), spawned with start_new_session=True and killed by
process group. Strictly sequential: one server at a time, VRAM must drain
(<500 MiB above baseline) between cells.

Comparability era: seeds are pinned as of 2026-07-16. Every sampling-
sensitive request (temperature > 0: brain, conversation, narration, longsum,
recordsqa, proactive, toolcall, codereview, codegen, parsejson, devplan,
vision/visionclass, the agentic and toolstress tool loops, and Stage B) now
carries a DETERMINISTIC per-case seed (crc32 of the case id), and judge
calls pin seed=0 on top of their temperature 0.0. Results recorded BEFORE
2026-07-16 are a DIFFERENT comparability era for sampling-sensitive roles —
do not compare their scores 1:1 against pinned-seed rows. Each role result
records the exact configuration it was scored with in "sampling_used".

Sample usage
------------
  # Fresh full audit (tune + full suite) on the 12GB GPU tier:
  .venv/bin/python scripts/bench/model_audit.py \
      --gguf /home/hectormr/LifeOS/models/foo/foo-Q4_K_M.gguf \
      --label foo-q4 --tiers vram12 --thinking-modes none,off,on

  # Re-audit at the saved peak recipe (skip tuning):
  .venv/bin/python scripts/bench/model_audit.py \
      --gguf /path/foo.gguf --label foo-q4 --tiers vram12 --use-recipe

  # Quick tune (reduced grid, no Stage B) on CPU:
  .venv/bin/python scripts/bench/model_audit.py \
      --gguf /path/foo.gguf --label foo-q4 --tiers cpu --quick

  # Side-by-side matrix / one model's full detail:
  .venv/bin/python scripts/bench/model_audit.py --compare
  .venv/bin/python scripts/bench/model_audit.py --report foo-q4
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.request
import zlib
from dataclasses import dataclass, asdict, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── paths & reuse wiring ─────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import bench_model as bm  # v1 orchestrator — spawn/kill/registry/roles reused

# Production sources of truth for the agentic role. The harness sends the
# EXACT system prompt, forced-synthesis nudge, and tool schemas that
# axi.briefing.run_agentic_briefing sends, imported (not paraphrased) so the
# harness cannot drift from production. Both modules are stdlib-only at import
# time. When the axi package is unavailable the rest of the audit still works;
# only the agentic role raises with a clear message.
def _import_axi_prod():
    """Import the production briefing prompt + web tool schemas.

    The audits run under the LIFEOS venv (extraction needs it), which does
    not have axi installed — inject axi/src into sys.path as a fallback so
    the agentic role can still import the REAL production prompt/schemas
    (this exact gap killed the gemma4-e4b audit on the 2026-07-15 marathon:
    the role raised and the whole audit died before persisting its row).
    """
    try:
        from axi.briefing import _FINAL_SYNTHESIS_PROMPT, build_briefing_system
        from axi.web_tools import web_fetch_tool_def, web_search_tool_def
    except ImportError:
        axi_src = str((SCRIPT_DIR.parents[1] / "src").resolve())
        if axi_src not in sys.path:
            sys.path.insert(0, axi_src)
        from axi.briefing import _FINAL_SYNTHESIS_PROMPT, build_briefing_system
        from axi.web_tools import web_fetch_tool_def, web_search_tool_def
    return (_FINAL_SYNTHESIS_PROMPT, build_briefing_system,
            web_fetch_tool_def, web_search_tool_def)


try:
    (AGENTIC_SYNTHESIS_PROMPT, _prod_briefing_system,
     _prod_web_fetch_tool_def, _prod_web_search_tool_def) = _import_axi_prod()
    _AXI_IMPORT_ERROR: Optional[Exception] = None
except Exception as _axi_import_exc:  # noqa: BLE001 — standalone run without axi
    AGENTIC_SYNTHESIS_PROMPT = None  # type: ignore[assignment]
    _prod_briefing_system = None  # type: ignore[assignment]
    _prod_web_fetch_tool_def = None  # type: ignore[assignment]
    _prod_web_search_tool_def = None  # type: ignore[assignment]
    _AXI_IMPORT_ERROR = _axi_import_exc

RESULTS_DIR = SCRIPT_DIR / "results"
AUDIT_REGISTRY_PATH = RESULTS_DIR / "model_audit.jsonl"
RECIPES_PATH = RESULTS_DIR / "model_recipes.json"
GOLDEN_DIR = bm.LIFEOS_SRC / "lifeos" / "agents" / "eval" / "golden_sets"
VISION_ASSETS_DIR = GOLDEN_DIR / "vision_assets"

# Ports we must never spawn on (prod judge / nano / secondary prod / spares).
FORBIDDEN_PORTS = {8080, 8081, 8082, 8090, 8091}

# Tier VRAM budgets in MiB (max VRAM the candidate may occupy).
TIER_BUDGETS_MIB = {"cpu": 0, "vram4": 3500, "vram8": 7500, "vram12": 11000}

# ctx_max probe (role "ctxprobe"): two-point linear KV extrapolation. Measure
# VRAM at the SAME launch config with two ctx values, fit a line, and predict
# the maximum -c that fits each tier budget. No binary search — KV cache
# growth is linear in ctx for llama.cpp.
CTX_PROBE_LO = 8192
CTX_PROBE_HI = 32768
CTX_PROBE_NOTE_CPU = "cpu tier — no VRAM ceiling"
CTX_PROBE_NOTE_SLOPE = "slope unmeasurable"

# House default sampling (our standard bench sampling).
HOUSE_SAMPLING = {"temperature": 0.6, "top_p": 0.95, "top_k": 20}

# Seed policies recorded in each role's "sampling_used" (2026-07-16 era).
SEED_POLICY_PER_CASE = "per-case-crc32"   # deterministic seed per golden case
SEED_POLICY_FIXED_0 = "fixed-0"           # extractor path: temperature 0, seed 0
SEED_POLICY_NA = "n/a"                    # no sampling at all (speed, embed)


def case_seed(case_id) -> int:
    """Deterministic per-case sampling seed: crc32 of the case id.

    Same case always samples with the same seed (kills run-to-run variance at
    temperature > 0 — qwen35-4b brain det swung 0.37↔0.51 across identical
    runs before pinning); different cases get different seeds so a golden set
    never samples with one correlated stream.
    """
    return zlib.crc32(str(case_id).encode("utf-8")) & 0x7FFFFFFF


def build_sampling_used(sampling: Optional[dict], thinking: str,
                        seed_policy: str) -> dict:
    """The per-role sampling record: WITH WHICH config a score was earned."""
    s = sampling or {}
    return {"temperature": s.get("temperature"), "top_p": s.get("top_p"),
            "top_k": s.get("top_k"), "seed_policy": seed_policy,
            "thinking": thinking}


def role_sampling_used(role: str, sampling: Optional[dict],
                       thinking: str) -> dict:
    """Accurate "sampling_used" for one role result.

    - speed/embed: no sampling is exercised at all (streaming perf /
      /v1/embeddings) → everything n/a.
    - extraction/domain: requests go through the production extractor, which
      pins temperature=0.0 / seed=0 itself → fixed-0.
    - agentic: production tool-loop sampling is PINNED (brain._base_payload
      engine='4b': 0.7/0.8/20) regardless of the recipe → prod values,
      per-case seed.
    - everything else: the recipe sampling + thinking, per-case seed.
    """
    if role in ("speed", "embed", "ctxprobe"):
        return build_sampling_used(None, "n/a", SEED_POLICY_NA)
    if role in ("extraction", "domain"):
        return build_sampling_used({"temperature": 0.0}, "n/a",
                                   SEED_POLICY_FIXED_0)
    if role == "agentic":
        return build_sampling_used(AGENTIC_PROD_SAMPLING, thinking,
                                   SEED_POLICY_PER_CASE)
    return build_sampling_used(sampling, thinking, SEED_POLICY_PER_CASE)

VALID_THINKING_MODES = ("none", "off", "on", "budget512")
VALID_ROLES = ("speed", "brain", "extraction", "domain", "toolcall",
               "vision", "codereview", "embed", "codegen", "conversation",
               "recordsqa", "narration", "longsum", "parsejson",
               "agentic", "proactive", "visionclass", "devplan",
               "toolstress", "ctxprobe")

FAST_SUBSET_SIZE = 12
FAST_SUBSET_STRIDE = 3
STAGE_A_MAX_CELLS = 10
STAGE_B_MAX_VARIANTS = 6
VRAM_DRAIN_DELTA_MIB = 500
OOM_FALLBACK_NGL = 24

CLEAN_OK_TOKEN = "sin bugs"

# OpenAI tool schemas for the toolcall role. Golden-set cases reference these
# by name (mirrors Axi's real whitelisted web-search tool-calling).
TOOL_SCHEMAS: dict[str, dict] = {
    "web_search": {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web for current information the assistant does not know.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query."},
                },
                "required": ["query"],
            },
        },
    },
    "create_reminder": {
        "type": "function",
        "function": {
            "name": "create_reminder",
            "description": "Create a reminder for the user.",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "What to remind."},
                    "when_iso": {"type": "string",
                                 "description": "When, as ISO 8601 datetime."},
                },
                "required": ["text", "when_iso"],
            },
        },
    },
    "get_health_summary": {
        "type": "function",
        "function": {
            "name": "get_health_summary",
            "description": "Summarize the user's logged health metrics over the last N days.",
            "parameters": {
                "type": "object",
                "properties": {
                    "days": {"type": "integer",
                             "description": "How many days back to summarize."},
                },
                "required": ["days"],
            },
        },
    },
}

# Tiny retrieval sanity set for the embed role (cosine argmax, no deps).
EMBED_SANITY = [
    {"query": "gasté 250 pesos en el súper",
     "docs": ["compra de despensa en el supermercado",
              "salí a correr cinco kilómetros",
              "medité diez minutos por la mañana"],
     "best": 0},
    {"query": "mi presión arterial estuvo alta hoy",
     "docs": ["receta de pastel de chocolate",
              "registro de salud: presión y pulso",
              "lista de canciones para el gimnasio"],
     "best": 1},
    {"query": "cena con mis papás el sábado",
     "docs": ["factura de electricidad de junio",
              "rutina de pesas para espalda",
              "reunión familiar el fin de semana"],
     "best": 2},
]


# ═════════════════════════════════════════════════════════════════════════════
# PURE LOGIC (unit-tested — no process spawn, no network)
# ═════════════════════════════════════════════════════════════════════════════

# ── launch cells (Stage A sweep space) ───────────────────────────────────────

@dataclass(frozen=True)
class Cell:
    """One launch configuration to try in Stage A."""
    name: str
    ngl: int
    cpu_moe: bool = False
    cache_type: Optional[str] = None   # applied to both -ctk and -ctv
    flash_attn: bool = False
    batch: Optional[int] = None
    ubatch: Optional[int] = None
    threads: Optional[int] = None
    no_mmap: bool = False

    def to_extra_flags(self) -> list[str]:
        """Cell knobs → llama-server extra flags (ngl/cpu_moe go via bench_model)."""
        flags: list[str] = []
        if self.cache_type:
            flags += ["--cache-type-k", self.cache_type,
                      "--cache-type-v", self.cache_type]
        if self.flash_attn:
            flags += ["-fa", "on"]
        if self.batch is not None:
            flags += ["-b", str(self.batch)]
        if self.ubatch is not None:
            flags += ["-ub", str(self.ubatch)]
        if self.threads is not None:
            flags += ["-t", str(self.threads)]
        if self.no_mmap:
            flags.append("--no-mmap")
        return flags


def cell_from_dict(d: dict) -> Cell:
    """Rebuild a Cell from its asdict() form (registry / recipe round-trip)."""
    fields = {k: d[k] for k in
              ("name", "ngl", "cpu_moe", "cache_type", "flash_attn",
               "batch", "ubatch", "threads", "no_mmap") if k in d}
    return Cell(**fields)


def detect_moe(gguf_path: str, override: str = "auto") -> bool:
    """Is this a MoE model? --moe on/off overrides; auto = filename heuristic."""
    if override == "on":
        return True
    if override == "off":
        return False
    import re
    name = Path(gguf_path).name.lower()
    return bool(re.search(r"(moe|mixtral|granite-?3\.0-.*a|a\d+(\.\d+)?b)", name))


def build_stage_a_grid(tier: str, moe: bool, quick: bool = False) -> list[Cell]:
    """Pruned Stage-A launch grid (<= STAGE_A_MAX_CELLS, not exhaustive).

    GPU tiers: ngl=999, fa=on, threads=8 fixed; sweep cache q8_0/f16 x batch
    pairs x cpu-moe (MoE models only). CPU: ngl=0, no-mmap, small batch; sweep
    threads. --quick collapses each axis to its single most-likely-best value.
    """
    if tier == "cpu":
        threads = [8] if quick else [4, 8, 16]
        return [
            Cell(name=f"cpu-t{t}", ngl=0, threads=t, batch=512, ubatch=256,
                 no_mmap=True)
            for t in threads
        ]
    caches = ["q8_0"] if quick else ["q8_0", "f16"]
    batches = [(2048, 512)] if quick else [(2048, 512), (8192, 4096)]
    moes = ([True] if quick else [True, False]) if moe else [False]
    cells: list[Cell] = []
    for cm in moes:
        for ct in caches:
            for b, ub in batches:
                name = f"gpu-ngl999{'-cpumoe' if cm else ''}-{ct}-b{b}"
                cells.append(Cell(name=name, ngl=999, cpu_moe=cm, cache_type=ct,
                                  flash_attn=True, batch=b, ubatch=ub, threads=8))
    assert len(cells) <= STAGE_A_MAX_CELLS
    return cells


def oom_fallback_grid(cells: list[Cell], mid_ngl: int = OOM_FALLBACK_NGL) -> list[Cell]:
    """Mid-ngl retry cells when every full-offload cell OOMed.

    Keeps the sweep time-boxed: only the q8_0-cache cells (smallest KV) are
    retried at the mid offload, capped at 2.
    """
    picked = [c for c in cells if c.cache_type == "q8_0"][:2] or cells[:2]
    return [
        replace(c, ngl=mid_ngl, name=c.name.replace("ngl999", f"ngl{mid_ngl}"))
        for c in picked
    ]


def pareto_pick(results: list[dict], tier: str,
                budgets: dict[str, int] = TIER_BUDGETS_MIB) -> Optional[dict]:
    """Pick the best Stage-A cell: max decode tok/s subject to the tier budget.

    A cell is eligible when it ran OK and fits the budget: GPU tiers require
    vram_delta_mib <= budget; the cpu tier requires ngl == 0 (no VRAM at all).
    Ties break on lower TTFT, then earlier cell order. None when nothing fits.
    """
    budget = budgets[tier]
    eligible: list[tuple[int, dict]] = []
    for i, r in enumerate(results):
        if not r.get("ok"):
            continue
        if tier == "cpu":
            if (r.get("cell") or {}).get("ngl", 0) != 0:
                continue
        else:
            used = r.get("vram_delta_mib")
            if used is None or used > budget:
                continue
        eligible.append((i, r))
    if not eligible:
        return None

    def key(pair: tuple[int, dict]):
        i, r = pair
        ttft = r.get("ttft_ms")
        return (-(r.get("decode_toks_s") or 0.0),
                ttft if ttft is not None else float("inf"), i)

    return min(eligible, key=key)[1]


def compute_ctx_probe(vram_lo_mib: float, vram_hi_mib: float,
                      ctx_lo: int = CTX_PROBE_LO, ctx_hi: int = CTX_PROBE_HI,
                      budgets: dict[str, int] = TIER_BUDGETS_MIB,
                      native_ctx: Optional[int] = None) -> dict:
    """Two-point linear KV extrapolation → per-tier maximum context.

    Given VRAM measurements (delta vs baseline, MiB) of the SAME launch config
    at two ctx values:
      slope = (vram_hi - vram_lo) / (ctx_hi - ctx_lo)        [MiB per token]
      weights_vram ≈ vram_lo - slope * ctx_lo                 [model weights]
      ctx_max(tier) = floor((budget - weights_vram) / slope), clamped to ≥0

    ``native_ctx`` (the model's trained context, when known) additionally
    reports ``ctx_max_native_cap = min(ctx_max, native_ctx)`` per tier.
    A non-positive slope means the two measurements did not order as KV
    growth requires → note 'slope unmeasurable', no extrapolation.
    """
    result: dict = {
        "vram_lo_mib": vram_lo_mib,
        "vram_hi_mib": vram_hi_mib,
    }
    slope = (vram_hi_mib - vram_lo_mib) / float(ctx_hi - ctx_lo)
    result["slope_mib_per_1k_tokens"] = round(slope * 1000.0, 3)
    if slope <= 0:
        result["note"] = CTX_PROBE_NOTE_SLOPE
        result["ctx_max"] = {}
        return result
    weights = vram_lo_mib - slope * ctx_lo
    result["weights_vram_mib"] = round(weights, 1)
    ctx_max: dict[str, int] = {}
    for tier, budget in budgets.items():
        if budget <= 0:  # cpu tier: no VRAM budget, nothing to extrapolate
            continue
        ctx_max[tier] = max(0, math.floor((budget - weights) / slope))
    result["ctx_max"] = ctx_max
    if native_ctx is not None:
        result["ctx_max_native_cap"] = {
            t: min(v, int(native_ctx)) for t, v in ctx_max.items()
        }
    return result


# ── Stage B (quality tune) pure helpers ──────────────────────────────────────

def select_fast_subset(cases: list, n: int = FAST_SUBSET_SIZE,
                       stride: int = FAST_SUBSET_STRIDE) -> list:
    """Deterministic discriminative subset: every ``stride``-th case, cap ``n``.

    When the strided pick yields fewer than ``n`` (small sets), fill with the
    earliest unpicked cases. Same input list → same subset, always.
    """
    idxs = list(range(0, len(cases), stride))[:n]
    for i in range(len(cases)):
        if len(idxs) >= n:
            break
        if i not in idxs:
            idxs.append(i)
    return [cases[i] for i in sorted(idxs[:n])]


def parse_thinking_modes(raw: str) -> list[str]:
    """Validate --thinking-modes: comma list from VALID_THINKING_MODES."""
    modes = [m.strip() for m in raw.split(",") if m.strip()]
    bad = [m for m in modes if m not in VALID_THINKING_MODES]
    if bad:
        raise ValueError(f"unknown thinking mode(s): {bad} — valid: {list(VALID_THINKING_MODES)}")
    return modes or ["none"]


def build_stage_b_variants(card_sampling: Optional[dict],
                           thinking_modes: list[str],
                           max_variants: int = STAGE_B_MAX_VARIANTS) -> list[dict]:
    """Sampling presets x thinking modes, deduped and capped at 6.

    Sampling presets: the model-card default (--sampling JSON / recipe seed)
    when provided and different from ours, plus the house default. Card preset
    goes first so ties resolve in favour of the model author's recommendation.
    """
    samplings: list[tuple[str, dict]] = []
    if card_sampling and card_sampling != HOUSE_SAMPLING:
        samplings.append(("card", dict(card_sampling)))
    samplings.append(("house", dict(HOUSE_SAMPLING)))
    variants = [
        {"name": f"{s_name}-think_{mode}", "sampling": s, "thinking": mode}
        for s_name, s in samplings
        for mode in (thinking_modes or ["none"])
    ]
    return variants[:max_variants]


def thinking_server_flags(mode: str) -> list[str]:
    """Extra llama-server flags a thinking mode needs (budget → launch flag)."""
    if mode == "budget512":
        return ["--reasoning-budget", "512"]
    return []


def thinking_request_kwargs(mode: str) -> dict:
    """Request-level chat_template_kwargs for a thinking mode ('none' = template default)."""
    if mode == "off":
        return {"chat_template_kwargs": {"enable_thinking": False}}
    if mode in ("on", "budget512"):
        return {"chat_template_kwargs": {"enable_thinking": True}}
    return {}


# ── recipe registry (results/model_recipes.json) ─────────────────────────────

def load_recipes(path: Path) -> dict:
    """{label: {tier: recipe}} — empty dict when the file is missing/invalid."""
    p = Path(path)
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except json.JSONDecodeError:
        return {}


def save_recipe(path: Path, label: str, tier: str, recipe: dict) -> dict:
    """Upsert one label+tier recipe; other labels/tiers are preserved."""
    recipes = load_recipes(path)
    recipes.setdefault(label, {})[tier] = recipe
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(recipes, ensure_ascii=False, indent=2) + "\n",
                          encoding="utf-8")
    return recipes


def get_recipe(recipes: dict, label: str, tier: str) -> Optional[dict]:
    return (recipes.get(label) or {}).get(tier)


def make_recipe(winner: dict, variant: dict, ctx: int,
                now: Optional[str] = None) -> dict:
    """Assemble the peak recipe from the Stage-A winner + Stage-B variant."""
    cell = winner.get("cell") or {}
    launch_cell = cell_from_dict(cell)
    return {
        "launch": {
            "ngl": launch_cell.ngl,
            "cpu_moe": launch_cell.cpu_moe,
            "ctx": ctx,
            "cell_name": launch_cell.name,
            "extra_flags": launch_cell.to_extra_flags(),
        },
        "sampling": dict(variant.get("sampling") or HOUSE_SAMPLING),
        "thinking": variant.get("thinking", "none"),
        "scores": {
            "stage_a_decode_toks_s": winner.get("decode_toks_s"),
            "stage_a_ttft_ms": winner.get("ttft_ms"),
            "stage_a_vram_delta_mib": winner.get("vram_delta_mib"),
            "stage_b_det": variant.get("det"),
        },
        "timestamp_utc": now or datetime.now(timezone.utc).isoformat(),
    }


# ── scorers (toolcall / vision / codereview / embed) ─────────────────────────

def _norm(text: str) -> str:
    """Lowercase + strip accents so 'inyección' matches 'inyeccion'."""
    decomposed = unicodedata.normalize("NFD", str(text).lower())
    return "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")


def _contains(text: str, needle: str) -> bool:
    return _norm(needle) in _norm(text)


def score_toolcall_case(case: dict, message: Optional[dict]) -> dict:
    """Score one tool-calling response message against a golden case.

    expect.tool == null → the model must NOT call (false-call trap).
    expect.tool == name → first tool_call must match the name and every
    arg_substrings entry must appear (accent/case-insensitive) in the arg value.
    """
    expect = case.get("expect") or {}
    expected_tool = expect.get("tool")
    tool_calls = (message or {}).get("tool_calls") or []

    if expected_tool is None:
        false_call = bool(tool_calls)
        return {"id": case.get("id"), "expected_call": False,
                "correct_tool": not false_call, "args_ok": None,
                "false_call": false_call, "passed": not false_call}

    if not tool_calls:
        return {"id": case.get("id"), "expected_call": True,
                "correct_tool": False, "args_ok": False,
                "false_call": False, "passed": False}

    fn = (tool_calls[0] or {}).get("function") or {}
    name_ok = fn.get("name") == expected_tool
    raw_args = fn.get("arguments") or "{}"
    try:
        args = json.loads(raw_args) if isinstance(raw_args, str) else dict(raw_args)
    except (json.JSONDecodeError, TypeError):
        args = {}
    args_ok = all(
        all(_contains(str(args.get(arg, "")), sub) for sub in subs)
        for arg, subs in (expect.get("arg_substrings") or {}).items()
    )
    return {"id": case.get("id"), "expected_call": True,
            "correct_tool": name_ok, "args_ok": args_ok,
            "false_call": False, "passed": name_ok and args_ok}


def aggregate_toolcall(per_case: list[dict]) -> dict:
    """correct-tool rate, arg accuracy, false-call rate, overall pass score."""
    call_cases = [r for r in per_case if r.get("expected_call")]
    nocall_cases = [r for r in per_case if not r.get("expected_call")]
    correct = [r for r in call_cases if r.get("correct_tool")]

    def rate(hits: int, total: int) -> float:
        return round(hits / total, 4) if total else 0.0

    return {
        "n": len(per_case),
        "correct_tool_rate": rate(len(correct), len(call_cases)),
        "arg_accuracy": rate(sum(1 for r in correct if r.get("args_ok")),
                             len(call_cases)),
        "false_call_rate": rate(sum(1 for r in nocall_cases if r.get("false_call")),
                                len(nocall_cases)),
        "score": rate(sum(1 for r in per_case if r.get("passed")), len(per_case)),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


def score_vision_case(case: dict, response_text: str) -> dict:
    """Every must_contain group needs >=1 alternative present in the answer."""
    missing = [group for group in (case.get("must_contain") or [])
               if not any(_contains(response_text, alt) for alt in group)]
    return {"id": case.get("id"), "passed": not missing, "missing": missing}


def score_codereview_case(case: dict, response_text: str) -> dict:
    """Buggy: all must_contain groups hit. Clean: 'SIN BUGS' or no planted keyword."""
    if case.get("clean"):
        claims_clean = _contains(response_text, CLEAN_OK_TOKEN)
        hits = [kw for kw in (case.get("must_not_contain") or [])
                if _contains(response_text, kw)]
        passed = claims_clean or not hits
        return {"id": case.get("id"), "clean": True, "passed": passed,
                "false_positive": not passed, "keyword_hits": hits}
    missing = [group for group in (case.get("must_contain") or [])
               if not any(_contains(response_text, alt) for alt in group)]
    return {"id": case.get("id"), "clean": False, "passed": not missing,
            "false_positive": False, "missing": missing}


def aggregate_codereview(per_case: list[dict]) -> dict:
    buggy = [r for r in per_case if not r.get("clean")]
    clean = [r for r in per_case if r.get("clean")]

    def rate(hits: int, total: int) -> float:
        return round(hits / total, 4) if total else 0.0

    return {
        "n": len(per_case),
        "detection_rate": rate(sum(1 for r in buggy if r["passed"]), len(buggy)),
        "false_positive_rate": rate(sum(1 for r in clean if r["false_positive"]),
                                    len(clean)),
        "score": rate(sum(1 for r in per_case if r["passed"]), len(per_case)),
        "failed_ids": [r.get("id") for r in per_case if not r["passed"]],
    }


def aggregate_pass_rate(per_case: list[dict]) -> dict:
    """Generic pass-rate aggregate (vision role)."""
    n = len(per_case)
    passed = sum(1 for r in per_case if r.get("passed"))
    return {"n": n, "pass_rate": round(passed / n, 4) if n else 0.0,
            "failed_ids": [r.get("id") for r in per_case if not r.get("passed")]}


def cosine(a: list[float], b: list[float]) -> float:
    """Plain-python cosine similarity (no numpy dependency needed)."""
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


# ── codegen role pure helpers (extraction / harness / scoring) ───────────────

CODEGEN_PASS_SENTINEL = "__CODEGEN_PASS__"

CODEGEN_SYSTEM = (
    "Eres un ingeniero de software senior escribiendo código Python para LifeOS. "
    "Implementa EXACTAMENTE la función pedida, en Python puro, sin dependencias "
    "externas ni entrada/salida. Maneja los casos borde indicados. Responde "
    "ÚNICAMENTE con un bloque ```python``` que contenga el código completo, "
    "sin explicaciones."
)

_CODE_FENCE_RE = re.compile(r"```([A-Za-z0-9_+-]*)[ \t]*\n(.*?)```", re.DOTALL)


def extract_code_block(text: str) -> str:
    """Pull the model's code out of its reply.

    Preference order: all ```python fenced blocks (joined — models often split
    the function and a demo), else the first fenced block of any language, else
    the raw text. <think> blocks are stripped first.
    """
    cleaned = re.sub(r"<think>.*?</think>", "", text or "", flags=re.DOTALL)
    blocks = _CODE_FENCE_RE.findall(cleaned)
    python_blocks = [body for lang, body in blocks
                     if lang.lower() in ("python", "py", "python3")]
    if python_blocks:
        return "\n\n".join(b.strip() for b in python_blocks).strip()
    if blocks:
        return blocks[0][1].strip()
    return cleaned.strip()


def code_compiles(code: str) -> bool:
    """Does the extracted code at least parse as Python? (compile rate metric)"""
    import ast
    try:
        ast.parse(code)
        return True
    except SyntaxError:
        return False


def build_codegen_harness(case: dict, code: str) -> str:
    """Model code + injected asserts → one self-contained ``python -c`` script.

    The case's tests travel as embedded JSON (repr-quoted, so arbitrary args /
    expected values survive). Prints CODEGEN_PASS_SENTINEL only when every
    assert holds; any failure exits non-zero via the raised AssertionError.
    """
    tests_json = json.dumps(case.get("tests") or [], ensure_ascii=False)
    fn = case["function_name"]
    return (
        f"{code}\n\n"
        "import json as _json\n"
        f"_tests = _json.loads({tests_json!r})\n"
        "for _i, _t in enumerate(_tests):\n"
        f"    _got = {fn}(*_t.get('args', []), **(_t.get('kwargs') or {{}}))\n"
        "    _exp = _t['expected']\n"
        "    assert _got == _exp, f'test {_i}: got {_got!r}, expected {_exp!r}'\n"
        f"print({CODEGEN_PASS_SENTINEL!r})\n"
    )


def execute_codegen_harness(harness: str, timeout_s: float,
                            python_bin: str = sys.executable) -> dict:
    """Run the harness in an ISOLATED subprocess (never exec() in-process).

    Sandboxing: ``python -I`` (isolated mode: no user site, env python vars
    ignored), a minimal env, cwd = throwaway temp dir, own session/process
    group (start_new_session), hard timeout with a process-GROUP kill so
    forked/spun-off children die too. Local-model code is untrusted-ish.
    """
    with tempfile.TemporaryDirectory(prefix="axi-codegen-") as tmp:
        env = {"PATH": "/usr/bin:/bin", "HOME": tmp,
               "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8"}
        proc = subprocess.Popen(
            [python_bin, "-I", "-c", harness], cwd=tmp, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, text=True)
        try:
            out, err = proc.communicate(timeout=timeout_s)
            return {"returncode": proc.returncode, "stdout": out or "",
                    "stderr": err or "", "timed_out": False}
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                proc.kill()
            proc.wait(timeout=5)
            return {"returncode": None, "stdout": "", "stderr": "",
                    "timed_out": True}


def score_codegen_case(case: dict, code: str,
                       exec_result: Optional[dict]) -> dict:
    """Pure scorer on a canned subprocess result (pass = all asserts held)."""
    compiled = bool(code) and code_compiles(code)
    if not compiled:
        return {"id": case.get("id"), "compiled": False, "passed": False,
                "error": "no code / does not parse"}
    r = exec_result or {}
    if r.get("timed_out"):
        return {"id": case.get("id"), "compiled": True, "passed": False,
                "error": f"timeout after {case.get('timeout_s')}s (killed)"}
    passed = (r.get("returncode") == 0
              and CODEGEN_PASS_SENTINEL in (r.get("stdout") or ""))
    return {"id": case.get("id"), "compiled": True, "passed": passed,
            "error": None if passed
            else ((r.get("stderr") or "").strip()[-300:] or "tests failed")}


def aggregate_codegen(per_case: list[dict]) -> dict:
    n = len(per_case)

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    return {
        "n": n,
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed"))),
        "compile_rate": rate(sum(1 for r in per_case if r.get("compiled"))),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


# ── conversation role pure helpers (rubric judge prompt + det checks) ────────

CONVERSATION_MAX_CHARS = 1500  # warm-but-concise: past this a reply is a lecture


def _conversation_transcript(messages: list[dict]) -> str:
    return "\n".join(f"[{m.get('role', 'user')}] {m.get('content', '')}"
                     for m in messages or [])


def build_conversation_judge_prompt(case: dict, response: str) -> str:
    """Judge prompt built from the CASE'S OWN rubric (criteria have
    name/weight/description — a different shape than brain_quality's, so we
    mirror subjective_judge._build_judge_prompt instead of calling it)."""
    criteria = (case.get("rubric") or {}).get("criteria") or []
    lines: list[str] = []
    keys: list[str] = []
    for idx, c in enumerate(criteria):
        key = f"c{idx + 1}"
        keys.append(key)
        lines.append(f'  "{key}" — {c.get("name", key)} '
                     f'(weight={c.get("weight", 1.0)}): {c.get("description", "")}')
    criteria_block = "\n".join(lines)
    keys_str = ", ".join(f'"{k}": 0.0..1.0' for k in keys)
    return f"""\
Evaluá la calidad conversacional de la ÚLTIMA respuesta del asistente,
considerando toda la conversación previa.

=== CONVERSACIÓN ===
{_conversation_transcript(case.get("messages") or [])}

=== RESPUESTA DEL CANDIDATO ===
{response}

=== RUBRIC ===
Criterios a evaluar (puntuá cada uno entre 0.0 y 1.0):
{criteria_block}

Devolvé SOLO este JSON (sin markdown, sin texto adicional):
{{{keys_str}, "note": "observación breve en ≤15 palabras"}}"""


def weighted_rubric_score(criteria: list[dict], parsed: dict) -> float:
    """Weighted 0-1 score from judge JSON keys c1..cN (clamped, missing = 0)."""
    weighted = 0.0
    total = 0.0
    for idx, c in enumerate(criteria):
        try:
            score = float(parsed.get(f"c{idx + 1}", 0.0))
        except (TypeError, ValueError):
            score = 0.0
        score = max(0.0, min(1.0, score))
        weight = c.get("weight", 1.0)
        weighted += score * weight
        total += weight
    return round(weighted / total, 4) if total > 0 else 0.0


def check_conversation_deterministic(response: str,
                                     max_chars: int = CONVERSATION_MAX_CHARS) -> dict:
    """Judge-free checks: reply is Spanish; non-empty, non-error, sane length."""
    import cpu_sweep
    text = (response or "").strip()
    sane = bool(text) and not text.startswith("__ERROR__") and len(text) <= max_chars
    return {"spanish": bool(text) and cpu_sweep.is_spanish(text), "sane": sane}


def aggregate_conversation(per_case: list[dict],
                           note: Optional[str] = None) -> dict:
    """{n, judge_score (weighted mean, None when judge skipped), spanish_rate}."""
    n = len(per_case)
    judged = [r["judge_score"] for r in per_case
              if r.get("judge_score") is not None]

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    out = {
        "n": n,
        "judge_score": round(sum(judged) / len(judged), 4) if judged else None,
        "spanish_rate": rate(sum(1 for r in per_case if r.get("spanish"))),
        "sane_rate": rate(sum(1 for r in per_case if r.get("sane"))),
        "failed_ids": [r.get("id") for r in per_case
                       if not (r.get("spanish") and r.get("sane"))],
    }
    if note:
        out["note"] = note
    return out


# ── shared numeric-fidelity helpers (recordsqa / narration / longsum) ────────

_NUM_TOKEN_RE = re.compile(r"\d+(?:[.,]\d+)*")

FABRICATION_TRIVIAL_MAX = 10


def number_tokens(text: str) -> list[str]:
    """All numeric tokens in ``text`` ('118', '7.5', '1,200', date parts)."""
    return _NUM_TOKEN_RE.findall(text or "")


def _canon_num(tok: str) -> str:
    """Canonical number form: drop es-MX thousands commas ('1,200' → '1200'),
    strip leading zeros on pure integers ('05' → '5'). Decimals keep their
    period ('83.5' stays '83.5' — never collides with '835')."""
    c = tok.replace(",", "")
    if c.isdigit():
        return str(int(c))
    return c


def fabricated_numbers(reply: str, source: str) -> list[str]:
    """Numeric tokens in ``reply`` that do NOT appear in ``source``.

    Tolerance rules (the anti-fabrication contract):
      - membership is canonical: '1,200' == '1200', '05' == '5';
      - bare integers 0..FABRICATION_TRIVIAL_MAX (10) are always allowed
        (counting words: 'los 2 registros', '3 frases');
      - anything the source itself mentions is allowed — for recordsqa the
        source is records_block + question, so years named in the question
        ('¿...en 2025?') never count as fabricated.
    Every other number in the reply is a fabrication.
    """
    allowed = {_canon_num(t) for t in number_tokens(source)}
    fabricated: list[str] = []
    for tok in number_tokens(reply):
        c = _canon_num(tok)
        if c in allowed:
            continue
        if c.isdigit() and int(c) <= FABRICATION_TRIVIAL_MAX:
            continue
        fabricated.append(tok)
    return fabricated


# ── recordsqa role pure helpers (grounded personal-records QA) ───────────────

RECORDSQA_REFUSAL_MARKERS = (
    "no tengo", "no hay", "no aparece", "no encuentro", "no existe",
    "sin registro", "no cuento con", "no esta registrado", "no se registro",
)


def build_recordsqa_system(case: dict) -> str:
    """Mirror domain_chat._build_query_system (records-only, no graph block)."""
    domain = case.get("domain", "salud")
    upper = domain.upper()
    today = case.get("today", "")
    year = today[:4]
    return (
        f"Eres el asistente del chat de {upper} de Axi. Respondes en español, claro y breve.\n"
        f"HOY es {today} (año {year}). Usa esta fecha para resolver toda "
        "referencia temporal relativa: 'diciembre' significa el diciembre MÁS RECIENTE "
        "anterior o igual a hoy; 'el mes pasado', 'la semana pasada', etc. se resuelven "
        "siempre contra HOY.\n\n"
        f"Responde ÚNICAMENTE con base en los siguientes registros de {domain} del usuario. "
        "NO inventes datos. Si la información pedida NO está en los registros ni en la "
        "memoria del grafo, di claramente que no tienes ese registro.\n"
        "REGLAS ABSOLUTAS SOBRE FECHAS Y VALORES:\n"
        "- Usa EXACTAMENTE la fecha que aparece en cada registro. JAMÁS inventes "
        "ni infieras una fecha distinta. Si varios registros comparten la misma "
        "fecha, NO los repartas en días distintos.\n"
        "- Copia los valores TAL CUAL (no cambies un 83 por 85). No estimes.\n"
        "- Para preguntas de TENDENCIA o '¿cómo va/cómo se ha comportado X?': "
        "responde BREVE (2-3 frases) con la tendencia general (estable/sube/baja, "
        "rango aproximado) y el valor MÁS RECIENTE con su fecha. NO enumeres cada "
        "registro uno por uno.\n\n"
        f"REGISTROS DE {upper} (más recientes primero):\n{case.get('records_block', '')}"
    )


def score_recordsqa_case(case: dict, reply: str) -> dict:
    """must_contain any-of groups + fabricated-number detector + refusal check."""
    expected = case.get("expected") or {}
    text = reply or ""
    missing = [group for group in (expected.get("must_contain") or [])
               if not any(_contains(text, alt) for alt in group)]
    fabricated: list[str] = []
    if expected.get("must_not_contain_numbers_absent_from_records"):
        source = f"{case.get('records_block', '')}\n{case.get('question', '')}"
        fabricated = fabricated_numbers(text, source)
    refusal_ok = True
    if expected.get("refusal_expected"):
        refusal_ok = any(_contains(text, m) for m in RECORDSQA_REFUSAL_MARKERS)
    return {"id": case.get("id"),
            "passed": not missing and not fabricated and refusal_ok,
            "missing": missing, "fabricated": fabricated,
            "refusal_ok": refusal_ok}


def aggregate_recordsqa(per_case: list[dict]) -> dict:
    n = len(per_case)

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    return {
        "n": n,
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed"))),
        "fabrication_rate": rate(sum(1 for r in per_case if r.get("fabricated"))),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


# ── narration role pure helpers (digest narration, numeric fidelity) ─────────

# Mirror of dashboard._DIGEST_NARRATOR_SYSTEM (the production digest narrator).
NARRATION_SYSTEM = (
    "Eres Axi. Vas a narrar el resumen del día del usuario. La entrada es una "
    "lista de HECHOS ya calculados (secciones con conteos, números y valores "
    "exactos). Escribe de 4 a 6 frases cálidas y concisas en español que "
    "conecten los puntos del día.\n"
    "REGLAS ABSOLUTAS:\n"
    "- Copia cada número, monto, fecha y valor EXACTAMENTE como aparece en los hechos.\n"
    "- NUNCA agregues datos, fechas, correlaciones ni conclusiones que no estén en los hechos.\n"
    "- No inventes causas: si dos hechos no aparecen conectados, no los conectes.\n"
    "- Si una sección no aparece o está vacía, NO la menciones.\n"
    "- Sin listas ni encabezados: solo texto corrido de 4 a 6 frases."
)

_SENT_SPLIT_RE = re.compile(r"[.!?…]+(?:\s+|$)")


def count_sentences(text: str) -> int:
    """Sentence count via terminal punctuation followed by space/end — decimals
    ('7.5') and times inside a sentence never split."""
    return len([s for s in _SENT_SPLIT_RE.split((text or "").strip())
                if s.strip()])


def score_narration_case(case: dict, reply: str) -> dict:
    """Numeric fidelity (every facts number present, none fabricated) +
    structure (sentence count within bounds, Spanish)."""
    import cpu_sweep
    facts = case.get("facts_text", "")
    text = reply or ""
    reply_nums = {_canon_num(t) for t in number_tokens(text)}
    missing_numbers = sorted({t for t in number_tokens(facts)
                              if _canon_num(t) not in reply_nums})
    fabricated = fabricated_numbers(text, facts)
    numeric_fidelity = not missing_numbers and not fabricated
    cons = case.get("constraints") or {}
    n_sent = count_sentences(text)
    sentences_ok = (cons.get("min_sentences", 1) <= n_sent
                    <= cons.get("max_sentences", 99))
    spanish = bool(text.strip()) and cpu_sweep.is_spanish(text)
    return {"id": case.get("id"), "numeric_fidelity": numeric_fidelity,
            "structure": sentences_ok and spanish,
            "missing_numbers": missing_numbers, "fabricated": fabricated,
            "sentences": n_sent, "spanish": spanish,
            "passed": numeric_fidelity and sentences_ok and spanish,
            "judge_score": None}


def narration_judge_case(case: dict) -> dict:
    """Adapt a narration case to the conversation rubric-judge helpers."""
    return {"messages": [{"role": "user",
                          "content": "HECHOS DEL DÍA:\n" + case.get("facts_text", "")}],
            "rubric": case.get("rubric")}


def aggregate_narration(per_case: list[dict], note: Optional[str] = None) -> dict:
    n = len(per_case)
    judged = [r["judge_score"] for r in per_case
              if r.get("judge_score") is not None]

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    out = {
        "n": n,
        "numeric_fidelity_rate": rate(sum(1 for r in per_case
                                          if r.get("numeric_fidelity"))),
        "structure_rate": rate(sum(1 for r in per_case if r.get("structure"))),
        "judge_score": round(sum(judged) / len(judged), 4) if judged else None,
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }
    if note:
        out["note"] = note
    return out


# ── longsum role pure helpers (long-context summarization) ───────────────────

LONGSUM_WINDOW_MINUTES = 15  # mirrors config default meeting_window_minutes

# Mirror of meeting.py's mandated executive-report section headers.
LONGSUM_EXECUTIVE_SECTIONS = (
    "## Participantes", "## Contexto y propósito",
    "## Necesidades / pain points del cliente", "## Temas tratados",
    "## Decisiones tomadas", "## Action items", "## Objeciones y riesgos",
    "## Cifras y plazos mencionados", "## Próximos pasos",
    "## Observaciones del consultor",
)

# Mirror of chat_archive._SUMMARY_SYSTEM.
LONGSUM_CHAT_ARCHIVE_SYSTEM = (
    "Resumí esta tanda de conversación entre Héctor y su asistente Axi en un "
    "párrafo compacto (máximo 8 líneas), en español. CONSERVÁ los hechos y "
    "decisiones importantes (nombres propios, fechas, datos personales, temas "
    "tratados, acuerdos). NO inventes nada que no esté en el texto. Es un "
    "resumen para la memoria de largo plazo de Axi."
)

LONGSUM_CTX_CHARS_PER_TOKEN = 3  # safe chars-per-token heuristic for the skip


def longsum_case_fits_ctx(prompt_chars: int, ctx: int) -> bool:
    """Skip heuristic: a prompt longer than ctx*3 chars cannot safely fit."""
    return prompt_chars <= ctx * LONGSUM_CTX_CHARS_PER_TOKEN


def build_longsum_prompt(case: dict) -> tuple[Optional[str], str]:
    """(system, user) mirroring the production prompt for the case's kind:
    meeting.py's window pass, meeting.py's executive pass, or
    chat_archive's archive summary."""
    kind = case.get("kind")
    transcript = case.get("transcript", "")
    wm = LONGSUM_WINDOW_MINUTES
    if kind == "meeting_window":
        user = (
            f"Eres un asistente que toma notas para reuniones de negocios y ventas. "
            f"Analiza estos {wm} minutos. "
            f"`[mic]` = Héctor (asistente/dueño). `[system]` = cliente/prospecto u otros participantes.\n\n"
            f"Produce notas en bullets concretos. Captura SIEMPRE:\n"
            f"- Pain points, necesidades o problemas mencionados\n"
            f"- Cifras, fechas, presupuestos, plazos (también los visibles en pantalla)\n"
            f"- Compromisos asumidos por cualquier parte\n"
            f"- Objeciones del cliente\n"
            f"- Preguntas sin responder\n"
            f"- Decisiones tomadas\n\n"
            f"NO inventes datos. Si una ventana solo tiene saludos o setup técnico, di 'solo logística/setup'. "
            f"Si hay silencios o contenido irrelevante, ignóralos.\n\n"
            f"Transcripción:\n{transcript}"
        )
        return None, user
    if kind == "executive":
        sections = "\n\n".join(
            f"{h}\n..." for h in (case.get("required_sections")
                                  or LONGSUM_EXECUTIVE_SECTIONS))
        user = (
            "Eres un consultor senior que escribe el reporte ejecutivo de una reunión "
            "de negocios con un cliente o prospecto.\n\n"
            "A continuación tienes notas por ventanas de "
            f"{wm} minutos:\n\n{transcript}\n\n"
            "Escribe el REPORTE EJECUTIVO en español mexicano, formato Markdown, "
            "con EXACTAMENTE estas secciones (en este orden). Si una sección no "
            "aplica, escribe `—` y nada más. NO inventes información: si no está "
            "en las notas, no la incluyas.\n\n"
            f"{sections}\n"
        )
        return None, user
    # chat_archive: system prompt + raw transcript as the user message.
    return LONGSUM_CHAT_ARCHIVE_SYSTEM, transcript


def score_longsum_case(case: dict, reply: str) -> dict:
    """Planted-atom recall + executive section structure + fabricated numbers."""
    text = reply or ""
    atoms = case.get("planted_atoms") or []
    missing_atoms = [a.get("label") for a in atoms
                     if not any(_contains(text, alt)
                                for alt in (a.get("must_contain_any") or []))]
    atom_recall = (round((len(atoms) - len(missing_atoms)) / len(atoms), 4)
                   if atoms else 1.0)
    missing_sections = [sec for sec in (case.get("required_sections") or [])
                        if not _contains(text, sec)]
    fabricated = fabricated_numbers(text, case.get("transcript", ""))
    structure_ok = not missing_sections
    return {"id": case.get("id"), "kind": case.get("kind"),
            "atom_recall": atom_recall, "missing_atoms": missing_atoms,
            "structure_ok": structure_ok, "missing_sections": missing_sections,
            "fabricated": fabricated,
            "passed": not missing_atoms and structure_ok and not fabricated}


def aggregate_longsum(per_case: list[dict],
                      skipped_ids: Optional[list] = None,
                      note: Optional[str] = None) -> dict:
    n = len(per_case)

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    out = {
        "n": n,
        "atom_recall": (round(sum(r.get("atom_recall", 0.0) for r in per_case) / n, 4)
                        if n else 0.0),
        "structure_rate": rate(sum(1 for r in per_case if r.get("structure_ok"))),
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed"))),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }
    if skipped_ids:
        out["skipped_ids"] = list(skipped_ids)
    if note:
        out["note"] = note
    return out


# ── parsejson role pure helpers (strict structured-parsing fallbacks) ────────

# Mirror of intents._KNOWN_INTENTS (scan order matters — production returns
# the FIRST known label found in the model's reply).
VOICE_INTENT_LABELS = (
    "dictation", "meeting_start", "meeting_stop", "open_dashboard",
    "translate_on", "translate_off", "game_on", "game_off",
    "clear_conversation", "dev_develop",
)

PARSEJSON_SCHEDULE_KEYS = ("is_reminder", "kind", "recurring", "cron",
                           "when_iso", "content")

_MODEL_JSON_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


def parse_model_json(text: str) -> Optional[dict]:
    """Recover a JSON object from a model reply — mirrors the production
    tolerance (extractor._parse_json_strict / reminder_brain fence strip):
    markdown fences, leading prose before '{', trailing junk after '}'."""
    if not text:
        return None
    m = _MODEL_JSON_FENCE_RE.search(text)
    if m:
        text = m.group(1)
    if not text.lstrip().startswith("{"):
        idx = text.find("{")
        if idx == -1:
            return None
        text = text[idx:]
    try:
        data = json.loads(text)
        return data if isinstance(data, dict) else None
    except json.JSONDecodeError:
        last = text.rfind("}")
        if last != -1:
            try:
                data = json.loads(text[: last + 1])
                return data if isinstance(data, dict) else None
            except json.JSONDecodeError:
                return None
        return None


def _iso_parses(value) -> bool:
    if not isinstance(value, str):
        return False
    try:
        datetime.fromisoformat(value)
        return True
    except ValueError:
        return False


def score_parsejson_case(case: dict, reply: str) -> dict:
    """Score one structured-parsing case against its production contract."""
    kind = case.get("kind")
    expected = case.get("expected") or {}
    text = reply or ""
    json_valid: Optional[bool] = None
    passed = False

    if kind == "when":
        data = parse_model_json(text)
        json_valid = data is not None and "when_iso" in data
        if json_valid:
            val = data.get("when_iso")
            if expected.get("null_expected"):
                passed = val is None
            else:
                prefix = expected.get("iso_prefix")
                passed = _iso_parses(val) and \
                    (not prefix or str(val).startswith(prefix))
    elif kind == "schedule":
        data = parse_model_json(text)
        json_valid = data is not None
        if json_valid:
            exact = expected.get("exact") or {}
            if not exact.get("is_reminder", True):
                # Negative: production only checks data.get("is_reminder").
                passed = not data.get("is_reminder")
            else:
                ok = all(data.get(k) == v for k, v in exact.items())
                prefix = expected.get("when_iso_prefix")
                if prefix:
                    val = data.get("when_iso")
                    ok = ok and _iso_parses(val) and str(val).startswith(prefix)
                content = str(data.get("content") or "")
                ok = ok and all(_contains(content, sub)
                                for sub in expected.get("content_contains") or [])
                passed = ok
    elif kind == "voice_intent":
        lower = text.strip().lower()
        found = next((lab for lab in VOICE_INTENT_LABELS if lab in lower), None)
        passed = found == expected.get("label")
    elif kind == "graph_facts":
        data = parse_model_json(text)
        json_valid = data is not None and isinstance(data.get("facts"), list)
        if json_valid:
            facts = data["facts"]
            if expected.get("facts_empty"):
                passed = facts == []
            else:
                labels = " || ".join(str((f or {}).get("label", ""))
                                     for f in facts if isinstance(f, dict))
                groups = expected.get("fact_label_substrings") or []
                passed = bool(facts) and all(
                    any(_contains(labels, alt) for alt in group)
                    for group in groups)
    elif kind == "coreference":
        # Mirror identity._llm_same_entity's yes-detection exactly.
        is_yes = (text or "").strip().lower()[:2] in ("si", "sí", "s.", "ye")
        passed = is_yes == (expected.get("label") == "si")

    return {"id": case.get("id"), "kind": kind,
            "negative": bool(case.get("negative")),
            "json_valid": json_valid, "passed": passed}


def aggregate_parsejson(per_case: list[dict]) -> dict:
    """Metrics with negatives weighted: a failed negative case (the over-eager
    failure mode) appears TWICE in failed_ids."""
    n = len(per_case)
    negatives = [r for r in per_case if r.get("negative")]
    json_scored = [r for r in per_case if r.get("json_valid") is not None]

    def rate(hits: int, total: int) -> float:
        return round(hits / total, 4) if total else 0.0

    failed_ids: list = []
    for r in per_case:
        if not r.get("passed"):
            failed_ids.append(r.get("id"))
            if r.get("negative"):
                failed_ids.append(r.get("id"))  # negatives count double
    return {
        "n": n,
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed")), n),
        "negative_pass_rate": rate(sum(1 for r in negatives if r.get("passed")),
                                   len(negatives)),
        "json_valid_rate": rate(sum(1 for r in json_scored if r.get("json_valid")),
                                len(json_scored)),
        "failed_ids": failed_ids,
    }


# ── agentic role pure helpers (multi-round research → JSON synthesis) ────────

AGENTIC_MAX_ROUNDS = 5   # mirrors briefing.run_agentic_briefing max_tool_rounds=5
AGENTIC_MAX_TOKENS = 4096  # mirrors briefing.run_agentic_briefing max_tokens=4096

# Production tool-loop sampling. brain._ask_with_tools_impl builds every round
# with _base_payload(engine="4b") — temp 0.7 / top_p 0.8 / top_k 20 — for ANY
# model serving 8080, so a candidate promoted to the briefing role would run
# with exactly these values. The audit pins them (house sampling is ignored
# for this role) so agentic numbers are production-realistic.
AGENTIC_PROD_SAMPLING = {"temperature": 0.7, "top_p": 0.8, "top_k": 20}

# Verbatim mirror of the Spanish tool-instructions suffix that
# brain._ask_with_tools_impl appends to the caller's system prompt
# (lang=None → Spanish branch; the graph-recall block is absent in a bench
# environment with no memory graph, which is also the production no-recall
# branch). test_model_audit.py asserts this against the brain.py source.
BRAIN_TOOL_INSTRUCTIONS_ES = (
    "\n\nHERRAMIENTAS ACTIVAS:\n"
    "- En esta llamada sí puedes usar las herramientas locales declaradas en tools.\n"
    "- Si una herramienta devuelve resultados, trátalos como información real provista por el sistema.\n"
    "- No digas que necesitas /busca si ya recibiste resultados de una herramienta web_search.\n"
    "- Si los resultados son insuficientes, dilo con precisión y cita lo que sí hay."
)


def _require_axi(symbol) -> None:
    if symbol is None:
        raise RuntimeError(
            "agentic role needs the axi package for the production prompt/"
            f"schemas — run inside axi/.venv (import error: {_AXI_IMPORT_ERROR})")


def build_agentic_system(today: str) -> str:
    """The EXACT system prompt production sends for an agentic briefing.

    run_agentic_briefing passes briefing.build_briefing_system(today) to
    ask_with_tools, and brain._ask_with_tools_impl appends the Spanish
    tool-instructions suffix. The production JSON contract is
    {title, summary, items:[{title, title_es, summary, detailed_summary, url,
    hn_url, hn_comments_summary}]} — `markdown` is DERIVED by
    parse_briefing_result, never requested from the model.
    """
    _require_axi(_prod_briefing_system)
    return _prod_briefing_system(today) + BRAIN_TOOL_INSTRUCTIONS_ES


def agentic_tool_schemas() -> list[dict]:
    """Both briefing tools, exactly as production offers them (search, fetch).

    These are axi.web_tools' real schemas — web_search with time_range and
    categories params and Spanish descriptions — NOT the simplified toolcall-
    role schema in TOOL_SCHEMAS.
    """
    _require_axi(_prod_web_search_tool_def)
    return [_prod_web_search_tool_def(), _prod_web_fetch_tool_def()]


def _canned_search_results(spec: dict, query: str) -> list[dict]:
    """Resolve the canned result set for one web_search query.

    Two shapes are supported:
    - flat: {"results": [...]} — every query gets the same set;
    - keyed: {"queries": [{"match_any": [...], "results": [...]}, ...],
      "default_results": [...]} — the first entry with a match_any term
      contained in the query (accent/case-insensitive) wins; queries matching
      no entry get default_results (usually [] — the planted "first search
      finds nothing, reformulate and retry" scenario).
    """
    for entry in spec.get("queries") or []:
        if any(_contains(query, term) for term in entry.get("match_any") or []):
            return entry.get("results") or []
    if spec.get("queries"):
        return spec.get("default_results") or []
    return spec.get("results") or []


def make_canned_tool_handlers(case: dict, call_log: list[dict]) -> dict:
    """Canned web_search / web_fetch handlers for one golden case.

    Each handler records the call into ``call_log`` (for the tool-usage
    scorer) and returns EXACTLY the JSON shape the production handlers in
    axi.web_tools produce — web_search: {ok, query, results:[{title, url,
    snippet}]}; web_fetch: {ok, url, text, links:[{text, url}]} — serialized
    the way brain._run_tool_call serializes handler dicts
    (json.dumps ensure_ascii=False).
    """
    canned = case.get("canned_tools") or {}

    def web_search(args: dict) -> str:
        query = str((args or {}).get("query", ""))
        call_log.append({"tool": "web_search", "query": query})
        results = _canned_search_results(canned.get("web_search") or {}, query)
        # web_search_handler shape: ok=False on an empty hit list (the system
        # prompt tells the model to retry with a simpler query).
        return json.dumps({"ok": bool(results), "query": query,
                           "results": results}, ensure_ascii=False)

    def web_fetch(args: dict) -> str:
        url = str((args or {}).get("url", ""))
        call_log.append({"tool": "web_fetch", "url": url})
        pages = canned.get("web_fetch") or {}
        page = pages.get(url)
        if page is None:  # tolerate a trailing-slash mismatch
            for known, spec in pages.items():
                if url.rstrip("/") == known.rstrip("/"):
                    page = spec
                    break
        # web_fetch_handler never raises: an unfetchable URL comes back as
        # ok=False with empty text/links (read_fn absorbs the failure).
        if page is None:
            return json.dumps({"ok": False, "url": url, "text": "",
                               "links": []}, ensure_ascii=False)
        # Canned page: plain string (text only) or {"text": ..., "links": [...]}
        if isinstance(page, dict):
            text = str(page.get("text") or "")
            links = list(page.get("links") or [])
        else:
            text, links = str(page), []
        return json.dumps({"ok": bool(text or links), "url": url,
                           "text": text, "links": links}, ensure_ascii=False)

    return {"web_search": web_search, "web_fetch": web_fetch}


def execute_canned_tool_call(tool_call: dict, handlers: dict) -> dict:
    """Mirror brain._run_tool_call: parsed-JSON args in, tool message out.

    Unknown tools / bad arguments / handler errors become model-visible
    'Tool error' results, never exceptions."""
    call_id = str((tool_call or {}).get("id") or "tool_call")
    fn = (tool_call or {}).get("function")
    fn = fn if isinstance(fn, dict) else {}
    name = str(fn.get("name") or "")
    raw_args = fn.get("arguments") or "{}"
    if name not in handlers:
        content = f"Tool error: unknown tool '{name}'."
    else:
        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
            if not isinstance(args, dict):
                raise ValueError("tool arguments must be a JSON object")
            content = handlers[name](args)
        except Exception as e:  # noqa: BLE001 — tool failures stay model-visible
            content = f"Tool error in {name}: {e}"
    return {"role": "tool", "tool_call_id": call_id, "name": name,
            "content": content}


def run_agentic_loop(case: dict, chat_fn,
                     max_rounds: int = AGENTIC_MAX_ROUNDS,
                     today: str = "2026-07-15") -> dict:
    """Drive a REAL multi-round tool loop against a candidate.

    Mirrors brain._ask_with_tools_impl as used by run_agentic_briefing:
    tools are offered every round; when the model calls them, the CANNED
    handlers execute and their results are fed back; a model that keeps
    calling tools is capped at ``max_rounds`` tool rounds, after which the
    tools are DROPPED and AGENTIC_SYNTHESIS_PROMPT is appended as a user turn
    to force the final JSON (forced synthesis).

    ``chat_fn(messages, tools)`` returns a response message dict (the shape
    chat_completion returns) — injected so unit tests can script a fake
    candidate with zero network.
    """
    call_log: list[dict] = []
    handlers = make_canned_tool_handlers(case, call_log)
    tools = agentic_tool_schemas()
    messages: list[dict] = [
        {"role": "system", "content": build_agentic_system(today)},
        {"role": "user", "content": case.get("prompt", "")},
    ]
    rounds_used = 0
    for rnd in range(max_rounds + 1):
        if rnd == max_rounds:  # forced final synthesis: drop tools, nudge
            messages.append({"role": "user",
                             "content": AGENTIC_SYNTHESIS_PROMPT})
            msg = chat_fn(messages, None) or {}
            return {"text": (msg.get("content") or "").strip(),
                    "rounds": rounds_used,
                    "calls": call_log, "forced_synthesis": True}
        msg = chat_fn(messages, tools) or {}
        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            return {"text": (msg.get("content") or "").strip(),
                    "rounds": rounds_used,
                    "calls": call_log, "forced_synthesis": False}
        rounds_used += 1
        messages.append({"role": "assistant",
                         "content": msg.get("content") or "",
                         "tool_calls": tool_calls})
        for tc in tool_calls:
            if isinstance(tc, dict):
                messages.append(execute_canned_tool_call(tc, handlers))
    # Unreachable (the final round always returns), kept for type-safety.
    return {"text": "", "rounds": rounds_used, "calls": call_log,
            "forced_synthesis": True}


def score_agentic_case(case: dict, loop_result: dict) -> dict:
    """Deterministic: tool usage + rounds cap + JSON keys + planted facts.

    ``expected.tools_required: false`` marks a tool-OPTIONAL case (the user
    prompt already carries the facts): tool usage is NOT scored — the case
    passes/fails on the JSON contract and facts alone, whether or not the
    model chose to call tools. ``facts_must_not_appear`` lists planted
    DISTRACTOR facts that must be absent from the final answer
    (selection/anti-fabrication check).
    """
    expected = case.get("expected") or {}
    text = loop_result.get("text") or ""
    calls = loop_result.get("calls") or []
    called = {c.get("tool") for c in calls}
    tools_required = expected.get("tools_required", True)
    must = expected.get("must_call_tools") or []
    tools_ok = all(t in called for t in must) if tools_required else True
    # Query discipline: every query_must_mention term must appear in at least
    # one issued web_search query (accent/case-insensitive).
    qmm = ((case.get("canned_tools") or {}).get("web_search")
           or {}).get("query_must_mention") or []
    if tools_required and tools_ok and qmm and "web_search" in must:
        queries = [c.get("query", "") for c in calls
                   if c.get("tool") == "web_search"]
        tools_ok = all(any(_contains(q, term) for q in queries) for term in qmm)
    data = parse_model_json(text)
    keys = expected.get("final_json_keys") or []
    json_valid = data is not None and all(k in data for k in keys)
    facts_missing = [f for f in (expected.get("facts_must_appear") or [])
                     if not _contains(text, f)]
    facts_forbidden = [f for f in (expected.get("facts_must_not_appear") or [])
                       if _contains(text, f)]
    rounds = loop_result.get("rounds", 0)
    rounds_ok = rounds <= AGENTIC_MAX_ROUNDS
    return {"id": case.get("id"), "tools_ok": tools_ok,
            "json_valid": json_valid, "facts_missing": facts_missing,
            "facts_forbidden": facts_forbidden,
            "rounds": rounds, "forced_synthesis":
                bool(loop_result.get("forced_synthesis")),
            "passed": tools_ok and json_valid and not facts_missing
                      and not facts_forbidden and rounds_ok}


def aggregate_agentic(per_case: list[dict]) -> dict:
    """Role aggregate. Metric semantics (documented in golden_sets/README.md):

    - tool_correct_rate: share of cases whose tool discipline held — every
      must_call_tools tool was called AND query_must_mention terms appeared in
      the issued queries; tool-OPTIONAL cases (tools_required=false) count as
      satisfied by definition, so the rate never punishes skipping tools when
      the case allows it.
    - mean_rounds: average number of TOOL rounds used (a round = one model
      reply containing tool_calls; 0 = answered directly; 5 = exhausted the
      cap and was forced to synthesize without tools).
    """
    n = len(per_case)

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    return {
        "n": n,
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed"))),
        "tool_correct_rate": rate(sum(1 for r in per_case if r.get("tools_ok"))),
        "json_valid_rate": rate(sum(1 for r in per_case if r.get("json_valid"))),
        "mean_rounds": (round(sum(r.get("rounds", 0) for r in per_case) / n, 2)
                        if n else 0.0),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


# ── toolstress role pure helpers (MCP-style tool-protocol robustness) ────────

TOOLSTRESS_MAX_ROUNDS = 6
TOOLSTRESS_MAX_TOKENS = 1024

# What MCP demands of a model, distilled into a deterministic role: pick the
# RIGHT tool among many confusable ones, fill deep nested JSON args exactly,
# recover from tool errors by retrying with corrected args, and follow a
# skill-like procedure document step by step with values threaded between
# calls. LifeOS runs no MCP servers today; this measures readiness.
TOOLSTRESS_SYSTEM_ES = (
    "Eres Axi, el asistente personal de LifeOS. Tienes HERRAMIENTAS locales "
    "declaradas en tools; úsalas cuando la petición lo requiera.\n"
    "- Elige EXACTAMENTE la herramienta correcta: hay varias parecidas y solo "
    "una es la adecuada para cada petición.\n"
    "- Llena los argumentos EXACTAMENTE según el esquema de la herramienta "
    "(objetos anidados, enums y fechas ISO 8601 incluidos).\n"
    "- Si una herramienta devuelve un error, corrige los argumentos que el "
    "error señale y reintenta la MISMA herramienta.\n"
    "- Si este mensaje incluye un PROCEDIMIENTO, ejecuta sus pasos EN ORDEN y "
    "usa los datos que devuelva cada paso en los pasos siguientes.\n"
    "- Al terminar, confirma al usuario en una frase corta en español."
)

# Forced wrap-up nudge when the model exhausts the round cap (tools dropped).
TOOLSTRESS_WRAPUP_PROMPT = (
    "Ya no puedes usar más herramientas. Responde ahora al usuario en una "
    "frase corta en español confirmando qué se hizo (o qué falló)."
)


def _ts_tool(name: str, description: str, properties: dict,
             required: list[str]) -> dict:
    """One OpenAI function schema for the toolstress registry."""
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": properties,
                       "required": required}}}


_TS_DATE_RANGE = {"type": "object",
                  "description": "Rango de fechas ISO (YYYY-MM-DD).",
                  "properties": {"from": {"type": "string"},
                                 "to": {"type": "string"}},
                  "required": ["from", "to"]}

# ~12 deliberately confusable tools, offered ALL AT ONCE on every case (the
# MCP-style stress: a crowded registry of near-neighbours). Separate from the
# simpler TOOL_SCHEMAS used by the toolcall role.
TOOLSTRESS_REGISTRY: dict[str, dict] = {
    "create_reminder": _ts_tool(
        "create_reminder",
        "Crea un recordatorio puntual que Axi disparará a la hora indicada.",
        {"text": {"type": "string", "description": "Qué recordar."},
         "when_iso": {"type": "string",
                      "description": "Cuándo, datetime ISO 8601."}},
        ["text", "when_iso"]),
    "create_calendar_event": _ts_tool(
        "create_calendar_event",
        "Agenda un evento en el calendario con hora de inicio Y de fin.",
        {"title": {"type": "string"},
         "start_iso": {"type": "string", "description": "Inicio ISO 8601."},
         "end_iso": {"type": "string", "description": "Fin ISO 8601."},
         "location": {"type": "string"},
         "attendees": {"type": "array", "items": {"type": "string"},
                       "description": "Nombres de los invitados."}},
        ["title", "start_iso", "end_iso"]),
    "create_task": _ts_tool(
        "create_task",
        "Añade una tarea pendiente SIN hora a la lista de un proyecto.",
        {"title": {"type": "string"},
         "project": {"type": "string"},
         "priority": {"type": "string", "enum": ["low", "medium", "high"]},
         "tags": {"type": "array", "items": {"type": "string"}}},
        ["title", "priority"]),
    "search_web": _ts_tool(
        "search_web",
        "Busca información pública y actual en internet.",
        {"query": {"type": "string"}}, ["query"]),
    "search_memory": _ts_tool(
        "search_memory",
        "Busca en la memoria personal del usuario (conversaciones, acuerdos y "
        "personas conocidas).",
        {"query": {"type": "string"},
         "domain": {"type": "string",
                    "enum": ["salud", "finanzas", "agenda", "personas",
                             "todo"]}},
        ["query"]),
    "search_files": _ts_tool(
        "search_files",
        "Busca archivos locales por nombre o patrón.",
        {"pattern": {"type": "string"}, "path": {"type": "string"}},
        ["pattern"]),
    "get_health_summary": _ts_tool(
        "get_health_summary",
        "Resumen AGREGADO de todas las métricas de salud de los últimos N "
        "días.",
        {"days": {"type": "integer",
                  "description": "Cuántos días hacia atrás."}},
        ["days"]),
    "get_health_entries": _ts_tool(
        "get_health_entries",
        "Registros CRUDOS de UNA métrica de salud dentro de un rango de "
        "fechas.",
        {"metric": {"type": "string",
                    "enum": ["pressure", "pulse", "weight", "sleep"]},
         "date_range": _TS_DATE_RANGE},
        ["metric", "date_range"]),
    "send_notification": _ts_tool(
        "send_notification",
        "Manda una notificación del sistema al PROPIO usuario.",
        {"message": {"type": "string"},
         "channel": {"type": "string", "enum": ["push", "email"]}},
        ["message", "channel"]),
    "send_message": _ts_tool(
        "send_message",
        "Envía un mensaje de chat a OTRA persona.",
        {"recipient": {"type": "string"}, "text": {"type": "string"}},
        ["recipient", "text"]),
    "update_config": _ts_tool(
        "update_config",
        "Actualiza la configuración: una sección + un objeto changes "
        "{clave: valor}.",
        {"section": {"type": "string"},
         "changes": {"type": "object",
                     "description": "Objeto {clave: valor} con los cambios.",
                     "additionalProperties": True}},
        ["section", "changes"]),
    "export_data": _ts_tool(
        "export_data",
        "Exporta registros del usuario a un archivo.",
        {"format": {"type": "string", "enum": ["csv", "json", "pdf"]},
         "filters": {"type": "object",
                     "properties": {
                         "domain": {"type": "string",
                                    "enum": ["salud", "finanzas", "agenda",
                                             "todo"]},
                         "date_range": _TS_DATE_RANGE},
                     "required": ["domain", "date_range"]}},
        ["format", "filters"]),
    "create_expense": _ts_tool(
        "create_expense",
        "Registra un gasto; usa split=true y person_id para gastos "
        "compartidos.",
        {"amount": {"type": "number"},
         "category": {"type": "string"},
         "split": {"type": "boolean"},
         "person_id": {"type": "string"}},
        ["amount", "category"]),
}


def toolstress_tool_schemas() -> list[dict]:
    """The full registry, fixed order — every case offers ALL the tools."""
    return list(TOOLSTRESS_REGISTRY.values())


def build_toolstress_system(case: dict) -> str:
    """Base system prompt + the case's skill-like procedure doc (if any)."""
    procedure = case.get("procedure")
    if procedure:
        return TOOLSTRESS_SYSTEM_ES + "\n\n" + procedure
    return TOOLSTRESS_SYSTEM_ES


def make_toolstress_handlers(case: dict, call_log: list[dict]) -> dict:
    """Canned handlers for EVERY registry tool.

    Per-tool case spec (``canned_tools``):
    - ``first_error``: JSON returned verbatim on the FIRST call to the tool
      (the error-recovery planted failure); later calls fall through.
    - ``result``: JSON returned on (subsequent) calls.
    Tools without a spec return ``{"ok": true, "tool": name}``. Every call is
    recorded into ``call_log`` as {tool, args} for the scorer.
    """
    canned = case.get("canned_tools") or {}
    counts: dict[str, int] = {}

    def make(name: str):
        spec = canned.get(name) or {}

        def handler(args: dict) -> str:
            counts[name] = counts.get(name, 0) + 1
            call_log.append({"tool": name, "args": dict(args or {})})
            if counts[name] == 1 and spec.get("first_error") is not None:
                return json.dumps(spec["first_error"], ensure_ascii=False)
            result = spec.get("result")
            if result is None:
                result = {"ok": True, "tool": name}
            return json.dumps(result, ensure_ascii=False)

        return handler

    return {name: make(name) for name in TOOLSTRESS_REGISTRY}


def run_toolstress_loop(case: dict, chat_fn,
                        max_rounds: int = TOOLSTRESS_MAX_ROUNDS) -> dict:
    """Multi-round tool loop against a candidate (agentic-role plumbing).

    Tools are offered every round; canned handlers execute and feed results
    back as role=tool messages. A model still calling tools after
    ``max_rounds`` rounds gets the tools DROPPED and TOOLSTRESS_WRAPUP_PROMPT
    appended as a user turn (forced wrap-up). ``chat_fn(messages, tools)``
    returns a response message dict — injected so unit tests can script a
    fake candidate with zero network.
    """
    call_log: list[dict] = []
    handlers = make_toolstress_handlers(case, call_log)
    tools = toolstress_tool_schemas()
    messages: list[dict] = [
        {"role": "system", "content": build_toolstress_system(case)},
        {"role": "user", "content": case.get("prompt", "")},
    ]
    rounds_used = 0
    for rnd in range(max_rounds + 1):
        if rnd == max_rounds:  # forced wrap-up: drop tools, nudge
            messages.append({"role": "user",
                             "content": TOOLSTRESS_WRAPUP_PROMPT})
            msg = chat_fn(messages, None) or {}
            return {"text": (msg.get("content") or "").strip(),
                    "rounds": rounds_used,
                    "calls": call_log, "forced_wrapup": True}
        msg = chat_fn(messages, tools) or {}
        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            return {"text": (msg.get("content") or "").strip(),
                    "rounds": rounds_used,
                    "calls": call_log, "forced_wrapup": False}
        rounds_used += 1
        messages.append({"role": "assistant",
                         "content": msg.get("content") or "",
                         "tool_calls": tool_calls})
        for tc in tool_calls:
            if isinstance(tc, dict):
                messages.append(execute_canned_tool_call(tc, handlers))
    # Unreachable (the final round always returns), kept for type-safety.
    return {"text": "", "rounds": rounds_used, "calls": call_log,
            "forced_wrapup": True}


_TS_MISSING = object()


def _ts_nested_lookup(obj, path: str):
    """Dotted-path lookup into nested dicts: 'filters.date_range.from'."""
    cur = obj
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return _TS_MISSING
        cur = cur[part]
    return cur


def _ts_value_matches(expected, actual, exact: bool) -> bool:
    """Type-aware match for one expected arg value.

    Strings: exact → accent/case-insensitive equality; subset → containment
    (so 'karla' matches 'Karla Ruiz' and a stringified attendees list).
    Booleans require a real JSON bool (True never matches 1). Numbers compare
    numerically (450 matches 450.0 but not '450a').
    """
    if actual is _TS_MISSING:
        return False
    if isinstance(expected, bool):
        return isinstance(actual, bool) and actual == expected
    if isinstance(expected, str):
        if exact:
            return _norm(str(actual)) == _norm(expected)
        return _contains(str(actual), expected)
    if isinstance(expected, (int, float)):
        if isinstance(actual, bool):
            return False
        try:
            return float(actual) == float(expected)
        except (TypeError, ValueError):
            return False
    return actual == expected


def toolstress_arg_mismatches(args: dict, paths: dict,
                              exact: bool = False) -> list[str]:
    """Dotted paths whose expected value does NOT match ``args`` (sorted)."""
    return sorted(p for p, v in (paths or {}).items()
                  if not _ts_value_matches(v, _ts_nested_lookup(args or {}, p),
                                           exact))


def score_toolstress_case(case: dict, loop_result: dict) -> dict:
    """Deterministic per-kind scoring. Kinds and their pass conditions:

    - selection: the expected tool was called, NO forbidden neighbour was
      called, and some call to it satisfied required_args_subset (containment
      semantics, nested paths supported).
    - nested_args: the expected tool was called with EVERY args_exact dotted
      path matching exactly (accent/case-insensitive for strings).
    - error_recovery: after the planted first_error the model RETRIED the
      SAME tool (>=2 calls), a retry satisfied corrected_paths, and the final
      answer acknowledges the outcome (final_must_mention_any, any-of).
    - procedure: the call log contains the expected steps as an ORDERED
      subsequence, each step's args_subset matching — threaded values (ids /
      ranges returned by earlier canned steps) are checked by exact planted
      values in later steps' args_subset.
    """
    kind = case.get("kind")
    expected = case.get("expected") or {}
    calls = loop_result.get("calls") or []
    text = loop_result.get("text") or ""
    rounds = loop_result.get("rounds", 0)
    rounds_ok = rounds <= TOOLSTRESS_MAX_ROUNDS
    out: dict = {"id": case.get("id"), "kind": kind, "rounds": rounds,
                 "forced_wrapup": bool(loop_result.get("forced_wrapup"))}
    tool = expected.get("tool")
    tool_args = [c.get("args") or {} for c in calls if c.get("tool") == tool]

    if kind == "selection":
        forbidden_called = sorted(
            {c.get("tool") for c in calls}
            & set(expected.get("forbidden_tools") or []))
        subset = expected.get("required_args_subset") or {}
        args_ok = any(not toolstress_arg_mismatches(a, subset)
                      for a in tool_args)
        selection_ok = bool(tool_args) and not forbidden_called
        out.update(selection_ok=selection_ok,
                   forbidden_called=forbidden_called, args_ok=args_ok,
                   passed=selection_ok and args_ok and rounds_ok)
    elif kind == "nested_args":
        exact_paths = expected.get("args_exact") or {}
        best = min((toolstress_arg_mismatches(a, exact_paths, exact=True)
                    for a in tool_args),
                   key=len, default=sorted(exact_paths))
        args_ok = bool(tool_args) and not best
        out.update(tool_called=bool(tool_args), mismatched_paths=best,
                   args_ok=args_ok, passed=args_ok and rounds_ok)
    elif kind == "error_recovery":
        corrected = expected.get("corrected_paths") or {}
        retried = len(tool_args) >= 2
        recovery_ok = retried and any(
            not toolstress_arg_mismatches(a, corrected)
            for a in tool_args[1:])
        terms = expected.get("final_must_mention_any") or []
        ack_ok = bool(text.strip()) and (
            not terms or any(_contains(text, t) for t in terms))
        out.update(retried=retried, recovery_ok=recovery_ok, ack_ok=ack_ok,
                   passed=recovery_ok and ack_ok and rounds_ok)
    elif kind == "procedure":
        steps = expected.get("steps") or []
        idx = 0
        for c in calls:
            if idx >= len(steps):
                break
            step = steps[idx]
            if (c.get("tool") == step.get("tool")
                    and not toolstress_arg_mismatches(
                        c.get("args") or {}, step.get("args_subset") or {})):
                idx += 1
        procedure_ok = bool(steps) and idx == len(steps)
        out.update(steps_completed=idx, steps_total=len(steps),
                   procedure_ok=procedure_ok,
                   passed=procedure_ok and rounds_ok)
    else:
        out.update(passed=False, error=f"unknown kind {kind!r}")
    return out


def aggregate_toolstress(per_case: list[dict]) -> dict:
    """Role aggregate. Per-kind rates are pass rates over that kind's cases
    (0.0 when the kind is absent); pass_rate covers every case."""
    def rate(sub: list[dict]) -> float:
        return (round(sum(1 for r in sub if r.get("passed")) / len(sub), 4)
                if sub else 0.0)

    def by(kind: str) -> list[dict]:
        return [r for r in per_case if r.get("kind") == kind]

    return {
        "n": len(per_case),
        "pass_rate": rate(per_case),
        "tool_selection_rate": rate(by("selection")),
        "arg_exactness_rate": rate(by("nested_args")),
        "recovery_rate": rate(by("error_recovery")),
        "procedure_rate": rate(by("procedure")),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


# ── proactive role pure helpers (autonomous thought quality + restraint) ─────

PROACTIVE_SENTINEL_WAIT = "ESPERAR"   # mirrors autonomous.cron.SENTINEL_WAIT
PROACTIVE_SENTINEL_NONE = "NADA"      # mirrors autonomous.cron.SENTINEL_NONE

_PROACTIVE_VERDICT_BY_SENTINEL = {PROACTIVE_SENTINEL_WAIT: "esperar",
                                  PROACTIVE_SENTINEL_NONE: "nada"}


def parse_proactive_reply(reply: str, max_chars: int) -> tuple[str, Optional[str]]:
    """Mirror autonomous.cron.parse_reply exactly.

    Sentinel detection is WHOLE-STRING equality after trimming and stripping
    trailing punctuation/quotes; a reply that merely CONTAINS a sentinel word
    is a real message. Empty / brain-error replies map to 'nada'.
    """
    norm = (reply or "").strip()
    upper = norm.upper().strip(" .!¡¿?\"'`")
    if upper == PROACTIVE_SENTINEL_WAIT:
        return ("esperar", None)
    if upper == PROACTIVE_SENTINEL_NONE:
        return ("nada", None)
    if not norm:
        return ("nada", None)
    if norm.startswith("[") and "brain" in norm.lower():
        return ("nada", None)
    return ("msg", norm[:max_chars].rstrip())


def score_proactive_case(case: dict, reply: str) -> dict:
    """Sentinel discipline on restraint cases; short-Spanish-on-topic on speak.

    Restraint: the verdict must be the exact expected sentinel (a null
    sentinel accepts either ESPERAR or NADA). Speak: the reply must be a real
    message (NOT a sentinel), fit max_chars RAW (production truncates; the
    audit fails oversize instead), be Spanish, and mention the topic when
    ``topic_must_mention_any`` is present.
    """
    import cpu_sweep
    expected = case.get("expected") or {}
    max_chars = case.get("max_chars", 220)
    verdict, message = parse_proactive_reply(reply, max_chars)

    if expected.get("sentinel_expected"):
        want = expected.get("sentinel")
        if want is None:
            passed = verdict in ("esperar", "nada")
        else:
            passed = verdict == _PROACTIVE_VERDICT_BY_SENTINEL.get(want)
        return {"id": case.get("id"), "restraint": True, "verdict": verdict,
                "passed": passed}

    spoke = verdict == "msg" and bool(message)
    raw = (reply or "").strip()
    length_ok = spoke and len(raw) <= max_chars
    spanish = spoke and cpu_sweep.is_spanish(message or "")
    topics = expected.get("topic_must_mention_any") or []
    topic_ok = (not topics) or (spoke and any(_contains(message or "", t)
                                              for t in topics))
    return {"id": case.get("id"), "restraint": False, "verdict": verdict,
            "spoke": spoke, "length_ok": length_ok, "spanish": spanish,
            "topic_ok": topic_ok,
            "passed": spoke and length_ok and spanish and topic_ok}


def aggregate_proactive(per_case: list[dict]) -> dict:
    restraint = [r for r in per_case if r.get("restraint")]
    speak = [r for r in per_case if not r.get("restraint")]

    def rate(hits: int, total: int) -> float:
        return round(hits / total, 4) if total else 0.0

    return {
        "n": len(per_case),
        "restraint_rate": rate(sum(1 for r in restraint if r.get("passed")),
                               len(restraint)),
        "speak_pass_rate": rate(sum(1 for r in speak if r.get("passed")),
                                len(speak)),
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed")),
                          len(per_case)),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


# ── visionclass role pure helpers (structured vision classification) ─────────

# Mirror of posture.analyze._PROMPT_ES (the production posture classifier).
VISIONCLASS_PROMPT_ES = (
    "Mirá la imagen y analizá la postura de la persona frente al escritorio "
    "(si hay alguien). Clasificá en UNO de estos estados:\n"
    "  - good           — postura correcta, espalda recta, cabeza alineada\n"
    "  - slouched       — hombros caídos, espalda encorvada\n"
    "  - forward_head   — cabeza adelantada respecto al cuerpo\n"
    "  - leaning        — inclinado hacia un lado\n"
    "  - not_at_desk    — no hay nadie sentado al escritorio\n"
    "  - face_not_visible — hay alguien pero no se ve la cara/postura\n\n"
    "Devolvé SOLO un JSON, sin texto extra antes ni después:\n"
    '{"state":"...","confidence":0.0-1.0,"suggestion":"breve texto en español"}\n'
    "La sugerencia debe ser corta (≤ 100 chars), específica si la postura es "
    "problemática, vacía si es 'good' o 'not_at_desk'."
)

# States whose suggestion must be empty/near-empty (mirrors the prompt rule).
VISIONCLASS_GOOD_STATES = ("good", "not_at_desk")
VISIONCLASS_GOOD_SUGGESTION_MAX = 40
VISIONCLASS_SUGGESTION_MAX = 100


def score_visionclass_case(case: dict, reply: str) -> dict:
    """JSON contract + label accuracy + confidence range + suggestion rule."""
    contract_keys = ((case.get("json_contract") or {}).get("keys")
                     or ["state", "confidence", "suggestion"])
    data = parse_model_json(reply or "")
    json_valid = data is not None and all(k in data for k in contract_keys)
    if not json_valid:
        return {"id": case.get("id"), "json_valid": False,
                "label_correct": False, "passed": False}
    state = str(data.get("state", "")).lower().strip()
    label_correct = state == case.get("expected_label")
    in_labels = state in (case.get("labels") or [])
    try:
        conf = float(data.get("confidence"))
        conf_ok = 0.0 <= conf <= 1.0
    except (TypeError, ValueError):
        conf_ok = False
    suggestion = str(data.get("suggestion") or "").strip()
    if state in VISIONCLASS_GOOD_STATES:
        suggestion_ok = len(suggestion) <= VISIONCLASS_GOOD_SUGGESTION_MAX
    else:
        suggestion_ok = len(suggestion) <= VISIONCLASS_SUGGESTION_MAX
    return {"id": case.get("id"), "json_valid": True,
            "label_correct": label_correct, "in_labels": in_labels,
            "conf_ok": conf_ok, "suggestion_ok": suggestion_ok,
            "passed": label_correct and in_labels and conf_ok and suggestion_ok}


def aggregate_visionclass(per_case: list[dict]) -> dict:
    n = len(per_case)

    def rate(hits: int) -> float:
        return round(hits / n, 4) if n else 0.0

    return {
        "n": n,
        "label_accuracy": rate(sum(1 for r in per_case
                                   if r.get("label_correct"))),
        "json_valid_rate": rate(sum(1 for r in per_case
                                    if r.get("json_valid"))),
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed"))),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }


# ── devplan role pure helpers (self-dev director: instruction + review) ──────

# Mirrors of dev_director's ENGLISH production prompts (VT-3B's director role).
DEVPLAN_DIRECTOR_SYSTEM = (
    "You are a senior software engineer directing an AI coding agent. "
    "Given a goal, produce ONE specific, actionable coding instruction for Claude Code. "
    "Include: what file/function to target, the expected behavior, edge cases to handle, "
    "and that tests must be added. Be concise and precise. Output only the instruction."
)

DEVPLAN_REVIEWER_SYSTEM = (
    "You are a code reviewer. Given a goal and a git diff, decide if the implementation "
    "is correct and complete. Start your answer with 'DONE' if satisfied, or 'NOT DONE' "
    "if there are issues, followed by a brief reason."
)

# Deterministic keyword classes for the instruction scorer: at least one hit
# per class = the instruction names a concrete target, describes behavior, and
# demands tests/edge cases (matching is accent/case-insensitive).
DEVPLAN_INSTRUCTION_KEYWORDS: dict[str, tuple[str, ...]] = {
    "target": ("file", ".py", "module", "function", "class", "method", "def "),
    "behavior": ("should", "must", "return", "when", "expect", "ensure",
                 "behavior", "behaviour", "so that"),
    "tests": ("test", "edge case", "edge-case", "pytest"),
}

DEVPLAN_INSTRUCTION_MAX_CHARS = 1200

_DEVPLAN_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)


def _devplan_strip_think(text: str) -> str:
    """VT-3B replies may carry <think> blocks (dev_director strips them too)."""
    return _DEVPLAN_THINK_RE.sub("", text or "").strip()


def score_devplan_instruction(case: dict, reply: str) -> dict:
    """Keyword-class + length scorer for a director instruction."""
    text = _devplan_strip_think(reply)
    hits = {name: any(_contains(text, kw) for kw in kws)
            for name, kws in DEVPLAN_INSTRUCTION_KEYWORDS.items()}
    max_chars = case.get("max_chars", DEVPLAN_INSTRUCTION_MAX_CHARS)
    length_ok = 0 < len(text) <= max_chars
    return {"id": case.get("id"), "kind": "instruction",
            "keyword_hits": hits, "length_ok": length_ok,
            "passed": length_ok and all(hits.values()),
            "judge_score": None}


def devplan_review_verdict(reply: str) -> bool:
    """Mirror dev_director._review's verdict parse exactly."""
    low = _devplan_strip_think(reply).lower().strip()
    return low.startswith("done") and not low.startswith("not done")


def score_devplan_review(case: dict, reply: str) -> dict:
    """DONE/NOT DONE verdict must match the case's ``satisfies`` flag."""
    done = devplan_review_verdict(reply)
    return {"id": case.get("id"), "kind": "review", "verdict_done": done,
            "passed": done == bool(case.get("satisfies"))}


def devplan_judge_case(case: dict) -> dict:
    """Adapt an instruction case to the conversation rubric-judge helpers."""
    return {"messages": [{"role": "user",
                          "content": f"Goal: {case.get('goal', '')}"}],
            "rubric": case.get("rubric")}


def aggregate_devplan(per_case: list[dict], note: Optional[str] = None) -> dict:
    instr = [r for r in per_case if r.get("kind") == "instruction"]
    rev = [r for r in per_case if r.get("kind") == "review"]
    judged = [r["judge_score"] for r in instr
              if r.get("judge_score") is not None]

    def rate(hits: int, total: int) -> float:
        return round(hits / total, 4) if total else 0.0

    out = {
        "n": len(per_case),
        "instruction_pass_rate": rate(sum(1 for r in instr if r.get("passed")),
                                      len(instr)),
        "review_accuracy": rate(sum(1 for r in rev if r.get("passed")),
                                len(rev)),
        "pass_rate": rate(sum(1 for r in per_case if r.get("passed")),
                          len(per_case)),
        "judge_score": (round(sum(judged) / len(judged), 4) if judged else None),
        "failed_ids": [r.get("id") for r in per_case if not r.get("passed")],
    }
    if note:
        out["note"] = note
    return out


# ── audit registry rows & comparison matrix ──────────────────────────────────

def assemble_audit_row(label: str, tier: str, gguf: str, server_bin: str,
                       recipe: dict, roles: dict,
                       stage_a_cells: list[dict], stage_b_variants: list[dict],
                       now: Optional[str] = None) -> dict:
    """One registry row: identity + peak recipe + role results + tuning trace."""
    return {
        "label": label,
        "tier": tier,
        "timestamp_utc": now or datetime.now(timezone.utc).isoformat(),
        "gguf": gguf,
        "server_bin": server_bin,
        "recipe": recipe,
        "roles": roles,
        "stage_a_cells": stage_a_cells,
        "stage_b_variants": stage_b_variants,
    }


def newest_per_label_tier(rows: list[dict]) -> list[dict]:
    """Collapse audit history to the newest row per (label, tier)."""
    best: dict[tuple[str, str], tuple[str, int, dict]] = {}
    for idx, row in enumerate(rows):
        key = (row.get("label", ""), row.get("tier", ""))
        stamp = (row.get("timestamp_utc", ""), idx)
        if key not in best or stamp > (best[key][0], best[key][1]):
            best[key] = (stamp[0], stamp[1], row)
    return [best[k][2] for k in sorted(best)]


def _brain_metric(roles: dict) -> Optional[float]:
    brain = roles.get("brain") or {}
    return brain.get("final") if brain.get("final") is not None else brain.get("det")


def _fmt_ctx_k(roles: dict) -> str:
    """ctxprobe's ctx_max for the audited tier, in thousands (e.g. '48k')."""
    val = (roles.get("ctxprobe") or {}).get("ctx_max_current")
    if isinstance(val, (int, float)) and not isinstance(val, bool):
        return f"{int(val // 1000)}k"
    return "-"


def build_audit_matrix(rows: list[dict], title: str = "MODEL AUDIT MATRIX") -> str:
    """Side-by-side matrix: newest row per label+tier, key metric per role."""
    latest = newest_per_label_tier(rows)
    bar = "=" * 205
    lines = [bar, f"  {title}  (newest audit per label+tier)", bar]
    lines.append(
        f"  {'Label':<20} {'tier':<7} {'brain':>6} {'extr%':>6} {'dom%':>6} "
        f"{'tool%':>6} {'vis%':>6} {'rev%':>6} {'code%':>6} {'conv':>6} "
        f"{'recQA%':>6} {'narr':>6} {'lsum%':>6} {'parse%':>6} "
        f"{'agent%':>6} {'proact%':>7} {'vcls%':>6} {'dev%':>6} "
        f"{'tstress%':>8} "
        f"{'ctxK':>5} {'tok/s':>7} {'VRAM MiB':>9} {'thinking':<9}"
    )
    lines.append("  " + "-" * 201)
    if not latest:
        lines.append("  (audit registry is empty — nothing audited yet)")
        lines.append(bar)
        return "\n".join(lines)
    for row in latest:
        roles = row.get("roles") or {}
        speed = roles.get("speed") or {}
        recipe = row.get("recipe") or {}
        vram = (recipe.get("scores") or {}).get("stage_a_vram_delta_mib")
        lines.append(
            f"  {row.get('label', ''):<20} {row.get('tier', ''):<7} "
            f"{bm._fmt(_brain_metric(roles), '6.3f')} "
            f"{bm._fmt((roles.get('extraction') or {}).get('case_pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('domain') or {}).get('overall_accuracy'), '6.1%')} "
            f"{bm._fmt((roles.get('toolcall') or {}).get('score'), '6.1%')} "
            f"{bm._fmt((roles.get('vision') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('codereview') or {}).get('score'), '6.1%')} "
            f"{bm._fmt((roles.get('codegen') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('conversation') or {}).get('judge_score'), '6.3f')} "
            f"{bm._fmt((roles.get('recordsqa') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('narration') or {}).get('numeric_fidelity_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('longsum') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('parsejson') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('agentic') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('proactive') or {}).get('pass_rate'), '7.1%')} "
            f"{bm._fmt((roles.get('visionclass') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('devplan') or {}).get('pass_rate'), '6.1%')} "
            f"{bm._fmt((roles.get('toolstress') or {}).get('pass_rate'), '8.1%')} "
            f"{_fmt_ctx_k(roles):>5} "
            f"{bm._fmt(speed.get('decode_p50_toks_s'), '7.1f')} "
            f"{bm._fmt(vram, '9.0f')} "
            f"{recipe.get('thinking', '-'):<9}"
        )
    lines.append(bar)
    return "\n".join(lines)


# Role → ordered candidate keys for its headline scalar (report table; the
# dashboard keeps its own mirror in axi.bench_audit._ROLE_HEADLINE_KEYS).
ROLE_HEADLINE_KEYS: dict[str, tuple[str, ...]] = {
    "brain": ("final", "det"),
    "extraction": ("case_pass_rate",),
    "domain": ("overall_accuracy",),
    "toolcall": ("score",),
    "vision": ("pass_rate",),
    "codereview": ("score",),
    "codegen": ("pass_rate",),
    "conversation": ("judge_score",),
    "recordsqa": ("pass_rate",),
    "narration": ("numeric_fidelity_rate",),
    "longsum": ("pass_rate",),
    "parsejson": ("pass_rate",),
    "agentic": ("pass_rate",),
    "proactive": ("pass_rate",),
    "visionclass": ("pass_rate",),
    "devplan": ("pass_rate",),
    "toolstress": ("pass_rate",),
    "speed": ("decode_p50_toks_s",),
    "embed": ("retrieval_rate",),
    "ctxprobe": ("ctx_max_current",),
}


def role_headline_metric(role: str, result) -> Optional[float]:
    """One role's headline scalar from its result dict (None if skipped)."""
    if not isinstance(result, dict) or "skipped" in result:
        return None
    for key in ROLE_HEADLINE_KEYS.get(role, ()):
        val = result.get(key)
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            return float(val)
    return None


def format_sampling_summary(sampling_used) -> str:
    """Compact one-line summary of a role's sampling_used record."""
    if not isinstance(sampling_used, dict):
        return "-"

    def fmt(v):
        return "-" if v is None else v

    return (f"T={fmt(sampling_used.get('temperature'))} "
            f"top_p={fmt(sampling_used.get('top_p'))} "
            f"top_k={fmt(sampling_used.get('top_k'))} "
            f"seed={sampling_used.get('seed_policy', '-')} "
            f"think={sampling_used.get('thinking', '-')}")


def build_role_config_table(roles: dict) -> list[str]:
    """Per-role config table lines: role | headline | sampling summary.

    This is what makes the registry answer "good WHERE and WITH WHAT config".
    Rows from the pre-2026-07-16 era have no sampling_used and render '-'.
    """
    lines = [f"  {'role':<12} {'headline':>9}  sampling used"]
    lines.append("  " + "-" * 74)
    for role, result in (roles or {}).items():
        head = role_headline_metric(role, result)
        head_s = "-" if head is None else f"{head:.4g}"
        su = result.get("sampling_used") if isinstance(result, dict) else None
        lines.append(f"  {role:<12} {head_s:>9}  {format_sampling_summary(su)}")
    return lines


def build_model_report(rows: list[dict], label: str) -> str:
    """Full audit detail for one label (all tiers, newest per tier)."""
    mine = [r for r in newest_per_label_tier(rows) if r.get("label") == label]
    if not mine:
        return f"No audit rows found for label '{label}'."
    out: list[str] = []
    for row in mine:
        bar = "=" * 78
        out += [bar, f"  AUDIT REPORT — {label}  [tier {row.get('tier')}]  "
                     f"{row.get('timestamp_utc', '')}", bar]
        out.append(f"  gguf       : {row.get('gguf')}")
        out.append(f"  server_bin : {row.get('server_bin')}")
        out.append("  recipe     : "
                   + json.dumps(row.get("recipe"), ensure_ascii=False, indent=2)
                     .replace("\n", "\n  "))
        if row.get("roles"):
            out.append("  role config (headline metric + sampling it was earned with):")
            out += build_role_config_table(row.get("roles") or {})
        for role, result in (row.get("roles") or {}).items():
            out.append(f"  role {role:<11}: "
                       + json.dumps(result, ensure_ascii=False, default=str))
        cells = row.get("stage_a_cells") or []
        if cells:
            out.append(f"  stage A    : {len(cells)} cells swept")
            for c in cells:
                cell = c.get("cell") or {}
                status = ("ok  " if c.get("ok")
                          else f"FAIL ({c.get('error', '?')})")
                out.append(f"    - {cell.get('name', '?'):<28} {status} "
                           f"decode={c.get('decode_toks_s')} ttft={c.get('ttft_ms')} "
                           f"vramΔ={c.get('vram_delta_mib')}")
        variants = row.get("stage_b_variants") or []
        if variants:
            out.append(f"  stage B    : {len(variants)} variants scored")
            for v in variants:
                out.append(f"    - {v.get('name', '?'):<24} det={v.get('det')}")
        out.append(bar)
    return "\n".join(out)


# ── argument parsing ─────────────────────────────────────────────────────────

def parse_audit_roles(raw: str) -> list[str]:
    roles = [r.strip() for r in raw.split(",") if r.strip()]
    bad = [r for r in roles if r not in VALID_ROLES]
    if bad:
        raise ValueError(f"unknown role(s): {bad} — valid: {list(VALID_ROLES)}")
    return roles


def parse_tiers(raw: str) -> list[str]:
    tiers = [t.strip() for t in raw.split(",") if t.strip()]
    bad = [t for t in tiers if t not in TIER_BUDGETS_MIB]
    if bad:
        raise ValueError(f"unknown tier(s): {bad} — valid: {sorted(TIER_BUDGETS_MIB)}")
    return tiers


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="model_audit.py",
        description="Tune-to-peak model audit: Stage A perf sweep → Stage B "
                    "quality tune → Stage C full role suite at the peak recipe.",
    )
    p.add_argument("--gguf", help="Candidate GGUF path (required unless --compare/--list/--report)")
    p.add_argument("--label", help="Registry key (required unless --compare/--list/--report)")
    p.add_argument("--server-bin", default="/usr/bin/llama-server",
                   help="llama-server binary (fork builds welcome)")
    p.add_argument("--mmproj", default=None, help="mmproj GGUF (enables the vision role)")
    p.add_argument("--tiers", default="vram12",
                   help=f"Comma list from {sorted(TIER_BUDGETS_MIB)} (default: vram12)")
    p.add_argument("--roles",
                   default="speed,brain,extraction,domain,toolcall,codereview,"
                           "vision,codegen,conversation,recordsqa,narration,"
                           "longsum,parsejson,agentic,proactive,visionclass,"
                           "devplan,toolstress",
                   help=f"Comma list from {list(VALID_ROLES)}; vision/visionclass "
                        "auto-skip without --mmproj; embed needs --embedding")
    p.add_argument("--quick", action="store_true",
                   help="Reduced Stage-A grid + skip Stage B")
    p.add_argument("--use-recipe", action="store_true",
                   help="Skip Stages A/B; audit at the saved recipe for label+tier")
    p.add_argument("--sampling", default=None,
                   help='Model-card default sampling as JSON, e.g. '
                        '\'{"temperature":0.7,"top_p":0.8}\'')
    p.add_argument("--thinking-modes", default="none",
                   help=f"Comma list from {list(VALID_THINKING_MODES)} (default: none)")
    p.add_argument("--moe", default="auto", choices=["auto", "on", "off"],
                   help="MoE model? auto = filename heuristic (drives --cpu-moe cells)")
    p.add_argument("--embedding", action="store_true",
                   help="Enable the embed role (spawns a separate --embedding server)")
    p.add_argument("--ctx", type=int, default=32768, help="Context size (default 32768)")
    p.add_argument("--native-ctx", type=int, default=None,
                   help="Model's trained context length; caps the ctxprobe "
                        "extrapolation as ctx_max_native_cap (default: no cap)")
    p.add_argument("--ctx-verify", action="store_true",
                   help="ctxprobe: one confirmation spawn at the predicted "
                        "ctx_max for the CURRENT tier (default off)")
    p.add_argument("--port", type=int, default=18080,
                   help="Bench port (default 18080; NEVER 8080/8081/8082/8090/8091)")
    p.add_argument("--n-runs", type=int, default=10, help="Speed-role runs (default 10)")
    p.add_argument("--brain-max-tokens", type=int, default=0,
                   help="Brain answer cap (default 0 = auto: 200, or 1024 when thinking)")
    p.add_argument("--registry", default=str(AUDIT_REGISTRY_PATH),
                   help=f"Audit registry JSONL (default: {AUDIT_REGISTRY_PATH})")
    p.add_argument("--recipes", default=str(RECIPES_PATH),
                   help=f"Recipe store JSON (default: {RECIPES_PATH})")
    p.add_argument("--compare", action="store_true",
                   help="Print the side-by-side audit matrix and exit")
    p.add_argument("--list", action="store_true", help="Alias of --compare")
    p.add_argument("--report", default=None, metavar="LABEL",
                   help="Print one model's full audit detail and exit")
    p.add_argument("--now", default=None, help="Override timestamp_utc (ISO 8601)")
    p.add_argument("--extra-flags", nargs=argparse.REMAINDER, default=[],
                   help="Verbatim llama-server flags appended to EVERY spawn "
                        "(stage A cells and stage C). Must come LAST. e.g. "
                        "--extra-flags --reasoning off  (gemma E-series leaks "
                        "reasoning as prose without it — June 2026 lesson)")
    return p


# ═════════════════════════════════════════════════════════════════════════════
# IMPURE ORCHESTRATION (spawns servers, hits the bench port — NOT unit-tested)
# ═════════════════════════════════════════════════════════════════════════════

def _http_post_json(url: str, payload: dict, timeout: int = 240) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def chat_completion(port: int, messages: list[dict], sampling: Optional[dict] = None,
                    thinking: str = "none", max_tokens: int = 512,
                    tools: Optional[list[dict]] = None, timeout: int = 240,
                    seed: Optional[int] = None) -> dict:
    """Non-streaming /v1/chat/completions; returns the response message dict.

    ``seed`` pins llama-server's sampler RNG for the request (pass
    case_seed(case_id) on every sampling-sensitive call — 2026-07-16 era).
    None omits the key (extraction/domain pin their own seed downstream).
    """
    payload: dict = {"model": "bench", "messages": messages,
                     "max_tokens": max_tokens, "stream": False}
    payload.update(sampling or {})
    payload.update(thinking_request_kwargs(thinking))
    if seed is not None:
        payload["seed"] = int(seed)
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    try:
        body = _http_post_json(f"http://127.0.0.1:{port}/v1/chat/completions",
                               payload, timeout=timeout)
        return body["choices"][0]["message"]
    except Exception as e:  # noqa: BLE001 — bench robustness: record, never crash
        return {"content": f"__ERROR__: {e}", "tool_calls": None}


def _message_text(message: dict) -> str:
    return message.get("content") or message.get("reasoning_content") or ""


def wait_vram_drain(baseline: Optional[int],
                    delta_mib: int = VRAM_DRAIN_DELTA_MIB,
                    timeout_s: int = 60) -> None:
    """Block until GPU memory is back near baseline (like gpu_bench_phase2)."""
    import brain_bench as bb
    floor = (baseline or 0) + delta_mib
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        vram, _ = bb.query_vram()
        if vram is None or vram <= floor:
            return
        time.sleep(2)
    print(f"  WARNING: VRAM did not drain to <{floor} MiB in {timeout_s}s; "
          "continuing anyway", flush=True)


def _spawn_recipe_server(args, ngl: int, cpu_moe: bool, extra_flags: list[str],
                         with_mmproj: bool = True, ctx: Optional[int] = None):
    """Spawn one candidate server; returns (proc, healthy).

    ``ctx`` overrides args.ctx for this spawn only (the ctxprobe role launches
    the same config at two different context sizes)."""
    import brain_bench as bb
    # Global --extra-flags apply to EVERY spawn, after the per-cell flags.
    all_flags = list(extra_flags or []) + list(getattr(args, "extra_flags", None) or [])
    argv = bm.build_server_argv(
        server_bin=args.server_bin, gguf=args.gguf, ngl=ngl, cpu_moe=cpu_moe,
        ctx=ctx if ctx is not None else args.ctx, port=args.port,
        mmproj=args.mmproj if with_mmproj else None,
        extra_flags=all_flags)
    # Tripwire: refuse to spawn if something ALREADY answers on the bench port.
    # Otherwise our health poll could succeed against a foreign/dying server and
    # every quality role would silently measure the wrong process (this exact
    # failure produced a garbage 7.2% extraction score on 2026-07-15).
    if bm.http_ok(f"http://127.0.0.1:{args.port}/health"):
        raise RuntimeError(
            f"port {args.port} already serving before spawn — refusing to bench "
            "against an unknown server (kill the leftover process first)")
    # CPU-only spawns must hide the GPU: llama.cpp-cuda otherwise initializes a
    # CUDA context that can fail mid-request under prod VRAM pressure and abort
    # the server (see spawn_server docstring — the 2026-07-15 crater).
    proc = bm.spawn_server(argv, hide_gpu=(ngl == 0))
    healthy = bb.poll_health(args.port, timeout_s=180)
    # Tripwire: the health answer must come from OUR process. If our spawn died
    # (e.g. failed to bind) but the port still answers, that is a foreign server.
    if healthy and proc.poll() is not None:
        raise RuntimeError(
            f"spawned server exited (rc={proc.returncode}) but port {args.port} "
            "still answers — a foreign server is serving the bench port")
    return proc, healthy


def run_cell(args, cell: Cell, vram_baseline: Optional[int],
             n_prompts: int = 3) -> dict:
    """Stage A: spawn one cell, measure decode/TTFT/VRAM/RSS on short prompts."""
    import brain_bench as bb
    print(f"  [stage A] cell {cell.name} ...", flush=True)
    result: dict = {"cell": asdict(cell), "ok": False}
    proc, healthy = _spawn_recipe_server(args, cell.ngl, cell.cpu_moe,
                                         cell.to_extra_flags(), with_mmproj=False)
    if not healthy:
        bm.kill_server(proc)
        wait_vram_drain(vram_baseline)
        result["error"] = "health timeout (OOM or unsupported flags)"
        print(f"    -> FAILED: {result['error']}", flush=True)
        return result
    try:
        bb.stream_request(args.port, bb.BENCH_PROMPTS[0], max_tokens=64)  # warmup
        ttfts: list[float] = []
        decodes: list[float] = []
        for i in range(n_prompts):
            r = bb.stream_request(args.port,
                                  bb.BENCH_PROMPTS[i % len(bb.BENCH_PROMPTS)],
                                  max_tokens=96)
            if r.get("ttft_ms") is not None:
                ttfts.append(r["ttft_ms"])
            decodes.append(r.get("decode_toks_s") or 0.0)
        vram_after, _ = bb.query_vram()
        try:
            rss_mb = round(bb.read_proc_mem(proc.pid).get("VmRSS", 0) / 1024, 1)
        except Exception:
            rss_mb = None
        result.update({
            "ok": True,
            "decode_toks_s": round(statistics.mean(decodes), 2) if decodes else 0.0,
            "ttft_ms": round(statistics.median(ttfts), 1) if ttfts else None,
            "vram_delta_mib": (vram_after - (vram_baseline or 0))
                              if vram_after is not None else None,
            "rss_mb": rss_mb,
        })
        print(f"    -> decode={result['decode_toks_s']} tok/s "
              f"ttft={result['ttft_ms']}ms vramΔ={result['vram_delta_mib']}",
              flush=True)
    except Exception as e:  # noqa: BLE001 — a broken cell must not kill the sweep
        result["error"] = f"measurement failed: {e}"
        print(f"    -> FAILED: {result['error']}", flush=True)
    finally:
        bm.kill_server(proc)
        wait_vram_drain(vram_baseline)
    return result


def run_stage_a(args, tier: str, moe: bool,
                vram_baseline: Optional[int]) -> tuple[Optional[dict], list[dict]]:
    grid = build_stage_a_grid(tier, moe, quick=args.quick)
    print(f"[stage A] tier={tier} — sweeping {len(grid)} cells", flush=True)
    results = [run_cell(args, c, vram_baseline) for c in grid]
    winner = pareto_pick(results, tier)
    if winner is None and tier != "cpu":
        fb = oom_fallback_grid(grid)
        print(f"[stage A] full offload failed/over budget — retrying "
              f"{len(fb)} mid-ngl cells", flush=True)
        results += [run_cell(args, c, vram_baseline) for c in fb]
        winner = pareto_pick(results, tier)
    return winner, results


def run_stage_b(args, winner: dict, card_sampling: Optional[dict],
                thinking_modes: list[str],
                vram_baseline: Optional[int]) -> tuple[dict, list[dict]]:
    """Score sampling x thinking variants on the fast brain subset (det only)."""
    import cpu_sweep
    import subjective_judge as sj

    cases = cpu_sweep.load_golden_set(cpu_sweep.GOLDEN_SET_PATH)
    subset = select_fast_subset(cases)
    variants = build_stage_b_variants(card_sampling, thinking_modes)
    print(f"[stage B] {len(variants)} variants x {len(subset)} fast cases", flush=True)

    cell = cell_from_dict(winner["cell"])
    scored: list[dict] = []
    # Group variants by required server flags so we relaunch only when needed.
    by_flags: dict[tuple, list[dict]] = {}
    for v in variants:
        by_flags.setdefault(tuple(thinking_server_flags(v["thinking"])), []).append(v)

    for flags, group in by_flags.items():
        proc, healthy = _spawn_recipe_server(
            args, cell.ngl, cell.cpu_moe,
            cell.to_extra_flags() + list(flags), with_mmproj=False)
        if not healthy:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)
            for v in group:
                scored.append({**v, "det": None, "error": "health timeout"})
            continue
        try:
            max_tokens = 1024 if any(v["thinking"] != "off" and v["thinking"] != "none"
                                     for v in group) else 256
            for v in group:
                passed = 0
                for case in subset:
                    system = sj.get_system_prompt_for_case(case)
                    messages = ([{"role": "system", "content": system}] if system else []) \
                               + [{"role": "user", "content": case.get("prompt", "")}]
                    msg = chat_completion(args.port, messages,
                                          sampling=v["sampling"],
                                          thinking=v["thinking"],
                                          max_tokens=max_tokens,
                                          seed=case_seed(case.get("id")))
                    ok, _ = cpu_sweep.check_deterministic(case, _message_text(msg))
                    passed += 1 if ok else 0
                det = round(passed / len(subset), 4) if subset else 0.0
                scored.append({**v, "det": det})
                print(f"  [stage B] {v['name']}: det={det}", flush=True)
        finally:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)

    ranked = [s for s in scored if s.get("det") is not None]
    if not ranked:
        # Everything failed — fall back to house/none so Stage C can still run.
        fallback = {"name": "house-think_none", "sampling": dict(HOUSE_SAMPLING),
                    "thinking": "none", "det": None}
        return fallback, scored
    best_det = max(s["det"] for s in ranked)
    winner_variant = next(s for s in ranked if s["det"] == best_det)
    return winner_variant, scored


# ── Stage C roles ────────────────────────────────────────────────────────────

def run_brain_role(port: int, sampling: dict, thinking: str,
                   brain_max_tokens: int) -> dict:
    """bench_model's brain role, but honouring the recipe sampling + thinking."""
    import cpu_sweep
    import subjective_judge as sj

    all_cases = sj.load_golden_set(sj.GOLDEN_SET_PATH)
    rubric_cases = [c for c in all_cases if c.get("rubric")]
    max_tokens = brain_max_tokens or (1024 if thinking in ("on", "budget512") else 200)
    print(f"  [brain] {len(all_cases)} cases ({len(rubric_cases)} rubric), "
          f"max_tokens={max_tokens}", flush=True)

    responses: dict[str, str] = {}
    passed = 0
    for i, case in enumerate(all_cases):
        system = sj.get_system_prompt_for_case(case)
        messages = ([{"role": "system", "content": system}] if system else []) \
                   + [{"role": "user", "content": case.get("prompt", "")}]
        msg = chat_completion(port, messages, sampling=sampling,
                              thinking=thinking, max_tokens=max_tokens,
                              seed=case_seed(case.get("id")))
        text = _message_text(msg)
        responses[case["id"]] = text
        ok, _ = cpu_sweep.check_deterministic(case, text)
        passed += 1 if ok else 0
        print(f"  [brain {i + 1}/{len(all_cases)}] {case['id']}: "
              f"{'PASS' if ok else 'FAIL'}", flush=True)
    det = round(passed / len(all_cases), 4) if all_cases else 0.0

    if sj.http_get_status(f"http://127.0.0.1:{bm.JUDGE_PORT}/health") != 200:
        note = f"subjective skipped: 35B judge not healthy on {bm.JUDGE_PORT}"
        print(f"  [brain] {note}", flush=True)
        return {"det": det, "subj": None, "final": None, "note": note,
                "n_cases": len(all_cases), "n_rubric": len(rubric_cases)}

    subj_scores: list[float] = []
    for case in rubric_cases:
        resp = responses.get(case["id"], "")
        if not resp or resp.startswith("__ERROR__"):
            subj_scores.append(0.0)
            continue
        subj_scores.append(sj.judge_response(case, resp)["weighted_score"])
    subj = round(sum(subj_scores) / len(subj_scores), 4) if subj_scores else 0.0
    return {"det": det, "subj": subj, "final": bm.final_score(det, subj),
            "note": None, "n_cases": len(all_cases), "n_rubric": len(rubric_cases)}


def run_domain_role(port: int) -> dict:
    """domain_classification golden set through the production layer routing.

    Mirrors lifeos.agents.eval._run_eval: regex-layer cases go through
    parse_finance (nano never sees them in prod); nano/guard cases hit the
    candidate via extractor.extract() at LIFEOS_NANO_ENDPOINT = bench port.
    """
    os.environ["LIFEOS_NANO_ENDPOINT"] = f"http://127.0.0.1:{port}"
    if str(bm.LIFEOS_SRC) not in sys.path:
        sys.path.insert(0, str(bm.LIFEOS_SRC))

    from lifeos.agents.eval import scoring
    from lifeos.agents import extractor
    from lifeos.finance.ingestion import parse_finance, FinanceIntent

    cases = scoring.load_golden_set(GOLDEN_DIR / "domain_classification.jsonl")
    print(f"  [domain] {len(cases)} cases via {os.environ['LIFEOS_NANO_ENDPOINT']}",
          flush=True)
    predictions: list[Optional[str]] = []
    for i, case in enumerate(cases, 1):
        if case.layer == "regex":
            pred = "finance" if isinstance(parse_finance(case.text), FinanceIntent) else None
        else:
            result = extractor.extract(case.text)
            pred = result.domain if result is not None else None
        predictions.append(pred)
        if i % 15 == 0:
            print(f"  [domain {i}/{len(cases)}]", flush=True)

    scores = scoring.score_by_layer(predictions, cases)
    nano = scores.get("nano")
    return {
        "overall_accuracy": round(scores["overall"].accuracy, 4),
        "nano_accuracy": round(nano.accuracy, 4) if nano else None,
        "per_layer": {k: round(v.accuracy, 4) for k, v in scores.items()},
        "n": len(cases),
    }


def run_toolcall_role(port: int, sampling: dict, thinking: str) -> dict:
    """tool_calling.jsonl through /v1/chat/completions with OpenAI tools."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "tool_calling.jsonl")
    print(f"  [toolcall] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        tools = [TOOL_SCHEMAS[name] for name in case.get("tools", [])
                 if name in TOOL_SCHEMAS]
        msg = chat_completion(port, case["messages"], sampling=sampling,
                              thinking=thinking, max_tokens=256, tools=tools,
                              seed=case_seed(case.get("id")))
        per_case.append(score_toolcall_case(case, msg))
    agg = aggregate_toolcall(per_case)
    print(f"  [toolcall] tool={agg['correct_tool_rate']:.0%} "
          f"args={agg['arg_accuracy']:.0%} false-call={agg['false_call_rate']:.0%}",
          flush=True)
    return agg


def run_vision_role(port: int, mmproj: Optional[str],
                    sampling: dict, thinking: str) -> dict:
    """vision_quality.jsonl with base64 image_url parts; needs --mmproj."""
    if not mmproj:
        note = "vision skipped: no --mmproj provided"
        print(f"  [vision] {note}", flush=True)
        return {"skipped": note}
    try:
        ensure_vision_assets()
    except Exception as e:  # noqa: BLE001 — record, don't crash the audit
        note = f"vision skipped: could not generate assets ({e})"
        print(f"  [vision] {note}", flush=True)
        return {"skipped": note}

    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "vision_quality.jsonl")
    print(f"  [vision] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        image_path = GOLDEN_DIR / case["image"]
        b64 = base64.b64encode(image_path.read_bytes()).decode()
        content = [
            {"type": "text", "text": case["question"]},
            {"type": "image_url",
             "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ]
        msg = chat_completion(port, [{"role": "user", "content": content}],
                              sampling=sampling, thinking=thinking, max_tokens=128,
                              seed=case_seed(case.get("id")))
        per_case.append(score_vision_case(case, _message_text(msg)))
    agg = aggregate_pass_rate(per_case)
    print(f"  [vision] pass={agg['pass_rate']:.0%}", flush=True)
    return agg


CODEREVIEW_PROMPT = (
    "Eres un revisor de código experto. Revisa el siguiente código {lang} y "
    "reporta cualquier bug que encuentres, explicando brevemente cada uno.\n"
    "Si el código NO tiene bugs, responde exactamente: SIN BUGS.\n\n"
    "```{lang}\n{snippet}\n```"
)


def run_codereview_role(port: int, sampling: dict, thinking: str) -> dict:
    """code_review.jsonl: planted-bug detection + clean-snippet false positives."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "code_review.jsonl")
    print(f"  [codereview] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        prompt = CODEREVIEW_PROMPT.format(lang=case.get("lang", ""),
                                          snippet=case.get("snippet", ""))
        msg = chat_completion(port, [{"role": "user", "content": prompt}],
                              sampling=sampling, thinking=thinking, max_tokens=384,
                              seed=case_seed(case.get("id")))
        per_case.append(score_codereview_case(case, _message_text(msg)))
    agg = aggregate_codereview(per_case)
    print(f"  [codereview] detect={agg['detection_rate']:.0%} "
          f"false-pos={agg['false_positive_rate']:.0%}", flush=True)
    return agg


def run_codegen_role(port: int, sampling: dict, thinking: str) -> dict:
    """code_generation.jsonl: model writes code, harness EXECUTES it (sandboxed)."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "code_generation.jsonl")
    print(f"  [codegen] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        msg = chat_completion(
            port,
            [{"role": "system", "content": CODEGEN_SYSTEM},
             {"role": "user", "content": case.get("prompt", "")}],
            sampling=sampling, thinking=thinking, max_tokens=768,
            seed=case_seed(case.get("id")))
        code = extract_code_block(_message_text(msg))
        exec_result = None
        if code and code_compiles(code):
            harness = build_codegen_harness(case, code)
            exec_result = execute_codegen_harness(harness,
                                                  case.get("timeout_s", 10))
        result = score_codegen_case(case, code, exec_result)
        print(f"  [codegen] {case.get('id')}: "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    agg = aggregate_codegen(per_case)
    print(f"  [codegen] pass={agg['pass_rate']:.0%} "
          f"compile={agg['compile_rate']:.0%}", flush=True)
    return agg


def judge_conversation_case(case: dict, response: str) -> dict:
    """One judge call (port 8080) scored against the case's own rubric."""
    import subjective_judge as sj
    prompt = build_conversation_judge_prompt(case, response)
    criteria = (case.get("rubric") or {}).get("criteria") or []

    def call_judge() -> str:
        body = _http_post_json(
            f"http://127.0.0.1:{bm.JUDGE_PORT}/v1/chat/completions",
            {"model": "judge",
             "messages": [{"role": "system", "content": sj.JUDGE_SYSTEM_PROMPT},
                          {"role": "user", "content": prompt}],
             "max_tokens": 200, "temperature": 0.0, "seed": 0, "stream": False,
             "chat_template_kwargs": {"enable_thinking": False}},
            timeout=120)
        msg = body["choices"][0]["message"]
        return msg.get("content") or msg.get("reasoning_content") or ""

    raw = ""
    parsed = None
    for _attempt in range(2):
        try:
            raw = call_judge()
        except Exception as e:  # noqa: BLE001 — bench robustness: record, don't crash
            raw = f"__JUDGE_ERROR__: {e}"
            break
        parsed = sj._parse_judge_json(raw)
        if parsed is not None:
            break
        time.sleep(1)
    if parsed is None:
        return {"weighted_score": 0.0, "note": f"parse_error: {raw[:100]}",
                "error": True}
    return {"weighted_score": weighted_rubric_score(criteria, parsed),
            "note": parsed.get("note", "")}


def run_conversation_role(port: int, sampling: dict, thinking: str) -> dict:
    """conversation_quality.jsonl: is Axi PLEASANT to talk to?

    Candidate reply at the recipe sampling/thinking (same as brain), judged by
    the prod 35B (port 8080) against each case's own rubric — plus two
    deterministic judge-free checks (Spanish reply, non-empty + sane length).
    Judge unhealthy → judge layer skipped with a recorded note, like brain.
    """
    import cpu_sweep
    import subjective_judge as sj
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "conversation_quality.jsonl")
    judge_healthy = sj.http_get_status(
        f"http://127.0.0.1:{bm.JUDGE_PORT}/health") == 200
    note = None if judge_healthy else \
        f"judge skipped: 35B judge not healthy on {bm.JUDGE_PORT}"
    if note:
        print(f"  [conversation] {note}", flush=True)
    print(f"  [conversation] {len(cases)} cases", flush=True)

    per_case: list[dict] = []
    for case in cases:
        msg = chat_completion(port, case["messages"], sampling=sampling,
                              thinking=thinking, max_tokens=256,
                              seed=case_seed(case.get("id")))
        text = _message_text(msg)
        det = check_conversation_deterministic(text)
        row = {"id": case.get("id"), **det, "judge_score": None}
        if judge_healthy:
            # Empty / errored / bloated replies score 0 without wasting a judge
            # call (mirrors brain's zero for missing responses).
            row["judge_score"] = (judge_conversation_case(case, text)
                                  .get("weighted_score", 0.0)
                                  if det["sane"] else 0.0)
        print(f"  [conversation] {row['id']}: es={det['spanish']} "
              f"sane={det['sane']} judge={row['judge_score']}", flush=True)
        per_case.append(row)
    agg = aggregate_conversation(per_case, note=note)
    js = agg.get("judge_score")
    print(f"  [conversation] judge={js if js is not None else '-'} "
          f"spanish={agg['spanish_rate']:.0%}", flush=True)
    return agg


def run_recordsqa_role(port: int, sampling: dict, thinking: str) -> dict:
    """records_qa.jsonl: grounded records QA in the domain_chat prompt shape."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "records_qa.jsonl")
    print(f"  [recordsqa] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        system = build_recordsqa_system(case)
        msg = chat_completion(
            port,
            [{"role": "system", "content": system},
             {"role": "user", "content": case.get("question", "")}],
            sampling=sampling, thinking=thinking, max_tokens=400,
            seed=case_seed(case.get("id")))
        result = score_recordsqa_case(case, _message_text(msg))
        print(f"  [recordsqa] {result['id']}: "
              f"{'PASS' if result['passed'] else 'FAIL'}"
              + (f" fabricated={result['fabricated']}"
                 if result["fabricated"] else ""), flush=True)
        per_case.append(result)
    agg = aggregate_recordsqa(per_case)
    print(f"  [recordsqa] pass={agg['pass_rate']:.0%} "
          f"fabrication={agg['fabrication_rate']:.0%}", flush=True)
    return agg


def run_narration_role(port: int, sampling: dict, thinking: str) -> dict:
    """digest_narration.jsonl: numeric fidelity + structure, plus the warmth
    rubric judge (prod 35B) when healthy — judge-absent skips with a note."""
    import cpu_sweep
    import subjective_judge as sj
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "digest_narration.jsonl")
    judge_healthy = sj.http_get_status(
        f"http://127.0.0.1:{bm.JUDGE_PORT}/health") == 200
    note = None if judge_healthy else \
        f"judge skipped: 35B judge not healthy on {bm.JUDGE_PORT}"
    if note:
        print(f"  [narration] {note}", flush=True)
    print(f"  [narration] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        msg = chat_completion(
            port,
            [{"role": "system", "content": NARRATION_SYSTEM},
             {"role": "user", "content": case.get("facts_text", "")}],
            sampling=sampling, thinking=thinking, max_tokens=320,
            seed=case_seed(case.get("id")))
        text = _message_text(msg)
        row = score_narration_case(case, text)
        if judge_healthy:
            row["judge_score"] = (judge_conversation_case(
                narration_judge_case(case), text).get("weighted_score", 0.0)
                if text.strip() and not text.startswith("__ERROR__") else 0.0)
        print(f"  [narration] {row['id']}: fidelity={row['numeric_fidelity']} "
              f"structure={row['structure']} judge={row['judge_score']}",
              flush=True)
        per_case.append(row)
    agg = aggregate_narration(per_case, note=note)
    print(f"  [narration] fidelity={agg['numeric_fidelity_rate']:.0%} "
          f"structure={agg['structure_rate']:.0%}", flush=True)
    return agg


def run_longsum_role(port: int, sampling: dict, thinking: str, ctx: int) -> dict:
    """long_summarization.jsonl: planted-atom recall on meeting-window,
    executive and chat-archive prompts. Long prompts that cannot fit the
    recipe ctx (chars > ctx*3) are skipped with a note, never truncated."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "long_summarization.jsonl")
    print(f"  [longsum] {len(cases)} cases (ctx={ctx})", flush=True)
    per_case: list[dict] = []
    skipped_ids: list = []
    max_tokens_by_kind = {"meeting_window": 600, "executive": 2048,
                          "chat_archive": 400}
    for case in cases:
        system, user = build_longsum_prompt(case)
        prompt_chars = len(user) + len(system or "")
        if not longsum_case_fits_ctx(prompt_chars, ctx):
            skipped_ids.append(case.get("id"))
            print(f"  [longsum] {case.get('id')}: SKIP "
                  f"({prompt_chars} chars > ctx*{LONGSUM_CTX_CHARS_PER_TOKEN})",
                  flush=True)
            continue
        messages = ([{"role": "system", "content": system}] if system else []) \
                   + [{"role": "user", "content": user}]
        msg = chat_completion(
            port, messages, sampling=sampling, thinking=thinking,
            max_tokens=max_tokens_by_kind.get(case.get("kind"), 600),
            seed=case_seed(case.get("id")))
        result = score_longsum_case(case, _message_text(msg))
        print(f"  [longsum] {result['id']}: recall={result['atom_recall']} "
              f"structure={result['structure_ok']} "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    note = (f"{len(skipped_ids)} case(s) skipped: prompt exceeds ctx*"
            f"{LONGSUM_CTX_CHARS_PER_TOKEN} chars" if skipped_ids else None)
    agg = aggregate_longsum(per_case, skipped_ids=skipped_ids, note=note)
    print(f"  [longsum] atom_recall={agg['atom_recall']:.0%} "
          f"pass={agg['pass_rate']:.0%}", flush=True)
    return agg


def run_parsejson_role(port: int, sampling: dict, thinking: str) -> dict:
    """structured_parsing.jsonl: the strict JSON/label parsing fallbacks
    (when / schedule / voice_intent / graph_facts / coreference)."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "structured_parsing.jsonl")
    print(f"  [parsejson] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        system = case.get("system")
        messages = ([{"role": "system", "content": system}] if system else []) \
                   + [{"role": "user", "content": case.get("prompt", "")}]
        msg = chat_completion(port, messages, sampling=sampling,
                              thinking=thinking,
                              max_tokens=case.get("max_tokens", 256),
                              seed=case_seed(case.get("id")))
        result = score_parsejson_case(case, _message_text(msg))
        print(f"  [parsejson] {result['id']}: "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    agg = aggregate_parsejson(per_case)
    print(f"  [parsejson] pass={agg['pass_rate']:.0%} "
          f"negatives={agg['negative_pass_rate']:.0%} "
          f"json={agg['json_valid_rate']:.0%}", flush=True)
    return agg


def run_agentic_role(port: int, sampling: dict, thinking: str) -> dict:
    """agentic_research.jsonl: REAL multi-round tool loop against the candidate
    (canned web_search/web_fetch handlers, <=5 rounds, forced synthesis).

    Fidelity: sampling and max_tokens are PINNED to what production's tool
    loop would send to any model serving the brain port — brain._base_payload
    (engine='4b'): temp 0.7 / top_p 0.8 / top_k 20, and
    briefing.run_agentic_briefing max_tokens=4096. The caller's house/recipe
    sampling is intentionally ignored for this role: the production loop never
    consults per-model recipes, so neither may the audit.
    """
    del sampling  # see docstring — the prod tool loop pins its own sampling
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "agentic_research.jsonl")
    print(f"  [agentic] {len(cases)} cases (max {AGENTIC_MAX_ROUNDS} tool "
          f"rounds, prod sampling {AGENTIC_PROD_SAMPLING}, "
          f"max_tokens={AGENTIC_MAX_TOKENS})", flush=True)

    def make_chat_fn(seed: int):
        # Per-case seed: every round of one case samples with the same pinned
        # seed; different cases differ (2026-07-16 seed era).
        def chat_fn(messages: list[dict], tools: Optional[list[dict]]) -> dict:
            return chat_completion(port, messages,
                                   sampling=AGENTIC_PROD_SAMPLING,
                                   thinking=thinking,
                                   max_tokens=AGENTIC_MAX_TOKENS, tools=tools,
                                   seed=seed)
        return chat_fn

    per_case: list[dict] = []
    for case in cases:
        loop_result = run_agentic_loop(case, make_chat_fn(case_seed(case.get("id"))))
        result = score_agentic_case(case, loop_result)
        print(f"  [agentic] {result['id']}: rounds={result['rounds']} "
              f"tools={result['tools_ok']} json={result['json_valid']} "
              f"{'PASS' if result['passed'] else 'FAIL'}"
              + (f" missing={result['facts_missing']}"
                 if result["facts_missing"] else "")
              + (f" forbidden={result['facts_forbidden']}"
                 if result["facts_forbidden"] else ""), flush=True)
        per_case.append(result)
    agg = aggregate_agentic(per_case)
    print(f"  [agentic] pass={agg['pass_rate']:.0%} "
          f"tools={agg['tool_correct_rate']:.0%} "
          f"json={agg['json_valid_rate']:.0%} rounds={agg['mean_rounds']}",
          flush=True)
    return agg


def run_toolstress_role(port: int, sampling: dict, thinking: str) -> dict:
    """tool_stress.jsonl: MCP-style tool-protocol robustness. Multi-round loop
    (agentic-role plumbing) with the full ~13-tool confusable registry offered
    every round, canned handlers (incl. planted first-call errors), <=6 tool
    rounds, forced wrap-up. Deterministic scoring per kind: selection /
    nested_args / error_recovery / procedure."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "tool_stress.jsonl")
    print(f"  [toolstress] {len(cases)} cases (max {TOOLSTRESS_MAX_ROUNDS} "
          f"tool rounds, {len(TOOLSTRESS_REGISTRY)} tools offered)",
          flush=True)

    def make_chat_fn(seed: int):
        # Per-case seed, same policy as the agentic loop (2026-07-16 era).
        def chat_fn(messages: list[dict], tools: Optional[list[dict]]) -> dict:
            return chat_completion(port, messages, sampling=sampling,
                                   thinking=thinking,
                                   max_tokens=TOOLSTRESS_MAX_TOKENS,
                                   tools=tools, seed=seed)
        return chat_fn

    per_case: list[dict] = []
    for case in cases:
        result = score_toolstress_case(
            case, run_toolstress_loop(case,
                                      make_chat_fn(case_seed(case.get("id")))))
        print(f"  [toolstress] {result['id']} ({result['kind']}): "
              f"rounds={result['rounds']} "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    agg = aggregate_toolstress(per_case)
    print(f"  [toolstress] pass={agg['pass_rate']:.0%} "
          f"sel={agg['tool_selection_rate']:.0%} "
          f"args={agg['arg_exactness_rate']:.0%} "
          f"recov={agg['recovery_rate']:.0%} "
          f"proc={agg['procedure_rate']:.0%}", flush=True)
    return agg


def run_proactive_role(port: int, sampling: dict, thinking: str) -> dict:
    """proactive_thought.jsonl: the production reflection/elicitation prompt
    verbatim as the user turn (max_tokens=150 like cron's _brain_ask)."""
    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "proactive_thought.jsonl")
    print(f"  [proactive] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        msg = chat_completion(
            port, [{"role": "user", "content": case.get("context_block", "")}],
            sampling=sampling, thinking=thinking, max_tokens=150,
            seed=case_seed(case.get("id")))
        result = score_proactive_case(case, _message_text(msg))
        print(f"  [proactive] {result['id']}: verdict={result['verdict']} "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    agg = aggregate_proactive(per_case)
    print(f"  [proactive] restraint={agg['restraint_rate']:.0%} "
          f"speak={agg['speak_pass_rate']:.0%} pass={agg['pass_rate']:.0%}",
          flush=True)
    return agg


def run_visionclass_role(port: int, mmproj: Optional[str],
                         sampling: dict, thinking: str) -> dict:
    """vision_classification.jsonl: posture-style strict-JSON classification
    over deterministic PIL scenes; needs --mmproj (skips with a note)."""
    if not mmproj:
        note = "visionclass skipped: no --mmproj provided"
        print(f"  [visionclass] {note}", flush=True)
        return {"skipped": note}
    try:
        ensure_posture_assets()
    except Exception as e:  # noqa: BLE001 — record, don't crash the audit
        note = f"visionclass skipped: could not generate assets ({e})"
        print(f"  [visionclass] {note}", flush=True)
        return {"skipped": note}

    import cpu_sweep
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "vision_classification.jsonl")
    print(f"  [visionclass] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        image_path = GOLDEN_DIR / case["image"]
        b64 = base64.b64encode(image_path.read_bytes()).decode()
        content = [
            {"type": "text", "text": VISIONCLASS_PROMPT_ES},
            {"type": "image_url",
             "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ]
        msg = chat_completion(port, [{"role": "user", "content": content}],
                              sampling=sampling, thinking=thinking,
                              max_tokens=200, seed=case_seed(case.get("id")))
        result = score_visionclass_case(case, _message_text(msg))
        print(f"  [visionclass] {result['id']}: "
              f"json={result['json_valid']} label={result['label_correct']} "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    agg = aggregate_visionclass(per_case)
    print(f"  [visionclass] label={agg['label_accuracy']:.0%} "
          f"json={agg['json_valid_rate']:.0%} pass={agg['pass_rate']:.0%}",
          flush=True)
    return agg


def run_devplan_role(port: int, sampling: dict, thinking: str) -> dict:
    """dev_planning.jsonl: director-instruction authoring (keyword classes +
    optional actionability rubric via the prod 35B judge) and DONE/NOT DONE
    goal-satisfaction review, mirroring dev_director's English prompts."""
    import cpu_sweep
    import subjective_judge as sj
    cases = cpu_sweep.load_golden_set(GOLDEN_DIR / "dev_planning.jsonl")
    judge_healthy = sj.http_get_status(
        f"http://127.0.0.1:{bm.JUDGE_PORT}/health") == 200
    note = None if judge_healthy else \
        f"judge skipped: 35B judge not healthy on {bm.JUDGE_PORT}"
    if note:
        print(f"  [devplan] {note}", flush=True)
    print(f"  [devplan] {len(cases)} cases", flush=True)
    per_case: list[dict] = []
    for case in cases:
        if case.get("kind") == "instruction":
            msg = chat_completion(
                port,
                [{"role": "system", "content": DEVPLAN_DIRECTOR_SYSTEM},
                 {"role": "user", "content": f"Goal: {case.get('goal', '')}"}],
                sampling=sampling, thinking=thinking, max_tokens=600,
                seed=case_seed(case.get("id")))
            text = _message_text(msg)
            result = score_devplan_instruction(case, text)
            if judge_healthy and case.get("rubric"):
                result["judge_score"] = (judge_conversation_case(
                    devplan_judge_case(case), _devplan_strip_think(text))
                    .get("weighted_score", 0.0)
                    if text.strip() and not text.startswith("__ERROR__")
                    else 0.0)
        else:
            # Mirror dev_director._review's user-message shape exactly.
            review_user = (f"Goal: {case.get('goal', '')}\n\n"
                           f"Diff:\n{case.get('diff', '')}")
            if case.get("tests_output") is not None:
                review_user += f"\n\nTest results:\n{case['tests_output']}"
            msg = chat_completion(
                port,
                [{"role": "system", "content": DEVPLAN_REVIEWER_SYSTEM},
                 {"role": "user", "content": review_user}],
                sampling=sampling, thinking=thinking, max_tokens=300,
                seed=case_seed(case.get("id")))
            result = score_devplan_review(case, _message_text(msg))
        print(f"  [devplan] {result['id']} ({result['kind']}): "
              f"{'PASS' if result['passed'] else 'FAIL'}", flush=True)
        per_case.append(result)
    agg = aggregate_devplan(per_case, note=note)
    print(f"  [devplan] instr={agg['instruction_pass_rate']:.0%} "
          f"review={agg['review_accuracy']:.0%} pass={agg['pass_rate']:.0%}",
          flush=True)
    return agg


def run_embed_role(args, recipe: dict, vram_baseline: Optional[int]) -> dict:
    """Separate --embedding spawn: latency + tiny cosine retrieval sanity."""
    launch = recipe.get("launch") or {}
    proc, healthy = _spawn_recipe_server(
        args, launch.get("ngl", 0), launch.get("cpu_moe", False),
        list(launch.get("extra_flags") or []) + ["--embedding"],
        with_mmproj=False)
    if not healthy:
        bm.kill_server(proc)
        wait_vram_drain(vram_baseline)
        return {"skipped": "embed skipped: server unhealthy with --embedding"}
    try:
        def embed(text: str) -> tuple[Optional[list[float]], float]:
            t0 = time.monotonic()
            try:
                body = _http_post_json(
                    f"http://127.0.0.1:{args.port}/v1/embeddings",
                    {"model": "bench", "input": text}, timeout=60)
                vec = body["data"][0]["embedding"]
            except Exception:
                vec = None
            return vec, (time.monotonic() - t0) * 1000.0

        latencies: list[float] = []
        hits = 0
        total = 0
        for pair in EMBED_SANITY:
            qvec, lat = embed(pair["query"])
            latencies.append(lat)
            if qvec is None:
                continue
            sims = []
            for doc in pair["docs"]:
                dvec, dlat = embed(doc)
                latencies.append(dlat)
                sims.append(cosine(qvec, dvec) if dvec else -1.0)
            total += 1
            if sims and sims.index(max(sims)) == pair["best"]:
                hits += 1
        return {
            "latency_p50_ms": round(statistics.median(latencies), 1) if latencies else None,
            "retrieval_hits": hits,
            "retrieval_total": total,
            "retrieval_rate": round(hits / total, 4) if total else 0.0,
        }
    finally:
        bm.kill_server(proc)
        wait_vram_drain(vram_baseline)


def run_ctxprobe(args, launch: dict, vram_baseline: Optional[int],
                 tier: Optional[str] = None) -> dict:
    """ctx_max probe: two spawns of the SAME launch config at CTX_PROBE_LO and
    CTX_PROBE_HI, then linear KV extrapolation to every tier VRAM budget.

    Runs OUTSIDE the shared stage-C server lifecycle (like embed) because it
    owns its own spawns. Per-role isolation: any failure is recorded as a
    note/skip, never raised. ``tier`` (the audited tier) adds the scalar
    ``ctx_max_current`` used by --compare and the dashboard headline.
    """
    import brain_bench as bb
    ngl = launch.get("ngl", 0)
    if ngl == 0:
        return {"skipped": CTX_PROBE_NOTE_CPU}

    flags = list(launch.get("extra_flags") or [])

    def probe(ctx: int) -> tuple[str, Optional[float]]:
        """One spawn at ``ctx``; returns (status, vram_delta_mib)."""
        try:
            proc, healthy = _spawn_recipe_server(
                args, ngl, launch.get("cpu_moe", False), flags,
                with_mmproj=False, ctx=ctx)
        except Exception as e:  # noqa: BLE001 — bench robustness
            return f"spawn error: {e}", None
        try:
            if not healthy:
                return "health timeout (OOM or unsupported flags)", None
            vram, _ = bb.query_vram()
            if vram is None:
                return "no-gpu", None
            return "ok", float(vram - (vram_baseline or 0))
        finally:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)

    deltas: dict[int, float] = {}
    for ctx in (CTX_PROBE_LO, CTX_PROBE_HI):
        print(f"  [ctxprobe] spawn at ctx={ctx}", flush=True)
        status, delta = probe(ctx)
        if status == "no-gpu":
            return {"skipped": CTX_PROBE_NOTE_CPU}
        if delta is None:
            return {"note": f"probe spawn failed at ctx={ctx}: {status} — "
                            "ctx_max not measured"}
        deltas[ctx] = delta

    result = compute_ctx_probe(
        deltas[CTX_PROBE_LO], deltas[CTX_PROBE_HI],
        native_ctx=getattr(args, "native_ctx", None))
    result["ctx_max_current"] = (result.get("ctx_max") or {}).get(tier)
    print(f"  [ctxprobe] slope={result.get('slope_mib_per_1k_tokens')} "
          f"MiB/1k tok, weights≈{result.get('weights_vram_mib')} MiB, "
          f"ctx_max={result.get('ctx_max')}", flush=True)

    predicted = result["ctx_max_current"]
    if getattr(args, "ctx_verify", False) and predicted and predicted > 0:
        print(f"  [ctxprobe] verify spawn at predicted ctx_max={predicted}",
              flush=True)
        status, delta = probe(predicted)
        result["verify"] = {"ctx": predicted, "ok": status == "ok",
                            "vram_delta_mib": delta, "status": status}
    return result


def run_stage_c(args, recipe: dict, roles: list[str],
                vram_baseline: Optional[int],
                tier: Optional[str] = None) -> dict:
    """Full role suite at the peak recipe. Sequential; one server at a time."""
    launch = recipe.get("launch") or {}
    sampling = recipe.get("sampling") or dict(HOUSE_SAMPLING)
    thinking = recipe.get("thinking", "none")
    extra = list(launch.get("extra_flags") or []) + thinking_server_flags(thinking)

    results: dict = {}
    main_roles = [r for r in roles if r not in ("embed", "ctxprobe")]
    if main_roles:
        proc, healthy = _spawn_recipe_server(
            args, launch.get("ngl", 0), launch.get("cpu_moe", False), extra)
        if not healthy:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)
            raise RuntimeError("stage C server never became healthy at the recipe "
                               "launch config — recipe may be stale for this host")
        def _dispatch_role(role: str) -> None:
            if role == "speed":
                results["speed"] = bm.run_speed_role(args.port, proc.pid,
                                                     args.n_runs)
            elif role == "brain":
                results["brain"] = run_brain_role(args.port, sampling, thinking,
                                                  args.brain_max_tokens)
            elif role == "extraction":
                results["extraction"] = bm.run_extraction_role(args.port)
            elif role == "domain":
                results["domain"] = run_domain_role(args.port)
            elif role == "toolcall":
                results["toolcall"] = run_toolcall_role(args.port, sampling,
                                                        thinking)
            elif role == "vision":
                results["vision"] = run_vision_role(args.port, args.mmproj,
                                                    sampling, thinking)
            elif role == "codereview":
                results["codereview"] = run_codereview_role(args.port, sampling,
                                                            thinking)
            elif role == "codegen":
                results["codegen"] = run_codegen_role(args.port, sampling,
                                                      thinking)
            elif role == "conversation":
                results["conversation"] = run_conversation_role(
                    args.port, sampling, thinking)
            elif role == "recordsqa":
                results["recordsqa"] = run_recordsqa_role(args.port,
                                                          sampling, thinking)
            elif role == "narration":
                results["narration"] = run_narration_role(args.port,
                                                          sampling, thinking)
            elif role == "longsum":
                results["longsum"] = run_longsum_role(
                    args.port, sampling, thinking,
                    (launch.get("ctx") or args.ctx))
            elif role == "parsejson":
                results["parsejson"] = run_parsejson_role(args.port,
                                                          sampling, thinking)
            elif role == "agentic":
                results["agentic"] = run_agentic_role(args.port,
                                                      sampling, thinking)
            elif role == "proactive":
                results["proactive"] = run_proactive_role(args.port,
                                                          sampling, thinking)
            elif role == "visionclass":
                results["visionclass"] = run_visionclass_role(
                    args.port, args.mmproj, sampling, thinking)
            elif role == "devplan":
                results["devplan"] = run_devplan_role(args.port,
                                                      sampling, thinking)
            elif role == "toolstress":
                results["toolstress"] = run_toolstress_role(args.port,
                                                            sampling,
                                                            thinking)

        try:
            for role in main_roles:
                print(f"[stage C] role {role}", flush=True)
                try:
                    _dispatch_role(role)
                except Exception as role_exc:  # noqa: BLE001
                    # One broken role must NEVER kill the whole audit — the
                    # 2026-07-15 e4b run lost 15 finished roles when agentic
                    # raised. Record the error, keep going; the row still
                    # persists and the role can be backfilled later.
                    print(f"  [{role}] ERROR (recorded, audit continues): "
                          f"{role_exc}", flush=True)
                    results[role] = {"error": str(role_exc)[:300]}
        finally:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)

    if "embed" in roles:
        print("[stage C] role embed (separate --embedding spawn)", flush=True)
        results["embed"] = run_embed_role(args, recipe, vram_baseline)

    if "ctxprobe" in roles:
        print("[stage C] role ctxprobe (two separate KV-probe spawns)",
              flush=True)
        try:
            results["ctxprobe"] = run_ctxprobe(args, launch, vram_baseline,
                                               tier=tier)
        except Exception as role_exc:  # noqa: BLE001 — per-role isolation
            print(f"  [ctxprobe] ERROR (recorded, audit continues): "
                  f"{role_exc}", flush=True)
            results["ctxprobe"] = {"error": str(role_exc)[:300]}

    # Per-role sampling record: WITH WHICH config each score was earned
    # (registry answers "good WHERE and WITH WHAT config", not just "good").
    for role, res in results.items():
        if isinstance(res, dict) and "sampling_used" not in res:
            res["sampling_used"] = role_sampling_used(role, sampling, thinking)
    return results


# ── vision asset generation (PIL; deterministic, idempotent) ─────────────────

def ensure_vision_assets(assets_dir: Path = VISION_ASSETS_DIR) -> list[Path]:
    """Generate the tiny deterministic PNGs the vision golden set references.

    Requires Pillow (present in axi/.venv) ONLY when generation is needed.
    Idempotent: when every expected PNG already exists on disk, PIL is never
    imported — so the vision role also works from venvs without Pillow (the
    lifeos venv lacks it, which used to force a bogus 'skipped' note even
    though all assets were already generated). Solid shapes, a rendered word,
    and a 3-bar chart — trivially verifiable answers for a real VLM.
    """
    expected = [
        "red_square.png", "blue_circle.png", "green_triangle.png",
        "black_cross.png", "yellow_bg.png", "text_hola.png",
        "two_shapes.png", "bar_chart.png",
    ]
    existing = [assets_dir / n for n in expected]
    if all(p.exists() for p in existing):
        return existing

    from PIL import Image, ImageDraw

    assets_dir.mkdir(parents=True, exist_ok=True)
    made: list[Path] = []

    def build(name: str, painter) -> None:
        path = assets_dir / name
        if path.exists():
            return
        img = Image.new("RGB", (256, 256), (255, 255, 255))
        painter(ImageDraw.Draw(img), img)
        img.save(path, format="PNG")
        made.append(path)

    build("red_square.png",
          lambda d, im: d.rectangle([64, 64, 192, 192], fill=(220, 20, 20)))
    build("blue_circle.png",
          lambda d, im: d.ellipse([64, 64, 192, 192], fill=(20, 60, 220)))
    build("green_triangle.png",
          lambda d, im: d.polygon([(128, 48), (40, 208), (216, 208)],
                                  fill=(20, 160, 40)))

    def build_text(name: str) -> None:
        path = assets_dir / name
        if path.exists():
            return
        img = Image.new("RGB", (64, 56), (255, 255, 255))
        ImageDraw.Draw(img).text((10, 20), "HOLA", fill=(0, 0, 0))
        img = img.resize((256, 224), Image.NEAREST)  # chunky but crisp glyphs
        img.save(path, format="PNG")
        made.append(path)

    build_text("text_hola.png")

    def paint_bars(d, im) -> None:
        d.line([(24, 232), (232, 232)], fill=(0, 0, 0), width=3)  # x axis
        d.rectangle([48, 160, 88, 230], fill=(220, 20, 20))       # short
        d.rectangle([108, 96, 148, 230], fill=(20, 60, 220))      # medium
        d.rectangle([168, 40, 208, 230], fill=(20, 160, 40))      # tall

    build("bar_chart.png", paint_bars)

    def paint_two(d, im) -> None:
        d.rectangle([32, 80, 112, 176], fill=(220, 20, 20))
        d.ellipse([144, 80, 224, 176], fill=(20, 60, 220))

    build("two_shapes.png", paint_two)
    build("yellow_bg.png",
          lambda d, im: d.rectangle([0, 0, 256, 256], fill=(245, 205, 30)))

    def paint_cross(d, im) -> None:
        d.rectangle([112, 32, 144, 224], fill=(0, 0, 0))
        d.rectangle([32, 112, 224, 144], fill=(0, 0, 0))

    build("black_cross.png", paint_cross)
    return made


def ensure_posture_assets(assets_dir: Path = VISION_ASSETS_DIR) -> list[Path]:
    """Generate the deterministic posture-scene PNGs for the visionclass role.

    Same contract as ensure_vision_assets: idempotent, PIL imported ONLY when
    generation is needed. Each scene is a side-view desk (line) + chair with a
    stick figure whose spine/head geometry encodes the posture label:
    upright spine (good), curved forward spine + dropped head (slouched),
    straight spine + head far forward (forward_head), whole figure tilted
    (leaning), and an empty chair (not_at_desk).
    """
    expected = [
        "posture_good.png", "posture_slouched.png", "posture_forward_head.png",
        "posture_leaning.png", "posture_not_at_desk.png", "posture_good_2.png",
    ]
    existing = [assets_dir / n for n in expected]
    if all(p.exists() for p in existing):
        return existing

    from PIL import Image, ImageDraw

    assets_dir.mkdir(parents=True, exist_ok=True)
    made: list[Path] = []
    ink = (20, 20, 20)

    def scene(name: str, painter) -> None:
        path = assets_dir / name
        if path.exists():
            return
        img = Image.new("RGB", (256, 256), (255, 255, 255))
        d = ImageDraw.Draw(img)
        # Shared furniture, side view: desk slab (right) + chair seat (left).
        d.rectangle([150, 150, 246, 158], fill=(150, 100, 60))   # desk top
        d.rectangle([236, 158, 246, 236], fill=(150, 100, 60))   # desk leg
        d.rectangle([60, 176, 130, 184], fill=(90, 90, 90))      # chair seat
        d.rectangle([62, 184, 70, 236], fill=(90, 90, 90))       # chair leg
        painter(d)
        img.save(path, format="PNG")
        made.append(path)

    def figure(d, *, spine, head_center, arm) -> None:
        """Stick figure: spine polyline, head circle, one arm to the desk."""
        d.line(spine, fill=ink, width=6)
        hx, hy = head_center
        d.ellipse([hx - 16, hy - 16, hx + 16, hy + 16], outline=ink, width=5)
        d.line(arm, fill=ink, width=5)
        d.line([(95, 176), (120, 214), (150, 214)], fill=ink, width=5)  # leg

    scene("posture_good.png", lambda d: figure(
        d, spine=[(95, 176), (95, 96)], head_center=(95, 74),
        arm=[(95, 116), (150, 148)]))
    scene("posture_good_2.png", lambda d: figure(
        d, spine=[(90, 176), (90, 94)], head_center=(90, 72),
        arm=[(90, 118), (150, 146)]))
    scene("posture_slouched.png", lambda d: figure(
        d, spine=[(95, 176), (98, 140), (116, 116), (136, 106)],
        head_center=(150, 106), arm=[(116, 116), (156, 146)]))
    scene("posture_forward_head.png", lambda d: figure(
        d, spine=[(95, 176), (95, 100)], head_center=(138, 84),
        arm=[(95, 118), (150, 148)]))
    scene("posture_leaning.png", lambda d: figure(
        d, spine=[(95, 176), (58, 104)], head_center=(48, 82),
        arm=[(76, 140), (150, 150)]))
    scene("posture_not_at_desk.png", lambda d: None)
    return made


# ── entry point ──────────────────────────────────────────────────────────────

def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    registry_path = Path(args.registry)
    recipes_path = Path(args.recipes)

    if args.compare or args.list:
        print(build_audit_matrix(bm.load_registry(registry_path)))
        return 0
    if args.report:
        print(build_model_report(bm.load_registry(registry_path), args.report))
        return 0

    if not args.gguf or not args.label:
        print("ERROR: --gguf and --label are required "
              "(unless --compare/--list/--report).", file=sys.stderr)
        return 2
    if args.port in FORBIDDEN_PORTS:
        print(f"ERROR: refusing protected port {args.port} "
              f"(forbidden: {sorted(FORBIDDEN_PORTS)}).", file=sys.stderr)
        return 2
    if not Path(args.gguf).exists():
        print(f"ERROR: GGUF not found: {args.gguf}", file=sys.stderr)
        return 2
    if not Path(args.server_bin).exists():
        print(f"ERROR: server binary not found: {args.server_bin}", file=sys.stderr)
        return 2

    try:
        tiers = parse_tiers(args.tiers)
        roles = parse_audit_roles(args.roles)
        thinking_modes = parse_thinking_modes(args.thinking_modes)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    card_sampling = None
    if args.sampling:
        try:
            card_sampling = json.loads(args.sampling)
        except json.JSONDecodeError as e:
            print(f"ERROR: --sampling is not valid JSON: {e}", file=sys.stderr)
            return 2
    if "embed" in roles and not args.embedding:
        roles = [r for r in roles if r != "embed"]
    elif args.embedding and "embed" not in roles:
        roles.append("embed")

    moe = detect_moe(args.gguf, args.moe)
    import brain_bench as bb
    vram_baseline, _ = bb.query_vram()
    print(f"Audit: {args.label} | tiers={tiers} | roles={roles} | "
          f"moe={moe} | vram baseline={vram_baseline} MiB", flush=True)

    exit_code = 0
    for tier in tiers:
        print(f"\n{'#' * 70}\n#  TIER {tier}\n{'#' * 70}", flush=True)
        stage_a_cells: list[dict] = []
        stage_b_variants: list[dict] = []

        if args.use_recipe:
            recipe = get_recipe(load_recipes(recipes_path), args.label, tier)
            if recipe is None:
                print(f"ERROR: no saved recipe for {args.label}/{tier} in "
                      f"{recipes_path} — run once without --use-recipe.",
                      file=sys.stderr)
                exit_code = 1
                continue
            print(f"[recipe] using saved recipe from {recipes_path}", flush=True)
        else:
            winner, stage_a_cells = run_stage_a(args, tier, moe, vram_baseline)
            if winner is None:
                print(f"ERROR: no Stage-A cell fits tier {tier} "
                      f"(all failed or over budget) — skipping tier.",
                      file=sys.stderr)
                exit_code = 1
                continue
            if args.quick:
                variant = {"name": "house-think_" + thinking_modes[0],
                           "sampling": dict(HOUSE_SAMPLING),
                           "thinking": thinking_modes[0], "det": None}
            else:
                variant, stage_b_variants = run_stage_b(
                    args, winner, card_sampling, thinking_modes, vram_baseline)
            recipe = make_recipe(winner, variant, args.ctx, now=args.now)
            save_recipe(recipes_path, args.label, tier, recipe)
            print(f"[recipe] saved peak recipe for {args.label}/{tier} → "
                  f"{recipes_path}", flush=True)

        try:
            roles_results = run_stage_c(args, recipe, roles, vram_baseline,
                                        tier=tier)
        except RuntimeError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            exit_code = 1
            continue

        row = assemble_audit_row(
            label=args.label, tier=tier, gguf=args.gguf,
            server_bin=args.server_bin, recipe=recipe, roles=roles_results,
            stage_a_cells=stage_a_cells, stage_b_variants=stage_b_variants,
            now=args.now)
        bm.append_registry_row(registry_path, row)
        print(build_model_report([row], args.label))

    print("\n" + build_audit_matrix(bm.load_registry(registry_path)))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
