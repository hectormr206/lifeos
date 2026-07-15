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
conversation (judge-scored conversational pleasantness + Spanish checks).

BUILDS ON bench_model.py — spawn/kill/registry/scorer wiring is imported, not
rewritten. Reuses cpu_sweep.check_deterministic, subjective_judge, and
lifeos.agents.eval.scoring exactly like v1 does.

Safety: candidate servers run ONLY on --port (default 18080; 8080/8081/8082/
8090/8091 are refused), spawned with start_new_session=True and killed by
process group. Strictly sequential: one server at a time, VRAM must drain
(<500 MiB above baseline) between cells.

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
from dataclasses import dataclass, asdict, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── paths & reuse wiring ─────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import bench_model as bm  # v1 orchestrator — spawn/kill/registry/roles reused

RESULTS_DIR = SCRIPT_DIR / "results"
AUDIT_REGISTRY_PATH = RESULTS_DIR / "model_audit.jsonl"
RECIPES_PATH = RESULTS_DIR / "model_recipes.json"
GOLDEN_DIR = bm.LIFEOS_SRC / "lifeos" / "agents" / "eval" / "golden_sets"
VISION_ASSETS_DIR = GOLDEN_DIR / "vision_assets"

# Ports we must never spawn on (prod judge / nano / secondary prod / spares).
FORBIDDEN_PORTS = {8080, 8081, 8082, 8090, 8091}

# Tier VRAM budgets in MiB (max VRAM the candidate may occupy).
TIER_BUDGETS_MIB = {"cpu": 0, "vram4": 3500, "vram8": 7500, "vram12": 11000}

# House default sampling (our standard bench sampling).
HOUSE_SAMPLING = {"temperature": 0.6, "top_p": 0.95, "top_k": 20}

VALID_THINKING_MODES = ("none", "off", "on", "budget512")
VALID_ROLES = ("speed", "brain", "extraction", "domain", "toolcall",
               "vision", "codereview", "embed", "codegen", "conversation")

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


def build_audit_matrix(rows: list[dict], title: str = "MODEL AUDIT MATRIX") -> str:
    """Side-by-side matrix: newest row per label+tier, key metric per role."""
    latest = newest_per_label_tier(rows)
    bar = "=" * 132
    lines = [bar, f"  {title}  (newest audit per label+tier)", bar]
    lines.append(
        f"  {'Label':<20} {'tier':<7} {'brain':>6} {'extr%':>6} {'dom%':>6} "
        f"{'tool%':>6} {'vis%':>6} {'rev%':>6} {'code%':>6} {'conv':>6} "
        f"{'tok/s':>7} {'VRAM MiB':>9} {'thinking':<9}"
    )
    lines.append("  " + "-" * 128)
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
            f"{bm._fmt(speed.get('decode_p50_toks_s'), '7.1f')} "
            f"{bm._fmt(vram, '9.0f')} "
            f"{recipe.get('thinking', '-'):<9}"
        )
    lines.append(bar)
    return "\n".join(lines)


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
                           "vision,codegen,conversation",
                   help=f"Comma list from {list(VALID_ROLES)}; vision auto-skips "
                        "without --mmproj; embed needs --embedding")
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
                    tools: Optional[list[dict]] = None, timeout: int = 240) -> dict:
    """Non-streaming /v1/chat/completions; returns the response message dict."""
    payload: dict = {"model": "bench", "messages": messages,
                     "max_tokens": max_tokens, "stream": False}
    payload.update(sampling or {})
    payload.update(thinking_request_kwargs(thinking))
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
                         with_mmproj: bool = True):
    """Spawn one candidate server; returns (proc, healthy)."""
    import brain_bench as bb
    argv = bm.build_server_argv(
        server_bin=args.server_bin, gguf=args.gguf, ngl=ngl, cpu_moe=cpu_moe,
        ctx=args.ctx, port=args.port,
        mmproj=args.mmproj if with_mmproj else None,
        extra_flags=extra_flags)
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
                                          max_tokens=max_tokens)
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
                              thinking=thinking, max_tokens=max_tokens)
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
                              thinking=thinking, max_tokens=256, tools=tools)
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
                              sampling=sampling, thinking=thinking, max_tokens=128)
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
                              sampling=sampling, thinking=thinking, max_tokens=384)
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
            sampling=sampling, thinking=thinking, max_tokens=768)
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
             "max_tokens": 200, "temperature": 0.0, "stream": False,
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
                              thinking=thinking, max_tokens=256)
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


def run_stage_c(args, recipe: dict, roles: list[str],
                vram_baseline: Optional[int]) -> dict:
    """Full role suite at the peak recipe. Sequential; one server at a time."""
    launch = recipe.get("launch") or {}
    sampling = recipe.get("sampling") or dict(HOUSE_SAMPLING)
    thinking = recipe.get("thinking", "none")
    extra = list(launch.get("extra_flags") or []) + thinking_server_flags(thinking)

    results: dict = {}
    main_roles = [r for r in roles if r != "embed"]
    if main_roles:
        proc, healthy = _spawn_recipe_server(
            args, launch.get("ngl", 0), launch.get("cpu_moe", False), extra)
        if not healthy:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)
            raise RuntimeError("stage C server never became healthy at the recipe "
                               "launch config — recipe may be stale for this host")
        try:
            for role in main_roles:
                print(f"[stage C] role {role}", flush=True)
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
        finally:
            bm.kill_server(proc)
            wait_vram_drain(vram_baseline)

    if "embed" in roles:
        print("[stage C] role embed (separate --embedding spawn)", flush=True)
        results["embed"] = run_embed_role(args, recipe, vram_baseline)
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
            roles_results = run_stage_c(args, recipe, roles, vram_baseline)
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
