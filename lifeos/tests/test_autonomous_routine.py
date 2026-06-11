"""Tests for lifeos.autonomous.routine — the routine-learning module.

Invocation (from repo root): cd /home/hectormr/LifeOS/lifeos/axi && .venv/bin/python -m pytest ../lifeos/tests/test_autonomous_routine.py

Strict TDD: every test was written RED first (stubs raise NotImplementedError),
then the implementation was added to turn it GREEN.

Privacy invariant: the JSONL written by write_routine_record MUST contain ONLY
the six scalar fields {ts, weekday, hour, presence, activity_descriptor, outcome}.
No life-data keys (message, text, image, screen, name, digest, body, content, data)
may appear in any line.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_NOW_TS = 1_749_600_000.0  # fixed reference timestamp (approx. 2025-06-11 ~12:00 UTC)
_DAY = 86_400.0


def _write_line(path: Path, **fields) -> None:
    """Helper: append a raw JSONL line to a file (bypasses write_routine_record)."""
    with open(path, "a") as fh:
        fh.write(json.dumps(fields) + "\n")


def _seed_records(path: Path, records: list[dict]) -> None:
    """Write multiple raw records to path."""
    for rec in records:
        _write_line(path, **rec)


# ---------------------------------------------------------------------------
# Phase 1 — write_routine_record
# ---------------------------------------------------------------------------


def test_write_routine_record_single_append(tmp_path: Path) -> None:
    """Single call produces exactly 1 line with exact 6-key schema."""
    from lifeos.autonomous.routine import write_routine_record

    p = tmp_path / "routine.jsonl"
    write_routine_record(
        p,
        ts=1.0,
        weekday=2,
        hour=10,
        presence="present",
        activity_descriptor="screen+present",
        outcome="pushed",
    )

    lines = p.read_text().splitlines()
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert set(parsed.keys()) == {"ts", "weekday", "hour", "presence", "activity_descriptor", "outcome"}


def test_write_routine_record_privacy(tmp_path: Path) -> None:
    """Written line contains only the 6 allowed fields — no life-data keys."""
    from lifeos.autonomous.routine import write_routine_record, _PRIVACY_BANNED_KEYS

    p = tmp_path / "routine.jsonl"
    write_routine_record(
        p,
        ts=1.0,
        weekday=0,
        hour=8,
        presence="unknown",
        activity_descriptor="no-screen+unknown",
        outcome="esperar",
    )

    parsed = json.loads(p.read_text().splitlines()[0])
    assert set(parsed.keys()) == {"ts", "weekday", "hour", "presence", "activity_descriptor", "outcome"}
    assert not _PRIVACY_BANNED_KEYS.intersection(parsed.keys()), (
        f"banned keys found: {_PRIVACY_BANNED_KEYS.intersection(parsed.keys())}"
    )


def test_write_routine_record_n_appends(tmp_path: Path) -> None:
    """5 sequential calls produce exactly 5 independently parseable lines."""
    from lifeos.autonomous.routine import write_routine_record

    p = tmp_path / "routine.jsonl"
    outcomes = ["pushed", "esperar", "nada", "skipped-empty", "skipped-brain-down"]
    for i, outcome in enumerate(outcomes):
        write_routine_record(
            p,
            ts=float(i),
            weekday=i % 7,
            hour=i % 24,
            presence="present",
            activity_descriptor="screen+present",
            outcome=outcome,
        )

    lines = p.read_text().splitlines()
    assert len(lines) == 5
    for line in lines:
        obj = json.loads(line)
        assert isinstance(obj, dict)


def test_write_routine_record_atomic_20(tmp_path: Path) -> None:
    """20 sequential calls → every line is a complete parseable JSON object."""
    from lifeos.autonomous.routine import write_routine_record

    p = tmp_path / "routine.jsonl"
    for i in range(20):
        write_routine_record(
            p,
            ts=float(i * 100),
            weekday=i % 7,
            hour=i % 24,
            presence="present" if i % 2 == 0 else "unknown",
            activity_descriptor="screen+present",
            outcome="esperar",
        )

    lines = p.read_text().splitlines()
    assert len(lines) == 20
    for line in lines:
        obj = json.loads(line)
        assert set(obj.keys()) == {"ts", "weekday", "hour", "presence", "activity_descriptor", "outcome"}


# ---------------------------------------------------------------------------
# Phase 2 — build_presence_profile
# ---------------------------------------------------------------------------


def test_build_presence_profile_known_rates(tmp_path: Path) -> None:
    """3 present + 1 away in bucket (1,9) → result[(1,9)] == (3, 4), no other key."""
    from lifeos.autonomous.routine import build_presence_profile

    p = tmp_path / "routine.jsonl"
    now_ts = _NOW_TS
    ts_recent = now_ts - 5 * _DAY  # 5 days ago — within 30d window
    records = [
        {"ts": ts_recent, "weekday": 1, "hour": 9, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"},
        {"ts": ts_recent, "weekday": 1, "hour": 9, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"},
        {"ts": ts_recent, "weekday": 1, "hour": 9, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"},
        {"ts": ts_recent, "weekday": 1, "hour": 9, "presence": "away",    "activity_descriptor": "x", "outcome": "esperar"},
    ]
    _seed_records(p, records)

    result = build_presence_profile(p, days=30, now_ts=now_ts)
    assert result == {(1, 9): (3, 4)}


def test_build_presence_profile_window_exclusion(tmp_path: Path) -> None:
    """Record 35d ago is excluded; record 5d ago is kept."""
    from lifeos.autonomous.routine import build_presence_profile

    p = tmp_path / "routine.jsonl"
    now_ts = _NOW_TS
    _seed_records(p, [
        {"ts": now_ts - 35 * _DAY, "weekday": 3, "hour": 14, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"},
        {"ts": now_ts - 5 * _DAY,  "weekday": 3, "hour": 14, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"},
    ])

    result = build_presence_profile(p, days=30, now_ts=now_ts)
    assert result == {(3, 14): (1, 1)}


def test_build_presence_profile_missing_file(tmp_path: Path) -> None:
    """Non-existent path returns {} without exception."""
    from lifeos.autonomous.routine import build_presence_profile

    result = build_presence_profile(tmp_path / "does_not_exist.jsonl", days=30, now_ts=_NOW_TS)
    assert result == {}


def test_build_presence_profile_corrupt_line(tmp_path: Path) -> None:
    """Bad line is skipped; valid in-window line contributes normally."""
    from lifeos.autonomous.routine import build_presence_profile

    p = tmp_path / "routine.jsonl"
    now_ts = _NOW_TS
    # One corrupt line, then one valid record
    p.write_text(
        "not-valid-json\n"
        + json.dumps({"ts": now_ts - 5 * _DAY, "weekday": 0, "hour": 10, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"})
        + "\n"
    )

    result = build_presence_profile(p, days=30, now_ts=now_ts)
    assert result == {(0, 10): (1, 1)}


# ---------------------------------------------------------------------------
# Phase 3 — format_routine_hint
# ---------------------------------------------------------------------------


def _make_profile(
    records: list[tuple[int, int, str]],  # (weekday, hour, presence)
) -> dict[tuple[int, int], tuple[int, int]]:
    """Build a profile dict from a flat list of (weekday, hour, presence) tuples."""
    from collections import defaultdict
    counts: dict[tuple[int, int], list[int, int]] = defaultdict(lambda: [0, 0])
    for wd, h, pres in records:
        counts[(wd, h)][1] += 1
        if pres == "present":
            counts[(wd, h)][0] += 1
    return {k: tuple(v) for k, v in counts.items()}


def test_format_routine_hint_cold_start_none() -> None:
    """< 10 total records → None regardless of local rate."""
    from lifeos.autonomous.routine import format_routine_hint

    # 8 records total, current bucket (2,10) has high local rate
    records = [(2, 10, "present")] * 6 + [(2, 10, "away")] * 2  # 8 total
    profile = _make_profile(records)
    result = format_routine_hint(profile, now_weekday=2, now_hour=10)
    assert result is None


def test_format_routine_hint_absent_bucket_none() -> None:
    """Bucket (5,3) absent from profile → None."""
    from lifeos.autonomous.routine import format_routine_hint

    # 15 records but none in (5,3) — and no neighbors close enough to smooth
    records = [(2, 10, "present")] * 15
    profile = _make_profile(records)
    result = format_routine_hint(profile, now_weekday=5, now_hour=3)
    assert result is None


def test_format_routine_hint_high_presence_hint() -> None:
    """High-presence bucket (rate >= 0.65, >= 4 local samples) returns Spanish hint."""
    from lifeos.autonomous.routine import format_routine_hint

    # 20 total records: 18 present at (2,10), 2 away — ensures global >= 10 and local rate high
    records = [(2, 10, "present")] * 18 + [(2, 10, "away")] * 2
    profile = _make_profile(records)
    result = format_routine_hint(profile, now_weekday=2, now_hour=10)
    assert result is not None
    assert "suele estar presente" in result
    # Should contain a percentage figure
    assert "%" in result


def test_format_routine_hint_low_presence() -> None:
    """Low-presence bucket (rate <= 0.25) returns None or low-phrasing string."""
    from lifeos.autonomous.routine import format_routine_hint

    # 20 total, only 2 present at (0,22)
    records = [(0, 22, "present")] * 2 + [(0, 22, "away")] * 18
    profile = _make_profile(records)
    result = format_routine_hint(profile, now_weekday=0, now_hour=22)
    # Acceptable: None OR a string with "rara vez"
    assert result is None or "rara vez" in result


def test_format_routine_hint_ambiguous_mid_band() -> None:
    """Rate in 0.25 < rate < 0.65 → None (no noisy hint)."""
    from lifeos.autonomous.routine import format_routine_hint

    # 20 total, 9 present at (1,14) → rate = 0.45
    records = [(1, 14, "present")] * 9 + [(1, 14, "away")] * 11
    profile = _make_profile(records)
    result = format_routine_hint(profile, now_weekday=1, now_hour=14)
    assert result is None


def test_format_routine_hint_smoothing() -> None:
    """±1h smoothing: current bucket empty but neighbors have high rate → hint returned."""
    from lifeos.autonomous.routine import format_routine_hint

    # Bucket (2,10) itself: 0 samples
    # Neighbor (2,9): 5 present, 0 away
    # Neighbor (2,11): 5 present, 0 away
    # Total smoothed: 10 present / 10 total = 1.0 → high rate
    # Plus we need >= 10 global records total
    records = (
        [(2, 9, "present")] * 5
        + [(2, 11, "present")] * 5
        + [(3, 15, "away")] * 5  # filler for global total
    )
    profile = _make_profile(records)
    result = format_routine_hint(profile, now_weekday=2, now_hour=10)
    assert result is not None


# ---------------------------------------------------------------------------
# Phase 4 — trim_routine_records
# ---------------------------------------------------------------------------


def test_trim_routine_records_drops_old(tmp_path: Path) -> None:
    """100d + 60d + 10d records; days=90 → 2 kept (60d and 10d)."""
    from lifeos.autonomous.routine import trim_routine_records

    p = tmp_path / "routine.jsonl"
    now_ts = _NOW_TS
    _seed_records(p, [
        {"ts": now_ts - 100 * _DAY, "weekday": 0, "hour": 9, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"},
        {"ts": now_ts - 60 * _DAY,  "weekday": 1, "hour": 10, "presence": "away",    "activity_descriptor": "x", "outcome": "esperar"},
        {"ts": now_ts - 10 * _DAY,  "weekday": 2, "hour": 11, "presence": "present", "activity_descriptor": "x", "outcome": "nada"},
    ])

    kept = trim_routine_records(p, days=90, now_ts=now_ts)
    assert kept == 2
    lines = p.read_text().splitlines()
    assert len(lines) == 2


def test_trim_routine_records_missing_file_noop(tmp_path: Path) -> None:
    """Non-existent path → no exception, returns 0."""
    from lifeos.autonomous.routine import trim_routine_records

    kept = trim_routine_records(tmp_path / "no_file.jsonl", days=90, now_ts=_NOW_TS)
    assert kept == 0


# ---------------------------------------------------------------------------
# Fix 1 — activity_descriptor allowlist sanitization at write boundary
# ---------------------------------------------------------------------------

_COARSE_ALLOWED = {
    "screen+present",
    "screen+unknown",
    "screen+away",
    "no-screen+unknown",
    "no-screen+present",
    "no-screen+away",
}


def test_write_routine_record_pii_descriptor_replaced_with_other(tmp_path: Path) -> None:
    """Free-text activity_descriptor is replaced with 'other'; PII string absent from JSONL."""
    from lifeos.autonomous.routine import write_routine_record

    pii_value = "coding on HealthRecords.py weight 82kg"
    p = tmp_path / "routine.jsonl"
    write_routine_record(
        p,
        ts=1.0,
        weekday=2,
        hour=10,
        presence="present",
        activity_descriptor=pii_value,
        outcome="pushed",
    )

    raw = p.read_text()
    assert pii_value not in raw, "PII string must NOT appear in the JSONL"
    rec = json.loads(raw.splitlines()[0])
    assert rec["activity_descriptor"] == "other", (
        f"Expected 'other', got {rec['activity_descriptor']!r}"
    )


def test_write_routine_record_coarse_tokens_pass_through_unchanged(tmp_path: Path) -> None:
    """All known coarse tokens pass through write_routine_record unchanged."""
    from lifeos.autonomous.routine import write_routine_record

    p = tmp_path / "routine.jsonl"
    for token in sorted(_COARSE_ALLOWED):
        write_routine_record(
            p,
            ts=1.0,
            weekday=0,
            hour=8,
            presence="unknown",
            activity_descriptor=token,
            outcome="esperar",
        )

    lines = p.read_text().splitlines()
    assert len(lines) == len(_COARSE_ALLOWED)
    written_tokens = {json.loads(line)["activity_descriptor"] for line in lines}
    assert written_tokens == _COARSE_ALLOWED, (
        f"Expected {_COARSE_ALLOWED}, got {written_tokens}"
    )


# ---------------------------------------------------------------------------
# Fix 2 — cold-start prompt byte-identity
# ---------------------------------------------------------------------------


def test_cold_start_prompt_byte_identity() -> None:
    """_build_prompt with routine_hint=None is BYTE-FOR-BYTE identical to call without the param."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    from lifeos.autonomous.cron import _build_prompt, _NO_PERCEPTION

    MX = ZoneInfo("America/Mexico_City")
    now = datetime(2026, 6, 10, 12, 0, tzinfo=MX)
    digest = "Héctor corrió 5 km hoy."
    edge = "Sin correlaciones."

    prompt_explicit_none = _build_prompt(now, digest, edge, _NO_PERCEPTION, routine_hint=None)
    prompt_no_kwarg = _build_prompt(now, digest, edge, _NO_PERCEPTION)
    assert prompt_explicit_none == prompt_no_kwarg, (
        "Prompt with routine_hint=None must be byte-identical to call without routine_hint"
    )


# ---------------------------------------------------------------------------
# Fix 3 — trim must DROP corrupt lines, not keep them
# ---------------------------------------------------------------------------


def test_trim_drops_corrupt_lines(tmp_path: Path) -> None:
    """Corrupt line + recent valid lines → after trim, corrupt line gone, valid lines kept."""
    from lifeos.autonomous.routine import trim_routine_records

    p = tmp_path / "routine.jsonl"
    now_ts = _NOW_TS
    recent_ts = now_ts - 5 * _DAY
    corrupt_line = "this-is-not-json\n"
    valid_rec = {"ts": recent_ts, "weekday": 1, "hour": 9, "presence": "present", "activity_descriptor": "screen+present", "outcome": "pushed"}
    p.write_text(corrupt_line + json.dumps(valid_rec) + "\n")

    kept = trim_routine_records(p, days=90, now_ts=now_ts)
    remaining = p.read_text().splitlines()

    assert "this-is-not-json" not in p.read_text(), "Corrupt line must be dropped"
    # The 1 valid line is kept
    assert len(remaining) == 1
    assert json.loads(remaining[0])["ts"] == recent_ts
    assert kept == 1


# ---------------------------------------------------------------------------
# Fix 4 — trim must not leave orphaned .tmp on os.replace failure
# ---------------------------------------------------------------------------


def test_trim_cleans_tmp_file_on_replace_failure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """If os.replace raises, no .tmp file is left in the directory."""
    import os as _os
    from lifeos.autonomous.routine import trim_routine_records

    p = tmp_path / "routine.jsonl"
    now_ts = _NOW_TS
    _write_line(p, ts=now_ts - 5 * _DAY, weekday=0, hour=8, presence="present",
                activity_descriptor="screen+present", outcome="pushed")

    def _failing_replace(src, dst):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(_os, "replace", _failing_replace)
    # Must not raise
    kept = trim_routine_records(p, days=90, now_ts=now_ts)
    assert kept == 0  # returns 0 on failure

    # No .tmp files left in tmp_path
    tmp_files = list(tmp_path.glob("*.tmp"))
    assert tmp_files == [], f"Orphaned .tmp files found: {tmp_files}"
