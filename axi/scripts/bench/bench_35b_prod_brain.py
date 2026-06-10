#!/usr/bin/env python3
"""bench_35b_prod_brain.py — Bench the current production brain (Qwen3.6-35B-A3B) as a candidate.

Phase 1: Deterministic quality (35 cases) + CPU perf — model on port 18080, CPU-only.
Phase 2: Subjective scoring — candidate responses judged by gemma4-26b-a4b-it
         (different judge family; see caveats in output).

Safety rules (same as cpu_sweep.py):
  - BENCH_PORT = 18080 ONLY — never 8080 / 8090
  - CUDA_VISIBLE_DEVICES='' — zero VRAM, no conflict with prod GPU brain on 8080
  - Kill port 18080 before switching between 35B candidate and gemma4-26b judge
  - DO NOT touch prod on 8080 or nano on 8090
"""
from __future__ import annotations

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

# ── paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
GOLDEN_SET_PATH = (
    Path(__file__).resolve().parents[3]
    / "lifeos" / "src" / "lifeos" / "agents" / "eval" / "golden_sets"
    / "brain_quality.jsonl"
)

BENCH_PORT = 18080  # NEVER 8080 or 8090
MODELS_DIR = Path("/home/hectormr/LifeOS/models")

# ── model under test ───────────────────────────────────────────────────────────
PROD_BRAIN_CFG = {
    "id": "qwen35-6-35b-a3b",
    "label": "Qwen3.6-35B-A3B (current prod brain)",
    "gguf": MODELS_DIR / "Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf",
    "mmproj": MODELS_DIR / "Qwen3.6-35B-A3B/mmproj-BF16.gguf",
    "ctx": 32768,
    "disable_thinking": True,  # Qwen3 family — matches prod disable_thinking=True
}

# ── judge model (cross-family, not the model under test) ───────────────────────
JUDGE_CFG = {
    "id": "gemma4-26b-a4b-it",
    "gguf": MODELS_DIR / "gemma4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
    "mmproj": MODELS_DIR / "gemma4-26b-a4b-it/mmproj-BF16.gguf",
    "ctx": 32768,
    "reasoning_off": True,  # Gemma4 — suppress thinking trace
}

# ── system prompts ─────────────────────────────────────────────────────────────
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

BENCH_PROMPTS = [
    "Hola Axi! Recordame qué tengo que hacer hoy si mañana tengo una reunión importante a las 9am.",
    "¿Cuál es la mejor forma de organizar mis gastos mensuales?",
    "Necesito preparar una presentación para el trabajo. ¿Por dónde empiezo?",
    "¿Qué ejercicios puedo hacer en casa sin equipamiento?",
    "¿Cómo puedo mejorar mi concentración cuando estudio?",
]

JUDGE_SYSTEM_PROMPT = """\
Sos un evaluador experto de respuestas de asistentes de IA en español rioplatense.
Tu tarea es puntuar la respuesta de un candidato según un rubric preciso.
Devolvé ÚNICAMENTE un objeto JSON válido, sin texto adicional, sin markdown, sin pensamientos previos.
El JSON debe tener exactamente las claves que el usuario especifique.
No agregues explicaciones ni prose fuera del JSON."""


# ── helpers ────────────────────────────────────────────────────────────────────

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


def poll_health(port: int, timeout_s: int = 600) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if http_get_status(url) == 200:
            return True
        time.sleep(3)
    return False


def chat_sync(
    port: int,
    prompt: str,
    system: str = "",
    max_tokens: int = 512,
    temperature: float = 0.0,
    disable_thinking: bool = False,
    enable_thinking: Optional[bool] = None,
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
    elif enable_thinking is False:
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
        content = msg.get("content") or msg.get("reasoning_content") or ""
        return content
    except Exception as e:
        return f"__ERROR__: {e}"


def stream_request(port: int, prompt: str, system: str = "", max_tokens: int = 250) -> dict:
    """Streaming inference request for perf measurement."""
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
        "chat_template_kwargs": {"enable_thinking": False},  # disable thinking for perf
    }
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft: Optional[float] = None
    content_chunks = 0
    reasoning_chunks = 0
    full_content = []

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
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


# ── server lifecycle ───────────────────────────────────────────────────────────

def spawn_server(model_cfg: dict, port: int = BENCH_PORT) -> tuple:
    """Spawn llama-server CPU-only. Returns (proc, pid, startup_s, error)."""
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
    env["CUDA_VISIBLE_DEVICES"] = ""

    note = " --reasoning off" if reasoning_off else ""
    print(f"  Spawning: {cmd[0]} -m ...{Path(gguf).name} -ngl 0 --port {port}{note}", flush=True)
    t_spawn = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    healthy = poll_health(port, timeout_s=600)
    startup_s = round(time.perf_counter() - t_spawn, 2)
    if not healthy:
        return proc, proc.pid, startup_s, f"Server never healthy after {startup_s:.0f}s"
    return proc, proc.pid, startup_s, None


def kill_bench_server() -> None:
    """Kill any process on BENCH_PORT 18080."""
    try:
        result = subprocess.run(
            ["pkill", "-f", f"[l]lama-server.*{BENCH_PORT}"],
            capture_output=True, timeout=10
        )
    except Exception:
        pass
    time.sleep(3)


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


# ── golden set ─────────────────────────────────────────────────────────────────

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


def get_system_prompt_for_case(case: dict) -> str:
    cat = case.get("category", "")
    if cat == "reminder_time":
        return REMINDER_SYSTEM_PROMPT
    elif cat == "intent_classification":
        return ""
    else:
        return SYSTEM_PROMPT


# ── deterministic quality checks (from cpu_sweep.py) ──────────────────────────

def is_spanish(text: str) -> bool:
    english_markers = ["I am", "I'm", "I don't", "I can", "Hello", "Thank you", "You are"]
    lower = text.lower()
    for m in english_markers:
        if m.lower() in lower:
            return False
    spanish_markers = ["el ", "la ", "un ", "una ", "es ", "en ", "de ", "que ", "con ", "por ",
                       "para ", "no ", "se ", "lo ", "le ", "al ", "del ", "ó", "ú", "á", "é", "í",
                       "ñ", "¿", "¡",
                       "las ", "los ", "son ", "hay ", "hola", "mi ", "me ", "sus ", "su "]
    for m in spanish_markers:
        if m in lower:
            return True
    if len(text.split()) <= 3:
        return True
    return False


def check_deterministic(case: dict, response: str) -> tuple[bool, list[str]]:
    checks = case.get("checks", {})
    failures = []
    lower_resp = response.lower()

    if checks.get("language") == "es":
        if not is_spanish(response):
            failures.append("language:not_spanish")

    for substring in checks.get("must_contain", []):
        if substring.lower() not in lower_resp:
            failures.append(f"must_contain:'{substring}'")

    must_contain_any = checks.get("must_contain_any", [])
    if must_contain_any:
        if not any(s.lower() in lower_resp for s in must_contain_any):
            failures.append(f"must_contain_any:{must_contain_any}")

    for substring in checks.get("must_not_contain", []):
        if substring.lower() in lower_resp:
            failures.append(f"must_not_contain:'{substring}'")

    if "max_words" in checks:
        word_count = len(response.split())
        adjusted_limit = round(checks["max_words"] * 1.10)
        if word_count > adjusted_limit:
            failures.append(f"max_words:{word_count}>{checks['max_words']}")

    parsed_json = None
    if checks.get("json_valid"):
        clean = re.sub(r"<think>.*?</think>", "", response, flags=re.DOTALL).strip()
        clean = re.sub(r"```(?:json)?\s*", "", clean).strip().rstrip("`").strip()
        try:
            parsed_json = json.loads(clean)
        except json.JSONDecodeError:
            m = re.search(r'\{[^{}]*\}', clean, re.DOTALL)
            if m:
                try:
                    parsed_json = json.loads(m.group())
                except json.JSONDecodeError:
                    pass
            if parsed_json is None:
                failures.append("json_valid:invalid_json")

    if checks.get("json_keys") and parsed_json is not None and isinstance(parsed_json, dict):
        for key in checks["json_keys"]:
            if key not in parsed_json:
                failures.append(f"json_keys:missing_key_{key}")

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

    if checks.get("is_iso_datetime") and parsed_json is not None and isinstance(parsed_json, dict):
        when_iso = parsed_json.get("when_iso")
        if isinstance(when_iso, str):
            import datetime as dt_mod
            try:
                dt_mod.datetime.fromisoformat(when_iso.replace("Z", "+00:00"))
            except ValueError:
                failures.append(f"is_iso_datetime:invalid({when_iso!r})")

    if checks.get("refuses"):
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


# ── perf measurement ───────────────────────────────────────────────────────────

def measure_perf(proc, pid, n_runs: int = 10) -> dict:
    """Measure perf on already-running server at BENCH_PORT."""
    print(f"  Running {n_runs+1} requests (1 warmup)...", flush=True)

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
        print(f"  [{i+1}/{n_runs}] ttft={r.get('ttft_ms')}ms decode={r.get('decode_toks_s'):.1f}tok/s", flush=True)

    mem = read_proc_mem(pid)
    rss_mb = round(mem.get("VmRSS", 0) / 1024, 1)
    hwm_mb = round(mem.get("VmHWM", 0) / 1024, 1)

    return {
        "n_runs": n_runs,
        "ttft_p50_ms": p50(ttfts),
        "ttft_p95_ms": p95(ttfts),
        "ttft_mean_ms": round(statistics.mean(ttfts), 1) if ttfts else 0.0,
        "decode_p50_toks_s": p50(decodes),
        "decode_p95_toks_s": p95(decodes),
        "decode_mean_toks_s": round(statistics.mean(decodes), 2) if decodes else 0.0,
        "idle_rss_mb": rss_mb,
        "peak_hwm_mb": hwm_mb,
        "note": "CPU-only (-ngl 0) — prod runs on GPU; these numbers are NOT representative of prod speed",
    }


# ── judge helpers ──────────────────────────────────────────────────────────────

def _build_judge_prompt(case: dict, response: str) -> str:
    rubric = case.get("rubric", {})
    criteria = rubric.get("criteria", [])
    pass_threshold = rubric.get("pass_threshold", 0.7)
    criteria_lines = []
    keys_needed = []
    for idx, c in enumerate(criteria):
        key = f"c{idx+1}"
        keys_needed.append(key)
        criteria_lines.append(f'  "{key}" (weight={c["weight"]}): {c["criterion"]}')
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
    cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    cleaned = re.sub(r"```(?:json)?\s*", "", cleaned).strip().rstrip("`").strip()
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass
    m = re.search(r'\{[^{}]*\}', cleaned, re.DOTALL)
    if m:
        try:
            return json.loads(m.group())
        except json.JSONDecodeError:
            pass
    return None


def judge_one_case(case: dict, response: str, judge_port: int = BENCH_PORT) -> dict:
    """Call judge (on judge_port) for one case/response. Returns structured result."""
    rubric = case.get("rubric", {})
    criteria = rubric.get("criteria", [])
    pass_threshold = rubric.get("pass_threshold", 0.7)
    prompt = _build_judge_prompt(case, response)

    def call_judge() -> str:
        url = f"http://127.0.0.1:{judge_port}/v1/chat/completions"
        payload = {
            "model": "judge",
            "messages": [
                {"role": "system", "content": JUDGE_SYSTEM_PROMPT},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": 200,
            "temperature": 0.0,
            "stream": False,
            # gemma4 family: disable thinking via enable_thinking: false
            # The judge is gemma4-26b; use reasoning_off at server spawn level already
            # but also pass chat_template_kwargs defensively for any Qwen-family judge
        }
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode(),
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
        print(f"    [judge retry {attempt+1}] parse fail: {raw[:120]!r}", file=sys.stderr)
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

    weighted = 0.0
    total_weight = 0.0
    criterion_scores = {}
    for idx, c in enumerate(criteria):
        key = f"c{idx+1}"
        score = float(parsed.get(key, 0.0))
        score = max(0.0, min(1.0, score))
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


def check_judge_sanity(scores: list[float]) -> Optional[str]:
    if not scores:
        return "no scores"
    if all(s >= 0.99 for s in scores):
        return "ALL_HIGH (likely sycophantic)"
    if all(s <= 0.01 for s in scores):
        return "ALL_LOW (likely refusing)"
    variance = max(scores) - min(scores)
    if variance < 0.05 and len(scores) >= 3:
        return f"FLAT (variance={variance:.3f})"
    return None


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--n-runs", type=int, default=5, help="Perf runs (default 5 for large model)")
    parser.add_argument("--quality-only", action="store_true")
    parser.add_argument("--subjective-only", action="store_true",
                        help="Skip det phase; load det score from stored result file")
    parser.add_argument("--det-result-file", default="",
                        help="Path to existing det result file (for --subjective-only)")
    args = parser.parse_args()

    print("=" * 70)
    print("  Bench: Qwen3.6-35B-A3B (current production brain)")
    print("  Model: MXFP4_MOE gguf — CPU-only on port 18080")
    print("  Judge (subjective): gemma4-26b-a4b-it (cross-family)")
    print("=" * 70)

    # Verify prod server not on 18080
    if http_get_status(f"http://127.0.0.1:{BENCH_PORT}/health") == 200:
        print(f"ERROR: Something already healthy on port {BENCH_PORT}!", file=sys.stderr)
        print("Run: pkill -f '[l]lama-server.*18080'", file=sys.stderr)
        sys.exit(1)

    if not GOLDEN_SET_PATH.exists():
        print(f"ERROR: Golden set not found: {GOLDEN_SET_PATH}", file=sys.stderr)
        sys.exit(1)

    golden_cases = load_golden_set(GOLDEN_SET_PATH)
    subjective_cases = [c for c in golden_cases if c.get("rubric")]
    print(f"Golden set: {len(golden_cases)} cases, {len(subjective_cases)} subjective\n", flush=True)

    # ── PHASE 1: Deterministic quality + perf ─────────────────────────────────
    det_score = 0.0
    perf_data = {}
    all_responses: dict[str, str] = {}
    per_category: dict = {}
    failures_list = []

    det_result_path = None

    if not args.subjective_only:
        print("\n" + "=" * 70)
        print("  PHASE 1: Deterministic quality + CPU perf")
        print("=" * 70)

        wait_for_low_load()
        vram_before, vram_total = query_vram()
        ts = datetime.now(timezone.utc).isoformat()

        proc, pid, startup_s, err = spawn_server(PROD_BRAIN_CFG)
        if err:
            print(f"\nFATAL: Failed to spawn 35B: {err}", file=sys.stderr)
            print("This may be an OOM condition — check available RAM.", file=sys.stderr)
            try:
                proc.kill()
            except Exception:
                pass
            sys.exit(2)

        print(f"\n  Server healthy in {startup_s}s!", flush=True)

        # Sanity check: verify thinking is disabled (first response should be clean)
        print("\n  Sanity check: verifying no <think> leakage...", flush=True)
        sanity_resp = chat_sync(
            BENCH_PORT, "¿Cuál es la capital de Argentina?",
            system=SYSTEM_PROMPT, max_tokens=100,
            disable_thinking=True,
        )
        if "<think>" in sanity_resp.lower():
            print(f"  [WARN] Thinking trace leaked in sanity check: {sanity_resp[:200]!r}", file=sys.stderr)
        elif not sanity_resp or sanity_resp.startswith("__ERROR__"):
            print(f"  [WARN] Sanity check empty or errored: {sanity_resp!r}", file=sys.stderr)
        else:
            print(f"  Sanity OK: {sanity_resp[:80]!r}", flush=True)

        # Perf measurement
        if not args.quality_only:
            print("\n  --- PERF MEASUREMENT ---", flush=True)
            perf_data = measure_perf(proc, pid, n_runs=args.n_runs)

        # Quality eval — capture ALL responses
        print(f"\n  --- QUALITY EVAL (35 cases) ---", flush=True)
        disable_thinking = PROD_BRAIN_CFG.get("disable_thinking", False)

        passed_total = 0
        for i, case in enumerate(golden_cases):
            case_id = case.get("id", f"case_{i}")
            category = case.get("category", "unknown")
            prompt = case.get("prompt", "")
            system = get_system_prompt_for_case(case)

            response = chat_sync(
                BENCH_PORT, prompt, system=system,
                max_tokens=200, temperature=0.6,
                disable_thinking=disable_thinking,
            )
            all_responses[case_id] = response

            if response.startswith("__ERROR__"):
                failures_list.append({"id": case_id, "category": category,
                                       "checks_failed": ["request_error"], "response": response[:200]})
                cat_entry = per_category.setdefault(category, {"passed": 0, "total": 0})
                cat_entry["total"] += 1
                print(f"  [{i+1}/35] {case_id}: ERROR — {response[:80]}", flush=True)
                continue

            passed, failed_checks = check_deterministic(case, response)
            cat_entry = per_category.setdefault(category, {"passed": 0, "total": 0})
            cat_entry["total"] += 1

            if passed:
                passed_total += 1
                cat_entry["passed"] += 1
                print(f"  [{i+1}/35] {case_id}: PASS", flush=True)
            else:
                failures_list.append({
                    "id": case_id, "category": category,
                    "checks_failed": failed_checks,
                    "response": response[:300],
                })
                print(f"  [{i+1}/35] {case_id}: FAIL {failed_checks}", flush=True)

        kill_server(proc, pid)
        vram_after, _ = query_vram()

        for cat, counts in per_category.items():
            counts["score"] = round(counts["passed"] / counts["total"], 3) if counts["total"] > 0 else 0.0

        det_score = round(passed_total / len(golden_cases), 3) if golden_cases else 0.0

        print(f"\n  Deterministic score: {det_score:.3f}  ({passed_total}/{len(golden_cases)} passed)", flush=True)
        print(f"  Per-category:", flush=True)
        for cat, counts in sorted(per_category.items()):
            print(f"    {cat:<30} {counts['score']:.3f}  ({counts['passed']}/{counts['total']})", flush=True)

        if perf_data:
            print(f"\n  Perf (CPU-only — NOT representative of prod GPU speed):", flush=True)
            print(f"    Startup       : {startup_s}s", flush=True)
            print(f"    TTFT p50      : {perf_data['ttft_p50_ms']:.1f} ms", flush=True)
            print(f"    Decode p50    : {perf_data['decode_p50_toks_s']:.1f} tok/s", flush=True)
            print(f"    Idle RSS      : {perf_data['idle_rss_mb']:.0f} MB ({perf_data['idle_rss_mb']/1024:.2f} GB)", flush=True)

        # Save det result file
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        det_result_path = RESULTS_DIR / f"cpu-sweep_qwen35-6-35b-a3b_{ts_str}.jsonl"
        det_row = {
            "phase": "cpu-only",
            "model_id": "qwen35-6-35b-a3b",
            "label": "Qwen3.6-35B-A3B (current prod brain)",
            "timestamp_utc": ts,
            "startup_s": startup_s,
            "perf": {**perf_data, "vram_before_mib": vram_before, "vram_after_mib": vram_after, "vram_total_mib": vram_total},
            "quality": {
                "total_cases": len(golden_cases),
                "deterministic_score": det_score,
                "passed": passed_total,
                "failed": len(golden_cases) - passed_total,
                "per_category": per_category,
                "failures": failures_list,
                "all_responses": all_responses,
            },
            "note": "CPU-only benchmark. Prod runs on GPU — speed figures not representative. disable_thinking=True matches prod.",
        }
        with open(det_result_path, "w", encoding="utf-8") as f:
            f.write(json.dumps(det_row, ensure_ascii=False) + "\n")
        print(f"\n  Det results saved: {det_result_path}", flush=True)

    else:
        # Load from existing file
        if args.det_result_file:
            p = Path(args.det_result_file)
        else:
            candidates = sorted(
                RESULTS_DIR.glob("cpu-sweep_qwen35-6-35b-a3b_*.jsonl"),
                key=lambda x: x.stat().st_mtime, reverse=True
            )
            if not candidates:
                print("ERROR: No existing det result file found. Run without --subjective-only first.", file=sys.stderr)
                sys.exit(1)
            p = candidates[0]
        print(f"  Loading det results from: {p}", flush=True)
        with open(p) as f:
            stored = json.loads(f.read())
        det_score = stored.get("quality", {}).get("deterministic_score", 0.0)
        all_responses = stored.get("quality", {}).get("all_responses", {})
        perf_data = stored.get("perf", {})
        print(f"  Loaded: det={det_score:.3f}, {len(all_responses)} responses", flush=True)

    # ── PHASE 2: Subjective scoring (judge = gemma4-26b) ──────────────────────
    print("\n" + "=" * 70)
    print("  PHASE 2: Subjective scoring")
    print("  Judge: gemma4-26b-a4b-it (cross-family judge)")
    print("  NOTE: All other 8 models were judged by the 35B itself.")
    print("        The 35B's subjective score uses a DIFFERENT judge.")
    print("        Deterministic (70%) is the fair comparator across all models.")
    print("=" * 70)

    # If we don't have responses yet (subjective-only with no stored responses), re-capture
    if len(all_responses) < len(golden_cases):
        print(f"\n  Re-capturing {len(golden_cases)} responses for subjective judging...", flush=True)
        wait_for_low_load()
        proc, pid, startup_s, err = spawn_server(PROD_BRAIN_CFG)
        if err:
            print(f"ERROR: Failed to spawn 35B for response capture: {err}", file=sys.stderr)
            sys.exit(2)
        disable_thinking = PROD_BRAIN_CFG.get("disable_thinking", False)
        for i, case in enumerate(golden_cases):
            case_id = case["id"]
            if case_id in all_responses:
                continue
            system = get_system_prompt_for_case(case)
            resp = chat_sync(BENCH_PORT, case["prompt"], system=system,
                             max_tokens=200, temperature=0.6, disable_thinking=disable_thinking)
            all_responses[case_id] = resp
            print(f"  [{i+1}/35] {case_id}: {'ok' if not resp.startswith('__ERROR__') else 'ERR'}", flush=True)
        kill_server(proc, pid)

    # Spin up gemma4-26b as judge on BENCH_PORT
    print(f"\n  Spawning gemma4-26b-a4b-it as judge on port {BENCH_PORT}...", flush=True)
    wait_for_low_load()
    judge_proc, judge_pid, judge_startup_s, judge_err = spawn_server(JUDGE_CFG)
    if judge_err:
        print(f"ERROR: Failed to spawn gemma4-26b judge: {judge_err}", file=sys.stderr)
        sys.exit(2)
    print(f"  Judge healthy in {judge_startup_s}s", flush=True)

    # Judge the 6 subjective cases
    per_case_results = []
    subjective_scores = []
    judge_scores_flat = []

    for case in subjective_cases:
        case_id = case["id"]
        response = all_responses.get(case_id, "")
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
        result = judge_one_case(case, response, judge_port=BENCH_PORT)
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
        time.sleep(0.5)

    kill_server(judge_proc, judge_pid)

    # Sanity check
    sanity_warn = check_judge_sanity(judge_scores_flat)
    if sanity_warn:
        print(f"\n  [WARN] Judge sanity: {sanity_warn}", file=sys.stderr)

    # Compute scores
    n_subj = len(subjective_cases)
    subj_score = round(sum(subjective_scores) / n_subj, 4) if n_subj > 0 else 0.0
    final_score = round(0.7 * det_score + 0.3 * subj_score, 4)

    # Save subjective results
    subj_path = RESULTS_DIR / "subjective_qwen35-6-35b-a3b.jsonl"
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(subj_path, "w", encoding="utf-8") as f:
        for row in per_case_results:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"\n  Subjective results saved: {subj_path}", flush=True)

    # ── Final summary ──────────────────────────────────────────────────────────
    print("\n" + "=" * 70)
    print("  FINAL RESULTS — Qwen3.6-35B-A3B (current prod brain)")
    print("=" * 70)
    print(f"  Deterministic  : {det_score:.4f}  ({int(det_score*35+0.5)}/35 cases)")
    print(f"  Subjective     : {subj_score:.4f}  (judge=gemma4-26b, {n_subj} cases)")
    print(f"  FINAL          : {final_score:.4f}  (0.7×det + 0.3×subj)")
    if sanity_warn:
        print(f"  Judge sanity   : {sanity_warn}")
    print()
    print("  KEY COMPARATOR: gemma4-26b-a4b-it (current leader)")
    print(f"  gemma4-26b det  = 0.743   (judged by 35B Qwen)")
    print(f"  35B-prod   det  = {det_score:.3f}   (same scorer, fair comparator)")
    delta_det = det_score - 0.743
    if delta_det > 0.005:
        print(f"  → 35B wins on det by +{delta_det:.3f} — gemma4-26b is NOT a quality upgrade")
    elif delta_det < -0.005:
        print(f"  → gemma4-26b wins on det by +{abs(delta_det):.3f} — gemma4-26b IS a quality upgrade signal")
    else:
        print(f"  → Essentially tied on det (delta={delta_det:+.3f})")
    print()
    print("  CAVEATS:")
    print("  - CPU-only speed: NOT representative of prod (GPU). Speed columns marked N/A.")
    print("  - Subjective judge differs: gemma4-26b judged the 35B; 35B judged all others.")
    print("    The 30% subjective axis is not directly comparable across models.")
    print("    Deterministic (70%) is the clean cross-model comparator.")
    print(f"  - Small subjective sample: {n_subj} cases only.")
    print("=" * 70)

    # Return data for engram/RANKING update
    return {
        "model_id": "qwen35-6-35b-a3b",
        "det_score": det_score,
        "subj_score": subj_score,
        "final_score": final_score,
        "sanity_warn": sanity_warn,
        "det_result_file": str(det_result_path) if det_result_path else "see --subjective-only load",
        "subj_result_file": str(subj_path),
        "perf": perf_data,
    }


if __name__ == "__main__":
    main()
