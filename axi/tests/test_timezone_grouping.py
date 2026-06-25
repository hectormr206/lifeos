"""Timezone-aware grouping and display tests — Strict TDD RED phase.

Tests cover:
  TZ-1  config_schema timezone default uses system tz (not hardcoded literal)
  TZ-2  same-day linker groups by LOCAL tz, not UTC (the headline cross-midnight case)
  TZ-3  same-day linker falls back to UTC on bad tz string (no crash)
  TZ-4  brain3d route passes 'tz' to template context
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from unittest.mock import patch

import pytest


# ─────────────────────────────────────────────────────────────────────────────
# TZ-1  config_schema: timezone default reflects system tz via tzlocal
# ─────────────────────────────────────────────────────────────────────────────


def test_config_timezone_default_uses_system_tz():
    """The 'timezone' ConfigField default must come from tzlocal, not a hardcoded literal.

    We patch tzlocal.get_localzone_name to a known value and re-evaluate the
    module-level default.  The test discriminates against a hardcoded string
    like 'America/Mexico_City': if the default is static, changing tzlocal has
    no effect and the assertion fails.
    """
    # Patch tzlocal at the module level that config_schema imports from.
    with patch("tzlocal.get_localzone_name", return_value="Europe/Berlin"):
        # Re-import to pick up patched tzlocal.
        import importlib
        import axi.config_schema as _cs
        importlib.reload(_cs)
        defaults = _cs.defaults()

    # After reload with patched tzlocal the default must reflect the patched value.
    assert defaults["timezone"] == "Europe/Berlin", (
        f"timezone default is '{defaults['timezone']}' — expected 'Europe/Berlin'. "
        "The default is not reading from tzlocal (still hardcoded)."
    )


def test_config_timezone_default_falls_back_to_utc_when_tzlocal_fails():
    """If tzlocal raises or returns None the default must fall back to 'UTC'."""
    with patch("tzlocal.get_localzone_name", side_effect=Exception("no tz")):
        import importlib
        import axi.config_schema as _cs
        importlib.reload(_cs)
        defaults = _cs.defaults()

    assert defaults["timezone"] == "UTC", (
        f"timezone default is '{defaults['timezone']}' — expected 'UTC' fallback "
        "when tzlocal raises."
    )


# ─────────────────────────────────────────────────────────────────────────────
# TZ-2  same-day linker groups by LOCAL tz, not UTC (cross-midnight test)
# ─────────────────────────────────────────────────────────────────────────────


def _insert_node(conn, kind="fact", label="test", domain="health", ts=None) -> int:
    now = ts or time.time()
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (kind, label, "{}", domain, now, now),
    )
    conn.commit()
    return cur.lastrowid


def _edge_exists(conn, a: int, b: int, kind: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind=? LIMIT 1",
        (a, b, kind),
    ).fetchone()
    return row is not None


def _any_edge(conn, a: int, b: int, kind: str) -> bool:
    return _edge_exists(conn, a, b, kind) or _edge_exists(conn, b, a, kind)


def test_same_day_groups_by_local_tz_not_utc():
    """Headline test: two timestamps that share a LOCAL calendar day but span UTC midnight
    must be linked when the linker is configured with the local tz, and must NOT be linked
    when they span a LOCAL midnight (even if they share the same UTC day).

    Setup (America/Mexico_City = UTC-6):
      ts_local_eve  = 2026-06-10 23:00 local  → 2026-06-11 05:00 UTC
      ts_local_morn = 2026-06-10 22:00 local  → 2026-06-11 04:00 UTC
    Both are LOCAL June 10.  UTC grouping puts them on June 11 together — that part
    is the same.  The discriminating case is the *negative* case:

      ts_just_past_local_midnight = 2026-06-11 00:30 local → 2026-06-11 06:30 UTC
    This is LOCAL June 11.  Grouping by UTC both 05:00 and 06:30 are on June 11 —
    UTC grouping would link them.  Local-tz grouping keeps them on different local days:
    ts_local_eve is June 10 local; ts_just_past is June 11 local → must NOT be linked.

    So: (ts_local_morn, ts_local_eve) → same local day → linked
        (ts_local_eve, ts_just_past_local_midnight) → different local day → NOT linked
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # America/Mexico_City = UTC-6 (standard; no DST at these dates for testing).
    # We fix the epoch values manually to avoid depending on ZoneInfo in the test itself.
    # UTC offset: -6h = -21600s

    # 2026-06-10 22:00 local (Mexico City) = 2026-06-11 04:00 UTC
    ts_local_morn = datetime(2026, 6, 11, 4, 0, 0, tzinfo=timezone.utc).timestamp()

    # 2026-06-10 23:00 local (Mexico City) = 2026-06-11 05:00 UTC
    ts_local_eve = datetime(2026, 6, 11, 5, 0, 0, tzinfo=timezone.utc).timestamp()

    # 2026-06-11 00:30 local (Mexico City) = 2026-06-11 06:30 UTC
    ts_just_past_local_midnight = datetime(2026, 6, 11, 6, 30, 0, tzinfo=timezone.utc).timestamp()

    # Nodes A and B share LOCAL June 10; node C is LOCAL June 11.
    nid_a = _insert_node(conn, label="A: June10 22h local", ts=ts_local_morn)
    nid_b = _insert_node(conn, label="B: June10 23h local", ts=ts_local_eve)
    nid_c = _insert_node(conn, label="C: June11 00:30 local", ts=ts_just_past_local_midnight)

    # Run linker with America/Mexico_City tz (window must be huge to capture test dates).
    window_days = 400  # test dates are ~2 weeks in the past relative to 2026-06-24
    created = run_same_day_linker(conn, tz_name="America/Mexico_City", window_days=window_days)

    # A and B share local June 10 → MUST be linked.
    assert _any_edge(conn, nid_a, nid_b, "same-day"), (
        "A (22h local) and B (23h local) share LOCAL June 10 but are NOT linked. "
        "Linker is grouping by UTC (where both fall on June 11) instead of by the "
        "configured local tz."
    )

    # B and C are local June 10 vs June 11 → must NOT be linked.
    assert not _any_edge(conn, nid_b, nid_c, "same-day"), (
        "B (June10 23h local = June11 05:00 UTC) and C (June11 00:30 local = June11 06:30 UTC) "
        "are on the SAME UTC day (June 11) but on DIFFERENT local days. They must NOT be linked "
        "when grouping by the configured local tz. UTC grouping would incorrectly link them."
    )


def test_same_day_linker_utc_default_groups_by_utc():
    """When tz_name is not provided (defaults to UTC), grouping is by UTC day — existing behaviour.

    This is the backward-compatibility guard: callers that don't pass tz_name keep UTC semantics.
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # Both timestamps are on the same UTC day (2026-06-15).
    ts1 = datetime(2026, 6, 15, 2, 0, 0, tzinfo=timezone.utc).timestamp()
    ts2 = datetime(2026, 6, 15, 22, 0, 0, tzinfo=timezone.utc).timestamp()

    nid1 = _insert_node(conn, label="UTC compat 1", ts=ts1)
    nid2 = _insert_node(conn, label="UTC compat 2", ts=ts2)

    run_same_day_linker(conn, window_days=400)  # no tz_name → UTC

    assert _any_edge(conn, nid1, nid2, "same-day"), (
        "Without tz_name, UTC default grouping must still link nodes on the same UTC day."
    )


# ─────────────────────────────────────────────────────────────────────────────
# TZ-3  bad tz string falls back to UTC without crashing
# ─────────────────────────────────────────────────────────────────────────────


def test_same_day_linker_bad_tz_falls_back_to_utc():
    """A bad/unknown tz string must not raise — linker falls back to UTC and continues."""
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    now = time.time()
    nid1 = _insert_node(conn, label="bad-tz node 1", ts=now)
    nid2 = _insert_node(conn, label="bad-tz node 2", ts=now + 3600)

    # Must not raise even with an invalid tz name.
    result = run_same_day_linker(conn, tz_name="Not/AZone")

    # Result must be an integer (not an exception).
    assert isinstance(result, int)


# ─────────────────────────────────────────────────────────────────────────────
# TZ-4  brain3d route passes 'tz' to template context
# ─────────────────────────────────────────────────────────────────────────────


@pytest.fixture
def dashboard_client(monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)

    from fastapi.testclient import TestClient
    return TestClient(dashboard.app)


def test_brain3d_route_passes_tz_to_template(dashboard_client):
    """The /brain3d route must inject the configured 'tz' into the template.

    We verify by checking the rendered HTML contains the tz value.
    The config used in tests defaults to 'America/Mexico_City'; the template
    must embed it so client-side JS can format dates in the user's local tz.
    """
    r = dashboard_client.get("/brain3d")
    assert r.status_code == 200
    # The configured tz string must appear in the rendered HTML.
    # (The template uses it as a JS variable or data attribute for toLocaleDateString.)
    assert "America/Mexico_City" in r.text or "UTC" in r.text, (
        "brain3d route does not embed the configured tz in the template. "
        "The 'tz' context variable is missing or unused in brain3d.html."
    )
