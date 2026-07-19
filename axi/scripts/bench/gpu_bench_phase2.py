#!/usr/bin/env python3
"""gpu_bench_phase2.py — GPU VRAM tier benchmark for Axi brain models.

Measures each cell on port 18080 in isolation:
  - Big-tier models (35B, 26B, 30B) at various GPU configs
  - Small keeper models at full GPU offload

Output: JSONL + updates to RANKING.md
"""
from __future__ import annotations

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

BENCH_PORT = 18080
RESULTS_DIR = (Path.home() / "LifeOS/lifeos/axi/scripts/bench/results")
MODELS_DIR = (Path.home() / "LifeOS/models")
RANKING_MD = RESULTS_DIR / "RANKING.md"

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

N_RUNS = 10


@dataclass
class CellResult:
    label: str
    model: str
    config: str          # brief description of flags used
    ngl: int
    cpu_moe: bool
    ctx: int
    timestamp_utc: str
    startup_s: Optional[float]
    n_runs: int
    ttft_p50_ms: float
    ttft_p95_ms: float
    decode_p50_toks_s: float
    decode_p95_toks_s: float
    decode_mean_toks_s: float
    vram_before_mib: Optional[int]
    vram_peak_mib: Optional[int]    # measured while generating
    vram_delta_mib: Optional[int]   # peak - before
    oom: bool = False
    error: str = ""


def query_vram() -> Optional[int]:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            text=True, timeout=5
        ).strip()
        return int(out.strip().split()[0])
    except Exception:
        return None


def kill_bench_server():
    """Kill any llama-server on 18080 and wait for VRAM to release."""
    subprocess.run(["pkill", "-f", "[l]lama-server.*18080"], capture_output=True)
    time.sleep(3)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        vram = query_vram()
        if vram is not None and vram < 500:
            return
        time.sleep(2)
    print("  WARNING: VRAM did not fully release after kill, continuing anyway", flush=True)


def poll_health(port: int, timeout_s: int = 180) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(2)
    return False


def stream_request(port: int, prompt: str, extra_body: dict | None = None) -> dict:
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    payload = {
        "model": "bench",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": 250,
        "temperature": 0.6,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "stream": True,
    }
    if extra_body:
        payload.update(extra_body)

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft: Optional[float] = None
    chunk_count = 0

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
            if rc or ct:
                chunk_count += 1

    total_time = time.perf_counter() - t0
    return {
        "ttft_ms": round(ttft * 1000, 1) if ttft is not None else None,
        "total_s": round(total_time, 3),
        "decode_toks_s": round(chunk_count / total_time, 2) if total_time > 0 else 0.0,
    }


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


def run_cell(
    label: str,
    model: str,
    model_path: str,
    mmproj: Optional[str],
    ngl: int,
    cpu_moe: bool,
    ctx: int,
    extra_flags: list[str] | None = None,
    extra_body: dict | None = None,
) -> CellResult:
    ts = datetime.now(timezone.utc).isoformat()
    config_parts = [f"ngl={ngl}"]
    if cpu_moe:
        config_parts.append("cpu-moe")
    config_parts.append(f"ctx={ctx}")
    if extra_flags:
        config_parts.extend(extra_flags)
    config_str = " ".join(config_parts)

    print(f"\n{'='*60}", flush=True)
    print(f"  CELL: {label}", flush=True)
    print(f"  Config: {config_str}", flush=True)
    print(f"{'='*60}", flush=True)

    # Ensure clean state
    kill_bench_server()
    vram_before = query_vram()
    print(f"  VRAM before: {vram_before} MiB", flush=True)

    # Build command
    cmd = ["/usr/bin/llama-server", "-m", model_path]
    if mmproj:
        cmd += ["--mmproj", mmproj]
    cmd += [
        "-ngl", str(ngl),
        "--jinja",
        "-c", str(ctx),
        "--host", "127.0.0.1",
        "--port", str(BENCH_PORT),
        "--cache-type-k", "q8_0",
        "--cache-type-v", "q8_0",
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
    if cpu_moe:
        cmd.append("--cpu-moe")
    if extra_flags:
        cmd.extend(extra_flags)

    print(f"  Spawning server...", flush=True)
    t_spawn = time.perf_counter()
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as e:
        return CellResult(
            label=label, model=model, config=config_str,
            ngl=ngl, cpu_moe=cpu_moe, ctx=ctx,
            timestamp_utc=ts, startup_s=None, n_runs=0,
            ttft_p50_ms=0, ttft_p95_ms=0,
            decode_p50_toks_s=0, decode_p95_toks_s=0, decode_mean_toks_s=0,
            vram_before_mib=vram_before, vram_peak_mib=None, vram_delta_mib=None,
            oom=False, error=f"spawn failed: {e}",
        )

    healthy = poll_health(BENCH_PORT, timeout_s=240)
    startup_s = round(time.perf_counter() - t_spawn, 2)

    if not healthy:
        # Check if OOM (VRAM might have spiked then dropped)
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=10)
        return CellResult(
            label=label, model=model, config=config_str,
            ngl=ngl, cpu_moe=cpu_moe, ctx=ctx,
            timestamp_utc=ts, startup_s=startup_s, n_runs=0,
            ttft_p50_ms=0, ttft_p95_ms=0,
            decode_p50_toks_s=0, decode_p95_toks_s=0, decode_mean_toks_s=0,
            vram_before_mib=vram_before, vram_peak_mib=None, vram_delta_mib=None,
            oom=True, error=f"server never healthy after {startup_s:.0f}s (likely OOM)",
        )

    print(f"  Server healthy in {startup_s}s", flush=True)

    # Warmup — discard
    print("  [warmup] discarding first request...", flush=True)
    try:
        stream_request(BENCH_PORT, BENCH_PROMPTS[0], extra_body)
    except Exception as e:
        print(f"  [warmup] error: {e}", flush=True)

    # Real runs + VRAM sampling
    ttfts: list[float] = []
    decodes: list[float] = []
    vram_samples: list[int] = []

    for i in range(N_RUNS):
        prompt = BENCH_PROMPTS[i % len(BENCH_PROMPTS)]
        # Sample VRAM mid-request in background
        vram_sample_result: list[int] = []

        def sample_vram():
            time.sleep(0.5)
            v = query_vram()
            if v:
                vram_sample_result.append(v)

        import threading
        t = threading.Thread(target=sample_vram, daemon=True)
        t.start()

        try:
            r = stream_request(BENCH_PORT, prompt, extra_body)
        except Exception as e:
            print(f"  [{i+1}/{N_RUNS}] ERROR: {e}", flush=True)
            continue

        t.join(timeout=5)
        if vram_sample_result:
            vram_samples.extend(vram_sample_result)

        if r["ttft_ms"] is not None:
            ttfts.append(r["ttft_ms"])
        decodes.append(r["decode_toks_s"])
        print(f"  [{i+1}/{N_RUNS}] ttft={r['ttft_ms']}ms decode={r['decode_toks_s']}tok/s", flush=True)

    # Peak VRAM after runs
    vram_after = query_vram()
    if vram_after:
        vram_samples.append(vram_after)

    vram_peak = max(vram_samples) if vram_samples else None
    vram_delta = (vram_peak - (vram_before or 0)) if vram_peak is not None else None

    # Graceful shutdown
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        proc.kill()

    return CellResult(
        label=label, model=model, config=config_str,
        ngl=ngl, cpu_moe=cpu_moe, ctx=ctx,
        timestamp_utc=ts, startup_s=startup_s, n_runs=len(decodes),
        ttft_p50_ms=round(p50(ttfts), 1),
        ttft_p95_ms=round(p95(ttfts), 1),
        decode_p50_toks_s=round(p50(decodes), 2),
        decode_p95_toks_s=round(p95(decodes), 2),
        decode_mean_toks_s=round(statistics.mean(decodes), 2) if decodes else 0.0,
        vram_before_mib=vram_before,
        vram_peak_mib=vram_peak,
        vram_delta_mib=vram_delta,
    )


def print_result(r: CellResult):
    print(f"\n--- RESULT: {r.label} ---")
    if r.oom or r.error:
        print(f"  STATUS: {'OOM' if r.oom else 'ERROR'} — {r.error}")
    else:
        print(f"  TTFT p50: {r.ttft_p50_ms:.1f} ms  p95: {r.ttft_p95_ms:.1f} ms")
        print(f"  Decode p50: {r.decode_p50_toks_s:.2f} tok/s  p95: {r.decode_p95_toks_s:.2f} tok/s")
        print(f"  VRAM before: {r.vram_before_mib} MiB  peak: {r.vram_peak_mib} MiB  delta: {r.vram_delta_mib} MiB")
        print(f"  Startup: {r.startup_s}s  N runs: {r.n_runs}")
    print()


def main():
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    ts_str = "20260609T120000Z"  # fixed timestamp as instructed

    # --- CELL DEFINITIONS ---
    # Model paths
    qwen35_gguf = str(MODELS_DIR / "Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf")
    qwen35_mmproj = str(MODELS_DIR / "Qwen3.6-35B-A3B/mmproj-BF16.gguf")

    gemma26_gguf = str(MODELS_DIR / "gemma4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf")
    gemma26_mmproj = str(MODELS_DIR / "gemma4-26b-a4b-it/mmproj-BF16.gguf")

    nemotron_gguf = str(MODELS_DIR / "nemotron3-nano-omni-30b-a3b/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-Q4_K_M.gguf")
    nemotron_mmproj = str(MODELS_DIR / "nemotron3-nano-omni-30b-a3b/mmproj-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16.gguf")

    gemma_e2b_gguf = str(MODELS_DIR / "gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf")
    gemma_e2b_mmproj = str(MODELS_DIR / "gemma4-e2b-it/mmproj-BF16.gguf")

    gemma_e4b_gguf = str(MODELS_DIR / "gemma4-e4b-it/gemma-4-E4B-it-Q4_K_M.gguf")
    gemma_e4b_mmproj = str(MODELS_DIR / "gemma4-e4b-it/mmproj-BF16.gguf")

    qwen35_4b_gguf = str(MODELS_DIR / "qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf")
    qwen35_4b_mmproj = str(MODELS_DIR / "qwen35-4b/mmproj-F16.gguf")

    # reasoning off flags
    reasoning_off = ["--reasoning", "off"]
    # qwen thinking disable — via chat template kwargs in request body
    qwen_no_think_body = {"chat_template_kwargs": {"thinking": False}}

    cells = [
        # --- BIG TIER ---
        # 1. Prod 35B with exact prod flags (--cpu-moe → low VRAM baseline)
        dict(
            label="qwen35-6-35b-a3b-prod-flags",
            model="qwen35-6-35b-a3b",
            model_path=qwen35_gguf,
            mmproj=qwen35_mmproj,
            ngl=999,
            cpu_moe=True,
            ctx=32768,
            extra_flags=[],
            extra_body=None,
        ),
        # 2. gemma4-26b full GPU (no --cpu-moe) — test if it fits 12GB
        dict(
            label="gemma4-26b-a4b-full-gpu",
            model="gemma4-26b-a4b-it",
            model_path=gemma26_gguf,
            mmproj=gemma26_mmproj,
            ngl=999,
            cpu_moe=False,
            ctx=32768,
            extra_flags=reasoning_off,
            extra_body=None,
        ),
        # 3. gemma4-26b with --cpu-moe (like prod 35B strategy)
        dict(
            label="gemma4-26b-a4b-cpu-moe",
            model="gemma4-26b-a4b-it",
            model_path=gemma26_gguf,
            mmproj=gemma26_mmproj,
            ngl=999,
            cpu_moe=True,
            ctx=32768,
            extra_flags=reasoning_off,
            extra_body=None,
        ),
        # 4. nemotron 30B with --cpu-moe
        dict(
            label="nemotron3-nano-30b-cpu-moe",
            model="nemotron3-nano-omni-30b-a3b",
            model_path=nemotron_gguf,
            mmproj=nemotron_mmproj,
            ngl=999,
            cpu_moe=True,
            ctx=32768,
            extra_flags=reasoning_off,
            extra_body=None,
        ),
        # --- VRAM TIER GRID (big models, reduced ngl for 4GB/8GB budgets) ---
        # 35B at 8GB budget: --cpu-moe already achieves ~4.9GB, so it's trivially 4GB/8GB
        # gemma4-26b at 8GB: try full GPU first (measured above), if OOM try ngl=40
        # gemma4-26b at 4GB: --cpu-moe (measured above)
        # For 8GB explicit test with gemma26 full GPU, we use ngl=40 if OOM detected
        # (This cell will only run if full-gpu cell OOMed)
        dict(
            label="gemma4-26b-a4b-ngl40-8gb",
            model="gemma4-26b-a4b-it",
            model_path=gemma26_gguf,
            mmproj=gemma26_mmproj,
            ngl=40,
            cpu_moe=False,
            ctx=32768,
            extra_flags=reasoning_off,
            extra_body=None,
        ),
        # --- SMALL KEEPERS at full GPU ---
        dict(
            label="gemma4-e2b-it-full-gpu",
            model="gemma4-e2b-it",
            model_path=gemma_e2b_gguf,
            mmproj=gemma_e2b_mmproj,
            ngl=999,
            cpu_moe=False,
            ctx=32768,
            extra_flags=reasoning_off,
            extra_body=None,
        ),
        dict(
            label="gemma4-e4b-it-full-gpu",
            model="gemma4-e4b-it",
            model_path=gemma_e4b_gguf,
            mmproj=gemma_e4b_mmproj,
            ngl=999,
            cpu_moe=False,
            ctx=32768,
            extra_flags=reasoning_off,
            extra_body=None,
        ),
        dict(
            label="qwen35-4b-full-gpu",
            model="qwen35-4b",
            model_path=qwen35_4b_gguf,
            mmproj=qwen35_4b_mmproj,
            ngl=999,
            cpu_moe=False,
            ctx=32768,
            extra_flags=[],
            extra_body=qwen_no_think_body,
        ),
    ]

    results: list[CellResult] = []
    jsonl_path = RESULTS_DIR / f"gpu_vram_tier_{ts_str}.jsonl"

    for i, cell_def in enumerate(cells):
        print(f"\n[{i+1}/{len(cells)}] Starting cell: {cell_def['label']}", flush=True)

        # Skip gemma26 ngl=40 if full-gpu succeeded (VRAM fit under 12GB)
        if cell_def["label"] == "gemma4-26b-a4b-ngl40-8gb":
            full_gpu = next((r for r in results if r.label == "gemma4-26b-a4b-full-gpu"), None)
            if full_gpu and not full_gpu.oom and not full_gpu.error:
                print(f"  Skipping ngl=40 fallback — full-gpu succeeded (VRAM={full_gpu.vram_peak_mib} MiB)", flush=True)
                continue

        r = run_cell(
            label=cell_def["label"],
            model=cell_def["model"],
            model_path=cell_def["model_path"],
            mmproj=cell_def.get("mmproj"),
            ngl=cell_def["ngl"],
            cpu_moe=cell_def["cpu_moe"],
            ctx=cell_def["ctx"],
            extra_flags=cell_def.get("extra_flags"),
            extra_body=cell_def.get("extra_body"),
        )
        print_result(r)
        results.append(r)

        # Save incrementally
        with jsonl_path.open("a") as f:
            f.write(json.dumps(asdict(r)) + "\n")
        print(f"  Saved to {jsonl_path}", flush=True)

        # Kill server before next cell
        kill_bench_server()

    # Final summary
    print("\n" + "="*70)
    print("  GPU BENCH PHASE 2 — FINAL SUMMARY")
    print("="*70)
    print(f"  {'Label':<40} {'Decode p50':>12} {'TTFT p50':>10} {'VRAM peak':>12} {'Status':>8}")
    print(f"  {'-'*40} {'-'*12} {'-'*10} {'-'*12} {'-'*8}")
    for r in results:
        if r.oom or r.error:
            status = "OOM" if r.oom else "ERR"
            print(f"  {r.label:<40} {'N/A':>12} {'N/A':>10} {'N/A':>12} {status:>8}")
        else:
            print(
                f"  {r.label:<40} "
                f"{r.decode_p50_toks_s:>10.2f}t/s "
                f"{r.ttft_p50_ms:>10.1f}ms "
                f"{str(r.vram_peak_mib)+' MiB':>12} "
                f"{'ok':>8}"
            )
    print()
    print(f"  Results: {jsonl_path}")

    return results, jsonl_path


if __name__ == "__main__":
    main()
