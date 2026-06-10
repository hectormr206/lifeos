#!/usr/bin/env python3
"""brain_bench.py — Axi brain-model hardware-tier benchmark harness.

Measures a single "cell spec" (model + launch config) on port 18080 in
isolation, or can read metrics from a live in-place server (e.g. prod on
8080) when ``--live-pid`` is given (no server spawn).

Usage
-----
  # Spawn a new server on port 18080 and benchmark it:
  python3 brain_bench.py --spec qwen36-35b-a3b --model-path /path/to.gguf

  # Measure the live prod brain in-place (read-only):
  python3 brain_bench.py --live --live-port 8080 --live-pid <PID> --label "qwen36-35b-a3b-baseline"

  # With a RAM cap (uses systemd-run --scope):
  python3 brain_bench.py --spec qwen36-35b-a3b --model-path /path/to.gguf --memory-max 48G

Output
------
- JSONL row appended to results/<label>_<timestamp>.jsonl
- Human-readable summary table printed to stdout

Methodology (non-negotiable)
-----------------------------
1. Spawned servers use start_new_session=True on port 18080 (never 8080/8090).
2. Smoke test: poll /health until 200 OK (timeout 120 s) before timing.
3. Load check: warn loudly if /proc/loadavg 1-min > 2.0.
4. Warmup: first request timing discarded.
5. Metrics: startup_s, TTFT_ms (stream), decode tok/s, p50/p95 over N=10,
   idle_rss_mb, peak_hwm_mb, vram_used_mib (before+after).
6. KV-bleed probe: guards against slot contamination.
7. Results: JSONL to results/ dir + human table.
"""
from __future__ import annotations

import argparse
import json
import os
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
REPO_ROOT = Path(__file__).resolve().parents[3]
RESULTS_DIR = Path(__file__).resolve().parent / "results"
BENCH_PORT = 18080  # NEVER 8080 or 8090

# ── production-parity prompts (Spanish life-assistant) ──────────────────────
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
]

# ── data structures ─────────────────────────────────────────────────────────


@dataclass
class CellSpec:
    """Describes one benchmark cell (model config to test)."""
    label: str
    model_path: str
    mmproj: Optional[str] = None
    ngl: int = 999
    cpu_moe: bool = True
    ctx: int = 32768
    kv_dtype: str = "q8_0"
    extra_flags: list[str] = field(default_factory=list)
    memory_max: Optional[str] = None  # e.g. "48G" — triggers systemd-run scope


@dataclass
class BenchResult:
    """All metrics for one cell run."""
    label: str
    timestamp_utc: str
    machine_load_1min: float
    load_warning: bool

    # server startup
    startup_s: Optional[float]
    live_mode: bool  # True = measured in-place, no spawn

    # per-request stats (N=10 real runs after 1 warmup)
    n_runs: int
    ttft_p50_ms: float
    ttft_p95_ms: float
    ttft_mean_ms: float
    decode_p50_toks_s: float
    decode_p95_toks_s: float
    decode_mean_toks_s: float

    # memory
    idle_rss_mb: Optional[float]
    peak_hwm_mb: Optional[float]

    # VRAM
    vram_before_mib: Optional[int]
    vram_after_mib: Optional[int]
    vram_total_mib: Optional[int]

    # sanity checks
    kv_bleed_detected: bool

    # errors / notes
    errors: list[str] = field(default_factory=list)


# ── helpers ─────────────────────────────────────────────────────────────────


def read_loadavg() -> tuple[float, float, float]:
    parts = Path("/proc/loadavg").read_text().split()
    return float(parts[0]), float(parts[1]), float(parts[2])


def read_proc_mem(pid: int) -> dict[str, int]:
    """Return VmRSS and VmHWM in kB from /proc/<pid>/status."""
    result = {}
    status = Path(f"/proc/{pid}/status").read_text()
    for line in status.splitlines():
        for key in ("VmRSS", "VmHWM"):
            if line.startswith(f"{key}:"):
                result[key] = int(line.split()[1])
    return result


def query_vram() -> tuple[Optional[int], Optional[int]]:
    """Return (used_mib, total_mib) or (None, None) if nvidia-smi unavailable."""
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


def poll_health(port: int, timeout_s: int = 120) -> bool:
    """Poll /health until 200 OK or timeout. Return True if healthy."""
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if http_get_status(url) == 200:
            return True
        time.sleep(1)
    return False


def stream_request(port: int, prompt: str, max_tokens: int = 250) -> dict:
    """Send one streaming inference request. Return timing dict."""
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

    total_time = time.perf_counter() - t0
    total_chunks = reasoning_chunks + content_chunks
    return {
        "ttft_ms": round(ttft * 1000, 1) if ttft is not None else None,
        "total_s": round(total_time, 3),
        "decode_toks_s": round(total_chunks / total_time, 2) if total_time > 0 else 0.0,
    }


def kv_bleed_probe(port: int) -> bool:
    """Return True if KV-slot contamination is detected."""
    url = f"http://127.0.0.1:{port}/v1/chat/completions"

    def ask(msgs: list, max_tokens: int = 60) -> str:
        p = {"model": "bench", "messages": msgs, "max_tokens": max_tokens,
             "temperature": 0.0, "stream": False}
        req = urllib.request.Request(
            url, data=json.dumps(p).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read())
        return body["choices"][0]["message"].get("content") or ""

    marker = "XBLEED9472831"
    ask([{"role": "user", "content": f"Recordá este código secreto: {marker}"}])
    r2 = ask([{"role": "user", "content": "¿Cuánto es 3 + 3?"}])
    return marker in r2


def build_server_cmd(spec: CellSpec, port: int) -> list[str]:
    """Assemble the llama-server argv for a CellSpec."""
    cmd = ["/usr/bin/llama-server", "-m", spec.model_path]
    if spec.mmproj:
        cmd += ["--mmproj", spec.mmproj]
    cmd += [
        "-ngl", str(spec.ngl),
        "--jinja",
        "-c", str(spec.ctx),
        "--host", "127.0.0.1",
        "--port", str(port),
        "--cache-type-k", spec.kv_dtype,
        "--cache-type-v", spec.kv_dtype,
        "-fa", "on",
        "-b", "8192",
        "-ub", "4096",
        "-t", "8",
        "-tb", "16",
        "--temp", "0.6",
        "--top-p", "0.95",
        "--top-k", "20",
        "--min-p", "0.0",
        "-np", "1",
        "--no-mmap",
        "--mlock",
    ]
    if spec.cpu_moe:
        cmd.append("--cpu-moe")
    cmd += spec.extra_flags
    return cmd


def wrap_systemd(cmd: list[str], memory_max: str) -> list[str]:
    """Wrap a command in a systemd-run user scope with a RAM cap."""
    return [
        "systemd-run", "--user", "--scope",
        f"--property=MemoryMax={memory_max}",
        "--property=MemorySwapMax=0",
        "--",
    ] + cmd


# ── core bench logic ─────────────────────────────────────────────────────────


def run_bench_on_live(
    port: int,
    pid: int,
    label: str,
    n_runs: int = 10,
) -> BenchResult:
    """Measure a server that's already running in-place (read-only)."""
    ts = datetime.now(timezone.utc).isoformat()
    load1, _, _ = read_loadavg()
    load_warn = load1 > 2.0
    if load_warn:
        print(f"WARNING: 1-min load={load1:.2f} > 2.0 — latency results may be inflated!", file=sys.stderr)

    vram_before, vram_total = query_vram()

    # Warmup — discard
    print("  [warmup] discarding first request...", flush=True)
    stream_request(port, BENCH_PROMPTS[0])

    # Real runs
    ttfts: list[float] = []
    decodes: list[float] = []
    for i in range(n_runs):
        prompt = BENCH_PROMPTS[i % len(BENCH_PROMPTS)]
        r = stream_request(port, prompt)
        if r["ttft_ms"] is not None:
            ttfts.append(r["ttft_ms"])
        decodes.append(r["decode_toks_s"])
        print(f"  [{i+1}/{n_runs}] ttft={r['ttft_ms']}ms decode={r['decode_toks_s']}tok/s", flush=True)

    vram_after, _ = query_vram()

    mem = read_proc_mem(pid)
    rss_mb = round(mem.get("VmRSS", 0) / 1024, 1)
    hwm_mb = round(mem.get("VmHWM", 0) / 1024, 1)

    bleed = kv_bleed_probe(port)

    def p50(xs: list[float]) -> float:
        s = sorted(xs)
        return s[len(s) // 2] if s else 0.0

    def p95(xs: list[float]) -> float:
        s = sorted(xs)
        return s[int(len(s) * 0.95)] if s else 0.0

    return BenchResult(
        label=label,
        timestamp_utc=ts,
        machine_load_1min=load1,
        load_warning=load_warn,
        startup_s=None,
        live_mode=True,
        n_runs=n_runs,
        ttft_p50_ms=p50(ttfts),
        ttft_p95_ms=p95(ttfts),
        ttft_mean_ms=round(statistics.mean(ttfts), 1) if ttfts else 0.0,
        decode_p50_toks_s=p50(decodes),
        decode_p95_toks_s=p95(decodes),
        decode_mean_toks_s=round(statistics.mean(decodes), 2) if decodes else 0.0,
        idle_rss_mb=rss_mb,
        peak_hwm_mb=hwm_mb,
        vram_before_mib=vram_before,
        vram_after_mib=vram_after,
        vram_total_mib=vram_total,
        kv_bleed_detected=bleed,
    )


def run_bench_on_spec(
    spec: CellSpec,
    n_runs: int = 10,
) -> BenchResult:
    """Spawn a new server for spec on BENCH_PORT, measure, kill."""
    ts = datetime.now(timezone.utc).isoformat()
    load1, _, _ = read_loadavg()
    load_warn = load1 > 2.0
    if load_warn:
        print(f"WARNING: 1-min load={load1:.2f} > 2.0 — results may be inflated!", file=sys.stderr)

    errors: list[str] = []
    vram_before, vram_total = query_vram()

    cmd = build_server_cmd(spec, BENCH_PORT)
    if spec.memory_max:
        cmd = wrap_systemd(cmd, spec.memory_max)

    print(f"  Spawning: {' '.join(cmd[:6])}...", flush=True)
    t_spawn = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,  # own process group — never touches prod
    )
    pid = proc.pid

    print(f"  Polling /health on port {BENCH_PORT}...", flush=True)
    healthy = poll_health(BENCH_PORT, timeout_s=120)
    startup_s = round(time.perf_counter() - t_spawn, 2)

    if not healthy:
        errors.append(f"Server never became healthy after {startup_s:.0f}s")
        proc.kill()
        return BenchResult(
            label=spec.label, timestamp_utc=ts,
            machine_load_1min=load1, load_warning=load_warn,
            startup_s=startup_s, live_mode=False, n_runs=0,
            ttft_p50_ms=0, ttft_p95_ms=0, ttft_mean_ms=0,
            decode_p50_toks_s=0, decode_p95_toks_s=0, decode_mean_toks_s=0,
            idle_rss_mb=None, peak_hwm_mb=None,
            vram_before_mib=vram_before, vram_after_mib=None, vram_total_mib=vram_total,
            kv_bleed_detected=False, errors=errors,
        )

    print(f"  Server healthy in {startup_s}s — running {n_runs+1} requests (1 warmup)...", flush=True)

    # Warmup
    stream_request(BENCH_PORT, BENCH_PROMPTS[0])

    ttfts: list[float] = []
    decodes: list[float] = []
    for i in range(n_runs):
        prompt = BENCH_PROMPTS[i % len(BENCH_PROMPTS)]
        r = stream_request(BENCH_PORT, prompt)
        if r["ttft_ms"] is not None:
            ttfts.append(r["ttft_ms"])
        decodes.append(r["decode_toks_s"])
        print(f"  [{i+1}/{n_runs}] ttft={r['ttft_ms']}ms decode={r['decode_toks_s']}tok/s", flush=True)

    vram_after, _ = query_vram()

    mem = read_proc_mem(pid)
    rss_mb = round(mem.get("VmRSS", 0) / 1024, 1)
    hwm_mb = round(mem.get("VmHWM", 0) / 1024, 1)

    bleed = kv_bleed_probe(BENCH_PORT)

    # Graceful shutdown
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        proc.wait(timeout=10)
    except Exception:
        proc.kill()

    def p50(xs: list[float]) -> float:
        s = sorted(xs)
        return s[len(s) // 2] if s else 0.0

    def p95(xs: list[float]) -> float:
        s = sorted(xs)
        return s[int(len(s) * 0.95)] if s else 0.0

    return BenchResult(
        label=spec.label,
        timestamp_utc=ts,
        machine_load_1min=load1,
        load_warning=load_warn,
        startup_s=startup_s,
        live_mode=False,
        n_runs=n_runs,
        ttft_p50_ms=p50(ttfts),
        ttft_p95_ms=p95(ttfts),
        ttft_mean_ms=round(statistics.mean(ttfts), 1) if ttfts else 0.0,
        decode_p50_toks_s=p50(decodes),
        decode_p95_toks_s=p95(decodes),
        decode_mean_toks_s=round(statistics.mean(decodes), 2) if decodes else 0.0,
        idle_rss_mb=rss_mb,
        peak_hwm_mb=hwm_mb,
        vram_before_mib=vram_before,
        vram_after_mib=vram_after,
        vram_total_mib=vram_total,
        kv_bleed_detected=bleed,
        errors=errors,
    )


# ── output ───────────────────────────────────────────────────────────────────


def save_jsonl(result: BenchResult, results_dir: Path) -> Path:
    results_dir.mkdir(parents=True, exist_ok=True)
    safe_label = result.label.replace("/", "_").replace(" ", "_")
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = results_dir / f"{safe_label}_{ts_str}.jsonl"
    with out_path.open("w") as f:
        f.write(json.dumps(asdict(result)) + "\n")
    return out_path


def print_summary(result: BenchResult) -> None:
    w = 60
    print("\n" + "=" * w)
    print(f"  Brain Bench Results — {result.label}")
    print("=" * w)
    print(f"  Timestamp       : {result.timestamp_utc}")
    print(f"  Mode            : {'live (in-place)' if result.live_mode else 'spawned'}")
    print(f"  Machine load    : {result.machine_load_1min:.2f} {'⚠ HIGH' if result.load_warning else 'ok'}")
    print(f"  N runs          : {result.n_runs}")
    if result.startup_s is not None:
        print(f"  Startup         : {result.startup_s}s")
    print()
    print(f"  TTFT  p50       : {result.ttft_p50_ms:.1f} ms")
    print(f"  TTFT  p95       : {result.ttft_p95_ms:.1f} ms")
    print(f"  TTFT  mean      : {result.ttft_mean_ms:.1f} ms")
    print()
    print(f"  Decode p50      : {result.decode_p50_toks_s:.1f} tok/s")
    print(f"  Decode p95      : {result.decode_p95_toks_s:.1f} tok/s")
    print(f"  Decode mean     : {result.decode_mean_toks_s:.1f} tok/s")
    print()
    if result.idle_rss_mb is not None:
        print(f"  Idle RSS        : {result.idle_rss_mb:.0f} MB")
    if result.peak_hwm_mb is not None:
        print(f"  Peak VmHWM      : {result.peak_hwm_mb:.0f} MB")
    if result.vram_before_mib is not None:
        print(f"  VRAM before     : {result.vram_before_mib} MiB / {result.vram_total_mib} MiB")
    if result.vram_after_mib is not None:
        delta = (result.vram_after_mib or 0) - (result.vram_before_mib or 0)
        print(f"  VRAM after      : {result.vram_after_mib} MiB  (delta: {delta:+d} MiB)")
    print()
    print(f"  KV-bleed        : {'DETECTED ⚠' if result.kv_bleed_detected else 'clean'}")
    if result.errors:
        print()
        for e in result.errors:
            print(f"  ERROR: {e}")
    print("=" * w)


# ── CLI ──────────────────────────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Axi brain-model hardware-tier benchmark harness"
    )
    p.add_argument("--label", default="unnamed",
                   help="Human label for this cell (default: unnamed)")
    p.add_argument("--n-runs", type=int, default=10,
                   help="Number of real inference runs after warmup (default: 10)")
    p.add_argument("--results-dir", default=str(RESULTS_DIR),
                   help="Directory to write JSONL results (default: ./results)")

    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--live", action="store_true",
                      help="Measure a live server in-place (no spawn)")
    mode.add_argument("--model-path", metavar="PATH",
                      help="Path to GGUF model — spawns a new server on port 18080")

    p.add_argument("--live-port", type=int, default=8080,
                   help="Port of the live server (default: 8080, used with --live)")
    p.add_argument("--live-pid", type=int,
                   help="PID of the live llama-server (for /proc memory stats)")

    # Spawned-server options
    p.add_argument("--mmproj", help="mmproj GGUF path")
    p.add_argument("--ngl", type=int, default=999, help="GPU layers (-ngl)")
    p.add_argument("--no-cpu-moe", action="store_true", help="Disable --cpu-moe flag")
    p.add_argument("--ctx", type=int, default=32768, help="Context size")
    p.add_argument("--kv-dtype", default="q8_0", help="KV cache dtype (q8_0, q4_0, f16)")
    p.add_argument("--memory-max", metavar="SIZE",
                   help="RAM cap for systemd-run scope (e.g. 48G). Omit for uncapped baseline.")
    p.add_argument("--extra-flags", nargs="*", default=[],
                   help="Extra flags passed to llama-server verbatim")

    return p.parse_args()


def main() -> None:
    args = parse_args()
    results_dir = Path(args.results_dir)

    if args.live:
        if not args.live_pid:
            print("ERROR: --live requires --live-pid", file=sys.stderr)
            sys.exit(1)
        health = http_get_status(f"http://127.0.0.1:{args.live_port}/health")
        if health != 200:
            print(f"ERROR: live server on port {args.live_port} is not healthy (status={health})", file=sys.stderr)
            sys.exit(1)
        print(f"==> Live mode: measuring server on port {args.live_port}, pid={args.live_pid}")
        result = run_bench_on_live(
            port=args.live_port,
            pid=args.live_pid,
            label=args.label,
            n_runs=args.n_runs,
        )
    else:
        spec = CellSpec(
            label=args.label,
            model_path=args.model_path,
            mmproj=args.mmproj,
            ngl=args.ngl,
            cpu_moe=not args.no_cpu_moe,
            ctx=args.ctx,
            kv_dtype=args.kv_dtype,
            extra_flags=args.extra_flags or [],
            memory_max=args.memory_max,
        )
        print(f"==> Spawned mode: benchmarking spec '{spec.label}' on port {BENCH_PORT}")
        result = run_bench_on_spec(spec, n_runs=args.n_runs)

    print_summary(result)
    out_path = save_jsonl(result, results_dir)
    print(f"\nResults saved to: {out_path}")


if __name__ == "__main__":
    main()
