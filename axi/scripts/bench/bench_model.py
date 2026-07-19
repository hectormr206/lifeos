#!/usr/bin/env python3
"""bench_model.py — reusable local-LLM benchmark orchestrator for LifeOS/Axi.

ONE script to benchmark any GGUF, on ANY llama.cpp binary (including fork
builds), across our production roles, appending a machine-readable row to a
registry so a known model is never re-run.

It REUSES the existing scoring logic — nothing is reimplemented here:
  - deterministic brain scorer : cpu_sweep.check_deterministic
  - subjective 35B judge       : subjective_judge.judge_response / chat_sync
  - extraction eval            : lifeos.agents.eval.scoring.score_extraction
                                 + lifeos.agents.extractor.extract
  - speed metrics              : brain_bench.stream_request / query_vram /
                                 read_proc_mem / poll_health

Roles (any subset via --roles):
  speed      → TTFT p50/p95, decode tok/s p50/mean, VRAM before/after, idle RSS
  brain      → deterministic over 35 cases + subjective over the 6 rubric cases
               (subjective needs the prod 35B judge live on 8080; skipped with a
               recorded note otherwise — deterministic is still reported)
  extraction → 69-case extraction eval against this candidate as the nano
               endpoint; case-pass-rate + per-field accuracy

The KEY new capability over the older hardcoded scripts is --server-bin: point
it at a fork build such as
  ~/LifeOS/PrismML-llama.cpp/build/bin/llama-server

Safety: the candidate ALWAYS runs on its own --port (default 18080, never
8080/8090/8081), spawned with start_new_session=True and killed by process
group. Port 8080 is the read-only prod 35B judge; 8090 is the prod nano.

Sample usage
------------
  # Benchmark a fork-built model, all three roles, CPU-only:
  .venv/bin/python scripts/bench/bench_model.py \
      --gguf ~/LifeOS/models/prism-7b/prism-7b-Q4_K_M.gguf \
      --label prism-7b-q4 \
      --server-bin ~/LifeOS/PrismML-llama.cpp/build/bin/llama-server \
      --ngl 0 --ctx 32768 --port 18080 --n-runs 10

  # Only speed + extraction, offloaded to GPU, extra passthrough flags:
  .venv/bin/python scripts/bench/bench_model.py \
      --gguf /path/model.gguf --label mymodel --roles speed,extraction \
      --ngl 999 --cpu-moe --extra-flags --cache-type-k q8_0 --mlock

  # Just show the registry (newest row per label) side by side:
  .venv/bin/python scripts/bench/bench_model.py --list
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
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── paths & reuse wiring ─────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
REGISTRY_PATH = RESULTS_DIR / "model_registry.jsonl"
REPO_ROOT = SCRIPT_DIR.parents[2]            # ~/LifeOS/lifeos
LIFEOS_SRC = REPO_ROOT / "lifeos" / "src"    # importable lifeos package root

# Make the sibling bench scripts importable so we REUSE (never copy) scorers.
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

# Ports we must never spawn on (prod judge / nano / secondary prod).
FORBIDDEN_PORTS = {8080, 8081, 8090}
JUDGE_PORT = 8080  # read-only prod 35B judge, used for the subjective layer

FINAL_DET_WEIGHT = 0.7
FINAL_SUBJ_WEIGHT = 0.3


# ═════════════════════════════════════════════════════════════════════════════
# PURE LOGIC (unit-tested — no process spawn, no network)
# ═════════════════════════════════════════════════════════════════════════════

def final_score(det: float, subj: float) -> float:
    """Combined brain score: 0.7*deterministic + 0.3*subjective (matches RANKING.md)."""
    return round(FINAL_DET_WEIGHT * det + FINAL_SUBJ_WEIGHT * subj, 4)


def build_server_argv(
    server_bin: str,
    gguf: str,
    ngl: int,
    cpu_moe: bool,
    ctx: int,
    port: int,
    mmproj: Optional[str] = None,
    extra_flags: Optional[list[str]] = None,
) -> list[str]:
    """Assemble the llama-server argv.

    The chosen ``server_bin`` is ALWAYS argv[0] — this is what lets us point at a
    fork build instead of the system ``/usr/bin/llama-server``. ``extra_flags``
    are appended verbatim (passthrough).
    """
    argv = [server_bin, "-m", gguf]
    if mmproj:
        argv += ["--mmproj", mmproj]
    argv += [
        "-ngl", str(ngl),
        "-c", str(ctx),
        "--jinja",
        "--host", "127.0.0.1",
        "--port", str(port),
    ]
    if cpu_moe:
        argv.append("--cpu-moe")
    if extra_flags:
        argv += list(extra_flags)
    return argv


def load_registry(path: Path) -> list[dict]:
    """Read the registry JSONL into a list of rows (empty when missing)."""
    if not Path(path).exists():
        return []
    rows: list[dict] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            rows.append(json.loads(s))
        except json.JSONDecodeError:
            pass
    return rows


def append_registry_row(path: Path, row: dict) -> None:
    """Append ONE row to the registry (history is preserved; never rewritten)."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with Path(path).open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")


def newest_per_label(rows: list[dict]) -> list[dict]:
    """Collapse history to the newest row per label.

    "Newest" = highest ``timestamp_utc`` (ISO strings sort chronologically);
    ties break on later position in the file. Returned sorted by label.
    """
    best: dict[str, tuple[int, str, dict]] = {}
    for idx, row in enumerate(rows):
        label = row.get("label", "")
        ts = row.get("timestamp_utc", "")
        key = (ts, idx)
        if label not in best or key > (best[label][1], best[label][0]):
            best[label] = (idx, ts, row)
    return [best[label][2] for label in sorted(best)]


def _fmt(value: object, spec: str, dash: str = "-") -> str:
    """Format a possibly-None numeric value, falling back to a dash."""
    if value is None:
        return dash
    try:
        return format(value, spec)
    except (ValueError, TypeError):
        return str(value)


def build_comparison_table(rows: list[dict], title: str = "MODEL REGISTRY") -> str:
    """Render newest-per-label rows as a side-by-side comparison table.

    Pure string builder — safe to unit-test. Missing metrics render as ``-``.
    """
    latest = newest_per_label(rows)
    lines: list[str] = []
    bar = "=" * 104
    lines.append(bar)
    lines.append(f"  {title}  (newest row per label)")
    lines.append(bar)
    header = (
        f"  {'Label':<22} {'det':>5} {'subj':>5} {'final':>6} "
        f"{'tok/s':>7} {'TTFTp50':>8} {'RSS MB':>7} "
        f"{'extr%':>6} {'server_bin':<24}"
    )
    lines.append(header)
    lines.append("  " + "-" * 100)
    if not latest:
        lines.append("  (registry is empty — nothing benchmarked yet)")
        lines.append(bar)
        return "\n".join(lines)

    for row in latest:
        brain = row.get("brain") or {}
        speed = row.get("speed") or {}
        extraction = row.get("extraction") or {}
        server_bin = row.get("server_bin", "")
        server_short = server_bin if len(server_bin) <= 23 else "…" + server_bin[-22:]
        lines.append(
            f"  {row.get('label', ''):<22} "
            f"{_fmt(brain.get('det'), '5.3f')} "
            f"{_fmt(brain.get('subj'), '5.3f')} "
            f"{_fmt(brain.get('final'), '6.4f')} "
            f"{_fmt(speed.get('decode_p50_toks_s'), '7.1f')} "
            f"{_fmt(speed.get('ttft_p50_ms'), '8.1f')} "
            f"{_fmt(speed.get('idle_rss_mb'), '7.0f')} "
            f"{_fmt(extraction.get('case_pass_rate'), '6.1%')} "
            f"{server_short:<24}"
        )
    lines.append(bar)
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    """CLI definition (pure — unit-tested for flag wiring)."""
    p = argparse.ArgumentParser(
        prog="bench_model.py",
        description="Reusable local-LLM benchmark orchestrator (speed/brain/extraction).",
    )
    p.add_argument("--gguf", help="Path to the candidate GGUF (required unless --list)")
    p.add_argument("--label", help="Human label / registry key (required unless --list)")
    p.add_argument(
        "--server-bin", default="/usr/bin/llama-server",
        help="llama-server binary — point at a fork build to benchmark it "
             "(default: /usr/bin/llama-server)",
    )
    p.add_argument(
        "--roles", default="speed,brain,extraction",
        help="Comma list from {speed,brain,extraction} (default: all three)",
    )
    p.add_argument("--ngl", type=int, default=0, help="GPU layers, -ngl (default 0 = CPU)")
    p.add_argument("--brain-max-tokens", type=int, default=200,
                   help="Max tokens per brain answer (default 200; raise to ~1024 "
                        "for thinking-ON models so reasoning + final answer fit)")
    p.add_argument("--cpu-moe", action="store_true", help="Pass --cpu-moe to llama-server")
    p.add_argument("--ctx", type=int, default=32768, help="Context size -c (default 32768)")
    p.add_argument(
        "--port", type=int, default=18080,
        help="Candidate server port (default 18080; NEVER 8080/8090/8081)",
    )
    p.add_argument("--mmproj", default=None, help="Optional mmproj GGUF (vision models)")
    p.add_argument("--n-runs", type=int, default=10, help="Speed inference runs (default 10)")
    p.add_argument(
        "--now", default=None,
        help="Override timestamp_utc (ISO 8601). Default: current UTC time.",
    )
    p.add_argument(
        "--registry", default=str(REGISTRY_PATH),
        help=f"Registry JSONL path (default: {REGISTRY_PATH})",
    )
    p.add_argument(
        "--list", action="store_true",
        help="Print the registry (newest per label) and exit — no benchmarking.",
    )
    p.add_argument(
        "--extra-flags", nargs=argparse.REMAINDER, default=[],
        help="Everything after this flag is passed verbatim to llama-server.",
    )
    return p


def parse_roles(raw: str) -> list[str]:
    """Validate & normalise the --roles list."""
    valid = {"speed", "brain", "extraction"}
    roles = [r.strip() for r in raw.split(",") if r.strip()]
    bad = [r for r in roles if r not in valid]
    if bad:
        raise ValueError(f"unknown role(s): {bad} — valid: {sorted(valid)}")
    return roles


def _percentile(xs: list[float], q: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * q))]


# ═════════════════════════════════════════════════════════════════════════════
# IMPURE ORCHESTRATION (spawns servers, hits the network — NOT unit-tested)
# ═════════════════════════════════════════════════════════════════════════════

def http_ok(url: str, timeout: int = 3) -> bool:
    """True iff `url` answers 200 within `timeout` seconds."""
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def spawn_server(argv: list[str], hide_gpu: bool = False) -> subprocess.Popen:
    """Spawn the candidate llama-server in its own session (own process group).

    hide_gpu=True sets CUDA_VISIBLE_DEVICES="" for the child. REQUIRED for
    CPU-only cells (ngl=0): the llama.cpp-cuda build still initializes a CUDA
    context even with zero offloaded layers (same gotcha documented in
    llama-nano.service), and with the prod brains holding ~11/12 GB VRAM that
    lazy allocation can fail MID-REQUEST → ggml_abort → the bench server dies
    silently between roles and every later score measures a corpse (the
    2026-07-15 "7.2% extraction" crater).

    Set BENCH_SERVER_LOG=/path/prefix to capture each spawned server's
    stdout+stderr to <prefix>.<pid>.log — essential when diagnosing a server
    that dies mid-audit (default DEVNULL keeps normal runs quiet).
    """
    env = os.environ.copy()
    if hide_gpu:
        env["CUDA_VISIBLE_DEVICES"] = ""
    print(f"  Spawning: {argv[0]} -m {Path(argv[2]).name} ...", flush=True)
    log_prefix = os.environ.get("BENCH_SERVER_LOG")
    if log_prefix:
        out = open(f"{log_prefix}.next.log", "wb")  # renamed to .<pid>.log below
    else:
        out = subprocess.DEVNULL
    proc = subprocess.Popen(
        argv,
        stdout=out,
        stderr=subprocess.STDOUT if log_prefix else subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    if log_prefix:
        out.close()
        os.replace(f"{log_prefix}.next.log", f"{log_prefix}.{proc.pid}.log")
        # reopen appending under the final name so the fd survives the rename
        proc._bench_log = f"{log_prefix}.{proc.pid}.log"  # type: ignore[attr-defined]
    return proc


def kill_server(proc: subprocess.Popen) -> None:
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
    time.sleep(2)


def run_speed_role(port: int, pid: int, n_runs: int) -> dict:
    """Speed metrics via brain_bench streaming helpers (reused, not copied)."""
    import brain_bench as bb

    vram_before, vram_total = bb.query_vram()
    print("  [speed] warmup (discarded)...", flush=True)
    bb.stream_request(port, bb.BENCH_PROMPTS[0])

    ttfts: list[float] = []
    decodes: list[float] = []
    for i in range(n_runs):
        prompt = bb.BENCH_PROMPTS[i % len(bb.BENCH_PROMPTS)]
        r = bb.stream_request(port, prompt)
        if r["ttft_ms"] is not None:
            ttfts.append(r["ttft_ms"])
        decodes.append(r["decode_toks_s"])
        print(f"  [speed {i+1}/{n_runs}] ttft={r['ttft_ms']}ms decode={r['decode_toks_s']}tok/s", flush=True)

    vram_after, _ = bb.query_vram()
    try:
        mem = bb.read_proc_mem(pid)
        rss_mb = round(mem.get("VmRSS", 0) / 1024, 1)
    except Exception:
        rss_mb = None

    return {
        "n_runs": n_runs,
        "ttft_p50_ms": round(_percentile(ttfts, 0.50), 1),
        "ttft_p95_ms": round(_percentile(ttfts, 0.95), 1),
        "decode_p50_toks_s": round(_percentile(decodes, 0.50), 2),
        "decode_mean_toks_s": round(statistics.mean(decodes), 2) if decodes else 0.0,
        "vram_before_mib": vram_before,
        "vram_after_mib": vram_after,
        "vram_total_mib": vram_total,
        "idle_rss_mb": rss_mb,
    }


def run_brain_role(port: int, brain_max_tokens: int = 200) -> dict:
    """Deterministic (35 cases) + subjective (6 rubric cases) brain scoring.

    Reuses cpu_sweep.check_deterministic and subjective_judge.judge_response /
    chat_sync / get_system_prompt_for_case. Subjective needs the 35B judge live
    on 8080; when absent it is skipped with a recorded note and det still reports.

    brain_max_tokens caps each answer. Default 200 matches how the roster was
    benched (thinking OFF). For a reasoning/thinking-ON model, raise it (e.g.
    1024) so the model has room to think AND still emit its final answer —
    otherwise thinking burns the whole budget and content comes back empty.
    """
    import cpu_sweep
    import subjective_judge as sj

    all_cases = sj.load_golden_set(sj.GOLDEN_SET_PATH)
    rubric_cases = [c for c in all_cases if c.get("rubric")]
    print(f"  [brain] {len(all_cases)} cases ({len(rubric_cases)} rubric)", flush=True)

    responses: dict[str, str] = {}
    passed = 0
    for i, case in enumerate(all_cases):
        system = sj.get_system_prompt_for_case(case)
        resp = sj.chat_sync(port, case.get("prompt", ""), system=system,
                            max_tokens=brain_max_tokens, temperature=0.6)
        responses[case["id"]] = resp
        ok, _ = cpu_sweep.check_deterministic(case, resp)
        passed += 1 if ok else 0
        print(f"  [brain {i+1}/{len(all_cases)}] {case['id']}: {'PASS' if ok else 'FAIL'}", flush=True)

    det = round(passed / len(all_cases), 4) if all_cases else 0.0

    judge_healthy = sj.http_get_status(f"http://127.0.0.1:{JUDGE_PORT}/health") == 200
    if not judge_healthy:
        note = f"subjective skipped: 35B judge not healthy on {JUDGE_PORT}"
        print(f"  [brain] {note}", flush=True)
        return {"det": det, "subj": None, "final": None, "note": note,
                "n_cases": len(all_cases), "n_rubric": len(rubric_cases)}

    subj_scores: list[float] = []
    for case in rubric_cases:
        resp = responses.get(case["id"], "")
        if not resp or resp.startswith("__ERROR__"):
            subj_scores.append(0.0)
            continue
        result = sj.judge_response(case, resp)
        subj_scores.append(result["weighted_score"])
    subj = round(sum(subj_scores) / len(subj_scores), 4) if subj_scores else 0.0

    return {
        "det": det,
        "subj": subj,
        "final": final_score(det, subj),
        "note": None,
        "n_cases": len(all_cases),
        "n_rubric": len(rubric_cases),
    }


def run_extraction_role(port: int) -> dict:
    """69-case extraction eval with the candidate as the nano endpoint.

    Reuses lifeos.agents.eval.scoring + lifeos.agents.extractor. LIFEOS_NANO_ENDPOINT
    is a MODULE-LEVEL constant in lifeos.agents.runtime captured at import time, so
    it MUST be set before the first import here (lazy import below guarantees that).
    """
    os.environ["LIFEOS_NANO_ENDPOINT"] = f"http://127.0.0.1:{port}"
    if str(LIFEOS_SRC) not in sys.path:
        sys.path.insert(0, str(LIFEOS_SRC))

    import dataclasses
    from lifeos.agents.eval import scoring
    from lifeos.agents import extractor

    golden = LIFEOS_SRC / "lifeos" / "agents" / "eval" / "golden_sets" / "extraction_quality.jsonl"
    cases = scoring.load_extraction_golden_set(golden)
    print(f"  [extraction] {len(cases)} cases via nano endpoint {os.environ['LIFEOS_NANO_ENDPOINT']}", flush=True)

    predictions: list[dict] = []
    empty = {k: None for k in (
        "domain", "kind", "amount", "currency", "merchant", "systolic", "diastolic",
        "pulse_bpm", "sleep_hours", "weight_kg", "glucose_mg_dl", "duration_minutes", "title")}
    empty.update({"people": [], "dates_text": [], "items": []})

    none_count = 0
    for i, case in enumerate(cases, 1):
        result = extractor.extract(case.text, temperature=0.0, seed=0,
                                   timeout_s=30.0, retry_timeout_s=60.0)
        none_count += 1 if result is None else 0
        predictions.append(dict(empty) if result is None else dataclasses.asdict(result))
        if i % 10 == 0:
            print(f"  [extraction {i}/{len(cases)}]", flush=True)
        # Tripwire: if the first 10 cases are mostly None, something is broken
        # (wrong server, dying process, template mismatch) — say so LOUDLY so a
        # cratered score is never mistaken for a bad model.
        if i == 10 and none_count >= 6:
            print(f"  [extraction] WARNING: {none_count}/10 leading cases returned "
                  "None — the endpoint/server is likely broken; treat this score "
                  "as INVALID and investigate before comparing.", flush=True)

    score = scoring.score_extraction(predictions, cases)
    return {
        "case_pass_rate": round(score.case_pass_rate, 4),
        "field_accuracy": {k: round(v, 4) for k, v in score.field_accuracy.items()},
        "total": score.total,
    }


def print_run_summary(row: dict) -> None:
    print("\n" + "=" * 66)
    print(f"  BENCH RESULT — {row['label']}")
    print("=" * 66)
    print(f"  gguf        : {row['gguf']}")
    print(f"  server_bin  : {row['server_bin']}")
    launch = row["launch"]
    print(f"  launch      : -ngl {launch['ngl']} -c {launch['ctx']} "
          f"port {launch['port']}{' --cpu-moe' if launch['cpu_moe'] else ''}")
    print(f"  roles       : {', '.join(row['roles'])}")
    if row.get("speed"):
        s = row["speed"]
        print(f"  speed       : decode p50 {s['decode_p50_toks_s']} tok/s | "
              f"TTFT p50 {s['ttft_p50_ms']}ms | RSS {s['idle_rss_mb']}MB")
    if row.get("brain"):
        b = row["brain"]
        subj = "-" if b["subj"] is None else f"{b['subj']:.3f}"
        fin = "-" if b["final"] is None else f"{b['final']:.4f}"
        print(f"  brain       : det {b['det']:.3f} | subj {subj} | final {fin}"
              f"{'  (' + b['note'] + ')' if b.get('note') else ''}")
    if row.get("extraction"):
        e = row["extraction"]
        print(f"  extraction  : case pass {e['case_pass_rate']:.1%} over {e['total']} cases")
    print("=" * 66)


# ── entry point ──────────────────────────────────────────────────────────────

def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    registry_path = Path(args.registry)

    # --list: no benchmarking, just show the registry side by side.
    if args.list:
        print(build_comparison_table(load_registry(registry_path)))
        return 0

    if not args.gguf or not args.label:
        print("ERROR: --gguf and --label are required (unless --list).", file=sys.stderr)
        return 2

    try:
        roles = parse_roles(args.roles)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if args.port in FORBIDDEN_PORTS:
        print(f"ERROR: refusing to spawn on protected prod port {args.port} "
              f"(forbidden: {sorted(FORBIDDEN_PORTS)}).", file=sys.stderr)
        return 2

    if not Path(args.gguf).exists():
        print(f"ERROR: GGUF not found: {args.gguf}", file=sys.stderr)
        return 2
    if not Path(args.server_bin).exists():
        print(f"ERROR: server binary not found: {args.server_bin}", file=sys.stderr)
        return 2

    argv_server = build_server_argv(
        server_bin=args.server_bin, gguf=args.gguf, ngl=args.ngl,
        cpu_moe=args.cpu_moe, ctx=args.ctx, port=args.port,
        mmproj=args.mmproj, extra_flags=args.extra_flags,
    )

    # Import brain_bench lazily (only when we need to spawn/poll).
    import brain_bench as bb

    proc = spawn_server(argv_server, hide_gpu=(args.ngl == 0))
    print(f"  Polling /health on port {args.port} (<=180s)...", flush=True)
    healthy = bb.poll_health(args.port, timeout_s=180)
    if not healthy:
        kill_server(proc)
        print(f"ERROR: candidate server never became healthy on port {args.port}. "
              f"Check the model/binary/flags:\n  {' '.join(argv_server)}", file=sys.stderr)
        return 1

    row: dict = {
        "label": args.label,
        "timestamp_utc": args.now or datetime.now(timezone.utc).isoformat(),
        "gguf": args.gguf,
        "server_bin": args.server_bin,
        "launch": {
            "ngl": args.ngl,
            "cpu_moe": bool(args.cpu_moe),
            "ctx": args.ctx,
            "port": args.port,
            "mmproj": args.mmproj,
            "extra_flags": list(args.extra_flags),
        },
        "roles": roles,
    }

    try:
        if "speed" in roles:
            row["speed"] = run_speed_role(args.port, proc.pid, args.n_runs)
        if "brain" in roles:
            row["brain"] = run_brain_role(args.port, args.brain_max_tokens)
        if "extraction" in roles:
            row["extraction"] = run_extraction_role(args.port)
    finally:
        kill_server(proc)

    append_registry_row(registry_path, row)
    print_run_summary(row)

    others = [r for r in load_registry(registry_path) if r.get("label") != args.label]
    if others:
        print("\n" + build_comparison_table(load_registry(registry_path),
                                            title="COMPARISON vs REGISTRY"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
