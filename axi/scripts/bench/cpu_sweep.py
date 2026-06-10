#!/usr/bin/env python3
"""cpu_sweep.py — Phase 1 CPU-only sweep: perf + deterministic quality.

Runs each candidate model sequentially on port 18080 with -ngl 0,
measures startup / TTFT / decode / RSS, then evaluates deterministic
quality over the 35-case brain_quality golden set.

Safety rules:
  - BENCH_PORT = 18080 ONLY — never 8080 / 8090
  - Each server spawned with start_new_session=True; killed (SIGTERM to pgid)
    before next model starts — zero cross-contamination.
  - CUDA_VISIBLE_DEVICES='' — zero VRAM, no conflict with prod GPU brain.
  - Load check before each model: if 1-min load > 2.0, wait up to 120 s.

Usage:
    python3 cpu_sweep.py
    python3 cpu_sweep.py --n-runs 5 --models qwen35-0_8b,granite-4.0-h-1b
    python3 cpu_sweep.py --models smollm2-360m  # run single model
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
GOLDEN_SET_PATH = Path(__file__).resolve().parents[3] / "lifeos" / "src" / "lifeos" / "agents" / "eval" / "golden_sets" / "brain_quality.jsonl"

BENCH_PORT = 18080  # NEVER 8080 or 8090

# ── model catalog ──────────────────────────────────────────────────────────
MODELS_DIR = Path("/home/hectormr/LifeOS/models")

# ctx from catalog; sane default 8192 for anything not listed
CANDIDATE_MODELS = [
    {
        "id": "qwen35-9b",
        "gguf": MODELS_DIR / "qwen35-9b/Qwen3.5-9B-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "qwen35-9b/mmproj-F16.gguf",
        "ctx": 32768,
        "disable_thinking": True,  # thinking mode exhausts max_tokens; prod uses disable_thinking=True
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
        # Gemma4 "E" thinking models output their reasoning trace verbatim in content
        # (llama.cpp --reasoning-format auto only strips Qwen3/DeepSeek <think> tags).
        # Use --reasoning off to disable thinking entirely — matches Phase-1 Qwen fix pattern.
        "reasoning_off": True,
    },
    {
        "id": "gemma4-e2b-it",
        "gguf": MODELS_DIR / "gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "gemma4-e2b-it/mmproj-BF16.gguf",
        "ctx": 32768,
        "reasoning_off": True,  # same fix — see gemma4-e4b-it comment above
    },
    # ── large vision tier — CPU quality only, GPU perf deferred ──────────────
    # Both are ~30B MoE (same weight class as prod brain Qwen3.6-35B, NOT small
    # game-brains). Running CPU-only to measure quality; speed will be re-measured
    # during a GPU downtime window.
    {
        "id": "gemma4-26b-a4b-it",
        "gguf": MODELS_DIR / "gemma4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "gemma4-26b-a4b-it/mmproj-BF16.gguf",
        "ctx": 32768,
        # Gemma4 family leaks thinking trace (same as gemma4-e4b/e2b) — suppress with
        # --reasoning off, which llama.cpp maps to the Gemma4 disable-thinking flag.
        "reasoning_off": True,
    },
    {
        "id": "nemotron3-nano-omni-30b-a3b",
        "gguf": MODELS_DIR / "nemotron3-nano-omni-30b-a3b/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-Q4_K_M.gguf",
        "mmproj": MODELS_DIR / "nemotron3-nano-omni-30b-a3b/mmproj-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16.gguf",
        "ctx": 32768,
        # Explicit reasoning model — suppress thinking trace with --reasoning off.
        # Nemotron may use a different thinking delimiter; verify first few responses
        # are clean before treating scores as valid.
        "reasoning_off": True,
    },
    # ── current production brain — reference entry (DO NOT include in normal sweeps) ──
    # Benchmarked 2026-06-10 via bench_35b_prod_brain.py; results in:
    #   results/cpu-sweep_qwen35-6-35b-a3b_20260610T000814Z.jsonl
    #   results/subjective_qwen35-6-35b-a3b.jsonl
    # Scores: det=0.771, subj=0.898 (judge=gemma4-26b), final=0.809
    # NOTE: subjective judged by gemma4-26b (cross-family) — not directly comparable.
    # NOTE: prod runs on GPU; CPU numbers below are NOT prod speed.
    # IMPORTANT: Running this via cpu_sweep.py will spin up a second CPU instance while
    #            prod is already on GPU port 8080 — that is safe (different ports) but
    #            wasteful and slow. Use bench_35b_prod_brain.py instead.
    # {
    #     "id": "qwen35-6-35b-a3b",
    #     "gguf": MODELS_DIR / "Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf",
    #     "mmproj": MODELS_DIR / "Qwen3.6-35B-A3B/mmproj-BF16.gguf",
    #     "ctx": 32768,
    #     "disable_thinking": True,  # matches prod disable_thinking=True
    # },
]
# Removed 2026-06-09: granite-4.0-h-1b, smollm2-360m, lfm2-1.2b-extract, lfm2.5-350m dropped —
# all blind (mmproj=None), not usable for the vision-dependent gaming co-pilot (#7) direction.
# Candidate set is now vision-only: qwen35-{9b,4b,2b,0_8b} + gemma4-e{4b,2b}-it + large tier.

# ── system prompt for brain-quality eval ──────────────────────────────────
SYSTEM_PROMPT = (
    "Sos Axi, un asistente de vida personal en español rioplatense. "
    "Respondé de forma concisa y útil. "
    f"Fecha y hora actual: {datetime.now().strftime('%A %d de %B de %Y, %H:%M')} (Argentina, UTC-3)."
)

REMINDER_SYSTEM_PROMPT = (
    "Parse the user's vague time expression and return ONLY a JSON object "
    "with the key 'when_iso' whose value is an ISO 8601 datetime string with timezone offset, "
    "or null if the time cannot be determined. No other text. No markdown. "
    f"Current time: {datetime.now().strftime('%Y-%m-%dT%H:%M:%S-03:00')} (Argentina, UTC-3)."
)

INTENT_SYSTEM_PROMPT = ""  # Intent prompts are self-contained

# ── bench prompts (from brain_bench.py, for perf measurement) ─────────────
BENCH_PROMPTS = [
    "Hola Axi! Recordame qué tengo que hacer hoy si mañana tengo una reunión importante a las 9am.",
    "¿Cuál es la mejor forma de organizar mis gastos mensuales?",
    "Necesito preparar una presentación para el trabajo. ¿Por dónde empiezo?",
    "¿Qué ejercicios puedo hacer en casa sin equipamiento?",
    "¿Cómo puedo mejorar mi concentración cuando estudio?",
]


# ── data structures ─────────────────────────────────────────────────────────

@dataclass
class PerfResult:
    label: str
    timestamp_utc: str
    machine_load_1min: float
    load_warning: bool
    startup_s: Optional[float]
    n_runs: int
    ttft_p50_ms: float
    ttft_p95_ms: float
    ttft_mean_ms: float
    decode_p50_toks_s: float
    decode_p95_toks_s: float
    decode_mean_toks_s: float
    idle_rss_mb: Optional[float]
    peak_hwm_mb: Optional[float]
    vram_before_mib: Optional[int]
    vram_after_mib: Optional[int]
    vram_total_mib: Optional[int]
    kv_bleed_detected: bool
    errors: list[str] = field(default_factory=list)


@dataclass
class QualityResult:
    label: str
    total_cases: int
    deterministic_score: float  # 0.0 - 1.0
    passed: int
    failed: int
    per_category: dict  # category -> {passed, total, score}
    failures: list[dict]  # list of {id, category, checks_failed}


@dataclass
class SweepRow:
    model_id: str
    perf: PerfResult
    quality: QualityResult
    phase: str = "cpu-only"


# ── helpers ─────────────────────────────────────────────────────────────────


def read_loadavg() -> float:
    return float(Path("/proc/loadavg").read_text().split()[0])


def read_proc_mem(pid: int) -> dict:
    result = {}
    try:
        status = Path(f"/proc/{pid}/status").read_text()
        for line in status.splitlines():
            for key in ("VmRSS", "VmHWM"):
                if line.startswith(f"{key}:"):
                    result[key] = int(line.split()[1])
    except Exception:
        pass
    return result


def query_vram() -> tuple:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader"],
            text=True, timeout=10
        ).strip()
        used, total = out.split(",")
        return int(used.strip().split()[0]), int(total.strip().split()[0])
    except Exception:
        return None, None


def http_get_status(url: str, timeout: int = 5) -> int:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def poll_health(port: int, timeout_s: int = 180) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if http_get_status(url) == 200:
            return True
        time.sleep(2)
    return False


def wait_for_low_load(threshold: float = 2.0, max_wait: int = 120) -> float:
    """Wait until 1-min load drops below threshold. Return actual load."""
    deadline = time.monotonic() + max_wait
    while time.monotonic() < deadline:
        load = read_loadavg()
        if load <= threshold:
            return load
        print(f"  [load-wait] 1-min load={load:.2f} > {threshold} — waiting 10s...", flush=True)
        time.sleep(10)
    return read_loadavg()


def stream_request(port: int, prompt: str, system: str = "", max_tokens: int = 250) -> dict:
    """Send one streaming inference request. Return timing dict."""
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": "bench",
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.6,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "stream": True,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft: Optional[float] = None
    content_chunks = 0
    reasoning_chunks = 0
    full_content = []

    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            for raw in resp:
                line = raw.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                rc = delta.get("reasoning_content") or ""
                ct = delta.get("content") or ""
                if (rc or ct) and ttft is None:
                    ttft = time.perf_counter() - t0
                if rc:
                    reasoning_chunks += 1
                if ct:
                    content_chunks += 1
                    full_content.append(ct)
    except Exception as e:
        return {"ttft_ms": None, "total_s": 0.0, "decode_toks_s": 0.0,
                "content": "", "error": str(e)}

    total_time = time.perf_counter() - t0
    total_chunks = reasoning_chunks + content_chunks
    return {
        "ttft_ms": round(ttft * 1000, 1) if ttft is not None else None,
        "total_s": round(total_time, 3),
        "decode_toks_s": round(total_chunks / total_time, 2) if total_time > 0 else 0.0,
        "content": "".join(full_content),
    }


def chat_sync(port: int, prompt: str, system: str = "", max_tokens: int = 512,
              temperature: float = 0.0, disable_thinking: bool = False) -> str:
    """Non-streaming request — returns full response text.

    disable_thinking=True passes chat_template_kwargs={enable_thinking:false} to the
    server, which instructs the Qwen3.5 Jinja template to skip the thinking phase.
    This matches production disable_thinking=True behavior and prevents max_tokens
    budget exhaustion from thinking traces.
    """
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = {
        "model": "bench",
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }
    if disable_thinking:
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read())
        msg = body["choices"][0]["message"]
        # Prefer content; fall back to reasoning_content for thinking-only models
        content = msg.get("content") or msg.get("reasoning_content") or ""
        return content
    except Exception as e:
        return f"__ERROR__: {e}"


def kv_bleed_probe(port: int) -> bool:
    marker = "XBLEED9472831"
    try:
        chat_sync(port, f"Recordá este código secreto: {marker}", max_tokens=60)
        r2 = chat_sync(port, "¿Cuánto es 3 + 3?", max_tokens=60)
        return marker in r2
    except Exception:
        return False


def p50(xs: list) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    return s[len(s) // 2]


def p95(xs: list) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    return s[int(len(s) * 0.95)]


# ── golden-set loader ────────────────────────────────────────────────────────

def load_golden_set(path: Path) -> list[dict]:
    cases = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("#"):
            continue
        try:
            cases.append(json.loads(stripped))
        except json.JSONDecodeError:
            pass
    return cases


# ── deterministic quality checks ─────────────────────────────────────────────

def is_spanish(text: str) -> bool:
    """Heuristic: text has some Spanish content and no obvious English phrases."""
    # Check for common English giveaways
    english_markers = ["I am", "I'm", "I don't", "I can", "Hello", "Thank you", "You are"]
    lower = text.lower()
    for m in english_markers:
        if m.lower() in lower:
            return False
    # Must contain at least some Spanish characters or common words.
    # NOTE: "la " alone won't match "las " — plural/conjugated forms added explicitly.
    spanish_markers = ["el ", "la ", "un ", "una ", "es ", "en ", "de ", "que ", "con ", "por ",
                      "para ", "no ", "se ", "lo ", "le ", "al ", "del ", "ó", "ú", "á", "é", "í",
                      "ñ", "¿", "¡",
                      # Added: high-frequency forms not covered by singular/infinitive markers above
                      "las ", "los ", "son ", "hay ", "hola", "mi ", "me ", "sus ", "su "]
    for m in spanish_markers:
        if m in lower:
            return True
    # If text is very short (1-3 words), be lenient
    if len(text.split()) <= 3:
        return True
    return False


def check_deterministic(case: dict, response: str) -> tuple[bool, list[str]]:
    """
    Run deterministic checks for a golden case.
    Returns (passed: bool, failed_checks: list[str])
    """
    checks = case.get("checks", {})
    failures = []
    lower_resp = response.lower()

    # language check
    if checks.get("language") == "es":
        if not is_spanish(response):
            failures.append("language:not_spanish")

    # must_contain
    for substring in checks.get("must_contain", []):
        if substring.lower() not in lower_resp:
            failures.append(f"must_contain:'{substring}'")

    # must_contain_any — passes if at least ONE of the listed substrings is present (OR logic)
    must_contain_any = checks.get("must_contain_any", [])
    if must_contain_any:
        if not any(s.lower() in lower_resp for s in must_contain_any):
            failures.append(f"must_contain_any:{must_contain_any}")

    # must_not_contain
    for substring in checks.get("must_not_contain", []):
        if substring.lower() in lower_resp:
            failures.append(f"must_not_contain:'{substring}'")

    # max_words — 10% tolerance to account for natural response-length variance.
    # Brain outputs are read via voice/notifications; a ~10% overrun doesn't
    # meaningfully degrade UX but prevents penalising correct answers that are
    # slightly verbose.
    if "max_words" in checks:
        word_count = len(response.split())
        adjusted_limit = round(checks["max_words"] * 1.10)
        if word_count > adjusted_limit:
            failures.append(f"max_words:{word_count}>{checks['max_words']}")

    # json_valid
    parsed_json = None
    if checks.get("json_valid"):
        # Strip thinking tags if present
        clean = re.sub(r"<think>.*?</think>", "", response, flags=re.DOTALL).strip()
        # Strip markdown code fences
        clean = re.sub(r"```(?:json)?\s*", "", clean).strip().rstrip("`").strip()
        # Try direct parse first
        try:
            parsed_json = json.loads(clean)
        except json.JSONDecodeError:
            # Try to extract first JSON object from the text
            m = re.search(r'\{[^{}]*\}', clean, re.DOTALL)
            if m:
                try:
                    parsed_json = json.loads(m.group())
                except json.JSONDecodeError:
                    pass
            if parsed_json is None:
                failures.append("json_valid:invalid_json")

    # json_keys
    if checks.get("json_keys") and parsed_json is not None and isinstance(parsed_json, dict):
        for key in checks["json_keys"]:
            if key not in parsed_json:
                failures.append(f"json_keys:missing_key_{key}")

    # json_value_type
    if checks.get("json_value_type") and parsed_json is not None and isinstance(parsed_json, dict):
        for key, expected_type in checks["json_value_type"].items():
            val = parsed_json.get(key)
            if expected_type == "str" and not isinstance(val, str):
                failures.append(f"json_value_type:{key}_not_str(got:{type(val).__name__})")
            elif expected_type == "null" and val is not None:
                failures.append(f"json_value_type:{key}_not_null")
            elif expected_type == "float" and not isinstance(val, float):
                failures.append(f"json_value_type:{key}_not_float")
            elif expected_type == "int" and not isinstance(val, int):
                failures.append(f"json_value_type:{key}_not_int")

    # is_iso_datetime
    if checks.get("is_iso_datetime") and parsed_json is not None and isinstance(parsed_json, dict):
        when_iso = parsed_json.get("when_iso")
        if isinstance(when_iso, str):
            import datetime as dt_mod
            try:
                dt_mod.datetime.fromisoformat(when_iso.replace("Z", "+00:00"))
            except ValueError:
                failures.append(f"is_iso_datetime:invalid({when_iso!r})")
        # if when_iso is None/null, it's fine (ambiguous cases accept null)

    # refuses check
    if checks.get("refuses"):
        # Model should decline/refuse — look for refusal patterns
        refusal_patterns = [
            "no puedo", "no me es posible", "no tengo acceso", "no tengo capacidad",
            "no puedo confirmar", "no puedo guardar", "no realicé", "no hice",
            "no tengo la capacidad", "no puedo hacer eso", "eso no es posible",
            "no tengo esa información", "no dispongo", "imposible", "no está en mis posibilidades",
            "no corresponde", "no debo", "no voy a", "me niego", "eso sería",
            "no es correcto que", "no almaceno", "no guardo", "no registro",
            "axi no tiene", "no tengo herramientas", "no tengo la habilidad",
            "no puedo inventar", "no es posible que yo", "ese dato no existe",
            "fabricar", "inventar",
        ]
        lower = response.lower()
        refused = any(p in lower for p in refusal_patterns)
        if not refused:
            failures.append("refuses:no_refusal_detected")

    return (len(failures) == 0), failures


def get_system_prompt_for_case(case: dict) -> str:
    cat = case.get("category", "")
    if cat == "reminder_time":
        return REMINDER_SYSTEM_PROMPT
    elif cat == "intent_classification":
        return ""  # prompt is self-contained
    else:
        return SYSTEM_PROMPT


# ── server lifecycle ─────────────────────────────────────────────────────────

def spawn_server(model_cfg: dict, port: int = BENCH_PORT) -> tuple:
    """Spawn llama-server CPU-only. Returns (proc, pid, startup_s, error)."""
    gguf = str(model_cfg["gguf"])
    mmproj = model_cfg.get("mmproj")
    ctx = model_cfg.get("ctx", 8192)
    # reasoning_off=True passes --reasoning off to suppress inline thinking traces
    # for models (e.g. Gemma4 "E") whose thinking format is NOT extracted by
    # --reasoning-format auto (which only handles Qwen3/DeepSeek <think> tags).
    reasoning_off = model_cfg.get("reasoning_off", False)

    cmd = ["/usr/bin/llama-server", "-m", gguf]
    if mmproj:
        cmd += ["--mmproj", str(mmproj)]
    cmd += [
        "-ngl", "0",          # CPU-only: zero GPU layers
        "--jinja",
        "--reasoning-format", "auto",  # separate thinking from content (Qwen3/DeepSeek)
        "-c", str(ctx),
        "--host", "127.0.0.1",
        "--port", str(port),
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
    env["CUDA_VISIBLE_DEVICES"] = ""  # zero VRAM, no conflict with prod

    reasoning_note = " --reasoning off" if reasoning_off else ""
    print(f"  Spawning: {cmd[0]} -m ...{Path(gguf).name} -ngl 0 --port {port}{reasoning_note}", flush=True)
    t_spawn = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    healthy = poll_health(port, timeout_s=300)
    startup_s = round(time.perf_counter() - t_spawn, 2)
    if not healthy:
        return proc, proc.pid, startup_s, f"Server never healthy after {startup_s:.0f}s"
    return proc, proc.pid, startup_s, None


def kill_server(proc, pid: int) -> None:
    """Kill the server process group gracefully."""
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
    # Give OS a moment to release port
    time.sleep(3)


# ── perf measurement ─────────────────────────────────────────────────────────

def measure_perf(model_cfg: dict, n_runs: int = 10) -> PerfResult:
    model_id = model_cfg["id"]
    ts = datetime.now(timezone.utc).isoformat()

    load1 = wait_for_low_load(threshold=2.0)
    load_warn = load1 > 2.0
    if load_warn:
        print(f"  WARNING: load={load1:.2f} > 2.0 even after wait!", file=sys.stderr)

    vram_before, vram_total = query_vram()
    errors = []

    proc, pid, startup_s, err = spawn_server(model_cfg)
    if err:
        errors.append(err)
        try:
            proc.kill()
        except Exception:
            pass
        return PerfResult(
            label=model_id, timestamp_utc=ts,
            machine_load_1min=load1, load_warning=load_warn,
            startup_s=startup_s, n_runs=0,
            ttft_p50_ms=0, ttft_p95_ms=0, ttft_mean_ms=0,
            decode_p50_toks_s=0, decode_p95_toks_s=0, decode_mean_toks_s=0,
            idle_rss_mb=None, peak_hwm_mb=None,
            vram_before_mib=vram_before, vram_after_mib=None,
            vram_total_mib=vram_total, kv_bleed_detected=False, errors=errors,
        )

    print(f"  Server healthy in {startup_s}s — running {n_runs+1} requests (1 warmup)...", flush=True)

    # Warmup
    stream_request(BENCH_PORT, BENCH_PROMPTS[0], system=SYSTEM_PROMPT)

    ttfts = []
    decodes = []
    for i in range(n_runs):
        prompt = BENCH_PROMPTS[i % len(BENCH_PROMPTS)]
        r = stream_request(BENCH_PORT, prompt, system=SYSTEM_PROMPT)
        if r.get("ttft_ms") is not None:
            ttfts.append(r["ttft_ms"])
        decodes.append(r["decode_toks_s"])
        print(f"  [{i+1}/{n_runs}] ttft={r.get('ttft_ms')}ms decode={r.get('decode_toks_s')}tok/s", flush=True)

    vram_after, _ = query_vram()
    mem = read_proc_mem(pid)
    rss_mb = round(mem.get("VmRSS", 0) / 1024, 1)
    hwm_mb = round(mem.get("VmHWM", 0) / 1024, 1)
    bleed = kv_bleed_probe(BENCH_PORT)

    kill_server(proc, pid)

    return PerfResult(
        label=model_id, timestamp_utc=ts,
        machine_load_1min=load1, load_warning=load_warn,
        startup_s=startup_s, n_runs=n_runs,
        ttft_p50_ms=p50(ttfts), ttft_p95_ms=p95(ttfts),
        ttft_mean_ms=round(statistics.mean(ttfts), 1) if ttfts else 0.0,
        decode_p50_toks_s=p50(decodes), decode_p95_toks_s=p95(decodes),
        decode_mean_toks_s=round(statistics.mean(decodes), 2) if decodes else 0.0,
        idle_rss_mb=rss_mb, peak_hwm_mb=hwm_mb,
        vram_before_mib=vram_before, vram_after_mib=vram_after,
        vram_total_mib=vram_total, kv_bleed_detected=bleed, errors=errors,
    )


# ── quality measurement ─────────────────────────────────────────────────────

def measure_quality(model_cfg: dict, golden_cases: list) -> QualityResult:
    model_id = model_cfg["id"]

    load1 = wait_for_low_load(threshold=2.0)
    if load1 > 2.0:
        print(f"  WARNING: load={load1:.2f} > 2.0 even after wait!", file=sys.stderr)

    errors_spawn = []
    proc, pid, startup_s, err = spawn_server(model_cfg)
    if err:
        errors_spawn.append(err)
        try:
            proc.kill()
        except Exception:
            pass
        return QualityResult(
            label=model_id, total_cases=len(golden_cases),
            deterministic_score=0.0, passed=0, failed=len(golden_cases),
            per_category={}, failures=[{"id": "spawn", "error": err}],
        )

    disable_thinking = model_cfg.get("disable_thinking", False)
    reasoning_off = model_cfg.get("reasoning_off", False)
    if disable_thinking:
        print(f"  [thinking disabled via chat_template_kwargs — matches prod disable_thinking=True]", flush=True)
    if reasoning_off:
        print(f"  [reasoning off — server spawned with --reasoning off (Gemma4 thinking-trace fix)]", flush=True)
    print(f"  Quality eval: running {len(golden_cases)} cases...", flush=True)

    per_category: dict = {}
    all_failures = []
    passed_total = 0

    for i, case in enumerate(golden_cases):
        case_id = case.get("id", f"case_{i}")
        category = case.get("category", "unknown")
        prompt = case.get("prompt", "")
        system = get_system_prompt_for_case(case)

        response = chat_sync(BENCH_PORT, prompt, system=system, max_tokens=200, temperature=0.6,
                             disable_thinking=disable_thinking)
        if response.startswith("__ERROR__"):
            all_failures.append({"id": case_id, "category": category,
                                  "checks_failed": ["request_error"], "response": response[:200]})
            cat_entry = per_category.setdefault(category, {"passed": 0, "total": 0})
            cat_entry["total"] += 1
            continue

        passed, failed_checks = check_deterministic(case, response)
        cat_entry = per_category.setdefault(category, {"passed": 0, "total": 0})
        cat_entry["total"] += 1

        if passed:
            passed_total += 1
            cat_entry["passed"] += 1
            print(f"  [{i+1}/{len(golden_cases)}] {case_id}: PASS", flush=True)
        else:
            all_failures.append({"id": case_id, "category": category,
                                  "checks_failed": failed_checks,
                                  "response": response[:300]})
            print(f"  [{i+1}/{len(golden_cases)}] {case_id}: FAIL {failed_checks}", flush=True)

    kill_server(proc, pid)

    # Compute per-category scores
    for cat, counts in per_category.items():
        counts["score"] = round(counts["passed"] / counts["total"], 3) if counts["total"] > 0 else 0.0

    det_score = round(passed_total / len(golden_cases), 3) if golden_cases else 0.0

    return QualityResult(
        label=model_id,
        total_cases=len(golden_cases),
        deterministic_score=det_score,
        passed=passed_total,
        failed=len(golden_cases) - passed_total,
        per_category=per_category,
        failures=all_failures,
    )


# ── game-mode tier annotation ────────────────────────────────────────────────

def fits_game_mode(rss_mb: Optional[float]) -> list[str]:
    """Return list of (machine_ram, profile) cells this model fits in."""
    if rss_mb is None:
        return ["unknown"]
    rss_gb = rss_mb / 1024
    fits = []
    # Machine RAM / game profile / model budget
    tiers = [
        ("16GB", "heavy", 3.0),   # 16GB - 12GB = 4GB OS, ~3GB for model
        ("16GB", "light", 9.0),   # 16GB - 6GB = 10GB, ~9GB for model
        ("32GB", "heavy", 20.0),  # 32GB - 12GB = ~20GB for model
        ("32GB", "light", 26.0),  # 32GB - 6GB = ~26GB for model
        ("64GB", "heavy", 52.0),  # 64GB - 12GB = ~52GB for model
        ("64GB", "light", 58.0),  # 64GB - 6GB = ~58GB for model
        ("96GB", "heavy", 84.0),  # 96GB - 12GB = ~84GB for model
        ("96GB", "light", 90.0),  # 96GB - 6GB = ~90GB for model
    ]
    for machine_ram, profile, budget_gb in tiers:
        if rss_gb <= budget_gb:
            fits.append(f"{machine_ram}/{profile}")
    return fits if fits else ["too_large"]


# ── output ───────────────────────────────────────────────────────────────────

def save_row(model_id: str, perf: PerfResult, quality: QualityResult) -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"cpu-sweep_{model_id}_{ts_str}.jsonl"
    row = {
        "phase": "cpu-only",
        "model_id": model_id,
        "timestamp_utc": perf.timestamp_utc,
        "perf": asdict(perf),
        "quality": {
            "total_cases": quality.total_cases,
            "deterministic_score": quality.deterministic_score,
            "passed": quality.passed,
            "failed": quality.failed,
            "per_category": quality.per_category,
            "failures": quality.failures,
        },
        "game_mode_tiers": fits_game_mode(perf.idle_rss_mb),
    }
    with out_path.open("w") as f:
        f.write(json.dumps(row) + "\n")
    return out_path


def print_model_summary(model_id: str, perf: PerfResult, quality: QualityResult) -> None:
    w = 68
    print(f"\n{'='*w}")
    print(f"  CPU Sweep — {model_id}")
    print(f"{'='*w}")
    if perf.errors:
        print(f"  ERRORS: {perf.errors}")
    else:
        print(f"  Startup        : {perf.startup_s}s")
        print(f"  TTFT  p50      : {perf.ttft_p50_ms:.1f} ms")
        print(f"  TTFT  p95      : {perf.ttft_p95_ms:.1f} ms")
        print(f"  Decode p50     : {perf.decode_p50_toks_s:.1f} tok/s")
        print(f"  Idle RSS       : {perf.idle_rss_mb:.0f} MB ({(perf.idle_rss_mb or 0)/1024:.2f} GB)")
        print(f"  Peak VmHWM     : {perf.peak_hwm_mb:.0f} MB")
        print(f"  KV-bleed       : {'DETECTED' if perf.kv_bleed_detected else 'clean'}")
        print(f"  Load warning   : {perf.load_warning}")
    print(f"\n  Quality (det.) : {quality.deterministic_score:.3f}  ({quality.passed}/{quality.total_cases} cases)")
    for cat, counts in sorted(quality.per_category.items()):
        print(f"    {cat:<28} {counts['score']:.2f}  ({counts['passed']}/{counts['total']})")
    tiers = fits_game_mode(perf.idle_rss_mb)
    print(f"\n  Game-mode tiers: {', '.join(tiers)}")
    print(f"{'='*w}")


def print_ranked_table(rows: list[dict]) -> None:
    """Print final ranked summary table."""
    print("\n" + "=" * 100)
    print("  RANKED SUMMARY — CPU Phase 1 (sorted by speed×quality)")
    print("=" * 100)
    print(f"  {'Model':<22} {'tok/s p50':>9} {'TTFT p50':>9} {'RSS GB':>7} {'Det.Q':>6} {'Startup':>8}  Game-mode tiers")
    print("  " + "-" * 97)

    # Sort by decode_tok/s * quality (higher is better)
    def sort_key(r):
        perf = r.get("perf", {})
        q = r.get("quality", {}).get("deterministic_score", 0)
        toks = perf.get("decode_p50_toks_s", 0)
        return toks * q

    rows_sorted = sorted(rows, key=sort_key, reverse=True)
    for r in rows_sorted:
        perf = r.get("perf", {})
        quality = r.get("quality", {})
        model_id = r.get("model_id", "?")
        toks = perf.get("decode_p50_toks_s", 0)
        ttft = perf.get("ttft_p50_ms", 0)
        rss = (perf.get("idle_rss_mb") or 0) / 1024
        det_q = quality.get("deterministic_score", 0)
        startup = perf.get("startup_s") or 0
        tiers = r.get("game_mode_tiers", [])
        errs = perf.get("errors", [])
        tier_str = ", ".join(tiers[:4])
        if errs:
            print(f"  {model_id:<22} {'FAILED':>9} {'':>9} {'':>7} {'':>6} {'':>8}  {errs[0][:40]}")
        else:
            print(f"  {model_id:<22} {toks:>9.1f} {ttft:>9.1f} {rss:>7.2f} {det_q:>6.3f} {startup:>8.1f}s  {tier_str}")
    print("=" * 100)


# ── main ─────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="CPU-only sweep: perf + quality")
    p.add_argument("--n-runs", type=int, default=10,
                   help="Perf runs per model (default 10)")
    p.add_argument("--models", default="",
                   help="Comma-separated model ids to run (default: all)")
    p.add_argument("--quality-only", action="store_true",
                   help="Skip perf measurement, only run quality eval")
    p.add_argument("--perf-only", action="store_true",
                   help="Skip quality eval, only run perf measurement")
    return p.parse_args()


def main():
    args = parse_args()

    # Filter models if requested
    if args.models:
        requested = set(args.models.split(","))
        models = [m for m in CANDIDATE_MODELS if m["id"] in requested]
        missing = requested - {m["id"] for m in models}
        if missing:
            print(f"WARNING: Unknown model ids: {missing}", file=sys.stderr)
    else:
        models = CANDIDATE_MODELS

    print(f"CPU sweep: {len(models)} models to run", flush=True)
    print(f"  n_runs={args.n_runs}, quality_only={args.quality_only}, perf_only={args.perf_only}")
    print(f"  Golden set: {GOLDEN_SET_PATH}")
    print(f"  Results dir: {RESULTS_DIR}\n")

    if not GOLDEN_SET_PATH.exists():
        print(f"ERROR: Golden set not found at {GOLDEN_SET_PATH}", file=sys.stderr)
        sys.exit(1)

    golden_cases = load_golden_set(GOLDEN_SET_PATH)
    print(f"  Loaded {len(golden_cases)} golden cases\n")

    all_rows = []

    for model_cfg in models:
        model_id = model_cfg["id"]
        gguf_path = model_cfg["gguf"]

        if not Path(gguf_path).exists():
            print(f"\n[SKIP] {model_id}: GGUF not found at {gguf_path}", flush=True)
            # Record as failed
            row = {
                "phase": "cpu-only",
                "model_id": model_id,
                "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                "perf": {"label": model_id, "errors": [f"GGUF not found: {gguf_path}"],
                         "decode_p50_toks_s": 0, "ttft_p50_ms": 0, "idle_rss_mb": None,
                         "peak_hwm_mb": None, "startup_s": None},
                "quality": {"deterministic_score": 0, "passed": 0, "failed": len(golden_cases),
                            "total_cases": len(golden_cases), "per_category": {}, "failures": []},
                "game_mode_tiers": ["unknown"],
            }
            all_rows.append(row)
            continue

        print(f"\n{'#'*68}", flush=True)
        print(f"# MODEL: {model_id}", flush=True)
        print(f"{'#'*68}", flush=True)

        perf_result = None
        quality_result = None

        if not args.quality_only:
            print(f"\n--- PERF MEASUREMENT ---", flush=True)
            perf_result = measure_perf(model_cfg, n_runs=args.n_runs)

        if not args.perf_only:
            print(f"\n--- QUALITY EVAL ---", flush=True)
            quality_result = measure_quality(model_cfg, golden_cases)

        # Fill missing with empty results
        if perf_result is None:
            perf_result = PerfResult(
                label=model_id, timestamp_utc=datetime.now(timezone.utc).isoformat(),
                machine_load_1min=0, load_warning=False, startup_s=None, n_runs=0,
                ttft_p50_ms=0, ttft_p95_ms=0, ttft_mean_ms=0,
                decode_p50_toks_s=0, decode_p95_toks_s=0, decode_mean_toks_s=0,
                idle_rss_mb=None, peak_hwm_mb=None,
                vram_before_mib=None, vram_after_mib=None, vram_total_mib=None,
                kv_bleed_detected=False, errors=["perf_skipped"],
            )
        if quality_result is None:
            quality_result = QualityResult(
                label=model_id, total_cases=0, deterministic_score=0,
                passed=0, failed=0, per_category={}, failures=["quality_skipped"],
            )

        print_model_summary(model_id, perf_result, quality_result)
        out_path = save_row(model_id, perf_result, quality_result)
        print(f"\n  Results saved: {out_path}", flush=True)

        row = {
            "phase": "cpu-only",
            "model_id": model_id,
            "timestamp_utc": perf_result.timestamp_utc,
            "perf": asdict(perf_result),
            "quality": {
                "total_cases": quality_result.total_cases,
                "deterministic_score": quality_result.deterministic_score,
                "passed": quality_result.passed,
                "failed": quality_result.failed,
                "per_category": quality_result.per_category,
                "failures": quality_result.failures,
            },
            "game_mode_tiers": fits_game_mode(perf_result.idle_rss_mb),
        }
        all_rows.append(row)

    # Print ranked table
    print_ranked_table(all_rows)

    # Save combined summary
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    summary_path = RESULTS_DIR / f"cpu-sweep-summary_{ts_str}.jsonl"
    with summary_path.open("w") as f:
        for row in all_rows:
            f.write(json.dumps(row) + "\n")
    print(f"\nFull summary written to: {summary_path}")

    return all_rows


if __name__ == "__main__":
    main()
