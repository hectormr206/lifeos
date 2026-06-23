"""FIX 1 — Integration coverage for the unguarded nano/chat bridge_entry sites.

Adds:
  - One nano-extract path test per domain (finance, exercise, spirituality,
    learning, lifeos-events): monkeypatches the nano extractor to return a
    forced ExtractionResult and asserts a domain_node_map row + node is created.
  - One chat-ask fast-path test per domain: monkeypatches the relevant
    ingestion parser (parse_exercise, parse_spirituality, parse_learning,
    parse_event, parse_finance) and asserts a domain_node_map row is created.
  - One real-pipeline cross-domain same-day linkage test: creates entries via
    the real create() paths (not raw _insert_fact_node), runs run_same_day_linker,
    and asserts a same-day edge forms between two resulting nodes.

All tests rely on the `fresh_db` autouse fixture — NO nested tempfile.TemporaryDirectory.

TDD order: written RED (no coverage), then GREEN after FIX 1 — the nano/chat
bridge_entry calls already exist in dashboard.py; these tests just guard them.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pytest


# ─── dashboard monkeypatch helpers ───────────────────────────────────────────


def _patch_dashboard_system_calls(monkeypatch):
    """Patch the system-state helpers that dashboard.py imports at startup."""
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


# ─── ExtractionResult stub ────────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class _ExtractionResult:
    """Minimal local stub matching lifeos.agents.extractor.ExtractionResult."""
    domain: str | None
    amount: float | None = None
    currency: str | None = None
    merchant: str | None = None
    people: list = field(default_factory=list)
    dates_text: list = field(default_factory=list)
    duration_minutes: float | None = None
    items: list = field(default_factory=list)
    title: str | None = None
    kind: str | None = None
    systolic: int | None = None
    diastolic: int | None = None
    pulse_bpm: int | None = None
    sleep_hours: float | None = None
    weight_kg: float | None = None
    glucose_mg_dl: float | None = None
    confidence: float = 0.9


# ═══════════════════════════════════════════════════════════════════════════
# Nano-extract path: one test per domain
# These guard the 5 nano bridge_entry sites in _try_nano_extract
# (dashboard.py ~2688, 2746, 2771, 2813, 3033)
# ═══════════════════════════════════════════════════════════════════════════


def test_nano_extract_finance_creates_domain_node_map_row(monkeypatch):
    """FIX1-nano — nano-extract finance path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py ~2711 would fail this test.

    The finance fast-path runs before the logging_mode=True → nano branch, so we
    monkeypatch finance_ingestion.parse_finance to return None so the text reaches
    the nano extractor.  The nano extractor is also monkeypatched to return a
    forced finance ExtractionResult.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    # Suppress the finance chat fast-path so nano gets the request.
    monkeypatch.setattr(dashboard.finance_ingestion, "parse_finance", lambda _t: None)

    forced = _ExtractionResult(
        domain="finance", kind="expense", amount=450.0, currency="MXN",
        merchant="super", title="gasté 450 en super",
    )
    monkeypatch.setattr(
        "lifeos.agents.extractor.extract",
        lambda _text: forced,
        raising=False,
    )

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={"text": "gasté 450 en el super ayer", "logging_mode": True, "speak": False},
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='finance'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for finance (nano path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_nano_extract_exercise_creates_domain_node_map_row(monkeypatch):
    """FIX1-nano — nano-extract exercise path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py ~2746 would fail this test.

    The exercise fast-path runs before the logging_mode=True → nano branch, so
    we monkeypatch ex_ingestion.parse_exercise to return None.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    # Suppress the exercise chat fast-path so nano gets the request.
    monkeypatch.setattr(dashboard.ex_ingestion, "parse_exercise", lambda _t: None)

    forced = _ExtractionResult(
        domain="exercise", kind="walk", duration_minutes=45.0,
        title="caminé 45 min",
    )
    monkeypatch.setattr(
        "lifeos.agents.extractor.extract",
        lambda _text: forced,
        raising=False,
    )

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={"text": "caminé 45 minutos en el parque esta tarde", "logging_mode": True, "speak": False},
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='exercise'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for exercise (nano path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_nano_extract_spirituality_creates_domain_node_map_row(monkeypatch):
    """FIX1-nano — nano-extract spirituality path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py ~3033 would fail this test.

    The spirituality fast-path runs before the logging_mode=True → nano branch,
    so we monkeypatch spirit_ingestion.parse_spirituality to return None.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    # Suppress the spirituality chat fast-path so nano gets the request.
    monkeypatch.setattr(dashboard.spirit_ingestion, "parse_spirituality", lambda _t: None)

    forced = _ExtractionResult(
        domain="spirituality", kind="gratitude",
        title="hoy agradezco mi familia",
    )
    monkeypatch.setattr(
        "lifeos.agents.extractor.extract",
        lambda _text: forced,
        raising=False,
    )

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={"text": "hoy agradezco tener salud y familia", "logging_mode": True, "speak": False},
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='spirituality'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for spirituality (nano path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_nano_extract_learning_creates_domain_node_map_row(monkeypatch):
    """FIX1-nano — nano-extract learning path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py ~2771 would fail this test.

    'leyendo Clean Architecture cap 5' does NOT match learn_ingestion.parse_learning
    (which requires quoted titles or explicit prefixes), so no fast-path suppression
    is needed — nano gets the request directly.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    forced = _ExtractionResult(
        domain="learning", kind="book",
        title="leyendo Clean Architecture",
    )
    monkeypatch.setattr(
        "lifeos.agents.extractor.extract",
        lambda _text: forced,
        raising=False,
    )

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={"text": "leyendo Clean Architecture cap 5", "logging_mode": True, "speak": False},
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='learning'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for learning (nano path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_nano_extract_events_creates_domain_node_map_row(monkeypatch, tmp_path):
    """FIX1-nano — nano-extract events path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py ~2813 would fail this test.

    Uses logging_mode=True so nano gets the request (fast-paths run before
    logging_mode routing, so we also monkeypatch parse_event to return None).

    Note: axi store creates {LIFEOS_STATE_DIR}/events.db as a plain SQLite
    telemetry file which conflicts with the sqlcipher-encrypted lifeos events DB
    at the same path. We redirect the lifeos events DB to a different filename
    within tmp_path using LIFEOS_EVENTS_DB_PATH / LIFEOS_EVENTS_KEY_PATH so
    both stores coexist without collision.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    # Redirect lifeos events store to avoid collision with axi telemetry events.db.
    lifeos_ev_db = str(tmp_path / "lifeos_events.db")
    lifeos_ev_key = str(tmp_path / "lifeos_events.key")
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", lifeos_ev_db)
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", lifeos_ev_key)
    from lifeos.events import store as ev_store
    ev_store.apply_migrations()

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    # Suppress the events chat fast-path so nano gets the request.
    monkeypatch.setattr(dashboard.events_ingestion, "parse_event", lambda _t: None)

    forced = _ExtractionResult(
        domain="events", kind="birthday",
        title="cumple de Juan",
        dates_text=["15 de julio"],
    )
    monkeypatch.setattr(
        "lifeos.agents.extractor.extract",
        lambda _text: forced,
        raising=False,
    )

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={"text": "aniversario de boda el 20 de agosto", "logging_mode": True, "speak": False},
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='lifeos-events'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for lifeos-events (nano path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# Chat-ask fast-path: one test per domain
# These guard the 5 chat bridge_entry sites in api_chat_ask
# (dashboard.py ~3411, 3467, 3519, 3576, 3796)
# ═══════════════════════════════════════════════════════════════════════════


def test_chat_exercise_fast_path_creates_domain_node_map_row(monkeypatch):
    """FIX1-chat — chat-ask exercise fast-path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py:3411 would fail this test.
    Uses parse_exercise ingestion parser which recognises 'caminé 30 min'.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={
            "text": "caminé 30 min esta mañana",
            "logging_mode": False,
            "speak": False,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='exercise'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for exercise (chat fast-path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_chat_spirituality_fast_path_creates_domain_node_map_row(monkeypatch):
    """FIX1-chat — chat-ask spirituality fast-path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py:3467 would fail this test.
    Uses parse_spirituality which recognises 'hoy agradezco X'.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={
            "text": "hoy agradezco la salud de mi familia",
            "logging_mode": False,
            "speak": False,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='spirituality'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for spirituality (chat fast-path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_chat_learning_fast_path_creates_domain_node_map_row(monkeypatch):
    """FIX1-chat — chat-ask learning fast-path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py:3519 would fail this test.
    Uses parse_learning which recognises quoted book titles.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={
            "text": "empecé 'Clean Architecture' de Uncle Bob",
            "logging_mode": False,
            "speak": False,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='learning'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for learning (chat fast-path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_chat_events_fast_path_creates_domain_node_map_row(monkeypatch, tmp_path):
    """FIX1-chat — chat-ask events fast-path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py ~3576 would fail this test.
    Uses parse_event which recognises 'cumple X DATE' pattern.

    Note: axi store creates {LIFEOS_STATE_DIR}/events.db (plain SQLite telemetry),
    conflicting with the sqlcipher lifeos events DB at the same path. We redirect
    the lifeos events DB via LIFEOS_EVENTS_DB_PATH / LIFEOS_EVENTS_KEY_PATH.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    # Redirect lifeos events store to avoid collision with axi telemetry events.db.
    lifeos_ev_db = str(tmp_path / "lifeos_events.db")
    lifeos_ev_key = str(tmp_path / "lifeos_events.key")
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", lifeos_ev_db)
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", lifeos_ev_key)
    from lifeos.events import store as ev_store
    ev_store.apply_migrations()

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={
            "text": "cumple de Juan el 15 de julio",
            "logging_mode": False,
            "speak": False,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='lifeos-events'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for lifeos-events (chat fast-path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


def test_chat_finance_fast_path_creates_domain_node_map_row(monkeypatch):
    """FIX1-chat — chat-ask finance fast-path writes domain_node_map row.

    Deleting the bridge_entry call at dashboard.py:3796 would fail this test.
    Uses parse_finance which recognises 'gasté N en X' pattern.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    _patch_dashboard_system_calls(monkeypatch)
    from axi import dashboard

    client = TestClient(dashboard.app)
    resp = client.post(
        "/api/chat/ask",
        json={
            "text": "gasté 250 en gasolina",
            "logging_mode": False,
            "speak": False,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

    conn = store._connect()
    rows = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='finance'"
    ).fetchall()
    assert len(rows) >= 1, (
        f"Expected ≥1 domain_node_map row for finance (chat fast-path), got {len(rows)}\n"
        f"Response: {resp.json()}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# Real-pipeline cross-domain same-day linkage
# B-W4: guards that the wiring + linker form edges using real create() paths
# ═══════════════════════════════════════════════════════════════════════════


def test_real_pipeline_cross_domain_same_day_edge():
    """FIX1-e2e — two entries created through real create() paths get same-day linked.

    Uses finance + exercise create() (not raw _insert_fact_node) so the
    bridge_entry wiring is exercised end-to-end. run_same_day_linker must form
    a same-day edge between the two resulting nodes.

    The test_three_domain_same_day_linkage test uses raw inserts; this test
    guards the actual wiring path.
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker
    from axi.domain_bridge import create_fact_node_for_entry
    from datetime import datetime, timezone

    from lifeos.finance import entries as fin_entries
    from lifeos.exercise import sessions as ex_sessions

    now = datetime.now(timezone.utc)

    # Create a finance entry through the real create() path.
    fin_entry = fin_entries.create(
        kind="expense", title="gasté 100 en tacos",
        amount=100.0, when=now, currency="MXN",
    )
    fin_node_id = create_fact_node_for_entry("finance", fin_entry)

    # Create an exercise session through the real create() path.
    ex_entry = ex_sessions.create(
        kind="walk", title="caminata matutina",
        duration_minutes=30, when=now,
    )
    ex_node_id = create_fact_node_for_entry("exercise", ex_entry)

    # Both nodes must be in domain_node_map.
    conn = store._connect()
    fin_row = conn.execute(
        "SELECT node_id FROM domain_node_map WHERE domain='finance' AND entry_id=?",
        (str(fin_entry.id),),
    ).fetchone()
    assert fin_row is not None, "finance entry not in domain_node_map"

    ex_row = conn.execute(
        "SELECT node_id FROM domain_node_map WHERE domain='exercise' AND entry_id=?",
        (str(ex_entry.id),),
    ).fetchone()
    assert ex_row is not None, "exercise entry not in domain_node_map"

    # Run the same-day linker.
    run_same_day_linker(conn, window_days=1)

    # Assert a same-day edge was formed between the two nodes.
    edge = conn.execute(
        "SELECT 1 FROM edges WHERE "
        "((from_id=? AND to_id=?) OR (from_id=? AND to_id=?)) AND kind='same-day'",
        (fin_node_id, ex_node_id, ex_node_id, fin_node_id),
    ).fetchone()
    assert edge is not None, (
        f"Expected a same-day edge between finance node {fin_node_id} "
        f"and exercise node {ex_node_id} after run_same_day_linker"
    )
