#!/usr/bin/env python3
"""
Phase 2 VRAM-tier benchmark — Group 1 (small full-GPU) + Group 2 (big @4GB budget).
Appends JSON rows to gpu_vram_tier_20260609T120000Z.jsonl.
"""
import json, subprocess, time, requests, datetime, statistics, os, sys

RESULTS_FILE = "/home/hectormr/LifeOS/lifeos/axi/scripts/bench/results/gpu_vram_tier_20260609T120000Z.jsonl"
PORT = 18080
BASE_URL = f"http://127.0.0.1:{PORT}"

PROMPT = "You are Axi, a helpful assistant. Explain briefly what photosynthesis is in 3 sentences."


def vram_used():
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
        text=True
    ).strip()
    return int(out.split("\n")[0].strip())


def kill_server():
    subprocess.run(["pkill", "-f", "[l]lama-server.*18080"], capture_output=True)
    # Wait until VRAM drops back toward baseline
    for _ in range(60):
        time.sleep(2)
        v = vram_used()
        if v < 1000:
            break
    time.sleep(2)


def wait_healthy(timeout=120):
    start = time.time()
    while time.time() - start < timeout:
        try:
            r = requests.get(f"{BASE_URL}/health", timeout=3)
            if r.status_code == 200 and r.json().get("status") == "ok":
                return True
        except Exception:
            pass
        time.sleep(2)
    return False


def chat(messages, reasoning_off=True):
    payload = {
        "model": "bench",
        "messages": messages,
        "max_tokens": 120,
        "temperature": 0.0,
    }
    if reasoning_off:
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    t0 = time.time()
    r = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=60)
    elapsed = time.time() - t0
    r.raise_for_status()
    data = r.json()
    usage = data.get("usage", {})
    completion_tokens = usage.get("completion_tokens", 0)
    return elapsed, completion_tokens


def measure_run(label, server_cmd, n_runs=10, reasoning_off=True):
    """Start server, run n_runs+1 chats (first is warmup), record metrics."""
    result = {
        "label": label,
        "model": server_cmd.get("model_id", ""),
        "config": server_cmd.get("config_str", ""),
        "ngl": server_cmd.get("ngl", 0),
        "cpu_moe": server_cmd.get("cpu_moe", False),
        "ctx": server_cmd.get("ctx", 32768),
        "timestamp_utc": datetime.datetime.utcnow().isoformat() + "+00:00",
        "startup_s": 0,
        "n_runs": 0,
        "ttft_p50_ms": 0,
        "ttft_p95_ms": 0,
        "decode_p50_toks_s": 0,
        "decode_p95_toks_s": 0,
        "decode_mean_toks_s": 0,
        "vram_before_mib": 0,
        "vram_peak_mib": None,
        "vram_delta_mib": None,
        "oom": False,
        "error": "",
    }

    kill_server()
    vram_before = vram_used()
    result["vram_before_mib"] = vram_before

    print(f"\n{'='*60}")
    print(f"Starting: {label}")
    print(f"CMD: {' '.join(server_cmd['argv'])}")
    print(f"VRAM before: {vram_before} MiB")

    proc = subprocess.Popen(
        server_cmd["argv"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    t_start = time.time()
    healthy = wait_healthy(90)
    startup_s = time.time() - t_start
    result["startup_s"] = round(startup_s, 2)

    if not healthy:
        proc.terminate()
        proc.wait(timeout=10)
        kill_server()
        result["oom"] = True
        result["error"] = f"server never healthy after 90s (likely OOM)"
        print(f"  OOM/ERROR: {result['error']}")
        return result

    vram_after_load = vram_used()
    print(f"  Healthy in {startup_s:.1f}s, VRAM after load: {vram_after_load} MiB")

    # Warmup
    msgs = [{"role": "user", "content": PROMPT}]
    try:
        chat(msgs, reasoning_off=reasoning_off)
    except Exception as e:
        print(f"  Warmup failed: {e}")

    ttfts = []
    toks_per_s = []
    peak_vram = vram_after_load

    for i in range(n_runs):
        try:
            elapsed, toks = chat(msgs, reasoning_off=reasoning_off)
            v = vram_used()
            if v > peak_vram:
                peak_vram = v
            # TTFT approximation: time for first token (using full elapsed for short completions)
            # For a 120-token cap at ~25 tok/s: decode ~4.8s, so ttft = elapsed - decode_time
            # We approximate: use elapsed as total round-trip; decode ≈ toks/speed
            # Simple: record total elapsed as ttft proxy (generation is short)
            ttfts.append(elapsed * 1000)  # ms
            if toks > 0 and elapsed > 0:
                toks_per_s.append(toks / elapsed)
            print(f"  run {i+1}/{n_runs}: {elapsed:.2f}s, {toks} toks, {toks/elapsed if toks>0 else 0:.1f} tok/s, VRAM={v} MiB")
        except Exception as e:
            print(f"  run {i+1} error: {e}")

    proc.terminate()
    proc.wait(timeout=15)
    kill_server()

    if ttfts:
        ttfts_sorted = sorted(ttfts)
        result["ttft_p50_ms"] = round(statistics.median(ttfts_sorted), 1)
        result["ttft_p95_ms"] = round(ttfts_sorted[int(len(ttfts_sorted) * 0.95)], 1)
    if toks_per_s:
        tps_sorted = sorted(toks_per_s)
        result["decode_p50_toks_s"] = round(statistics.median(tps_sorted), 2)
        result["decode_p95_toks_s"] = round(tps_sorted[int(len(tps_sorted) * 0.95)], 2)
        result["decode_mean_toks_s"] = round(statistics.mean(tps_sorted), 2)
    result["n_runs"] = len(ttfts)
    result["vram_peak_mib"] = peak_vram
    result["vram_delta_mib"] = peak_vram - vram_before

    print(f"  DONE: p50={result['decode_p50_toks_s']} tok/s, peak VRAM={peak_vram} MiB (delta={result['vram_delta_mib']} MiB)")
    return result


def append_row(row):
    with open(RESULTS_FILE, "a") as f:
        f.write(json.dumps(row) + "\n")
    print(f"  => Appended row: {row['label']}")


def make_cmd(argv, model_id, config_str, ngl, cpu_moe, ctx):
    return {"argv": argv, "model_id": model_id, "config_str": config_str,
            "ngl": ngl, "cpu_moe": cpu_moe, "ctx": ctx}


# ---------------------------------------------------------------------------
# GROUP 1 — small models full-GPU (-ngl 999, no --cpu-moe)
# ---------------------------------------------------------------------------

group1 = [
    make_cmd(
        argv=[
            "llama-server", "-m", "/home/hectormr/LifeOS/models/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf",
            "--mmproj", "/home/hectormr/LifeOS/models/gemma4-e2b-it/mmproj-BF16.gguf",
            "--port", str(PORT), "-ngl", "999", "--ctx-size", "32768",
            "--reasoning", "off", "-a", "bench", "--log-disable",
        ],
        model_id="gemma4-e2b-it", config_str="ngl=999 full-gpu ctx=32768 --reasoning off",
        ngl=999, cpu_moe=False, ctx=32768,
    ),
    make_cmd(
        argv=[
            "llama-server", "-m", "/home/hectormr/LifeOS/models/gemma4-e4b-it/gemma-4-E4B-it-Q4_K_M.gguf",
            "--mmproj", "/home/hectormr/LifeOS/models/gemma4-e4b-it/mmproj-BF16.gguf",
            "--port", str(PORT), "-ngl", "999", "--ctx-size", "32768",
            "--reasoning", "off", "-a", "bench", "--log-disable",
        ],
        model_id="gemma4-e4b-it", config_str="ngl=999 full-gpu ctx=32768 --reasoning off",
        ngl=999, cpu_moe=False, ctx=32768,
    ),
    make_cmd(
        argv=[
            "llama-server", "-m", "/home/hectormr/LifeOS/models/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf",
            "--mmproj", "/home/hectormr/LifeOS/models/qwen35-4b/mmproj-F16.gguf",
            "--port", str(PORT), "-ngl", "999", "--ctx-size", "32768",
            "-a", "bench", "--log-disable",
        ],
        model_id="qwen35-4b", config_str="ngl=999 full-gpu ctx=32768",
        ngl=999, cpu_moe=False, ctx=32768,
    ),
]

labels_g1 = ["gemma4-e2b-it-full-gpu", "gemma4-e4b-it-full-gpu", "qwen35-4b-full-gpu"]

print("=== GROUP 1: Small models — full GPU offload ===")
# reasoning_off controls chat_template_kwargs enable_thinking=False in the payload
# gemma4 models use --reasoning off server flag, qwen35 uses chat_template_kwargs
reasoning_off_flags = [True, True, True]  # all three: disable thinking in requests
for label, cmd, ro in zip(labels_g1, group1, reasoning_off_flags):
    row = measure_run(label, cmd, n_runs=10, reasoning_off=ro)
    append_row(row)

# ---------------------------------------------------------------------------
# GROUP 2 — big models squeezed to ≤4096 MiB
# We probe ngl values: start at 20, step up/down based on VRAM reading
# ---------------------------------------------------------------------------

print("\n=== GROUP 2: Big models squeezed to ≤4GB VRAM ===")

def probe_ngl(label, base_cmd_fn, ngl_start=20, ngl_step=4, max_vram=4096):
    """Binary-search for the highest ngl that keeps peak VRAM ≤ max_vram."""
    kill_server()
    best_row = None
    ngl_candidates = list(range(ngl_start, 0, -ngl_step))
    # Also try some values below ngl_start
    if ngl_start > 4:
        ngl_candidates += [4, 2, 1]
    ngl_candidates = sorted(set(ngl_candidates), reverse=True)

    # Quick probe: try ngl_start first; if VRAM > budget, try lower values
    for ngl in ngl_candidates:
        kill_server()
        vram_before = vram_used()
        cmd = base_cmd_fn(ngl)
        print(f"\n  Probing ngl={ngl} for {label} ...")
        proc = subprocess.Popen(
            cmd["argv"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        t0 = time.time()
        healthy = wait_healthy(90)
        if not healthy:
            proc.terminate()
            proc.wait(timeout=10)
            kill_server()
            print(f"    ngl={ngl}: no healthy (OOM or slow), trying lower")
            continue
        # Single test run to measure VRAM
        try:
            msgs = [{"role": "user", "content": PROMPT}]
            chat(msgs, reasoning_off=True)  # warmup
            elapsed, toks = chat(msgs, reasoning_off=True)
            peak = vram_used()
            tps = toks / elapsed if toks > 0 else 0
            print(f"    ngl={ngl}: VRAM={peak} MiB, {tps:.1f} tok/s")
            if peak <= max_vram:
                # Do full 10-run measurement
                proc.terminate()
                proc.wait(timeout=15)
                kill_server()
                full_cmd = base_cmd_fn(ngl)
                row = measure_run(f"{label}-ngl{ngl}-4gb", full_cmd, n_runs=10, reasoning_off=True)
                return row
            else:
                proc.terminate()
                proc.wait(timeout=15)
                kill_server()
        except Exception as e:
            print(f"    ngl={ngl}: error {e}")
            proc.terminate()
            proc.wait(timeout=15)
            kill_server()
    # If nothing fits, return best with error
    return {"label": f"{label}-4gb", "oom": True, "error": "no ngl fit ≤4GB", "n_runs": 0,
            "decode_mean_toks_s": 0, "vram_peak_mib": None}


# Qwen3.6-35B-A3B with --cpu-moe, reduce ngl
def qwen35_cmd(ngl):
    return make_cmd(
        argv=[
            "llama-server",
            "-m", "/home/hectormr/LifeOS/models/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf",
            "--mmproj", "/home/hectormr/LifeOS/models/Qwen3.6-35B-A3B/mmproj-BF16.gguf",
            "--port", str(PORT), "-ngl", str(ngl), "--cpu-moe",
            "--ctx-size", "32768", "--reasoning", "off", "-a", "bench", "--log-disable",
        ],
        model_id="qwen35-6-35b-a3b", config_str=f"ngl={ngl} cpu-moe ctx=32768 --reasoning off",
        ngl=ngl, cpu_moe=True, ctx=32768,
    )


# gemma4-26b with --cpu-moe, reduce ngl
def gemma26b_cmd(ngl):
    return make_cmd(
        argv=[
            "llama-server",
            "-m", "/home/hectormr/LifeOS/models/gemma4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
            "--mmproj", "/home/hectormr/LifeOS/models/gemma4-26b-a4b-it/mmproj-BF16.gguf",
            "--port", str(PORT), "-ngl", str(ngl), "--cpu-moe",
            "--ctx-size", "32768", "--reasoning", "off", "-a", "bench", "--log-disable",
        ],
        model_id="gemma4-26b-a4b-it", config_str=f"ngl={ngl} cpu-moe ctx=32768 --reasoning off",
        ngl=ngl, cpu_moe=True, ctx=32768,
    )


# First verify the gemma26b model file exists
gemma26b_gguf = "/home/hectormr/LifeOS/models/gemma4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"
if not os.path.exists(gemma26b_gguf):
    # Try to find actual gguf name
    import glob
    matches = glob.glob("/home/hectormr/LifeOS/models/gemma4-26b-a4b-it/*.gguf")
    print(f"Gemma26b files: {matches}")
    gemma26b_gguf = [m for m in matches if "mmproj" not in m][0] if matches else None

# Probe starting at ngl=20 down in steps of 4
row_qwen_4gb = probe_ngl("qwen35-6-35b-a3b-cpu-moe", qwen35_cmd, ngl_start=20, ngl_step=4, max_vram=4096)
append_row(row_qwen_4gb)

if gemma26b_gguf:
    row_gemma26b_4gb = probe_ngl("gemma4-26b-a4b-it-cpu-moe", gemma26b_cmd, ngl_start=20, ngl_step=4, max_vram=4096)
    append_row(row_gemma26b_4gb)
else:
    print("ERROR: gemma4-26b gguf not found, skipping")

print("\n=== BENCHMARK COMPLETE ===")
print(f"Results in: {RESULTS_FILE}")
