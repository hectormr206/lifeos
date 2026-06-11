"""Routine-learning module for the autonomous tick.

Collects one privacy-safe record per tick and aggregates a
presence-by-(weekday, hour) profile. Provides a learned Spanish hint
for the brain's timing-decision prompt once sufficient data exists.

Privacy invariant: the JSONL written by this module contains ONLY
the six scalar fields defined in _RECORD_KEYS. Image bytes, message
text, names, digests, and any life-domain payload MUST NOT appear.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
import time as _time_module
from collections import defaultdict
from pathlib import Path

log = logging.getLogger("lifeos.autonomous.routine")

# ---------------------------------------------------------------------------
# Named constants (module-level for testability)
# ---------------------------------------------------------------------------

_MIN_TOTAL_RECORDS = 10
_MIN_BUCKET_SAMPLES = 4
_HIGH_RATE = 0.65
_LOW_RATE = 0.25

_WEEKDAYS_ES = [
    "lunes",
    "martes",
    "miércoles",
    "jueves",
    "viernes",
    "sábado",
    "domingo",
]

_RECORD_KEYS = {"ts", "weekday", "hour", "presence", "activity_descriptor", "outcome"}

_PRIVACY_BANNED_KEYS = {
    "message", "text", "image", "screen", "name",
    "digest", "body", "content", "data",
}

# Allowlist of coarse activity tokens that may be written to the JSONL.
# Any value NOT in this set is replaced with "other" before writing.
_ACTIVITY_ALLOWLIST: frozenset[str] = frozenset({
    "screen+present",
    "screen+unknown",
    "screen+away",
    "no-screen+unknown",
    "no-screen+present",
    "no-screen+away",
})


# ---------------------------------------------------------------------------
# write_routine_record
# ---------------------------------------------------------------------------

def write_routine_record(
    path: Path,
    *,
    ts: float,
    weekday: int,
    hour: int,
    presence: str,
    activity_descriptor: str,
    outcome: str,
) -> None:
    """Append ONE JSON line atomically. Never raises (best-effort; logs on OSError).

    Keyword-only scalar fields → structurally impossible to leak life-data/images.

    Thread-safety: on Linux, a single write() to an O_APPEND fd with payload
    < PIPE_BUF (~4 096 bytes) is atomic. Records are ~120-160 bytes — safe.
    """
    # Sanitize at write boundary: only coarse tokens from the allowlist may
    # be persisted; any free-text value (e.g. a window title) becomes "other".
    safe_descriptor = activity_descriptor if activity_descriptor in _ACTIVITY_ALLOWLIST else "other"
    rec = {
        "ts": ts,
        "weekday": weekday,
        "hour": hour,
        "presence": presence,
        "activity_descriptor": safe_descriptor,
        "outcome": outcome,
    }
    try:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as fh:
            fh.write(json.dumps(rec) + "\n")
    except OSError:
        log.warning("autonomous: routine record write failed", exc_info=True)


# ---------------------------------------------------------------------------
# build_presence_profile
# ---------------------------------------------------------------------------

def build_presence_profile(
    path: Path,
    *,
    days: int = 30,
    now_ts: float | None = None,
) -> dict[tuple[int, int], tuple[int, int]]:
    """Pure single-pass aggregation over the JSONL within the rolling ``days`` window.

    Returns ``{(weekday, hour): (present_count, total_count)}``.
    Missing file / parse errors → ``{}`` (each bad line skipped, never raises).
    ``now_ts`` defaults to ``time.time()``; injected in tests for deterministic windows.
    """
    if now_ts is None:
        now_ts = _time_module.time()
    cutoff = now_ts - days * 86400.0

    counts: dict[tuple[int, int], list[int, int]] = defaultdict(lambda: [0, 0])

    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    ts = float(rec["ts"])
                    if ts < cutoff:
                        continue
                    wd = int(rec["weekday"])
                    h = int(rec["hour"])
                    pres = rec["presence"]
                    counts[(wd, h)][1] += 1
                    if pres == "present":
                        counts[(wd, h)][0] += 1
                except (KeyError, ValueError, TypeError):
                    continue
    except FileNotFoundError:
        return {}
    except OSError:
        log.warning("autonomous: could not read routine JSONL", exc_info=True)
        return {}

    return {k: (v[0], v[1]) for k, v in counts.items()}


# ---------------------------------------------------------------------------
# format_routine_hint
# ---------------------------------------------------------------------------

def format_routine_hint(
    profile: dict[tuple[int, int], tuple[int, int]],
    *,
    now_weekday: int,
    now_hour: int,
) -> str | None:
    """PURE: no I/O, no clock. Returns a 1-2 sentence Spanish hint or None.

    None on cold-start (< _MIN_TOTAL_RECORDS total) / ambiguous signal / absent
    bucket / insufficient local samples. Never contains life-data.

    Uses ±1h smoothing within the same weekday: aggregates (wd, h-1), (wd, h),
    (wd, h+1) — clamped to 0..23, no cross-day wrap.
    """
    # Global floor: cold-start guard
    total_all = sum(total for _, total in profile.values())
    if total_all < _MIN_TOTAL_RECORDS:
        return None

    # ±1h smoothing within the same weekday
    neighbor_hours = [h for h in (now_hour - 1, now_hour, now_hour + 1) if 0 <= h <= 23]
    present_sum = 0
    total_sum = 0
    for h in neighbor_hours:
        bucket = profile.get((now_weekday, h))
        if bucket is not None:
            present_sum += bucket[0]
            total_sum += bucket[1]

    # No samples in smoothed window → None
    if total_sum < _MIN_BUCKET_SAMPLES:
        return None

    rate = present_sum / total_sum
    pct = round(rate * 100)
    dia = _WEEKDAYS_ES[now_weekday]
    hh = f"{now_hour:02d}"

    if rate >= _HIGH_RATE:
        return (
            f"Patrón habitual: los {dia} alrededor de las {hh}:00 "
            f"Héctor suele estar presente (~{pct}% de las veces). "
            "Es una ventana típicamente receptiva."
        )
    if rate <= _LOW_RATE:
        return (
            f"Patrón habitual: los {dia} alrededor de las {hh}:00 "
            f"Héctor rara vez está presente (~{pct}% de las veces). "
            "Probablemente no sea un buen momento."
        )

    # Middle band — ambiguous, return None
    return None


# ---------------------------------------------------------------------------
# trim_routine_records
# ---------------------------------------------------------------------------

def trim_routine_records(
    path: Path,
    *,
    days: int = 90,
    now_ts: float | None = None,
) -> int:
    """Rewrite the JSONL keeping only lines with ts >= now - days*86400.

    Returns count kept. Missing file → 0. Atomic via temp-file + os.replace.
    Never raises (best-effort; logs on OSError).
    """
    if now_ts is None:
        now_ts = _time_module.time()
    cutoff = now_ts - days * 86400.0
    path = Path(path)

    try:
        with open(path) as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        return 0
    except OSError:
        log.warning("autonomous: could not read routine JSONL for trim", exc_info=True)
        return 0

    survivors = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        try:
            rec = json.loads(stripped)
            if float(rec["ts"]) >= cutoff:
                survivors.append(stripped + "\n")
        except (KeyError, ValueError, TypeError):
            # Drop corrupt lines: build_presence_profile already ignores them,
            # so keeping them only lets them accumulate forever.
            pass

    tmp_name: str | None = None
    try:
        dir_path = path.parent
        with tempfile.NamedTemporaryFile(
            mode="w", dir=dir_path, delete=False, suffix=".tmp"
        ) as tmp:
            tmp_name = tmp.name
            tmp.writelines(survivors)
        os.replace(tmp_name, path)
        tmp_name = None  # replace succeeded; file was renamed, nothing to clean up
    except OSError:
        log.warning("autonomous: could not write trimmed routine JSONL", exc_info=True)
        return 0
    finally:
        if tmp_name is not None:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass

    return len(survivors)
