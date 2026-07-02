"""Pure decision logic and safety guards for the nightly self-improvement loop.

This module intentionally contains NO I/O, config reads, or clock reads in its
decision functions — every input is passed in so the scheduling gate and the
dev-engine guard are unit-testable in isolation.

The one exception is :func:`append_outcome_log`, which appends a best-effort
JSONL observability line; it never raises out to its caller.

SAFETY INVARIANT
----------------
A self-improve-originated dev run must NEVER be able to land changes to the
autonomous dev engine itself (the machinery that runs, reviews, lands and
schedules self-improvement). Today the only defence is a prompt instruction in
the nightly goal — advisory, not enforced. :data:`PROTECTED_DEV_ENGINE_PATHS`
plus :func:`violates_dev_engine_guard` make that invariant real at the land gate.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

log = logging.getLogger("axi.self_improve")


# ---------------------------------------------------------------------------
# Protected dev-engine surface
# ---------------------------------------------------------------------------
#
# Repo-relative paths (relative to the dev_director_repo root, ~/LifeOS/lifeos)
# that together constitute the autonomous dev engine. If a self-improve run
# touches ANY of these, landing it is refused. The set is deliberately the
# machinery that *builds/reviews/lands/schedules* self-improvement — editing it
# from within a self-improve run is the exact recursive-modification risk we
# guard against.
PROTECTED_DEV_ENGINE_PATHS: tuple[str, ...] = (
    "axi/src/axi/dev_run.py",          # run lifecycle + detached launch
    "axi/src/axi/_dev_run_entry.py",   # detached run entrypoint
    "axi/src/axi/dev_director.py",     # coder + review loop, diff extraction
    "axi/src/axi/dev_land.py",         # the landing gate (only path that pushes)
    "axi/src/axi/dev_env.py",          # persistent-environment runs
    "axi/src/axi/dev_env_instance.py", # env instance machinery
    "axi/src/axi/dev_task.py",         # dev task machinery
    "axi/src/axi/self_improve.py",     # this module: the scheduler + the guard
    "axi/src/axi/daemon.py",           # hosts the nightly self-improve loop
)


# ---------------------------------------------------------------------------
# Pure decision: should the nightly loop fire?
# ---------------------------------------------------------------------------


def should_fire_self_improve(
    *,
    now,
    enabled: bool,
    on_battery: bool,
    target_hour: int,
    last_fired_date: str | None,
    today: str,
) -> bool:
    """Return True iff the nightly self-improve run should start right now.

    Pure: no I/O, no config reads, no clock reads. Mirrors the original inline
    gate EXACTLY — fires only when the feature is enabled, we are on AC power,
    the current hour matches the target hour, and we have not already fired
    today.

    Args:
        now: an aware/naive datetime whose ``.hour`` is the current local hour.
        enabled: the ``dev_self_improve_enabled`` config flag.
        on_battery: True if the laptop is on battery (never fire a heavy run).
        target_hour: the ``dev_self_improve_hour`` config value (0-23).
        last_fired_date: the last date we fired ("%Y-%m-%d") or None.
        today: today's date string ("%Y-%m-%d").
    """
    if not enabled:
        return False
    if on_battery:
        return False
    if now.hour != target_hour:
        return False
    if last_fired_date == today:
        return False
    return True


# ---------------------------------------------------------------------------
# Pure guard: does a run touch the protected dev engine?
# ---------------------------------------------------------------------------


def violates_dev_engine_guard(
    changed_paths,
    *,
    protected: tuple[str, ...] = PROTECTED_DEV_ENGINE_PATHS,
) -> list[str]:
    """Return the subset of ``changed_paths`` that hits the protected dev engine.

    Pure. A changed path is considered a violation when it equals a protected
    repo-relative path or ends with ``/<protected path>`` — so it matches
    regardless of whether the diff reports repo-relative or absolute paths.

    Returns an empty list when nothing protected is touched.
    """
    offenders: list[str] = []
    for raw in changed_paths or []:
        if not raw:
            continue
        norm = str(raw).replace("\\", "/").lstrip("./")
        for prot in protected:
            if norm == prot or norm.endswith("/" + prot):
                offenders.append(raw)
                break
    return offenders


# ---------------------------------------------------------------------------
# Pure: extract changed file paths from a unified-diff / git patch
# ---------------------------------------------------------------------------


def changed_paths_from_patch(patch_text: str) -> list[str]:
    """Extract repo-relative changed file paths from a git patch.

    Parses ``diff --git a/<x> b/<y>`` headers (falling back to ``+++ b/<path>``
    lines for the destination). ``/dev/null`` destinations (deletions) fall back
    to the ``--- a/<path>`` source. Returns a de-duplicated, order-preserving
    list. Pure — never raises.
    """
    paths: list[str] = []
    seen: set[str] = set()

    def _add(p: str) -> None:
        p = p.strip()
        if p and p != "/dev/null" and p not in seen:
            seen.add(p)
            paths.append(p)

    pending_minus: str | None = None
    for line in (patch_text or "").splitlines():
        if line.startswith("diff --git "):
            # diff --git a/foo b/foo  → prefer the b/ side
            parts = line.split(" ")
            if len(parts) >= 4:
                b = parts[3]
                if b.startswith("b/"):
                    b = b[2:]
                _add(b)
            pending_minus = None
        elif line.startswith("--- "):
            src = line[4:].strip()
            if src.startswith("a/"):
                src = src[2:]
            pending_minus = src
        elif line.startswith("+++ "):
            dst = line[4:].strip()
            if dst.startswith("b/"):
                dst = dst[2:]
            if dst == "/dev/null" and pending_minus:
                _add(pending_minus)
            else:
                _add(dst)
            pending_minus = None
    return paths


# ---------------------------------------------------------------------------
# Observability: nightly outcome log (JSONL, best-effort)
# ---------------------------------------------------------------------------

_LOG_FILENAME = "self_improve_log.jsonl"
_GOAL_MAX = 200


def build_outcome_record(
    *,
    run_id: str,
    started_at: str | None,
    goal: str,
    status: str,
    changed_paths=None,
    guard_blocked: bool = False,
) -> dict:
    """Build a structured outcome record for the nightly log. Pure."""
    return {
        "run_id": run_id,
        "started_at": started_at,
        "goal": (goal or "")[:_GOAL_MAX],
        "status": status,
        "changed_paths": list(changed_paths or []),
        "guard_blocked": bool(guard_blocked),
    }


def append_outcome_log(state_dir, record: dict) -> None:
    """Append one JSONL record to ``<state_dir>/self_improve_log.jsonl``.

    Best-effort: any failure is swallowed (logged at debug) so an observability
    write can never break the nightly loop or the land gate.
    """
    try:
        log_path = Path(state_dir) / _LOG_FILENAME
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001
        log.debug("self_improve outcome log append failed", exc_info=True)
