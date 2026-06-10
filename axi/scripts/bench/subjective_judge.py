#!/usr/bin/env python3
"""subjective_judge.py — Phase 2 subjective scoring via the local 35B judge.

Workflow:
  1. Load the golden set and identify the 6 subjective cases.
  2. For each candidate model, re-capture all 35 responses by spawning the
     model on BENCH_PORT (18080) — the results files only store failures.
  3. Call the 35B judge on JUDGE_PORT (8080) for the 6 subjective cases,
     getting per-criterion scores 0..1.
  4. Compute per-model subjective_score and final = 0.7*det + 0.3*subj.
  5. Write per-case JSONL to results/subjective_<model_id>.jsonl.
  6. Print a ranked summary table.

Safety rules (inherited from cpu_sweep.py):
  - BENCH_PORT = 18080 ONLY — never 8080 / 8090
  - JUDGE_PORT = 8080 — read-only inference; never touch that server
  - Sequential judge calls — no aggressive parallelism
  - CUDA_VISIBLE_DEVICES='' for spawned candidate servers
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request
import urllib.error
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
GOLDEN_SET_PATH = (
    Path(__file__).resolve().parents[3]
    / "lifeos" / "src" / "lifeos" / "agents" / "eval" / "golden_sets"
    / "brain_quality.jsonl"
)

BENCH_PORT = 18080  # candidate servers — NEVER 8080 or 8090
JUDGE_PORT = 8080   # read-only: prod 35B Qwen — never restart/stop

MODELS_DIR = Path("/home/hectormr/LifeOS/models")

# Candidate set (vision-capable only; matches cpu_sweep.py CANDIDATE_MODELS)
CANDIDATE_MODELS = [
    {
        "id": "qwen35-9b",
        "gguf": MODELS_DIR / "qwen35-9b/Qwen3.5-9B-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "qwen35-9b/mmproj-F16.gguf",
        "ctx": 32768,
        "disable_thinking": True,
    },
    {
        "id": "qwen35-4b",
        "gguf": MODELS_DIR / "qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "qwen35-4b/mmproj-F16.gguf",
        "ctx": 32768,
        "disable_thinking": True,
    },
    {
        "id": "qwen35-2b",
        "gguf": MODELS_DIR / "qwen35-2b/Qwen3.5-2B-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "qwen35-2b/mmproj-F16.gguf",
        "ctx": 32768,
        "disable_thinking": True,
    },
    {
        "id": "qwen35-0_8b",
        "gguf": MODELS_DIR / "qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "qwen35-0_8b/mmproj-F16.gguf",
        "ctx": 8192,
        "disable_thinking": True,
    },
    {
        "id": "gemma4-e4b-it",
        "gguf": MODELS_DIR / "gemma4-e4b-it/gemma-4-E4B-it-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "gemma4-e4b-it/mmproj-BF16.gguf",
        "ctx": 32768,
        "reasoning_off": True,
    },
    {
        "id": "gemma4-e2b-it",
        "gguf": MODELS_DIR / "gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "gemma4-e2b-it/mmproj-BF16.gguf",
        "ctx": 32768,
        "reasoning_off": True,
    },
    # ── large vision tier — CPU quality only, GPU perf deferred ──────────────
    {
        "id": "gemma4-26b-a4b-it",
        "gguf": MODELS_DIR / "gemma4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "gemma4-26b-a4b-it/mmproj-BF16.gguf",
        "ctx": 32768,
        "reasoning_off": True,
    },
    {
        "id": "nemotron3-nano-omni-30b-a3b",
        "gguf": MODELS_DIR / "nemotron3-nano-omni-30b-a3b/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "nemotron3-nano-omni-30b-a3b/mmproj-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16.gguf",
        "ctx": 32768,
        "reasoning_off": True,
    },
]

# Source files for deterministic scores — must use the authoritative corrected
# files where they exist.
DET_RESULT_FILES = {
    "gemma4-e2b-it":              RESULTS_DIR / "cpu-sweep_gemma4-e2b-it_corrected.jsonl",
    "gemma4-e4b-it":              RESULTS_DIR / "cpu-sweep_gemma4-e4b-it_corrected.jsonl",
    "qwen35-9b":                  RESULTS_DIR / "cpu-sweep_qwen35-9b_20260608T221129Z.jsonl",
    "qwen35-4b":                  RESULTS_DIR / "cpu-sweep_qwen35-4b_20260608T222146Z.jsonl",
    "qwen35-2b":                  RESULTS_DIR / "cpu-sweep_qwen35-2b_20260608T222752Z.jsonl",
    "qwen35-0_8b":                RESULTS_DIR / "cpu-sweep_qwen35-0_8b_20260608T223155Z.jsonl",
    # large tier — populated after cpu_sweep runs for these models
    "gemma4-26b-a4b-it":          None,  # will be set dynamically after sweep
    "nemotron3-nano-omni-30b-a3b": None,  # will be set dynamically after sweep
}

# ── system prompts (mirror cpu_sweep.py) ──────────────────────────────────────
SYSTEM_PROMPT = (
    "Sos Axi, un asistente de vida personal en español rioplatense. "
    "Respondé de forma concisa y útil. "
    f"Fecha y hora actual: {datetime.now().strftime('%A %d de %B de %Y, %H:%M')} "
    "(Argentina, UTC-3)."
)
REMINDER_SYSTEM_PROMPT = (
    "Parse the user's vague time expression and return ONLY a JSON object "
    "with the key 'when_iso' whose value is an ISO 8601 datetime string with timezone offset, "
    "or null if the time cannot be determined. No other text. No markdown. "
    f"Current time: {datetime.now().strftime('%Y-%m-%dT%H:%M:%S-03:00')} (Argentina, UTC-3)."
)


def get_system_prompt_for_case(case: dict) -> str:
    cat = case.get("category", "")
    if cat == "reminder_time":
        return REMINDER_SYSTEM_PROMPT
    elif cat == "intent_classification":
        return ""
    else:
        return SYSTEM_PROMPT


# ── golden set ────────────────────────────────────────────────────────────────

def load_golden_set(path: Path) -> list[dict]:
    cases = []
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("//") or s.startswith("#"):
            continue
        try:
            cases.append(json.loads(s))
        except json.JSONDecodeError:
            pass
    return cases


def load_deterministic_score(model_id: str) -> tuple[float, dict]:
    """Return (deterministic_score, perf_data) from the authoritative result file.

    For models where DET_RESULT_FILES has None, auto-discover the latest
    cpu-sweep_<model_id>_*.jsonl file in RESULTS_DIR.
    """
    path = DET_RESULT_FILES.get(model_id)
    if path is None:
        # Auto-discover: find the most recent sweep result for this model
        candidates = sorted(
            RESULTS_DIR.glob(f"cpu-sweep_{model_id}_*.jsonl"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if candidates:
            path = candidates[0]
            print(f"  [auto-discover] det result: {path.name}", flush=True)
        else:
            print(f"  [WARN] No det result file for {model_id} — run cpu_sweep first", file=sys.stderr)
            return 0.0, {}
    if not path.exists():
        print(f"  [WARN] No det result file for {model_id} at {path}", file=sys.stderr)
        return 0.0, {}
    with open(path) as f:
        data = json.loads(f.read())
    det_score = data.get("quality", {}).get("deterministic_score", 0.0)
    perf = data.get("perf", {})
    return det_score, perf


# ── HTTP helpers ──────────────────────────────────────────────────────────────

def http_get_status(url: str, timeout: int = 5) -> int:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def poll_health(port: int, timeout_s: int = 300) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if http_get_status(url) == 200:
            return True
        time.sleep(2)
    return False


def read_loadavg() -> float:
    return float(Path("/proc/loadavg").read_text().split()[0])


def wait_for_low_load(threshold: float = 2.0, max_wait: int = 120) -> float:
    deadline = time.monotonic() + max_wait
    while time.monotonic() < deadline:
        load = read_loadavg()
        if load <= threshold:
            return load
        print(f"  [load-wait] 1-min load={load:.2f} > {threshold} — waiting 10s...", flush=True)
        time.sleep(10)
    return read_loadavg()


def chat_sync(
    port: int,
    prompt: str,
    system: str = "",
    max_tokens: int = 512,
    temperature: float = 0.0,
    disable_thinking: bool = False,
) -> str:
    """Non-streaming chat request. Returns full response text."""
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload: dict = {
        "model": "bench",
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }
    if disable_thinking:
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            body = json.loads(resp.read())
        msg = body["choices"][0]["message"]
        return msg.get("content") or msg.get("reasoning_content") or ""
    except Exception as e:
        return f"__ERROR__: {e}"


# ── candidate server lifecycle ────────────────────────────────────────────────

def spawn_candidate_server(model_cfg: dict) -> tuple:
    """Spawn candidate model CPU-only on BENCH_PORT. Returns (proc, pid, error)."""
    gguf = str(model_cfg["gguf"])
    mmproj = model_cfg.get("mmproj")
    ctx = model_cfg.get("ctx", 8192)
    reasoning_off = model_cfg.get("reasoning_off", False)

    cmd = ["/usr/bin/llama-server", "-m", gguf]
    if mmproj:
        cmd += ["--mmproj", str(mmproj)]
    cmd += [
        "-ngl", "0",
        "--jinja",
        "--reasoning-format", "auto",
        "-c", str(ctx),
        "--host", "127.0.0.1",
        "--port", str(BENCH_PORT),
        "--cache-type-k", "q8_0",
        "--cache-type-v", "q8_0",
        "-fa", "on",
        "-b", "2048",
        "-ub", "512",
        "-t", "8",
        "-tb", "8",
        "--temp", "0.6",
        "--top-p", "0.95",
        "--top-k", "20",
        "--min-p", "0.0",
        "-np", "1",
        "--no-mmap",
        "--mlock",
    ]
    if reasoning_off:
        cmd += ["--reasoning", "off"]

    env = os.environ.copy()
    env["CUDA_VISIBLE_DEVICES"] = ""

    note = " --reasoning off" if reasoning_off else ""
    print(f"  Spawning: ...{Path(gguf).name} -ngl 0 --port {BENCH_PORT}{note}", flush=True)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    healthy = poll_health(BENCH_PORT, timeout_s=300)
    if not healthy:
        return proc, proc.pid, f"Server never healthy"
    return proc, proc.pid, None


def kill_server(proc, pid: int) -> None:
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
    time.sleep(3)


# ── response capture ──────────────────────────────────────────────────────────

def capture_all_responses(model_cfg: dict, golden_cases: list[dict]) -> dict[str, str]:
    """
    Spawn the candidate model and capture responses for ALL 35 golden cases.
    Returns {case_id: response_text}.
    """
    model_id = model_cfg["id"]
    disable_thinking = model_cfg.get("disable_thinking", False)

    wait_for_low_load()
    proc, pid, err = spawn_candidate_server(model_cfg)
    if err:
        print(f"  [ERROR] Failed to spawn {model_id}: {err}", file=sys.stderr)
        try:
            proc.kill()
        except Exception:
            pass
        return {}

    print(f"  Capturing {len(golden_cases)} responses for {model_id}...", flush=True)
    responses: dict[str, str] = {}

    for i, case in enumerate(golden_cases):
        case_id = case["id"]
        prompt = case.get("prompt", "")
        system = get_system_prompt_for_case(case)
        resp = chat_sync(
            BENCH_PORT, prompt, system=system,
            max_tokens=200, temperature=0.6,
            disable_thinking=disable_thinking,
        )
        responses[case_id] = resp
        status = "ERR" if resp.startswith("__ERROR__") else "ok"
        print(f"  [{i+1}/{len(golden_cases)}] {case_id}: {status}", flush=True)

    kill_server(proc, pid)
    return responses


# ── judge: subjective scoring ─────────────────────────────────────────────────

JUDGE_SYSTEM_PROMPT = """\
Sos un evaluador experto de respuestas de asistentes de IA en español rioplatense.
Tu tarea es puntuar la respuesta de un candidato según un rubric preciso.
Devolvé ÚNICAMENTE un objeto JSON válido, sin texto adicional, sin markdown, sin pensamientos previos.
El JSON debe tener exactamente las claves que el usuario especifique.
No agregues explicaciones ni prose fuera del JSON."""


def _build_judge_prompt(case: dict, response: str) -> str:
    rubric = case.get("rubric", {})
    criteria = rubric.get("criteria", [])
    pass_threshold = rubric.get("pass_threshold", 0.7)

    criteria_lines = []
    keys_needed = []
    for idx, c in enumerate(criteria):
        key = f"c{idx+1}"
        keys_needed.append(key)
        criteria_lines.append(
            f'  "{key}" (weight={c["weight"]}): {c["criterion"]}'
        )

    criteria_block = "\n".join(criteria_lines)
    keys_str = ", ".join(f'"{k}": 0.0..1.0' for k in keys_needed)

    return f"""\
Evaluá la siguiente respuesta de un asistente.

=== PROMPT DEL USUARIO ===
{case["prompt"]}

=== RESPUESTA DEL CANDIDATO ===
{response}

=== RUBRIC (pass_threshold={pass_threshold}) ===
Criterios a evaluar (puntuá cada uno entre 0.0 y 1.0):
{criteria_block}

Devolvé SOLO este JSON (sin markdown, sin texto adicional):
{{{keys_str}, "note": "observación breve en ≤15 palabras"}}"""


def _parse_judge_json(raw: str) -> Optional[dict]:
    """Strip code fences and prose, return parsed dict or None."""
    # Remove <think>...</think> blocks
    cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    # Strip markdown code fences
    cleaned = re.sub(r"```(?:json)?\s*", "", cleaned).strip().rstrip("`").strip()
    # Try direct parse
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass
    # Try to extract first JSON object
    m = re.search(r'\{[^{}]*\}', cleaned, re.DOTALL)
    if m:
        try:
            return json.loads(m.group())
        except json.JSONDecodeError:
            pass
    return None


def judge_response(case: dict, response: str) -> dict:
    """
    Call the 35B judge on port 8080 for one (case, response) pair.
    Returns {criterion_scores: dict, weighted_score: float, passed: bool, note: str, raw: str}.
    Retries once on JSON parse failure.
    """
    rubric = case.get("rubric", {})
    criteria = rubric.get("criteria", [])
    pass_threshold = rubric.get("pass_threshold", 0.7)

    prompt = _build_judge_prompt(case, response)

    def call_judge() -> str:
        url = f"http://127.0.0.1:{JUDGE_PORT}/v1/chat/completions"
        payload = {
            "model": "judge",
            "messages": [
                {"role": "system", "content": JUDGE_SYSTEM_PROMPT},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": 200,
            "temperature": 0.0,
            "stream": False,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read())
        msg = body["choices"][0]["message"]
        return msg.get("content") or msg.get("reasoning_content") or ""

    raw = ""
    parsed = None
    for attempt in range(2):
        try:
            raw = call_judge()
        except Exception as e:
            raw = f"__JUDGE_ERROR__: {e}"
            break
        parsed = _parse_judge_json(raw)
        if parsed is not None:
            break
        print(f"    [judge retry {attempt+1}] failed to parse JSON: {raw[:120]!r}", file=sys.stderr)
        time.sleep(1)

    if parsed is None:
        return {
            "criterion_scores": {},
            "weighted_score": 0.0,
            "passed": False,
            "note": f"parse_error: {raw[:100]}",
            "raw": raw,
            "error": True,
        }

    # Compute weighted score
    weighted = 0.0
    total_weight = 0.0
    criterion_scores = {}
    for idx, c in enumerate(criteria):
        key = f"c{idx+1}"
        score = float(parsed.get(key, 0.0))
        score = max(0.0, min(1.0, score))  # clamp
        weight = c.get("weight", 1.0)
        criterion_scores[key] = {"criterion": c["criterion"], "score": score, "weight": weight}
        weighted += score * weight
        total_weight += weight

    weighted_score = round(weighted / total_weight, 4) if total_weight > 0 else 0.0
    passed = weighted_score >= pass_threshold

    return {
        "criterion_scores": criterion_scores,
        "weighted_score": weighted_score,
        "passed": passed,
        "note": parsed.get("note", ""),
        "raw": raw,
    }


# ── sanity check: detect degenerate judge ────────────────────────────────────

def check_judge_sanity(scores: list[float]) -> Optional[str]:
    """Return a warning string if the judge looks degenerate."""
    if not scores:
        return "no scores"
    if all(s >= 0.99 for s in scores):
        return f"ALL_HIGH (all scores ≥ 0.99 — likely sycophantic)"
    if all(s <= 0.01 for s in scores):
        return f"ALL_LOW (all scores ≤ 0.01 — likely refusing)"
    variance = max(scores) - min(scores)
    if variance < 0.05 and len(scores) >= 3:
        return f"FLAT (variance={variance:.3f} — judge not discriminating)"
    return None


# ── main scoring loop ────────────────────────────────────────────────────────

def score_model(
    model_cfg: dict,
    golden_cases: list[dict],
    subjective_cases: list[dict],
) -> dict:
    """
    Full pipeline for one model:
    1. Load deterministic score from stored results.
    2. Re-capture all responses.
    3. Judge subjective cases.
    4. Combine and write output.
    Returns summary dict.
    """
    model_id = model_cfg["id"]
    print(f"\n{'#'*70}", flush=True)
    print(f"# SUBJECTIVE SCORING: {model_id}", flush=True)
    print(f"{'#'*70}", flush=True)

    # --- Step 1: load deterministic score ---
    det_score, perf_data = load_deterministic_score(model_id)
    print(f"  Deterministic score (from stored results): {det_score:.3f}", flush=True)

    # --- Step 2: capture all responses ---
    print(f"\n  Re-capturing all {len(golden_cases)} responses (needed for subjective cases)...", flush=True)
    responses = capture_all_responses(model_cfg, golden_cases)
    if not responses:
        print(f"  [ERROR] Could not capture responses for {model_id} — skipping.", file=sys.stderr)
        return {"model_id": model_id, "error": "capture_failed"}

    # --- Step 3: judge subjective cases ---
    print(f"\n  Judging {len(subjective_cases)} subjective cases via 35B judge...", flush=True)
    per_case_results = []
    subjective_scores = []
    judge_scores_flat = []

    for case in subjective_cases:
        case_id = case["id"]
        response = responses.get(case_id, "")
        if not response or response.startswith("__ERROR__"):
            print(f"  [judge] {case_id}: no response — score=0.0", flush=True)
            per_case_results.append({
                "case_id": case_id,
                "category": case["category"],
                "response": response,
                "judge_result": {"weighted_score": 0.0, "passed": False, "note": "no_response"},
            })
            subjective_scores.append(0.0)
            continue

        print(f"  [judge] {case_id}...", end=" ", flush=True)
        result = judge_response(case, response)
        score = result["weighted_score"]
        subjective_scores.append(score)
        judge_scores_flat.extend(
            [v["score"] for v in result.get("criterion_scores", {}).values()]
        )
        status = "PASS" if result["passed"] else "FAIL"
        err_note = " [PARSE_ERROR]" if result.get("error") else ""
        print(f"{status} ({score:.3f}) — {result.get('note', '')[:50]}{err_note}", flush=True)

        per_case_results.append({
            "case_id": case_id,
            "category": case["category"],
            "response": response,
            "judge_result": result,
        })
        # Gentle: small pause between sequential judge calls
        time.sleep(0.5)

    # --- Step 4: sanity check ---
    sanity_warn = check_judge_sanity(judge_scores_flat)
    if sanity_warn:
        print(f"\n  [WARN] Judge sanity check: {sanity_warn}", file=sys.stderr)

    # --- Step 5: compute aggregate scores ---
    n_subj = len(subjective_cases)
    subj_score = round(sum(subjective_scores) / n_subj, 4) if n_subj > 0 else 0.0
    final_score = round(0.7 * det_score + 0.3 * subj_score, 4)

    print(f"\n  det={det_score:.3f}  subj={subj_score:.3f}  final={final_score:.3f}", flush=True)

    # --- Step 6: write per-case JSONL ---
    out_path = RESULTS_DIR / f"subjective_{model_id}.jsonl"
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        for row in per_case_results:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"  Written: {out_path}", flush=True)

    # Per-category subjective breakdown
    cat_scores: dict[str, list[float]] = {}
    for i, case in enumerate(subjective_cases):
        cat = case["category"]
        cat_scores.setdefault(cat, []).append(subjective_scores[i])
    cat_breakdown = {
        cat: round(sum(v) / len(v), 4) for cat, v in cat_scores.items()
    }

    return {
        "model_id": model_id,
        "deterministic_score": det_score,
        "subjective_score": subj_score,
        "final_score": final_score,
        "per_category_subjective": cat_breakdown,
        "n_subjective_cases": n_subj,
        "judge_sanity_warning": sanity_warn,
        "perf": perf_data,
        "output_file": str(out_path),
    }


# ── ranked summary table ──────────────────────────────────────────────────────

def print_ranked_table(summaries: list[dict]) -> None:
    valid = [s for s in summaries if "error" not in s]
    valid.sort(key=lambda x: x["final_score"], reverse=True)

    print("\n" + "=" * 90)
    print("  FINAL RANKING — 0.7×det + 0.3×subj  (sorted by FINAL score)")
    print("=" * 90)
    print(
        f"  {'Model':<22} {'Det':>6} {'Subj':>6} {'FINAL':>7} "
        f"{'tok/s p50':>10} {'RSS MB':>8}  Sanity"
    )
    print("  " + "-" * 87)

    for s in valid:
        perf = s.get("perf", {})
        toks = perf.get("decode_p50_toks_s", 0) or 0
        rss = perf.get("idle_rss_mb") or 0
        warn = s.get("judge_sanity_warning") or "ok"
        print(
            f"  {s['model_id']:<22} "
            f"{s['deterministic_score']:>6.3f} "
            f"{s['subjective_score']:>6.3f} "
            f"{s['final_score']:>7.4f} "
            f"{toks:>10.1f} "
            f"{rss:>8.0f}  "
            f"{warn}"
        )
    print("=" * 90)

    # Deterministic-only ranking for comparison
    valid_det = sorted(valid, key=lambda x: x["deterministic_score"], reverse=True)
    print("\n  Deterministic-only ranking (for comparison):")
    for rank, s in enumerate(valid_det, 1):
        print(f"    {rank}. {s['model_id']} — det={s['deterministic_score']:.3f}")

    # Reordering analysis
    final_order = [s["model_id"] for s in valid]
    det_order = [s["model_id"] for s in valid_det]
    if final_order != det_order:
        print("\n  [NOTE] Adding subjective layer CHANGED the ranking:")
        for i, mid in enumerate(final_order):
            det_pos = det_order.index(mid) + 1
            final_pos = i + 1
            if det_pos != final_pos:
                direction = "UP" if final_pos < det_pos else "DOWN"
                print(f"    {mid}: det-rank #{det_pos} → final-rank #{final_pos} ({direction})")
    else:
        print("\n  [NOTE] Ranking unchanged vs deterministic-only.")


# ── entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Subjective judge — Phase 2 brain bench")
    parser.add_argument(
        "--models", default="",
        help="Comma-separated model ids (default: all 6 candidates)",
    )
    args = parser.parse_args()

    # Verify judge is reachable first
    if http_get_status(f"http://127.0.0.1:{JUDGE_PORT}/health") != 200:
        print(
            f"ERROR: Judge (35B) not reachable at http://127.0.0.1:{JUDGE_PORT}/health\n"
            "Stop — do not spin up a competing instance.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"Judge reachable on port {JUDGE_PORT}.", flush=True)

    # Load golden set
    if not GOLDEN_SET_PATH.exists():
        print(f"ERROR: Golden set not found: {GOLDEN_SET_PATH}", file=sys.stderr)
        sys.exit(1)
    all_cases = load_golden_set(GOLDEN_SET_PATH)
    subjective_cases = [c for c in all_cases if c.get("rubric")]
    print(
        f"Loaded {len(all_cases)} golden cases — "
        f"{len(subjective_cases)} subjective, "
        f"{len(all_cases)-len(subjective_cases)} deterministic-only.",
        flush=True,
    )

    # Filter models
    if args.models:
        requested = set(args.models.split(","))
        models = [m for m in CANDIDATE_MODELS if m["id"] in requested]
    else:
        models = CANDIDATE_MODELS

    print(f"Running {len(models)} models: {[m['id'] for m in models]}\n", flush=True)

    summaries = []
    for model_cfg in models:
        if not Path(model_cfg["gguf"]).exists():
            print(f"\n[SKIP] {model_cfg['id']}: GGUF not found", flush=True)
            summaries.append({"model_id": model_cfg["id"], "error": "gguf_missing"})
            continue
        summary = score_model(model_cfg, all_cases, subjective_cases)
        summaries.append(summary)

    print_ranked_table(summaries)

    # Write combined summary
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    summary_path = RESULTS_DIR / f"subjective-summary_{ts}.jsonl"
    with open(summary_path, "w", encoding="utf-8") as f:
        for s in summaries:
            f.write(json.dumps(s, ensure_ascii=False, default=str) + "\n")
    print(f"\nSummary written: {summary_path}")


if __name__ == "__main__":
    main()
