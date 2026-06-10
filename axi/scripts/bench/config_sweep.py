#!/usr/bin/env /home/hectormr/LifeOS/lifeos/axi/.venv/bin/python
"""config_sweep.py — Parameterized llama-server config-tuning perf harness.

Finds the best llama-server flags for 3 models by sweeping named configurations.

Usage
-----
  # Run all configs (DO NOT run while prod GPU is busy):
  python config_sweep.py --ts 20260610T200000Z

  # Filter to one group only:
  python config_sweep.py --ts 20260610T200000Z --only brain-ncpumoe

  # Filter by config name prefix:
  python config_sweep.py --ts 20260610T200000Z --only brain-draft

  # Dry-run: just print configs that would run:
  python config_sweep.py --ts 20260610T200000Z --only brain-mtp --dry-run

Output
------
  results/config-sweep_<ts>.jsonl   — one JSONL row per config
  Summary table printed to stdout on completion.

Safety rules (same as all bench scripts)
-----------------------------------------
  - BENCH_PORT = 18080 ONLY — never 8080 (prod) or 8090 (nano)
  - CUDA_VISIBLE_DEVICES left unchanged — the RUNNER ensures GPU is free
  - Each server gets a clean spawn + SIGTERM-to-pgid kill
  - Port release verified before next spawn
  - Health poll timeout = 300s; configs that time out record error and continue
  - OOM / crash → oom=True recorded, sweep continues to next config
  - DO NOT touch prod on 8080 or nano on 8090

Verified flag names (from `llama-server --help` on this machine)
-----------------------------------------------------------------
  CONFIRMED PRESENT:
    --cpu-moe / -cmoe             : keep ALL MoE expert weights on CPU
    --n-cpu-moe / -ncmoe N        : keep first N layers' MoE experts on CPU
                                    (NOTE: lower N = more experts on GPU)
    --cache-type-k / -ctk TYPE    : KV cache K dtype (q8_0, q4_0, f16, …)
    --cache-type-v / -ctv TYPE    : KV cache V dtype
    --spec-draft-model / -md      : path to draft model (alias: --model-draft)
    --spec-draft-n-max N          : max draft tokens (replaces removed --draft-max)
    --spec-draft-n-min N          : min draft tokens (replaces removed --draft-min)
    --spec-draft-p-min P          : min speculative probability (alias: --draft-p-min)
    --spec-type TYPE              : speculative type; valid: none, draft-simple,
                                    draft-eagle3, draft-mtp, ngram-simple, …
    --reasoning-format FORMAT     : controls thought tag extraction
    -rea / --reasoning [on|off|auto]

  REMOVED / RENAMED (do NOT use):
    --draft-max   → removed; use --spec-draft-n-max
    --draft-min   → removed; use --spec-draft-n-min
    --draft       / --draft-n / --draft-max → all removed

Brain model block count: 40 (read from GGUF metadata: qwen35moe.block_count=40)
Expert count: 256, expert_used_count: 8 (sparse MoE)

n-cpu-moe sweep rationale (--n-cpu-moe N means first N layers' experts stay CPU):
  - N=40 ≈ all layers on CPU (same as --cpu-moe baseline)
  - Lower N = more GPU. We sweep N in {40, 32, 24, 16, 8, 4, 0} descending.
  - N=0 means all experts on GPU — will likely OOM on 12GB; recorded as oom=True.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import statistics
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ── paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
MODELS_DIR = Path("/home/hectormr/LifeOS/models")

BENCH_PORT = 18080  # NEVER 8080 (prod) or 8090 (nano)

# ── production-parity prompts (Spanish life-assistant, same as other bench scripts) ──
SYSTEM_PROMPT = (
    "Sos Axi, un asistente de vida personal en español rioplatense. "
    "Respondé de forma concisa y útil."
)
BENCH_PROMPTS = [
    "Hola Axi! Recordame qué tengo que hacer hoy si mañana tengo una reunión importante a las 9am.",
    "¿Cuál es la mejor forma de organizar mis gastos mensuales?",
    "Necesito preparar una presentación para el trabajo. ¿Por dónde empiezo?",
    "¿Qué ejercicios puedo hacer en casa sin equipamiento?",
    "¿Cómo puedo mejorar mi concentración cuando estudio?",
    "¿Cómo organizo mejor mi agenda semanal?",
    "Dame 3 consejos para mejorar mis hábitos de sueño.",
    "¿Qué hago si se me acumula el trabajo y no sé por dónde empezar?",
    "¿Cómo puedo ahorrar dinero de forma sencilla?",
    "¿Cuál es la diferencia entre urgente e importante?",
]

# ── model paths ────────────────────────────────────────────────────────────────
BRAIN_GGUF = MODELS_DIR / "Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf"
BRAIN_MMPROJ = MODELS_DIR / "Qwen3.6-35B-A3B/mmproj-BF16.gguf"
NANO_DRAFT_GGUF = MODELS_DIR / "qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf"
MTP_GGUF = MODELS_DIR / "qwen36-35b-mtp/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf"
# MTP reuses the same mmproj as the brain model
MTP_MMPROJ = BRAIN_MMPROJ

E2B_GGUF = MODELS_DIR / "gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf"
E2B_MMPROJ = MODELS_DIR / "gemma4-e2b-it/mmproj-BF16.gguf"

# ── brain base flags (shared across all brain configs) ────────────────────────
# From prod: -ngl 999 -fa on --cache-type-k q8_0 --cache-type-v q8_0
#            --reasoning-format auto -c 32768 -b 8192 -ub 4096 -t 8 -tb 16
BRAIN_BASE_FLAGS = [
    "-ngl", "999",
    "-fa", "on",
    "--reasoning-format", "auto",
    "--jinja",
    "-c", "32768",
    "-b", "8192",
    "-ub", "4096",
    "-t", "8",
    "-tb", "16",
    "--no-mmap",
]

# n-cpu-moe sweep values for brain-ncpumoe group.
# Brain has block_count=40. N=40 ≈ all-on-CPU baseline. N=0 = all-on-GPU (expected OOM).
# Descending: more GPU as N decreases.
N_CPU_MOE_VALUES = [36, 34, 33, 30]  # whisper-safe refine: 2.3GB whisper co-resident → brain must fit ~8.7GB


# ── config dataclass ───────────────────────────────────────────────────────────

@dataclass
class BenchConfig:
    name: str                      # unique config name, used for --only filtering
    group: str                     # group name (brain-ncpumoe, brain-draft, brain-mtp, e2b-kv)
    model: str                     # short model label
    gguf: Path                     # main model gguf path
    flags: list[str]               # full flag list (excluding -m <gguf> --host --port)
    flags_summary: str             # human-readable flag summary for the JSONL row
    skip_if_missing: list[Path] = field(default_factory=list)  # skip config if any path missing
    is_speculative: bool = False   # whether to try to capture accept_rate from /metrics


# ── config registry ───────────────────────────────────────────────────────────

def build_configs() -> list[BenchConfig]:
    configs: list[BenchConfig] = []

    # ── GROUP: brain-ncpumoe ──────────────────────────────────────────────────
    # Baseline: all experts on CPU via --cpu-moe (current prod behaviour)
    configs.append(BenchConfig(
        name="brain-cpumoe-baseline",
        group="brain-ncpumoe",
        model="Qwen3.6-35B-A3B-MXFP4_MOE",
        gguf=BRAIN_GGUF,
        flags=BRAIN_BASE_FLAGS + [
            "--mmproj", str(BRAIN_MMPROJ),
            "--cpu-moe",   # all MoE expert weights stay on CPU
        ],
        flags_summary="--cpu-moe (all experts CPU, ~5GB VRAM, current prod)",
        skip_if_missing=[BRAIN_GGUF, BRAIN_MMPROJ],
        is_speculative=False,
    ))

    # --n-cpu-moe N sweep: keep first N layers' experts on CPU; rest go to GPU.
    # Lower N = more experts on GPU. N=40 ≈ --cpu-moe (all layers on CPU).
    for n in N_CPU_MOE_VALUES:
        configs.append(BenchConfig(
            name=f"brain-ncpumoe-{n}",
            group="brain-ncpumoe",
            model="Qwen3.6-35B-A3B-MXFP4_MOE",
            gguf=BRAIN_GGUF,
            flags=BRAIN_BASE_FLAGS + [
                "--mmproj", str(BRAIN_MMPROJ),
                "--n-cpu-moe", str(n),
            ],
            flags_summary=f"--n-cpu-moe {n} (first {n}/40 layers' experts on CPU, rest on GPU)",
            skip_if_missing=[BRAIN_GGUF, BRAIN_MMPROJ],
            is_speculative=False,
        ))

    # ── GROUP: brain-draft ────────────────────────────────────────────────────
    # Speculative decoding: 35B main + 0.8B nano as draft model.
    # Uses --cpu-moe for main model (conservative baseline for fair comparison).
    # Flag names verified: --spec-draft-model (-md), --spec-draft-n-max,
    #                      --spec-draft-n-min, --spec-draft-p-min
    configs.append(BenchConfig(
        name="brain-draft-nano",
        group="brain-draft",
        model="Qwen3.6-35B-A3B-MXFP4_MOE + Qwen3.5-0.8B-Q4_K_M (draft)",
        gguf=BRAIN_GGUF,
        flags=BRAIN_BASE_FLAGS + [
            "--mmproj", str(BRAIN_MMPROJ),
            "--cpu-moe",
            "--spec-type", "draft-simple",
            "--spec-draft-model", str(NANO_DRAFT_GGUF),
            "--spec-draft-n-max", "8",
            "--spec-draft-n-min", "1",
            "--spec-draft-p-min", "0.1",
        ],
        flags_summary=(
            "--cpu-moe --spec-type draft-simple "
            "--spec-draft-model qwen35-0.8b "
            "--spec-draft-n-max 8 --spec-draft-n-min 1 --spec-draft-p-min 0.1"
        ),
        skip_if_missing=[BRAIN_GGUF, BRAIN_MMPROJ, NANO_DRAFT_GGUF],
        is_speculative=True,
    ))

    # ── GROUP: brain-mtp ──────────────────────────────────────────────────────
    # Built-in MTP (Multi-Token Prediction) speculative decoding.
    # Uses a separate MTP-capable gguf which may not be downloaded yet.
    # --spec-type draft-mtp is the correct flag (verified from llama-server --help).
    # --spec-draft-n-max controls number of MTP tokens to speculate.
    configs.append(BenchConfig(
        name="brain-mtp",
        group="brain-mtp",
        model="Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL",
        gguf=MTP_GGUF,
        flags=BRAIN_BASE_FLAGS + [
            "--mmproj", str(MTP_MMPROJ),
            "--cpu-moe",
            "--spec-type", "draft-mtp",
            "--spec-draft-n-max", "3",   # conservative start for MTP
        ],
        flags_summary=(
            "--cpu-moe --spec-type draft-mtp --spec-draft-n-max 3"
        ),
        skip_if_missing=[MTP_GGUF, MTP_MMPROJ],  # MTP gguf may not be present yet
        is_speculative=True,
    ))

    # ── GROUP: e2b-kv ─────────────────────────────────────────────────────────
    # Gemma4-E2B KV cache quant comparison — full GPU (-ngl 999), no MoE flags.
    # --reasoning off because Gemma4 family needs it to suppress thinking trace.
    E2B_BASE_FLAGS = [
        "-ngl", "999",
        "-fa", "on",
        "--reasoning", "off",
        "--jinja",
        "-c", "16384",
        "-b", "8192",
        "-ub", "4096",
        "-t", "8",
        "-tb", "16",
        "--no-mmap",
        "--mmproj", str(E2B_MMPROJ),
    ]

    configs.append(BenchConfig(
        name="e2b-kv-q8",
        group="e2b-kv",
        model="gemma-4-E2B-it-Q4_K_M",
        gguf=E2B_GGUF,
        flags=E2B_BASE_FLAGS + [
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
        ],
        flags_summary="-ngl 999 --cache-type-k q8_0 --cache-type-v q8_0 (current)",
        skip_if_missing=[E2B_GGUF, E2B_MMPROJ],
        is_speculative=False,
    ))

    configs.append(BenchConfig(
        name="e2b-kv-q4",
        group="e2b-kv",
        model="gemma-4-E2B-it-Q4_K_M",
        gguf=E2B_GGUF,
        flags=E2B_BASE_FLAGS + [
            "--cache-type-k", "q4_0",
            "--cache-type-v", "q4_0",
        ],
        flags_summary="-ngl 999 --cache-type-k q4_0 --cache-type-v q4_0 (reduced VRAM)",
        skip_if_missing=[E2B_GGUF, E2B_MMPROJ],
        is_speculative=False,
    ))

    return configs


# ── statistics helpers ─────────────────────────────────────────────────────────

def p50(xs: list[float]) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    return s[len(s) // 2]


def p95(xs: list[float]) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    return s[int(len(s) * 0.95)]


# ── VRAM helpers ───────────────────────────────────────────────────────────────

def query_vram() -> Optional[int]:
    """Return current VRAM used in MiB via nvidia-smi, or None on failure."""
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            text=True, timeout=10
        ).strip()
        return int(out.split()[0])
    except Exception:
        return None


class VramPoller:
    """Background thread that polls nvidia-smi every second and tracks peak VRAM."""

    def __init__(self) -> None:
        self._peak: Optional[int] = None
        self._running = False
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._running = True
        self._peak = query_vram()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while self._running:
            v = query_vram()
            if v is not None:
                self._peak = max(self._peak or 0, v)
            time.sleep(1.0)

    def stop(self) -> Optional[int]:
        self._running = False
        if self._thread:
            self._thread.join(timeout=5)
        return self._peak


# ── HTTP helpers ───────────────────────────────────────────────────────────────

def http_get_status(url: str, timeout: int = 5) -> int:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def http_get_json(url: str, timeout: int = 10) -> Optional[dict]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


def poll_health(port: int, timeout_s: int = 300) -> bool:
    """Poll /health until 200 OK or timeout. Returns True if healthy."""
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if http_get_status(url) == 200:
            return True
        time.sleep(3)
    return False


def wait_port_free(port: int, timeout_s: int = 30) -> bool:
    """Wait until nothing is listening on the port. Returns True if free."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["ss", "-tlnp", f"sport = :{port}"],
            capture_output=True, text=True, timeout=5
        )
        if str(port) not in result.stdout:
            return True
        time.sleep(2)
    return False


# ── SSE streaming request with TTFT measurement ───────────────────────────────

def stream_request(port: int, prompt: str, max_tokens: int = 250) -> dict:
    """Send one streaming inference request. Measures TTFT across reasoning_content+content.

    Returns dict with ttft_ms, total_s, decode_toks_s, error (or None).
    Token count is chunk-based (same idiom as bench_35b_prod_brain.py and brain_bench.py).
    """
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    payload = {
        "model": "bench",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max_tokens,
        "temperature": 0.6,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "stream": True,
        # For Qwen3 family: disable thinking during perf measurement (reduces noise)
        "chat_template_kwargs": {"enable_thinking": False},
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
                # Track TTFT across both reasoning_content AND content (Qwen3 thinking models)
                rc = delta.get("reasoning_content") or ""
                ct = delta.get("content") or ""
                if (rc or ct) and ttft is None:
                    ttft = time.perf_counter() - t0
                if rc:
                    reasoning_chunks += 1
                if ct:
                    content_chunks += 1
    except Exception as e:
        return {
            "ttft_ms": None,
            "total_s": round(time.perf_counter() - t0, 3),
            "decode_toks_s": 0.0,
            "error": str(e),
        }

    total_time = time.perf_counter() - t0
    total_chunks = reasoning_chunks + content_chunks
    return {
        "ttft_ms": round(ttft * 1000, 1) if ttft is not None else None,
        "total_s": round(total_time, 3),
        "decode_toks_s": round(total_chunks / total_time, 2) if total_time > 0 else 0.0,
        "error": None,
    }


# ── /metrics acceptance rate extraction ───────────────────────────────────────

def fetch_accept_rate(port: int) -> Optional[float]:
    """Try to parse speculative decoding acceptance rate from /metrics (Prometheus format).

    Returns acceptance rate as float in [0, 1], or None if not available.
    The server exposes speculative stats under labels like:
      llamacpp:speculative_accepted_tokens_total
      llamacpp:speculative_draft_tokens_total
    """
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=10) as resp:
            text = resp.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    accepted: Optional[float] = None
    drafted: Optional[float] = None

    for line in text.splitlines():
        if line.startswith("#"):
            continue
        if "speculative_accepted_tokens_total" in line and not line.startswith("#"):
            try:
                accepted = float(line.split()[-1])
            except (ValueError, IndexError):
                pass
        if "speculative_draft_tokens_total" in line and not line.startswith("#"):
            try:
                drafted = float(line.split()[-1])
            except (ValueError, IndexError):
                pass

    if drafted is not None and drafted > 0 and accepted is not None:
        return round(accepted / drafted, 4)
    return None


# ── server lifecycle ───────────────────────────────────────────────────────────

def kill_server_on_port(port: int) -> None:
    """Kill any llama-server process on the given port. Verifies port is released."""
    try:
        subprocess.run(
            ["pkill", "-f", f"[l]lama-server.*{port}"],
            capture_output=True, timeout=10
        )
    except Exception:
        pass
    time.sleep(2)
    # Also try via lsof/fuser if pkill missed it
    try:
        result = subprocess.run(
            ["fuser", "-k", f"{port}/tcp"],
            capture_output=True, timeout=10
        )
    except Exception:
        pass
    time.sleep(2)


def kill_server(proc: subprocess.Popen, pid: int) -> None:
    """Send SIGTERM to the process group, then wait. Fall back to SIGKILL."""
    try:
        pgid = os.getpgid(pid)
        os.killpg(pgid, signal.SIGTERM)
        proc.wait(timeout=15)
    except ProcessLookupError:
        pass  # already gone
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
    time.sleep(3)


def spawn_server(config: BenchConfig) -> tuple[Optional[subprocess.Popen], int, float, Optional[str]]:
    """Spawn llama-server on BENCH_PORT for the given config.

    Returns (proc, pid, startup_s, error_message_or_None).
    If error_message is not None, the server did not become healthy.
    """
    cmd = ["/usr/bin/llama-server", "-m", str(config.gguf)]
    cmd += config.flags
    cmd += ["--host", "127.0.0.1", "--port", str(BENCH_PORT)]

    env = os.environ.copy()
    # Note: we do NOT force CUDA_VISIBLE_DEVICES — the RUNNER ensures GPU is free.
    # The bench script itself must not interfere with CUDA device assignment.

    short_name = config.gguf.name[:50]
    print(f"  Spawning: llama-server -m ...{short_name} [port {BENCH_PORT}]", flush=True)
    print(f"  Flags: {config.flags_summary}", flush=True)

    t_spawn = time.perf_counter()
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # own process group — isolates from parent
            env=env,
        )
    except Exception as e:
        return None, -1, 0.0, f"Popen failed: {e}"

    healthy = poll_health(BENCH_PORT, timeout_s=300)
    startup_s = round(time.perf_counter() - t_spawn, 2)

    if not healthy:
        # Check if process already exited (OOM, bad flags, etc.)
        ret = proc.poll()
        if ret is not None:
            error = f"Server exited with code {ret} after {startup_s:.0f}s (OOM or bad flags)"
        else:
            error = f"Server never became healthy after {startup_s:.0f}s (health poll timeout)"
            proc.kill()
        return proc, proc.pid, startup_s, error

    return proc, proc.pid, startup_s, None


# ── core measurement loop ──────────────────────────────────────────────────────

DEFAULT_N_RUNS = 9   # 1 warmup discarded + 9 measured = ~10 total requests


def measure_config(config: BenchConfig, n_runs: int = DEFAULT_N_RUNS) -> dict:
    """Run full measurement cycle for one config. Returns result dict.

    Steps:
    1. Pre-flight checks (gguf existence, port free)
    2. Spawn server
    3. 1 warmup request (discarded)
    4. N_BENCH_RUNS timed requests (VRAM polled in background)
    5. Fetch /metrics for accept_rate if speculative
    6. Kill server, verify port released
    7. Return result dict
    """
    result: dict = {
        "config_name": config.name,
        "group": config.group,
        "model": config.model,
        "flags_summary": config.flags_summary,
        "decode_p50": None,
        "decode_p95": None,
        "ttft_p50": None,
        "peak_vram_mib": None,
        "startup_s": None,
        "accept_rate": None,
        "oom": False,
        "error": None,
    }

    # ── 1. pre-flight: check required files exist ──────────────────────────────
    for path in config.skip_if_missing:
        if not path.exists():
            result["error"] = f"gguf not present yet: {path}"
            print(f"  [SKIP] {config.name}: {result['error']}", flush=True)
            return result

    # ── 2. ensure port 18080 is free before spawning ───────────────────────────
    if http_get_status(f"http://127.0.0.1:{BENCH_PORT}/health") == 200:
        print(f"  [WARN] Port {BENCH_PORT} already occupied — killing...", flush=True)
        kill_server_on_port(BENCH_PORT)
        if not wait_port_free(BENCH_PORT, timeout_s=30):
            result["error"] = f"Port {BENCH_PORT} could not be freed before spawn"
            return result

    # ── 3. spawn server ────────────────────────────────────────────────────────
    proc, pid, startup_s, spawn_error = spawn_server(config)
    result["startup_s"] = startup_s

    if spawn_error:
        # Determine if this looks like an OOM (exit code 137 = SIGKILL = OOM)
        if proc is not None:
            retcode = proc.poll()
            if retcode in (-9, 137) or "OOM" in spawn_error or "exited with code" in spawn_error:
                result["oom"] = True
        result["error"] = spawn_error
        print(f"  [FAIL] {config.name}: {spawn_error}", flush=True)
        kill_server_on_port(BENCH_PORT)
        wait_port_free(BENCH_PORT, timeout_s=20)
        return result

    print(f"  Server healthy in {startup_s}s", flush=True)

    # ── 4. warmup (discarded) ──────────────────────────────────────────────────
    print(f"  Warmup (1 request, discarded)...", flush=True)
    stream_request(BENCH_PORT, BENCH_PROMPTS[0])

    # ── 5. measurement runs with background VRAM polling ──────────────────────
    vram_poller = VramPoller()
    vram_poller.start()

    ttfts: list[float] = []
    decodes: list[float] = []
    errors_in_run: list[str] = []

    for i in range(n_runs):
        prompt = BENCH_PROMPTS[i % len(BENCH_PROMPTS)]
        r = stream_request(BENCH_PORT, prompt)
        if r.get("error"):
            errors_in_run.append(f"run {i+1}: {r['error']}")
            print(f"  [{i+1}/{n_runs}] ERROR: {r['error']}", flush=True)
        else:
            if r["ttft_ms"] is not None:
                ttfts.append(r["ttft_ms"])
            decodes.append(r["decode_toks_s"])
            print(
                f"  [{i+1}/{n_runs}] "
                f"ttft={r['ttft_ms']}ms "
                f"decode={r['decode_toks_s']:.1f}tok/s",
                flush=True,
            )

    peak_vram = vram_poller.stop()

    # ── 6. fetch accept_rate from /metrics if speculative ─────────────────────
    accept_rate: Optional[float] = None
    if config.is_speculative:
        accept_rate = fetch_accept_rate(BENCH_PORT)
        if accept_rate is not None:
            print(f"  Accept rate: {accept_rate:.3f} ({accept_rate*100:.1f}%)", flush=True)
        else:
            print("  Accept rate: not available in /metrics", flush=True)

    # ── 7. kill server and release port ───────────────────────────────────────
    kill_server(proc, pid)
    released = wait_port_free(BENCH_PORT, timeout_s=30)
    if not released:
        print(f"  [WARN] Port {BENCH_PORT} not released after kill — forcing...", flush=True)
        kill_server_on_port(BENCH_PORT)
        wait_port_free(BENCH_PORT, timeout_s=15)

    # ── 8. aggregate stats ─────────────────────────────────────────────────────
    if decodes:
        result["decode_p50"] = round(p50(decodes), 2)
        result["decode_p95"] = round(p95(decodes), 2)
    if ttfts:
        result["ttft_p50"] = round(p50(ttfts), 1)
    result["peak_vram_mib"] = peak_vram
    result["accept_rate"] = accept_rate

    if errors_in_run:
        result["error"] = "; ".join(errors_in_run)

    return result


# ── summary table ──────────────────────────────────────────────────────────────

def print_summary_table(results: list[dict]) -> None:
    print()
    print("=" * 100)
    print("  CONFIG SWEEP RESULTS")
    print("=" * 100)
    header = (
        f"  {'CONFIG NAME':<30} {'GROUP':<16} "
        f"{'DEC_P50':>8} {'DEC_P95':>8} {'TTFT_P50':>9} "
        f"{'VRAM_MiB':>9} {'STARTUP':>8} {'ACCEPT':>8} "
        f"{'OOM':>4} {'ERROR'}"
    )
    print(header)
    print("  " + "-" * 97)

    by_group: dict[str, list[dict]] = {}
    for r in results:
        by_group.setdefault(r["group"], []).append(r)

    for group, group_results in by_group.items():
        for r in group_results:
            decode_p50 = f"{r['decode_p50']:.1f}" if r["decode_p50"] is not None else "—"
            decode_p95 = f"{r['decode_p95']:.1f}" if r["decode_p95"] is not None else "—"
            ttft_p50 = f"{r['ttft_p50']:.0f}ms" if r["ttft_p50"] is not None else "—"
            vram = f"{r['peak_vram_mib']}" if r["peak_vram_mib"] is not None else "—"
            startup = f"{r['startup_s']:.1f}s" if r["startup_s"] is not None else "—"
            accept = f"{r['accept_rate']:.3f}" if r["accept_rate"] is not None else "—"
            oom = "YES" if r["oom"] else "no"
            error = (r["error"] or "")[:40]
            print(
                f"  {r['config_name']:<30} {r['group']:<16} "
                f"{decode_p50:>8} {decode_p95:>8} {ttft_p50:>9} "
                f"{vram:>9} {startup:>8} {accept:>8} "
                f"{oom:>4}  {error}"
            )
        print("  " + "-" * 97)

    print("=" * 100)
    print()
    print("  Units: decode tok/s (higher is better), TTFT ms (lower is better)")
    print("  VRAM MiB = peak during generation (nvidia-smi, 1s poll)")
    print("  accept = speculative draft acceptance rate (0-1), null if non-speculative or unavailable")
    print("=" * 100)


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Parameterized llama-server config-tuning perf harness for Axi brain models.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Groups available:
  brain-ncpumoe   Qwen3.6-35B MoE expert placement sweep (--cpu-moe vs --n-cpu-moe N)
  brain-draft     Speculative decoding with Qwen3.5-0.8B nano as draft model
  brain-mtp       Built-in MTP speculative decoding (requires separate MTP gguf)
  e2b-kv          Gemma4-E2B KV cache quant comparison (q8_0 vs q4_0)

Individual config names can also be used with --only (prefix match):
  --only brain-ncpumoe-16
  --only brain-cpumoe-baseline

DO NOT run while prod GPU is busy. Take Axi offline first.
Output: results/config-sweep_<ts>.jsonl
        """,
    )
    parser.add_argument(
        "--ts",
        required=True,
        help="Timestamp string for output filename, e.g. 20260610T200000Z (do not call Date.now — pass it explicitly)",
    )
    parser.add_argument(
        "--only",
        default=None,
        help="Run only configs whose name OR group starts with this prefix (case-insensitive)",
    )
    parser.add_argument(
        "--n-runs",
        type=int,
        default=DEFAULT_N_RUNS,
        help=f"Number of timed runs per config after warmup (default: {DEFAULT_N_RUNS})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print configs that would run without actually running them",
    )
    args = parser.parse_args()

    # Override module-level constant if user provides --n-runs
    n_runs = args.n_runs

    all_configs = build_configs()

    # Apply --only filter (prefix match on name OR group, case-insensitive)
    if args.only:
        prefix = args.only.lower()
        selected = [
            c for c in all_configs
            if c.name.lower().startswith(prefix) or c.group.lower().startswith(prefix)
        ]
        if not selected:
            print(f"ERROR: --only '{args.only}' matched no configs.", file=sys.stderr)
            print("Available names/groups:", file=sys.stderr)
            for c in all_configs:
                print(f"  {c.name}  ({c.group})", file=sys.stderr)
            sys.exit(1)
    else:
        selected = all_configs

    print("=" * 70)
    print("  config_sweep.py — Axi brain config-tuning harness")
    print(f"  Output timestamp: {args.ts}")
    print(f"  Configs to run: {len(selected)}")
    print(f"  Bench runs per config: {n_runs} (+ 1 warmup discarded)")
    print(f"  Port: {BENCH_PORT}")
    print("=" * 70)

    if args.dry_run:
        print("\n  DRY RUN — configs that would execute:\n")
        for i, c in enumerate(selected, 1):
            present = all(p.exists() for p in c.skip_if_missing)
            status = "ok" if present else "MISSING_GGUF"
            print(f"  [{i:02d}] {c.name:<30}  group={c.group}  status={status}")
            print(f"       flags: {c.flags_summary}")
        print()
        sys.exit(0)

    # Safety check: ensure prod on 8080 is NOT on the bench port
    if http_get_status(f"http://127.0.0.1:{BENCH_PORT}/health") == 200:
        print(
            f"ERROR: Something is already healthy on port {BENCH_PORT}!",
            file=sys.stderr,
        )
        print(
            f"Run: pkill -f '[l]lama-server.*{BENCH_PORT}'",
            file=sys.stderr,
        )
        sys.exit(1)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    output_path = RESULTS_DIR / f"config-sweep_{args.ts}.jsonl"

    all_results: list[dict] = []

    for i, config in enumerate(selected, 1):
        print(f"\n{'='*70}")
        print(f"  [{i}/{len(selected)}] {config.name}  (group: {config.group})")
        print(f"{'='*70}")

        result = measure_config(config, n_runs=n_runs)
        all_results.append(result)

        # Append result row immediately (crash-safe — partial results are useful)
        with open(output_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(result, ensure_ascii=False) + "\n")

        status = "OOM" if result["oom"] else ("ERROR" if result["error"] else "OK")
        decode = f"{result['decode_p50']:.1f} tok/s" if result["decode_p50"] else "—"
        ttft = f"{result['ttft_p50']:.0f}ms" if result["ttft_p50"] else "—"
        vram = f"{result['peak_vram_mib']} MiB" if result["peak_vram_mib"] else "—"
        print(f"  Result: {status}  decode_p50={decode}  ttft_p50={ttft}  peak_vram={vram}")

        # Brief pause between configs to let GPU/CPU cool and VRAM settle
        if i < len(selected):
            print("  Waiting 5s before next config...", flush=True)
            time.sleep(5)

    print_summary_table(all_results)
    print(f"\n  Results written to: {output_path}")


if __name__ == "__main__":
    main()
