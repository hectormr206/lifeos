"""Tests for Slice 1: domain_bridge.py module and store.py additions.

TDD order: RED tests written first, GREEN follows after implementation.

Phases covered:
  1.1 — store.py: node_limit guard on backfill_similar_to_edges
  1.2 — store.py: upsert_domain_node_map + get_node_for_domain_entry (already exist; regression only)
  1.3 — domain_bridge.py: DomainConfig skeleton + health renderer
  1.4 — domain_bridge.py: create_fact_node_for_entry + idempotency
  1.5 — domain_bridge.py: bridge_entry (best-effort wrapper)
  1.6 — domain_bridge.py: create_fact_node_for_interaction shim
  1.7 — dashboard.py + mcp_tools.py: health call sites wired (integration)
  1.9 — same-day linker integration with health + meeting nodes
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import patch, MagicMock

import pytest


# ─── helpers ────────────────────────────────────────────────────────────────


def _insert_fact_node(conn, *, label: str = "test", domain: str = "health") -> int:
    """Insert a bare fact node directly; return its id."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("fact", label, "{}", domain, now, now),
    )
    conn.commit()
    return cur.lastrowid


def _insert_embedded_node(conn, *, label: str = "test", domain: str = "health") -> int:
    """Insert a fact node with a synthetic embedding blob into nodes + vec_nodes."""
    import struct

    now = time.time()
    dim = 512
    blob = struct.pack(f"{dim}f", *([0.1] * dim))
    cur = conn.execute(
        "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, "
        "embedding, embedding_model, embedding_dim) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("fact", label, "{}", domain, now, now, blob, "test", dim),
    )
    conn.commit()
    nid = cur.lastrowid
    conn.execute(
        "INSERT OR REPLACE INTO vec_nodes(node_id, embedding) VALUES (?, ?)",
        (nid, blob),
    )
    conn.commit()
    return nid


@dataclass
class HealthEntryStub:
    """Minimal duck-typed health entry for testing renderers / bridge."""
    id: str = "he-001"
    kind: str = "vital"
    raw_utterance: str | None = None
    title: str | None = None


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.1 — store.py: node_limit guard on backfill_similar_to_edges
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_similar_to_edges_node_limit_caps_processing():
    """1.1.1 RED — node_limit=2 with 5 embedded nodes processes at most 2 nodes."""
    import axi.store as store

    conn = store._connect()

    # Insert 5 embedded nodes.
    for i in range(5):
        _insert_embedded_node(conn, label=f"node {i}", domain="health")

    call_count = {"n": 0}

    def _fake_check(nid, c, *, threshold=0.85):
        call_count["n"] += 1
        return 0

    with patch("axi.store.check_and_create_similar_to_edges", side_effect=_fake_check):
        store.backfill_similar_to_edges(node_limit=2)

    assert call_count["n"] == 2, (
        f"Expected 2 nodes processed with node_limit=2, got {call_count['n']}"
    )


def test_backfill_similar_to_edges_no_limit_processes_all():
    """1.1.3 RED — no node_limit processes all embedded nodes."""
    import axi.store as store

    conn = store._connect()

    for i in range(4):
        _insert_embedded_node(conn, label=f"all-node {i}", domain="health")

    call_count = {"n": 0}

    def _fake_check(nid, c, *, threshold=0.85):
        call_count["n"] += 1
        return 0

    with patch("axi.store.check_and_create_similar_to_edges", side_effect=_fake_check):
        store.backfill_similar_to_edges()  # no limit

    assert call_count["n"] == 4, (
        f"Expected all 4 nodes processed when no limit set, got {call_count['n']}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.3 — domain_bridge.py: health renderer
# ═══════════════════════════════════════════════════════════════════════════


def test_health_renderer_prefers_title():
    """TITLE-FIRST: the normalized title ("presión 110/81, pulso 51") is a far
    better recall label than the keyword-poor raw utterance ("110 81 51 pulsos"),
    which the brain could not interpret (and fabricated around)."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance="110 81 51 pulsos", title="presión 110/81, pulso 51")
    result = _health_renderer(entry)
    assert result == "presión 110/81, pulso 51"


def test_health_renderer_falls_back_to_raw_when_no_title():
    """No title → fall back to the raw utterance (free-form notes)."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance="me duele la cabeza", title=None)
    result = _health_renderer(entry)
    assert result == "me duele la cabeza"


def test_health_renderer_falls_back_to_title():
    """1.3.1 RED — no raw_utterance but title present → returns title."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance=None, title="poor sleep")
    result = _health_renderer(entry)
    assert result == "poor sleep"


def test_health_renderer_fallback_structured():
    """1.3.1 RED — neither raw_utterance nor title → returns non-empty structured string."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance=None, title=None, kind="vital")
    result = _health_renderer(entry)
    assert isinstance(result, str)
    assert len(result) > 0
    assert "health" in result.lower() or "vital" in result.lower()


def test_health_renderer_truncates_to_120():
    """1.3.1 triangulation — raw_utterance > 120 chars is truncated."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance="x" * 200)
    result = _health_renderer(entry)
    assert len(result) <= 120


# ─── FIX 5: whitespace-only label guards ────────────────────────────────────


def test_health_renderer_whitespace_only_raw_utterance_falls_back():
    """FIX 5 — whitespace-only raw_utterance must NOT produce a whitespace label."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance="   ", title="real title")
    result = _health_renderer(entry)
    assert result.strip() != "", "Renderer must not return whitespace-only label"
    assert result == "real title", f"Expected fallback to title, got {result!r}"


def test_health_renderer_whitespace_only_title_falls_back_to_structured():
    """FIX 5 — whitespace-only title falls back to structured string."""
    from axi.domain_bridge import _health_renderer

    entry = HealthEntryStub(raw_utterance=None, title="  \t  ", kind="vital")
    result = _health_renderer(entry)
    assert result.strip() != "", "Renderer must not return whitespace-only label"
    assert "vital" in result or "health" in result, f"Expected structured fallback, got {result!r}"


def test_relationships_renderer_whitespace_only_falls_back():
    """FIX 5 — whitespace-only raw_utterance in relationships renderer falls back."""
    from axi.domain_bridge import _relationships_renderer

    @dataclass
    class RelEntry:
        id: str = "r-001"
        raw_utterance: str | None = "   "
        title: str | None = "Met Alice"
        kind: str = "note"

    result = _relationships_renderer(RelEntry())
    assert result.strip() != "", "Renderer must not return whitespace-only label"
    assert result == "Met Alice", f"Expected fallback to title, got {result!r}"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.4 — domain_bridge.py: create_fact_node_for_entry + idempotency
# ═══════════════════════════════════════════════════════════════════════════


def test_create_fact_node_for_entry_creates_node_and_map():
    """1.4.1 RED — creates exactly one node in nodes + one row in domain_node_map."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    entry = HealthEntryStub(id="he-create-001", raw_utterance="presión 114/83, pulso 55")

    nid = create_fact_node_for_entry("health", entry)

    conn = store._connect()

    node = conn.execute("SELECT * FROM nodes WHERE id = ?", (nid,)).fetchone()
    assert node is not None, "Node not found in nodes table"
    assert node["kind"] == "fact"
    assert node["domain"] == "health"
    assert "presión" in node["label"]

    map_row = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='health' AND entry_id=?",
        (entry.id,),
    ).fetchone()
    assert map_row is not None, "domain_node_map row not found"
    assert int(map_row["node_id"]) == nid


def test_create_fact_node_for_entry_idempotent():
    """1.4.1 RED — second call returns same node_id, no new rows."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    entry = HealthEntryStub(id="he-idem-001", raw_utterance="glucosa 110 mg/dL")

    nid1 = create_fact_node_for_entry("health", entry)
    nid2 = create_fact_node_for_entry("health", entry)

    assert nid1 == nid2, "Second call must return same node_id"

    conn = store._connect()
    count = conn.execute(
        "SELECT COUNT(*) FROM domain_node_map WHERE domain='health' AND entry_id=?",
        (entry.id,),
    ).fetchone()[0]
    assert count == 1, f"Expected exactly 1 domain_node_map row, found {count}"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.5 — domain_bridge.py: bridge_entry (best-effort wrapper)
# ═══════════════════════════════════════════════════════════════════════════


def test_bridge_entry_returns_int_node_id():
    """1.5.1 RED — bridge_entry returns an int."""
    from axi.domain_bridge import bridge_entry

    entry = HealthEntryStub(id="he-bridge-001", raw_utterance="presión 120/80")
    result = bridge_entry("health", entry)
    assert isinstance(result, int)
    assert result > 0


def test_bridge_entry_swallows_exceptions():
    """1.5.1 RED — exception during create → returns None, no propagation."""
    from axi.domain_bridge import bridge_entry

    # Entry with no .id attribute will cause an error in the inner call.
    class BadEntry:
        raw_utterance = "test"
        title = "test"
        kind = "vital"
        # intentionally no .id

    result = bridge_entry("health", BadEntry())
    assert result is None, "bridge_entry must return None when an exception occurs"


def test_bridge_entry_embedding_is_null_after_create():
    """1.5.1 RED — node is created with embedding IS NULL (async embed)."""
    import axi.store as store
    from axi.domain_bridge import bridge_entry

    entry = HealthEntryStub(id="he-embed-001", raw_utterance="pulso 55")
    nid = bridge_entry("health", entry)
    assert nid is not None

    conn = store._connect()
    row = conn.execute("SELECT embedding FROM nodes WHERE id = ?", (nid,)).fetchone()
    assert row is not None
    # Embedding is async — immediately after create it must be NULL.
    assert row[0] is None, "Embedding should be NULL immediately after bridge_entry (async)"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.6 — domain_bridge.py: create_fact_node_for_interaction shim
# ═══════════════════════════════════════════════════════════════════════════


def test_create_fact_node_for_interaction_shim():
    """1.6.1 RED — shim calls through to create_fact_node_for_entry('relationships', ...)."""
    from axi.domain_bridge import create_fact_node_for_interaction, create_fact_node_for_entry

    @dataclass
    class InteractionStub:
        id: str = "rel-001"
        raw_utterance: str | None = "Met with Alice"
        title: str | None = None
        kind: str = "note"

    stub = InteractionStub()

    with patch("axi.domain_bridge.create_fact_node_for_entry", return_value=42) as mock_fn:
        result = create_fact_node_for_interaction(stub)

    mock_fn.assert_called_once_with("relationships", stub)
    assert result == 42


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.9 — same-day linker integration with health + meeting nodes
# ═══════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1.7 — Health API call site wiring integration test
# ═══════════════════════════════════════════════════════════════════════════


def test_health_api_post_creates_domain_node_map_row(monkeypatch):
    """1.7.1 RED — POST /api/health/entries results in a domain_node_map row."""
    import axi.store as store
    from fastapi.testclient import TestClient

    # Isolate health DB.
    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "health.db")
        key_path = os.path.join(td, "health.key")
        monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", key_path)
        from lifeos.health import store as hs
        hs.apply_migrations()

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

        client = TestClient(dashboard.app)
        from datetime import datetime, timezone
        now_iso = datetime.now(timezone.utc).isoformat()
        resp = client.post(
            "/api/health/entries",
            json={"kind": "vital", "title": "presión 114/83, pulso 55", "ts": now_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='health'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for health after POST, got {len(rows)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# FIX 4 — Health chat-site integration: parse_health fast-path
# ═══════════════════════════════════════════════════════════════════════════


def test_chat_health_fast_path_creates_domain_node_map_row(monkeypatch):
    """FIX 4 — POST /api/chat/ask with a parseable health phrase creates domain_node_map row.

    Drives the health ingestion fast-path in api_chat_ask (dashboard.py:3594
    bridge_entry call) through the real bridge.  Uses 'glucosa 110 mg/dL'
    which parse_health detects as a vital without a GPU/brain.
    """
    import axi.store as store
    from fastapi.testclient import TestClient

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "health.db")
        key_path = os.path.join(td, "health.key")
        monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", key_path)
        from lifeos.health import store as hs
        hs.apply_migrations()

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

        client = TestClient(dashboard.app)
        resp = client.post(
            "/api/chat/ask",
            json={
                "text": "glucosa 110 mg/dL",
                "logging_mode": False,
                "speak": False,
            },
        )
        # The chat endpoint returns 200 with an answer dict on the fast-path.
        assert resp.status_code == 200, (
            f"Expected 200 from chat ask, got {resp.status_code}: {resp.text}"
        )

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='health'"
        ).fetchall()
        assert len(rows) >= 1, (
            f"Expected at least 1 domain_node_map row for health after chat ask, got {len(rows)}\n"
            f"Response: {resp.json()}"
        )


def test_same_day_linker_connects_health_and_meeting_nodes():
    """1.9.1 RED — health fact node and meeting fact node on same day get linked."""
    import axi.store as store
    from axi.linkers import run_same_day_linker

    import sqlcipher3
    c = store._connect()
    c.row_factory = sqlcipher3.Row

    # Insert a health fact node for "today" (recent).
    now = time.time()
    health_nid = _insert_fact_node(c, label="slept 6h - poor quality", domain="health")
    # Insert a meeting fact node for the same day.
    meeting_nid = _insert_fact_node(c, label="team standup", domain="meetings")

    # Run the same-day linker (window covers today).
    edges_created = run_same_day_linker(c, window_days=1)

    # Check there is an edge between the two nodes.
    edge = c.execute(
        "SELECT 1 FROM edges WHERE "
        "((from_id=? AND to_id=?) OR (from_id=? AND to_id=?)) "
        "AND kind='same-day'",
        (health_nid, meeting_nid, meeting_nid, health_nid),
    ).fetchone()
    assert edge is not None, (
        "Expected a same-day edge between health node and meeting node; "
        f"edges_created={edges_created}"
    )


# ─── Slice 3: backfill fetch-limit regression guard ─────────────────────────


def test_fetch_domain_entries_uses_generous_limit_for_relationships():
    """3.backfill — _fetch_domain_entries must pass limit=_BACKFILL_FETCH_LIMIT
    (10_000) to list_recent, not silently rely on the store default (300).

    RED: fails when _fetch_domain_entries is called without an explicit limit.
    GREEN: passes once backfill_all_domains passes limit=_BACKFILL_FETCH_LIMIT.
    """
    from unittest.mock import patch, call
    from axi.domain_bridge import _fetch_domain_entries, _BACKFILL_FETCH_LIMIT

    captured_calls: list = []

    def _fake_list_recent(**kwargs):
        captured_calls.append(kwargs)
        return []

    with patch("lifeos.relationships.interactions.list_recent", _fake_list_recent):
        _fetch_domain_entries("relationships", days=90, limit=_BACKFILL_FETCH_LIMIT)

    assert captured_calls, "_fetch_domain_entries did not call list_recent at all"
    actual_limit = captured_calls[0].get("limit")
    assert actual_limit == _BACKFILL_FETCH_LIMIT, (
        f"list_recent was called with limit={actual_limit!r}, "
        f"expected {_BACKFILL_FETCH_LIMIT} (_BACKFILL_FETCH_LIMIT). "
        "backfill_all_domains must pass an explicit generous limit so historical "
        "entries beyond the store default (300) are candidates for bridging."
    )


def test_backfill_all_domains_fetches_with_generous_limit():
    """3.backfill — backfill_all_domains must pass _BACKFILL_FETCH_LIMIT to
    _fetch_domain_entries so the fetch pool is not silently capped at 300.

    RED: fails when backfill_all_domains calls _fetch_domain_entries without
    an explicit limit argument.
    GREEN: passes once the call includes limit=_BACKFILL_FETCH_LIMIT.
    """
    from unittest.mock import patch, MagicMock, call
    from axi.domain_bridge import backfill_all_domains, _BACKFILL_FETCH_LIMIT

    fetch_calls: list = []

    def _fake_fetch(domain, *, days, limit=None):
        fetch_calls.append({"domain": domain, "days": days, "limit": limit})
        return []

    with (
        patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch),
        patch("axi.store.get_node_for_domain_entry", return_value=None),
    ):
        backfill_all_domains(days=90, domains=["relationships"])

    assert fetch_calls, "backfill_all_domains did not call _fetch_domain_entries"
    actual_limit = fetch_calls[0].get("limit")
    assert actual_limit == _BACKFILL_FETCH_LIMIT, (
        f"_fetch_domain_entries was called with limit={actual_limit!r}, "
        f"expected {_BACKFILL_FETCH_LIMIT} (_BACKFILL_FETCH_LIMIT). "
        "Without an explicit generous limit the backfill silently truncates "
        "to the store default (e.g. 300) and never reaches old entries."
    )


# ═══════════════════════════════════════════════════════════════════════════
# Review-fix tests — low-value filter edge cases
# ═══════════════════════════════════════════════════════════════════════════


# ─── FIX 1: falsy-zero in has_numeric ───────────────────────────────────────

@dataclass
class FinanceEntryStub:
    """Minimal duck-typed finance entry."""
    id: str = "fe-001"
    raw_utterance: str | None = None
    title: str | None = "muestra"
    amount: float | None = None
    data: dict | None = None


@dataclass
class ExerciseEntryStub:
    """Minimal duck-typed exercise entry."""
    id: str = "ex-001"
    raw_utterance: str | None = None
    title: str | None = "correr"
    duration_minutes: int | None = None
    data: dict | None = None


class TestIsLowValueFalsyZero:
    """FIX 1 — amount=0 or duration_minutes=0 must be treated as real content."""

    def test_finance_amount_zero_is_kept(self):
        """FINANCE entry with amount=0 (free transaction), short title, no raw → NOT low-value.

        RED: fails when has_numeric uses bool(getattr(..., 'amount', None))
        because bool(0) is False, so the entry is wrongly dropped.
        GREEN: passes once the check uses `is not None`.
        """
        from axi.domain_bridge import _is_low_value

        entry = FinanceEntryStub(amount=0, title="muestra", raw_utterance=None, data=None)
        result = _is_low_value("muestra", entry)
        assert result is False, (
            "amount=0 must count as a present numeric field; entry must NOT be low-value"
        )

    def test_exercise_duration_minutes_zero_is_kept(self):
        """EXERCISE entry with duration_minutes=0, short title, no raw → NOT low-value.

        RED: fails when has_numeric uses bool(getattr(..., 'duration_minutes', None))
        because bool(0) is False, so the entry is wrongly dropped.
        GREEN: passes once the check uses `is not None`.
        """
        from axi.domain_bridge import _is_low_value

        entry = ExerciseEntryStub(duration_minutes=0, title="correr", raw_utterance=None, data=None)
        result = _is_low_value("correr", entry)
        assert result is False, (
            "duration_minutes=0 must count as a present numeric field; entry must NOT be low-value"
        )

    def test_finance_amount_zero_creates_node(self):
        """create_fact_node_for_entry returns a node_id (not None) for amount=0 entry.

        RED: drops the entry (returns None) when has_numeric uses truthiness check.
        GREEN: creates the node once `is not None` check is in place.
        """
        from unittest.mock import patch, MagicMock
        from axi import domain_bridge

        entry = FinanceEntryStub(id="fe-zero-001", amount=0, title="muestra", raw_utterance=None, data=None)

        with (
            patch("axi.store.get_node_for_domain_entry", return_value=None),
            patch("axi.store.add_node", return_value=42) as mock_add,
            patch("axi.store.upsert_domain_node_map"),
            patch("axi.store.trigger_embed_for_node"),
        ):
            node_id = domain_bridge.create_fact_node_for_entry("finance", entry)

        assert node_id is not None, (
            "create_fact_node_for_entry must create a node for a finance entry with amount=0"
        )


# ─── FIX 2: backfill counter only counts real creations ─────────────────────

class TestBackfillCounterSkipsLowValue:
    """FIX 2 — low-value skips (None return) must NOT increment backfill counters."""

    def test_low_value_skip_does_not_consume_node_limit_budget(self):
        """Backfill with 1 real entry + 1 low-value entry and node_limit=1 →
        the real entry is created and counts as 1; the low-value does not burn the budget.

        RED: fails when the counter increments unconditionally (create_fact_node_for_entry
        returns None for the low-value entry, but result[domain] and total_created are
        still incremented, exhausting the budget before the real entry is processed).
        GREEN: passes once the counter only increments when the return value is not None.
        """
        from unittest.mock import patch, MagicMock
        from types import SimpleNamespace
        from axi.domain_bridge import backfill_all_domains

        low_value_entry = SimpleNamespace(id="lv-001", title="muestra", raw_utterance=None, data=None, amount=None, duration_minutes=None, duration=None)
        real_entry = SimpleNamespace(id="real-001", title="presión 120/80", raw_utterance="presión 120/80", data=None, amount=None, duration_minutes=None, duration=None)

        def _fake_fetch(domain, *, days, limit=None):
            return [low_value_entry, real_entry]

        created_ids: list[str] = []

        def _fake_create(domain, entry):
            if entry.id == "lv-001":
                return None  # low-value skip
            created_ids.append(entry.id)
            return 99

        with (
            patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch),
            patch("axi.store.get_node_for_domain_entry", return_value=None),
            patch("axi.domain_bridge.create_fact_node_for_entry", side_effect=_fake_create),
            patch("axi.store.checkpoint"),
        ):
            result = backfill_all_domains(days=90, domains=["health"], node_limit=1)

        assert result["health"] == 1, (
            f"result['health'] should be 1 (only the real entry), got {result['health']}"
        )
        assert "real-001" in created_ids, "The real entry must have been processed"


# ─── FIX 3: has_data should consider `body` ─────────────────────────────────

@dataclass
class RelationshipsEntryStub:
    """Minimal duck-typed relationships interaction entry."""
    id: str = "ri-001"
    raw_utterance: str | None = None
    title: str | None = "charla"
    body: str | None = None
    data: dict | None = None


class TestIsLowValueBodyContent:
    """FIX 3 — non-empty body must count as real content and prevent low-value drop."""

    def test_short_title_no_raw_no_data_but_body_is_kept(self):
        """Relationships entry with short title, no raw_utterance, no data, but
        non-empty body → NOT low-value.

        RED: fails when _is_low_value ignores entry.body.
        GREEN: passes once body is included in the 'has content' check.
        """
        from axi.domain_bridge import _is_low_value

        entry = RelationshipsEntryStub(
            title="charla",
            raw_utterance=None,
            data=None,
            body="Spoke about the project status and next steps.",
        )
        result = _is_low_value("charla", entry)
        assert result is False, (
            "Entry with non-empty body must NOT be low-value even with a short single-word title"
        )

    def test_empty_body_still_low_value(self):
        """Entry with short title, no raw, no data, and empty body → still low-value."""
        from axi.domain_bridge import _is_low_value

        entry = RelationshipsEntryStub(
            title="charla",
            raw_utterance=None,
            data=None,
            body="",
        )
        result = _is_low_value("charla", entry)
        assert result is True, (
            "Entry with empty body and no other content must still be low-value"
        )

    def test_none_body_still_low_value(self):
        """Entry with short title, no raw, no data, body=None → still low-value."""
        from axi.domain_bridge import _is_low_value

        entry = RelationshipsEntryStub(
            title="charla",
            raw_utterance=None,
            data=None,
            body=None,
        )
        result = _is_low_value("charla", entry)
        assert result is True, (
            "Entry with body=None and no other content must still be low-value"
        )
