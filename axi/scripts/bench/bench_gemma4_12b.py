#!/usr/bin/env python3
"""bench_gemma4_12b.py — Quality-only benchmark for gemma4-12b-it.

Mirrors bench_35b_prod_brain.py pattern:
  1. Spawn gemma4-12b-it CPU-only on port 18080 (-ngl 0, --reasoning off)
  2. Run all 35 golden cases, capturing ALL responses (not just failures)
  3. Score deterministic quality (check_deterministic calibrated scorer)
  4. Kill model server
  5. Judge subjective cases via 35B on port 8080
  6. Compute final = 0.7*det + 0.3*subj
  7. Write results/cpu-sweep_gemma4-12b-it_<ts>.jsonl
  8. Write results/subjective_gemma4-12b-it.jsonl

Safety:
  - BENCH_PORT = 18080 ONLY
  - JUDGE_PORT = 8080 read-only
  - CUDA_VISIBLE_DEVICES='' on spawned server
  - Kills any stray server on 18080 before starting
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
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
GOLDEN_SET_PATH = (
    Path(__file__).resolve().parents[3]
    / "lifeos" / "src" / "lifeos" / "agents" / "eval" / "golden_sets"
    / "brain_quality.jsonl"
)

BENCH_PORT = 18080
JUDGE_PORT = 8080

MODEL_ID = "gemma4-12b-it"
GGUF_PATH = Path("/home/hectormr/LifeOS/models/gemma4-12b-it/gemma-4-12b-it-Q4_K_M.gguf")
MMPROJ_PATH = Path("/home/hectormr/LifeOS/models/gemma4-12b-it/mmproj-BF16.gguf")
CTX = 32768

# ── system prompts ────────────────────────────────────────────────────────────
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

JUDGE_SYSTEM_PROMPT = """\
Sos un evaluador experto de respuestas de asistentes de IA en español rioplatense.
Tu tarea es puntuar la respuesta de un candidato según un rubric preciso.
Devolvé ÚNICAMENTE un objeto JSON válido, sin texto adicional, sin markdown, sin pensamientos previos.
El JSON debe tener exactamente las claves que el usuario especifique.
No agregues explicaciones ni prose fuera del JSON."""


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


# ── HTTP helpers ──────────────────────────────────────────────────────────────
def http_get_status(url: str, timeout: int = 5) -> int:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def poll_health(port: int, timeout_s: int = 360) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if http_get_status(url) == 200:
            return True
        time.sleep(3)
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
    extra_kwargs: Optional[dict] = None,
) -> str:
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
    if extra_kwargs:
        payload.update(extra_kwargs)
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            body = json.loads(resp.read())
        msg = body["choices"][0]["message"]
        return msg.get("content") or msg.get("reasoning_content") or ""
    except Exception as e:
        return f"__ERROR__: {e}"


# ── server lifecycle ───────────────────────────────────────────────────────────
def kill_any_on_bench_port() -> None:
    """Kill anything running on BENCH_PORT before we start."""
    try:
        subprocess.run(
            ["pkill", "-f", f"[l]lama-server.*{BENCH_PORT}"],
            check=False, timeout=10
        )
        time.sleep(3)
    except Exception:
        pass


def spawn_server() -> tuple:
    """Spawn gemma4-12b-it CPU-only on BENCH_PORT. Returns (proc, pid, startup_s, error)."""
    cmd = ["/usr/bin/llama-server",
           "-m", str(GGUF_PATH),
           "--mmproj", str(MMPROJ_PATH),
           "-ngl", "0",
           "--jinja",
           "--reasoning-format", "auto",
           "--reasoning", "off",      # suppress Gemma4 thinking trace
           "-c", str(CTX),
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

    env = os.environ.copy()
    env["CUDA_VISIBLE_DEVICES"] = ""

    print(f"  Spawning: llama-server -m ...{GGUF_PATH.name} -ngl 0 --reasoning off --port {BENCH_PORT}", flush=True)
    t_spawn = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    healthy = poll_health(BENCH_PORT, timeout_s=420)
    startup_s = round(time.perf_counter() - t_spawn, 2)
    if not healthy:
        return proc, proc.pid, startup_s, f"Server never healthy after {startup_s:.0f}s"
    return proc, proc.pid, startup_s, None


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


# ── deterministic quality checks (from cpu_sweep.py — calibrated) ─────────────
def is_spanish(text: str) -> bool:
    english_markers = ["I am", "I'm", "I don't", "I can", "Hello", "Thank you", "You are"]
    lower = text.lower()
    for m in english_markers:
        if m.lower() in lower:
            return False
    spanish_markers = [
        "el ", "la ", "un ", "una ", "es ", "en ", "de ", "que ", "con ", "por ",
        "para ", "no ", "se ", "lo ", "le ", "al ", "del ", "ó", "ú", "á", "é", "í",
        "ñ", "¿", "¡",
        "las ", "los ", "son ", "hay ", "hola", "mi ", "me ", "sus ", "su ",
    ]
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


# ── subjective judge helpers ───────────────────────────────────────────────────
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


def judge_response(case: dict, response: str) -> dict:
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
        return f"ALL_HIGH (all scores ≥ 0.99 — likely sycophantic)"
    if all(s <= 0.01 for s in scores):
        return f"ALL_LOW (all scores ≤ 0.01 — likely refusing)"
    variance = max(scores) - min(scores)
    if variance < 0.05 and len(scores) >= 3:
        return f"FLAT (variance={variance:.3f} — judge not discriminating)"
    return None


# ── main ──────────────────────────────────────────────────────────────────────
def main() -> None:
    print(f"\n{'='*70}", flush=True)
    print(f"  BENCH: {MODEL_ID}", flush=True)
    print(f"  GGUF: {GGUF_PATH}", flush=True)
    print(f"  ctx={CTX}, --reasoning off (Gemma4 thinking-trace suppression)", flush=True)
    print(f"{'='*70}\n", flush=True)

    # Pre-flight checks
    if not GGUF_PATH.exists():
        print(f"ERROR: GGUF not found: {GGUF_PATH}", file=sys.stderr)
        sys.exit(1)
    if not MMPROJ_PATH.exists():
        print(f"ERROR: mmproj not found: {MMPROJ_PATH}", file=sys.stderr)
        sys.exit(1)
    if not GOLDEN_SET_PATH.exists():
        print(f"ERROR: Golden set not found: {GOLDEN_SET_PATH}", file=sys.stderr)
        sys.exit(1)
    if http_get_status(f"http://127.0.0.1:{JUDGE_PORT}/health") != 200:
        print(f"ERROR: Judge (35B) not reachable at port {JUDGE_PORT}", file=sys.stderr)
        sys.exit(1)
    print(f"Judge reachable on port {JUDGE_PORT}.", flush=True)

    all_cases = load_golden_set(GOLDEN_SET_PATH)
    subjective_cases = [c for c in all_cases if c.get("rubric")]
    print(
        f"Loaded {len(all_cases)} golden cases — "
        f"{len(subjective_cases)} subjective, "
        f"{len(all_cases) - len(subjective_cases)} deterministic-only.\n",
        flush=True,
    )

    # ── STEP 1: Kill any stale bench server ────────────────────────────────────
    kill_any_on_bench_port()

    # ── STEP 2: Spawn + capture all responses ─────────────────────────────────
    wait_for_low_load()
    proc, pid, startup_s, err = spawn_server()
    if err:
        print(f"ERROR: {err}", file=sys.stderr)
        try:
            proc.kill()
        except Exception:
            pass
        sys.exit(1)

    print(f"  Server healthy in {startup_s}s", flush=True)

    # Verify first few responses are clean (no leaked reasoning)
    print(f"\n  [sanity] Checking first response for reasoning leakage...", flush=True)
    sanity_resp = chat_sync(
        BENCH_PORT,
        "Hola, ¿cómo estás?",
        system=SYSTEM_PROMPT,
        max_tokens=80,
        temperature=0.0,
    )
    has_leak = any(tok in sanity_resp.lower() for tok in ["<think>", "</think>", "thinking", "let me think"])
    print(f"  Sanity response: {sanity_resp[:200]!r}", flush=True)
    if has_leak:
        print("  WARNING: Possible reasoning leak detected in sanity check!", file=sys.stderr)
    else:
        print("  Reasoning leak check: CLEAN", flush=True)
    is_clean_spanish = is_spanish(sanity_resp)
    print(f"  Spanish check: {'OK' if is_clean_spanish else 'WARNING — not Spanish'}", flush=True)

    # Capture ALL 35 responses
    print(f"\n  Capturing all {len(all_cases)} responses...", flush=True)
    all_responses: dict[str, str] = {}
    t_start = time.monotonic()
    for i, case in enumerate(all_cases):
        case_id = case["id"]
        system = get_system_prompt_for_case(case)
        resp = chat_sync(
            BENCH_PORT,
            case["prompt"],
            system=system,
            max_tokens=200,
            temperature=0.6,
        )
        all_responses[case_id] = resp
        status = "ERR" if resp.startswith("__ERROR__") else "ok"
        elapsed = time.monotonic() - t_start
        print(f"  [{i+1:2d}/{len(all_cases)}] {case_id}: {status}  [{elapsed:.0f}s elapsed]", flush=True)

    # Measure perf on a few live requests (tok/s estimate)
    print(f"\n  Measuring approximate tok/s (5 requests)...", flush=True)
    perf_prompt = "Hola Axi! Recordame qué tengo que hacer hoy si mañana tengo una reunión importante."
    tok_rates = []
    for _ in range(5):
        t0 = time.perf_counter()
        r = chat_sync(BENCH_PORT, perf_prompt, system=SYSTEM_PROMPT, max_tokens=80, temperature=0.6)
        elapsed = time.perf_counter() - t0
        word_count = len(r.split())
        toks = round(word_count * 1.3 / elapsed, 2) if elapsed > 0 else 0  # rough token estimate
        tok_rates.append(toks)
    tok_rates_sorted = sorted(tok_rates)
    tok_p50 = tok_rates_sorted[len(tok_rates_sorted) // 2]
    print(f"  Approx tok/s p50: {tok_p50:.1f}  (rough estimate — word*1.3/s)", flush=True)

    # Measure idle RSS
    rss_mb = None
    try:
        status_text = Path(f"/proc/{pid}/status").read_text()
        for line in status_text.splitlines():
            if line.startswith("VmRSS:"):
                rss_mb = round(int(line.split()[1]) / 1024, 1)
                break
    except Exception:
        pass

    kill_server(proc, pid)
    print(f"  Server killed cleanly.", flush=True)

    # ── STEP 3: Deterministic scoring ─────────────────────────────────────────
    print(f"\n{'─'*70}", flush=True)
    print(f"  DETERMINISTIC SCORING", flush=True)
    print(f"{'─'*70}", flush=True)

    per_category: dict[str, dict] = {}
    all_failures = []
    passed_total = 0
    all_case_results = []

    for case in all_cases:
        case_id = case["id"]
        category = case.get("category", "unknown")
        response = all_responses.get(case_id, "")

        if not response or response.startswith("__ERROR__"):
            all_failures.append({
                "id": case_id, "category": category,
                "checks_failed": ["request_error"], "response": response[:200],
            })
            per_category.setdefault(category, {"passed": 0, "total": 0})["total"] += 1
            all_case_results.append({
                "id": case_id, "category": category,
                "response": response, "passed": False, "checks_failed": ["request_error"],
            })
            continue

        passed, failed_checks = check_deterministic(case, response)
        cat_entry = per_category.setdefault(category, {"passed": 0, "total": 0})
        cat_entry["total"] += 1

        if passed:
            passed_total += 1
            cat_entry["passed"] += 1
            print(f"  PASS  {case_id}", flush=True)
        else:
            all_failures.append({
                "id": case_id, "category": category,
                "checks_failed": failed_checks, "response": response[:300],
            })
            print(f"  FAIL  {case_id}  {failed_checks}", flush=True)

        all_case_results.append({
            "id": case_id, "category": category,
            "response": response, "passed": passed, "checks_failed": failed_checks if not passed else [],
        })

    for cat, counts in per_category.items():
        counts["score"] = round(counts["passed"] / counts["total"], 3) if counts["total"] > 0 else 0.0

    det_score = round(passed_total / len(all_cases), 3) if all_cases else 0.0

    print(f"\n  Deterministic score: {det_score:.3f}  ({passed_total}/{len(all_cases)})", flush=True)
    print(f"  Per-category breakdown:", flush=True)
    for cat, counts in sorted(per_category.items()):
        print(f"    {cat:<28} {counts['score']:.3f}  ({counts['passed']}/{counts['total']})", flush=True)

    # ── STEP 4: Subjective judging ─────────────────────────────────────────────
    print(f"\n{'─'*70}", flush=True)
    print(f"  SUBJECTIVE JUDGING ({len(subjective_cases)} cases) via 35B on port {JUDGE_PORT}", flush=True)
    print(f"{'─'*70}", flush=True)

    per_case_subjective = []
    subjective_scores = []
    judge_scores_flat = []

    for case in subjective_cases:
        case_id = case["id"]
        response = all_responses.get(case_id, "")
        if not response or response.startswith("__ERROR__"):
            print(f"  [judge] {case_id}: no response — score=0.0", flush=True)
            per_case_subjective.append({
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
        print(f"{status} ({score:.3f}) — {result.get('note', '')[:60]}{err_note}", flush=True)

        per_case_subjective.append({
            "case_id": case_id,
            "category": case["category"],
            "response": response,
            "judge_result": result,
        })
        time.sleep(0.5)

    sanity_warn = check_judge_sanity(judge_scores_flat)
    if sanity_warn:
        print(f"\n  [WARN] Judge sanity: {sanity_warn}", file=sys.stderr)

    n_subj = len(subjective_cases)
    subj_score = round(sum(subjective_scores) / n_subj, 4) if n_subj > 0 else 0.0
    final_score = round(0.7 * det_score + 0.3 * subj_score, 4)

    print(f"\n  det={det_score:.3f}  subj={subj_score:.3f}  FINAL={final_score:.4f}", flush=True)

    # ── STEP 5: Write results ──────────────────────────────────────────────────
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    # Deterministic + perf result file
    det_out_path = RESULTS_DIR / f"cpu-sweep_{MODEL_ID}_{ts_str}.jsonl"
    det_row = {
        "phase": "cpu-only",
        "model_id": MODEL_ID,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "perf": {
            "label": MODEL_ID,
            "decode_p50_toks_s": tok_p50,
            "idle_rss_mb": rss_mb,
            "startup_s": startup_s,
            "errors": [],
            "note": "tok/s is word*1.3/elapsed estimate; CPU-only; no GPU phase",
        },
        "quality": {
            "total_cases": len(all_cases),
            "deterministic_score": det_score,
            "passed": passed_total,
            "failed": len(all_cases) - passed_total,
            "per_category": per_category,
            "failures": all_failures,
            "all_responses": all_case_results,  # full capture
        },
        "game_mode_tiers": ["unknown — dense 12B, RSS to be measured"],
        "reasoning_leak_check": "clean" if not has_leak else "WARNING:leak_detected",
    }
    with det_out_path.open("w", encoding="utf-8") as f:
        f.write(json.dumps(det_row, ensure_ascii=False) + "\n")
    print(f"\n  Det results written: {det_out_path}", flush=True)

    # Subjective result file
    subj_out_path = RESULTS_DIR / f"subjective_{MODEL_ID}.jsonl"
    with subj_out_path.open("w", encoding="utf-8") as f:
        for row in per_case_subjective:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"  Subj results written: {subj_out_path}", flush=True)

    # ── FINAL SUMMARY ──────────────────────────────────────────────────────────
    print(f"\n{'='*70}", flush=True)
    print(f"  FINAL SUMMARY — {MODEL_ID}", flush=True)
    print(f"{'='*70}", flush=True)
    print(f"  Deterministic  : {det_score:.3f}  ({passed_total}/{len(all_cases)})", flush=True)
    print(f"  Subjective     : {subj_score:.3f}  ({n_subj} cases)", flush=True)
    print(f"  FINAL (0.7/0.3): {final_score:.4f}", flush=True)
    print(f"  Tok/s p50 (CPU): {tok_p50:.1f} (approx)", flush=True)
    print(f"  Idle RSS       : {rss_mb} MB", flush=True)
    print(f"  Startup        : {startup_s}s", flush=True)
    print(f"  Reasoning leak : {'WARNING' if has_leak else 'clean'}", flush=True)
    if sanity_warn:
        print(f"  Judge sanity   : {sanity_warn}", flush=True)
    print(f"\n  Per-category (det):", flush=True)
    for cat, counts in sorted(per_category.items()):
        print(f"    {cat:<28} {counts['score']:.3f}  ({counts['passed']}/{counts['total']})", flush=True)
    print(f"\n  Files:", flush=True)
    print(f"    {det_out_path}", flush=True)
    print(f"    {subj_out_path}", flush=True)
    print(f"{'='*70}", flush=True)

    # Comparison reference
    print(f"\n  --- COMPARISON ---", flush=True)
    print(f"  prod-35B (ref)     det=0.771  subj=0.898†  FINAL=0.809†", flush=True)
    print(f"  gemma4-26b-a4b-it  det=0.743  subj=0.820   FINAL=0.766", flush=True)
    print(f"  gemma4-e2b-it      det=0.657  subj=0.795   FINAL=0.698  ← small-tier champ", flush=True)
    print(f"  gemma4-e4b-it      det=0.600  subj=0.817   FINAL=0.665", flush=True)
    print(f"  {MODEL_ID:<20} det={det_score:.3f}  subj={subj_score:.3f}   FINAL={final_score:.3f}", flush=True)
    print(f"  † 35B judged by gemma4-26b (cross-family) — not directly comparable", flush=True)


if __name__ == "__main__":
    main()
