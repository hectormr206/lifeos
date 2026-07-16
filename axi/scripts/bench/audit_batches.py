#!/usr/bin/env python3
"""audit_batches.py — sequential model-audit batch driver with pause/resume.

Replaces the ad-hoc shell chains (overnight_roster.sh / afternoon_finale.sh):
one JSON plan in, jobs run SEQUENTIALLY through the model_audit.py CLI, live
progress in results/audit_status.json (this driver owns the "batch" key; the
harness merges around it), and cooperative pause/resume through
results/audit_control.json.

Plan file
---------
Either a bare JSON list of jobs, or {"notes": "...", "jobs": [...]}. Each job:
  {"label": str, "gguf": str,               # required
   "mmproj": str?, "server_bin": str?,      # optional
   "tiers": ["vram12"], "thinking_modes": ["off","on"],
   "moe": "on"|"off"?, "extra_flags": [...]?,   # verbatim llama-server flags
   "roles": [...]?, "use_recipe": bool?, "per_role_tuning": bool?}
The shipped results/finale_plan.json orders jobs FASTEST FIRST (measured
tok/s) so early batches fill the audit table quickly; see its "notes".

Pause/resume contract
---------------------
The dashboard (or `audit_batches.py pause`) writes {"action": "pause"} to
results/audit_control.json. The driver reads it ONLY BETWEEN JOBS (a running
audit is never killed): on pause it kills the stand-in judge (GPU fully free
— Héctor may game), writes state=paused, and polls every 10 s until the
action is "run" again, then re-spawns the judge and continues.

Environment lifecycle (once per batch, not per job)
---------------------------------------------------
Setup: stop voice/whisper/tray/heartbeat (the DASHBOARD STAYS UP for live
viewing), axi-game-on --offline, spawn a stand-in CPU judge on 8080 (only if
the port is free — never fight a live server). Restore at the end: kill the
judge, axi-game-off, re-enable dev_self_improve_enabled, restart services,
print the final --compare matrix. SIGTERM-safe: the trap finishes writing
status and exits WITHOUT restore — restore is manual or next-run.

Usage
-----
  audit_batches.py run --plan results/finale_plan.json
  audit_batches.py pause     # after the current job finishes
  audit_batches.py resume
  audit_batches.py status
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import model_audit as ma  # status-file helpers are shared, not re-implemented

RESULTS_DIR = SCRIPT_DIR / "results"
STATUS_PATH = RESULTS_DIR / "audit_status.json"
CONTROL_PATH = RESULTS_DIR / "audit_control.json"
DEFAULT_PLAN_PATH = RESULTS_DIR / "finale_plan.json"
AUDIT_SCRIPT = SCRIPT_DIR / "model_audit.py"

REPO_ROOT = SCRIPT_DIR.parents[2]          # …/LifeOS/lifeos
LIFEOS_PYTHON = REPO_ROOT / "lifeos" / ".venv" / "bin" / "python"
AXI_PYTHON = REPO_ROOT / "axi" / ".venv" / "bin" / "python"

# Stand-in CPU judge (same spawn the shell chains used): qwen35-4b on 8080,
# GPU hidden. Spawned ONLY when nothing already serves the port.
JUDGE_PORT = 8080
JUDGE_ARGV = [
    "/usr/bin/llama-server",
    "-m", "/home/hectormr/LifeOS/models/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf",
    "-ngl", "0", "--jinja", "-c", "16384",
    "--host", "127.0.0.1", "--port", str(JUDGE_PORT),
    "-t", "6", "--no-mmap", "-np", "1",
]
JUDGE_HEALTH_TIMEOUT_S = 120

# Quiet-ish mode: voice stack down, DASHBOARD STAYS UP (axi-dashboard is
# deliberately absent — Héctor watches /models/audit live).
QUIET_SERVICES = ("axi-heartbeat.service", "axi-voice.service",
                  "axi-whisper.service", "axi-tray.service")
RESTORE_SERVICES_FIRST = ("axi-whisper.service", "axi-tray.service",
                          "axi-voice.service")
RESTORE_SERVICES_LAST = ("axi-heartbeat.service",)

PAUSE_POLL_S = 10

RESTORE_CONFIG_SNIPPET = (
    "from axi import config\n"
    "cfg = dict(config._load())\n"
    "cfg['dev_self_improve_enabled'] = True\n"
    "config.save(cfg)\n"
    "print('dev_self_improve_enabled restored to True')\n"
)

REQUIRED_JOB_KEYS = ("label", "gguf")


# ── plan handling (pure) ─────────────────────────────────────────────────────

def parse_plan(data) -> list[dict]:
    """Validate a loaded plan document → list of jobs. Raises ValueError."""
    if isinstance(data, dict):
        data = data.get("jobs")
    if not isinstance(data, list) or not data:
        raise ValueError("plan must be a non-empty JSON list of jobs "
                         "(or {'notes': ..., 'jobs': [...]})")
    for i, job in enumerate(data):
        if not isinstance(job, dict):
            raise ValueError(f"job {i} is not an object: {job!r}")
        missing = [k for k in REQUIRED_JOB_KEYS if not job.get(k)]
        if missing:
            raise ValueError(f"job {i} ({job.get('label', '?')}): "
                             f"missing required key(s) {missing}")
    return list(data)


def load_plan(path: Path) -> list[dict]:
    return parse_plan(json.loads(Path(path).read_text(encoding="utf-8")))


def build_audit_argv(job: dict, python_bin: str = str(LIFEOS_PYTHON),
                     audit_script: str = str(AUDIT_SCRIPT)) -> list[str]:
    """One job → the exact model_audit.py CLI invocation.

    --extra-flags MUST come last (argparse.REMAINDER swallows the rest).
    """
    argv = [python_bin, audit_script,
            "--label", job["label"], "--gguf", job["gguf"]]
    if job.get("mmproj"):
        argv += ["--mmproj", job["mmproj"]]
    if job.get("server_bin"):
        argv += ["--server-bin", job["server_bin"]]
    argv += ["--tiers", ",".join(job.get("tiers") or ["vram12"])]
    argv += ["--thinking-modes", ",".join(job.get("thinking_modes") or ["none"])]
    if job.get("moe"):
        argv += ["--moe", str(job["moe"])]
    if job.get("roles"):
        argv += ["--roles", ",".join(job["roles"])]
    if job.get("use_recipe"):
        argv.append("--use-recipe")
    if job.get("per_role_tuning") is False:
        argv.append("--no-per-role-tuning")
    if job.get("extra_flags"):
        argv += ["--extra-flags"] + [str(f) for f in job["extra_flags"]]
    return argv


# ── control + status files ───────────────────────────────────────────────────

def read_control(path: Path = CONTROL_PATH) -> str:
    """'pause' or 'run' — missing/corrupt/unknown always means 'run'."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "run"
    action = data.get("action") if isinstance(data, dict) else None
    return action if action in ("pause", "run") else "run"


def write_control(action: str, path: Path = CONTROL_PATH) -> None:
    if action not in ("pause", "run"):
        raise ValueError(f"invalid control action {action!r}")
    ma._atomic_write_json(Path(path), {"action": action})


def write_batch_status(queue: list[str], position: int, total: int,
                       state: str = "running", **kw) -> None:
    """The driver's status writes — it OWNS the ``batch`` key."""
    ma.write_status(_path=STATUS_PATH, state=state,
                    batch={"queue": list(queue), "position": position,
                           "total": total}, **kw)


# ── subprocess seams (every side effect goes through these — tests mock) ─────

def _run(cmd: list[str], check: bool = False, log_file=None) -> int:
    """Run one command to completion; never raises unless check=True."""
    print(f"[batch] $ {' '.join(cmd)}", flush=True)
    try:
        proc = subprocess.run(cmd, stdout=log_file or None,
                              stderr=subprocess.STDOUT if log_file else None)
        if check and proc.returncode != 0:
            raise RuntimeError(f"command failed rc={proc.returncode}: {cmd}")
        return proc.returncode
    except FileNotFoundError as e:
        if check:
            raise
        print(f"[batch] WARNING: {e}", flush=True)
        return 127


def run_job(argv: list[str], log_path: Path) -> int:
    """Run one audit job, streaming its output to a per-job log file."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", encoding="utf-8") as f:
        proc = subprocess.run(argv, stdout=f, stderr=subprocess.STDOUT)
    return proc.returncode


def port_serving(port: int) -> bool:
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=3) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001 — any failure means "not serving"
        return False


def spawn_judge(log_dir: Path) -> Optional[subprocess.Popen]:
    """Stand-in CPU judge on 8080 — ONLY when the port is free.

    Returns None when something already serves 8080 (prod judge / leftover):
    we use it as-is and must NOT kill it later.
    """
    if port_serving(JUDGE_PORT):
        print(f"[batch] port {JUDGE_PORT} already serving — using the "
              "existing judge (will not manage it)", flush=True)
        return None
    log_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["CUDA_VISIBLE_DEVICES"] = ""   # judge is CPU-only, GPU stays free
    logf = open(log_dir / "judge_standin.log", "a", encoding="utf-8")
    print(f"[batch] spawning stand-in judge on {JUDGE_PORT}", flush=True)
    proc = subprocess.Popen(JUDGE_ARGV, stdout=logf, stderr=subprocess.STDOUT,
                            env=env, start_new_session=True)
    deadline = time.monotonic() + JUDGE_HEALTH_TIMEOUT_S
    while time.monotonic() < deadline:
        if port_serving(JUDGE_PORT):
            return proc
        if proc.poll() is not None:
            break
        time.sleep(2)
    print("[batch] WARNING: stand-in judge never became healthy — "
          "judge-scored layers will be skipped by the harness", flush=True)
    return proc


def kill_judge(proc: Optional[subprocess.Popen]) -> None:
    if proc is None:
        return
    print("[batch] killing stand-in judge", flush=True)
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.terminate()
        except Exception:  # noqa: BLE001
            pass
    try:
        proc.wait(timeout=15)
    except Exception:  # noqa: BLE001
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:  # noqa: BLE001
            pass


# ── environment lifecycle ────────────────────────────────────────────────────

def setup_quiet(log_dir: Path) -> Optional[subprocess.Popen]:
    """Quiet-ish mode ONCE at batch start. The dashboard STAYS UP."""
    print("[batch] === quiet-ish mode (dashboard stays up) ===", flush=True)
    _run(["systemctl", "--user", "stop", *QUIET_SERVICES])
    _run(["bash", str(REPO_ROOT / "axi" / "scripts" / "axi-game-on"),
          "--offline"])
    return spawn_judge(log_dir)


def restore(judge_proc: Optional[subprocess.Popen]) -> None:
    """Full restore at batch end (order matters; see tests)."""
    print("[batch] === RESTORE ===", flush=True)
    kill_judge(judge_proc)
    _run(["bash", str(REPO_ROOT / "axi" / "scripts" / "axi-game-off")])
    _run([str(AXI_PYTHON), "-c", RESTORE_CONFIG_SNIPPET])
    _run(["systemctl", "--user", "start", *RESTORE_SERVICES_FIRST])
    _run(["systemctl", "--user", "start", *RESTORE_SERVICES_LAST])
    _run([str(LIFEOS_PYTHON), str(AUDIT_SCRIPT), "--compare"])


# ── pause gate (between jobs ONLY — a running job is never killed) ───────────

def pause_gate(judge_proc: Optional[subprocess.Popen], log_dir: Path,
               queue: list[str], position: int, total: int,
               sleep_fn=time.sleep) -> Optional[subprocess.Popen]:
    """Honour audit_control.json between jobs.

    pause → kill the stand-in judge (GPU completely free for gaming), write
    state=paused, poll every PAUSE_POLL_S until action == 'run', then
    re-spawn the judge and continue. Returns the (possibly new) judge proc.
    """
    if read_control() != "pause":
        return judge_proc
    print("[batch] PAUSED (between jobs) — GPU free; waiting for resume",
          flush=True)
    kill_judge(judge_proc)
    write_batch_status(queue, position, total, state="paused")
    while read_control() == "pause":
        sleep_fn(PAUSE_POLL_S)
    print("[batch] RESUMED — re-spawning stand-in judge", flush=True)
    write_batch_status(queue, position, total, state="running")
    return spawn_judge(log_dir)


# ── driver commands ──────────────────────────────────────────────────────────

class _Terminated(Exception):
    pass


def _sigterm_handler(signum, frame):  # noqa: ARG001
    raise _Terminated()


def cmd_run(args) -> int:
    plan = load_plan(Path(args.plan))
    queue = [job["label"] for job in plan]
    total = len(plan)
    log_dir = RESULTS_DIR / f"batch-{datetime.now():%Y%m%d-%H%M}"
    log_dir.mkdir(parents=True, exist_ok=True)
    print(f"[batch] {total} jobs — logs in {log_dir}", flush=True)

    signal.signal(signal.SIGTERM, _sigterm_handler)
    judge = setup_quiet(log_dir)
    position = 0
    failures = 0
    interrupted = False
    try:
        for i, job in enumerate(plan):
            position = i + 1
            judge = pause_gate(judge, log_dir, queue, position, total)
            write_batch_status(queue, position, total, state="running",
                               label=job["label"])
            argv = build_audit_argv(job, python_bin=args.python)
            log_path = log_dir / f"{position:02d}_{job['label']}.log"
            print(f"[batch] job {position}/{total}: {job['label']} "
                  f"→ {log_path.name}", flush=True)
            rc = run_job(argv, log_path)
            print(f"[batch] job {position}/{total}: {job['label']} "
                  f"exit={rc}", flush=True)
            if rc != 0:
                failures += 1
        write_batch_status(queue, total, total, state="done")
    except _Terminated:
        # SIGTERM: finish writing status; restore is manual / next-run.
        interrupted = True
        print("[batch] SIGTERM — status written; restore is manual or "
              "next-run", flush=True)
        write_batch_status(queue, position, total, state="idle")
    finally:
        if not interrupted:
            restore(judge)
            ma.write_status(_path=STATUS_PATH, state="idle")
    if interrupted:
        return 130
    return 1 if failures else 0


def cmd_pause(_args) -> int:
    write_control("pause")
    print("pause requested — takes effect after the CURRENT job finishes "
          "(a running audit is never killed)")
    return 0


def cmd_resume(_args) -> int:
    write_control("run")
    print("resume requested — the driver picks it up within "
          f"{PAUSE_POLL_S}s")
    return 0


def cmd_status(_args) -> int:
    status = ma.read_status(STATUS_PATH) or {"state": "idle"}
    print(json.dumps(status, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="audit_batches.py",
        description="Sequential model-audit batch driver with pause/resume "
                    "(plan JSON → model_audit.py CLI jobs).")
    sub = p.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="run a plan file sequentially")
    run.add_argument("--plan", default=str(DEFAULT_PLAN_PATH),
                     help=f"plan JSON (default: {DEFAULT_PLAN_PATH})")
    run.add_argument("--python", default=str(LIFEOS_PYTHON),
                     help="python used to run model_audit.py "
                          "(default: the lifeos venv, like the shell chains)")
    run.set_defaults(fn=cmd_run)
    sub.add_parser("pause", help="pause after the current job").set_defaults(
        fn=cmd_pause)
    sub.add_parser("resume", help="resume a paused batch").set_defaults(
        fn=cmd_resume)
    sub.add_parser("status", help="print audit_status.json").set_defaults(
        fn=cmd_status)
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
