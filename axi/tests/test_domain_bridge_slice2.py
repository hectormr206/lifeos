"""Tests for Slice 2: fan-out to finance, exercise, spirituality, learning, events.

TDD order: RED tests written first, GREEN follows after implementation.

Phases covered:
  2.1 — domain_bridge.py: renderers for all 5 remaining domains
  2.2 — dashboard.py + mcp_tools.py: finance call sites wired
  2.3 — dashboard.py: exercise call sites wired
  2.4 — dashboard.py: spirituality call sites wired
  2.5 — dashboard.py: learning call sites wired
  2.6 — dashboard.py: events call sites wired (title-only renderer)
  2.7 — cross-domain same-day linkage sanity (3 domains)
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import patch

import pytest
import uuid as _uuid


# ─── stub helpers ────────────────────────────────────────────────────────────


@dataclass
class FinanceEntryStub:
    id: str = "fin-001"
    kind: str = "expense"
    amount: float = 450.0
    currency: str = "MXN"
    merchant: str | None = "super"
    raw_utterance: str | None = None
    title: str | None = None


@dataclass
class ExerciseSessionStub:
    id: str = "ex-001"
    kind: str = "walk"
    duration_minutes: int = 45
    raw_utterance: str | None = None
    title: str | None = None


@dataclass
class SpiritualityEntryStub:
    id: str = "sp-001"
    kind: str = "gratitude"
    raw_utterance: str | None = None
    title: str | None = None


@dataclass
class LearningEntryStub:
    id: str = "le-001"
    kind: str = "book"
    raw_utterance: str | None = None
    title: str | None = None
    author: str | None = None


@dataclass
class EventEntryStub:
    id: str = "ev-001"
    kind: str = "birthday"
    title: str = "cumple de Juan"
    location: str | None = None
    raw_utterance: str | None = None


def _insert_fact_node(conn, *, label: str = "test", domain: str = "health") -> int:
    """Insert a bare fact node; return its id."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", label, "{}", domain, now, now),
    )
    conn.commit()
    return cur.lastrowid


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.1 — Renderers: finance
# ═══════════════════════════════════════════════════════════════════════════


def test_finance_renderer_uses_raw_utterance():
    """2.1.1 RED — raw_utterance present → renderer returns it."""
    from axi.domain_bridge import _finance_renderer

    entry = FinanceEntryStub(raw_utterance="gasté 450 en super", title="super")
    result = _finance_renderer(entry)
    assert result == "gasté 450 en super"


def test_finance_renderer_falls_back_to_title():
    """2.1.1 RED — no raw_utterance but title present → returns title."""
    from axi.domain_bridge import _finance_renderer

    entry = FinanceEntryStub(raw_utterance=None, title="Walmart")
    result = _finance_renderer(entry)
    assert result == "Walmart"


def test_finance_renderer_fallback_structured():
    """2.1.1 RED — neither → structured render with kind + amount + currency."""
    from axi.domain_bridge import _finance_renderer

    entry = FinanceEntryStub(raw_utterance=None, title=None,
                              kind="expense", amount=450.0, currency="MXN", merchant="super")
    result = _finance_renderer(entry)
    assert isinstance(result, str)
    assert len(result) > 0
    # Must mention finance context
    assert "finance" in result.lower() or "expense" in result.lower() or "450" in result


def test_finance_renderer_whitespace_only_falls_back():
    """2.1.1 — whitespace-only raw_utterance falls back to title."""
    from axi.domain_bridge import _finance_renderer

    entry = FinanceEntryStub(raw_utterance="   ", title="Oxxo")
    result = _finance_renderer(entry)
    assert result.strip() != ""
    assert result == "Oxxo"


def test_finance_renderer_truncates_to_120():
    """2.1.1 — long raw_utterance is truncated to 120 chars."""
    from axi.domain_bridge import _finance_renderer

    entry = FinanceEntryStub(raw_utterance="x" * 200)
    result = _finance_renderer(entry)
    assert len(result) <= 120


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.1 — Renderers: exercise
# ═══════════════════════════════════════════════════════════════════════════


def test_exercise_renderer_uses_raw_utterance():
    """2.1.1 RED — raw_utterance present → renderer returns it."""
    from axi.domain_bridge import _exercise_renderer

    entry = ExerciseSessionStub(raw_utterance="caminé 45 min", title="walk")
    result = _exercise_renderer(entry)
    assert result == "caminé 45 min"


def test_exercise_renderer_falls_back_to_title():
    """2.1.1 RED — no raw_utterance but title present → returns title."""
    from axi.domain_bridge import _exercise_renderer

    entry = ExerciseSessionStub(raw_utterance=None, title="Caminata matutina")
    result = _exercise_renderer(entry)
    assert result == "Caminata matutina"


def test_exercise_renderer_fallback_structured():
    """2.1.1 RED — neither → structured render with kind + duration."""
    from axi.domain_bridge import _exercise_renderer

    entry = ExerciseSessionStub(raw_utterance=None, title=None,
                                 kind="walk", duration_minutes=45)
    result = _exercise_renderer(entry)
    assert isinstance(result, str)
    assert len(result) > 0
    assert "exercise" in result.lower() or "walk" in result.lower() or "45" in result


def test_exercise_renderer_whitespace_only_falls_back():
    """2.1.1 — whitespace-only raw_utterance falls back to title."""
    from axi.domain_bridge import _exercise_renderer

    entry = ExerciseSessionStub(raw_utterance="  \t  ", title="Yoga")
    result = _exercise_renderer(entry)
    assert result.strip() != ""
    assert result == "Yoga"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.1 — Renderers: spirituality
# ═══════════════════════════════════════════════════════════════════════════


def test_spirituality_renderer_uses_raw_utterance():
    """2.1.1 RED — raw_utterance present → renderer returns it."""
    from axi.domain_bridge import _spirituality_renderer

    entry = SpiritualityEntryStub(raw_utterance="gratitud: amanecí con salud")
    result = _spirituality_renderer(entry)
    assert result == "gratitud: amanecí con salud"


def test_spirituality_renderer_falls_back_to_title():
    """2.1.1 RED — no raw_utterance but title present → returns title."""
    from axi.domain_bridge import _spirituality_renderer

    entry = SpiritualityEntryStub(raw_utterance=None, title="Meditación 20 min")
    result = _spirituality_renderer(entry)
    assert result == "Meditación 20 min"


def test_spirituality_renderer_fallback_structured():
    """2.1.1 RED — neither → structured render with kind."""
    from axi.domain_bridge import _spirituality_renderer

    entry = SpiritualityEntryStub(raw_utterance=None, title=None, kind="gratitude")
    result = _spirituality_renderer(entry)
    assert isinstance(result, str)
    assert len(result) > 0
    assert "spirituality" in result.lower() or "gratitude" in result.lower()


def test_spirituality_renderer_whitespace_only_falls_back():
    """2.1.1 — whitespace-only raw_utterance falls back to title."""
    from axi.domain_bridge import _spirituality_renderer

    entry = SpiritualityEntryStub(raw_utterance="   ", title="Reflexión vespertina")
    result = _spirituality_renderer(entry)
    assert result.strip() != ""
    assert result == "Reflexión vespertina"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.1 — Renderers: learning
# ═══════════════════════════════════════════════════════════════════════════


def test_learning_renderer_uses_raw_utterance():
    """2.1.1 RED — raw_utterance present → renderer returns it."""
    from axi.domain_bridge import _learning_renderer

    entry = LearningEntryStub(raw_utterance="leí: Clean Architecture cap 5")
    result = _learning_renderer(entry)
    assert result == "leí: Clean Architecture cap 5"


def test_learning_renderer_falls_back_to_title():
    """2.1.1 RED — no raw_utterance but title present → returns title."""
    from axi.domain_bridge import _learning_renderer

    entry = LearningEntryStub(raw_utterance=None, title="Clean Architecture")
    result = _learning_renderer(entry)
    assert result == "Clean Architecture"


def test_learning_renderer_fallback_structured():
    """2.1.1 RED — neither → structured render with kind."""
    from axi.domain_bridge import _learning_renderer

    entry = LearningEntryStub(raw_utterance=None, title=None, kind="book")
    result = _learning_renderer(entry)
    assert isinstance(result, str)
    assert len(result) > 0
    assert "learning" in result.lower() or "book" in result.lower()


def test_learning_renderer_whitespace_only_falls_back():
    """2.1.1 — whitespace-only raw_utterance falls back to title."""
    from axi.domain_bridge import _learning_renderer

    entry = LearningEntryStub(raw_utterance="   ", title="Diseño Atómico")
    result = _learning_renderer(entry)
    assert result.strip() != ""
    assert result == "Diseño Atómico"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.1 — Renderers: events (MUST use title, NEVER raw_utterance)
# ═══════════════════════════════════════════════════════════════════════════


def test_events_renderer_uses_title_not_raw_utterance():
    """2.1.1 RED — events renderer uses title, ignores raw_utterance entirely."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="cumple de Juan", raw_utterance="cumple juan 15 junio")
    result = _events_renderer(entry)
    # Must use title, NOT raw_utterance
    assert "cumple de Juan" in result
    assert result != "cumple juan 15 junio"


def test_events_renderer_includes_kind_and_location():
    """2.1.1 RED — events renderer appends kind + location in natural-language format."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="Aniversario", kind="anniversary", location="Casa")
    result = _events_renderer(entry)
    # Natural-language format: "Aniversario (anniversary) en Casa"
    assert result == "Aniversario (anniversary) en Casa"
    assert "Aniversario" in result
    assert "anniversary" in result
    assert "Casa" in result


def test_events_renderer_works_with_no_location():
    """2.1.1 — events renderer omits 'en {location}' when location is None."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="Graduación", kind="milestone", location=None)
    result = _events_renderer(entry)
    # Format: "Graduación (milestone)" — no trailing "en"
    assert result == "Graduación (milestone)"
    assert "en" not in result


def test_events_renderer_no_empty_parens_when_no_kind():
    """FIX3 — when kind is None, no empty parens in the output."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="Reunión familiar", kind=None, location=None)
    result = _events_renderer(entry)
    assert result == "Reunión familiar"
    assert "(" not in result


def test_events_renderer_never_none_raw_utterance():
    """2.1.1 — events renderer works even when raw_utterance is None (dropped on read)."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="Fiesta de cumple", kind="birthday",
                            location=None, raw_utterance=None)
    result = _events_renderer(entry)
    assert "Fiesta de cumple" in result


def test_events_renderer_hardened_fallback_no_title_with_kind():
    """FIX3 — absent title + present kind → 'event: {kind}', never bare 'event'."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="", kind="birthday", location=None)
    result = _events_renderer(entry)
    assert result == "event: birthday"
    assert result != "event"


def test_events_renderer_hardened_fallback_no_title_no_kind():
    """FIX3 — absent title + absent kind → 'event: other', never bare 'event'."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="", kind=None, location=None)
    result = _events_renderer(entry)
    assert result == "event: other"
    assert result != "event"


def test_events_renderer_whitespace_title_uses_hardened_fallback():
    """FIX3 — whitespace-only title triggers hardened fallback, not bare 'event'."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="   ", kind="meeting", location=None)
    result = _events_renderer(entry)
    assert result == "event: meeting"


def test_events_renderer_truncates_to_120():
    """2.1.1 — events renderer truncates output to 120 chars."""
    from axi.domain_bridge import _events_renderer

    entry = EventEntryStub(title="X" * 200, kind="birthday")
    result = _events_renderer(entry)
    assert len(result) <= 120


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.1 — All 5 domains registered in _DOMAIN_CONFIGS
# ═══════════════════════════════════════════════════════════════════════════


def test_all_slice2_domains_in_domain_configs():
    """2.1.2 RED — all 5 new domains are registered in _DOMAIN_CONFIGS."""
    from axi.domain_bridge import _DOMAIN_CONFIGS

    for domain in ("finance", "exercise", "spirituality", "learning", "lifeos-events"):
        assert domain in _DOMAIN_CONFIGS, f"Domain {domain!r} not in _DOMAIN_CONFIGS"


def test_finance_domain_config_renderer_callable():
    """2.1.2 — finance domain config has a callable renderer."""
    from axi.domain_bridge import _DOMAIN_CONFIGS

    cfg = _DOMAIN_CONFIGS["finance"]
    assert callable(cfg.renderer)
    stub = FinanceEntryStub(raw_utterance="gasté 100")
    assert isinstance(cfg.renderer(stub), str)


def test_events_domain_config_renderer_callable():
    """2.1.2 — lifeos-events domain config has a callable renderer."""
    from axi.domain_bridge import _DOMAIN_CONFIGS

    cfg = _DOMAIN_CONFIGS["lifeos-events"]
    assert callable(cfg.renderer)
    stub = EventEntryStub(title="cumple", kind="birthday")
    assert isinstance(cfg.renderer(stub), str)


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.2 — Finance: integration tests (create() sites wired)
# ═══════════════════════════════════════════════════════════════════════════


def test_finance_api_post_creates_domain_node_map_row(monkeypatch):
    """2.2.1 RED — POST /api/finance/entries → domain_node_map row created."""
    import axi.store as store
    from fastapi.testclient import TestClient

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "finance.db")
        key_path = os.path.join(td, "finance.key")
        monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", key_path)
        from lifeos.finance import store as fs
        fs.apply_migrations()

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
            "/api/finance/entries",
            json={"kind": "expense", "title": "super Walmart", "amount": 450.0, "ts": now_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='finance'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for finance after POST, got {len(rows)}"
        )


def test_finance_mcp_create_domain_node_map_row(monkeypatch):
    """2.2.6 RED — log_finance_entry in mcp_tools.py → domain_node_map row."""
    import axi.store as store

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "finance.db")
        key_path = os.path.join(td, "finance.key")
        monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", key_path)
        from lifeos.finance import store as fs
        fs.apply_migrations()

        from axi import mcp_tools
        from datetime import datetime, timezone
        now_iso = datetime.now(timezone.utc).isoformat()
        mcp_tools.log_finance_entry(
            kind="expense", title="gasolina", amount=600.0, when_iso=now_iso
        )

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='finance'"
        ).fetchall()
        assert len(rows) >= 1, (
            f"Expected at least 1 domain_node_map row for finance via mcp_tools, got {len(rows)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.3 — Exercise: integration test
# ═══════════════════════════════════════════════════════════════════════════


def test_exercise_api_post_creates_domain_node_map_row(monkeypatch):
    """2.3.1 RED — POST /api/exercise/sessions → domain_node_map row created."""
    import axi.store as store
    from fastapi.testclient import TestClient

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "exercise.db")
        key_path = os.path.join(td, "exercise.key")
        monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", key_path)
        from lifeos.exercise import store as exs
        exs.apply_migrations()

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
            "/api/exercise/sessions",
            json={"kind": "walk", "title": "caminata matutina",
                  "duration_minutes": 45, "ts": now_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='exercise'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for exercise after POST, got {len(rows)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.4 — Spirituality: integration test
# ═══════════════════════════════════════════════════════════════════════════


def test_spirituality_api_post_creates_domain_node_map_row(monkeypatch):
    """2.4.1 RED — POST /api/spirituality/entries → domain_node_map row created."""
    import axi.store as store
    from fastapi.testclient import TestClient

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "spirit.db")
        key_path = os.path.join(td, "spirit.key")
        monkeypatch.setenv("LIFEOS_SPIRITUALITY_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_SPIRITUALITY_KEY_PATH", key_path)
        from lifeos.spirituality import store as ss
        ss.apply_migrations()

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
            "/api/spirituality/entries",
            json={"kind": "gratitude", "title": "amanecí con salud", "ts": now_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='spirituality'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for spirituality after POST, got {len(rows)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.5 — Learning: integration test
# ═══════════════════════════════════════════════════════════════════════════


def test_learning_api_post_creates_domain_node_map_row(monkeypatch):
    """2.5.1 RED — POST /api/learning/entries → domain_node_map row created."""
    import axi.store as store
    from fastapi.testclient import TestClient

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "learning.db")
        key_path = os.path.join(td, "learning.key")
        monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", key_path)
        from lifeos.learning import store as ls
        ls.apply_migrations()

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
            "/api/learning/entries",
            json={"kind": "book", "title": "Clean Architecture", "ts": now_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='learning'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for learning after POST, got {len(rows)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.6 — Events: integration test (renderer uses title, never raw_utterance)
# ═══════════════════════════════════════════════════════════════════════════


def test_events_api_post_creates_domain_node_map_row(monkeypatch):
    """2.6.1 RED — POST /api/calendar → domain_node_map row created (lifeos-events domain)."""
    import axi.store as store
    from fastapi.testclient import TestClient

    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        db_path = os.path.join(td, "events.db")
        key_path = os.path.join(td, "events.key")
        monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", db_path)
        monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", key_path)
        from lifeos.events import store as evs
        evs.apply_migrations()

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
        future_iso = "2026-12-25T10:00:00+00:00"
        resp = client.post(
            "/api/calendar",
            json={"kind": "birthday", "title": "cumple de Juan", "ts": future_iso},
        )
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"

        conn = store._connect()
        rows = conn.execute(
            "SELECT * FROM domain_node_map WHERE domain='lifeos-events'"
        ).fetchall()
        assert len(rows) == 1, (
            f"Expected 1 domain_node_map row for lifeos-events after POST, got {len(rows)}"
        )

        # Verify the node label uses title (not raw_utterance which is not in Event dataclass)
        if rows:
            node_id = rows[0]["node_id"]
            node = conn.execute("SELECT label FROM nodes WHERE id=?", (node_id,)).fetchone()
            assert node is not None
            assert "cumple de Juan" in node["label"], (
                f"Node label should contain the event title, got: {node['label']!r}"
            )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2.7 — Cross-domain same-day linkage (3 domains)
# ═══════════════════════════════════════════════════════════════════════════


def test_three_domain_same_day_linkage():
    """2.7.1 RED — health + finance + exercise nodes on same day are all linked."""
    import axi.store as store
    from axi.linkers import run_same_day_linker
    import sqlcipher3

    c = store._connect()
    c.row_factory = sqlcipher3.Row

    # Insert 3 domain fact nodes for "today".
    health_nid = _insert_fact_node(c, label="slept 6h - poor quality", domain="health")
    finance_nid = _insert_fact_node(c, label="gasté 450 en super", domain="finance")
    exercise_nid = _insert_fact_node(c, label="caminé 45 min", domain="exercise")

    run_same_day_linker(c, window_days=1)

    # Check health <-> finance edge.
    edge_hf = c.execute(
        "SELECT 1 FROM edges WHERE "
        "((src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?)) OR (src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?))) AND relation='same-day'",
        (health_nid, finance_nid, finance_nid, health_nid),
    ).fetchone()
    assert edge_hf is not None, "Expected same-day edge between health and finance nodes"

    # Check health <-> exercise edge.
    edge_he = c.execute(
        "SELECT 1 FROM edges WHERE "
        "((src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?)) OR (src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?))) AND relation='same-day'",
        (health_nid, exercise_nid, exercise_nid, health_nid),
    ).fetchone()
    assert edge_he is not None, "Expected same-day edge between health and exercise nodes"

    # Check finance <-> exercise edge.
    edge_fe = c.execute(
        "SELECT 1 FROM edges WHERE "
        "((src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?)) OR (src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?))) AND relation='same-day'",
        (finance_nid, exercise_nid, exercise_nid, finance_nid),
    ).fetchone()
    assert edge_fe is not None, "Expected same-day edge between finance and exercise nodes"


# ═══════════════════════════════════════════════════════════════════════════
# Phase MOOD-1 — expose canonical "mood" in node data via extra_data_fn
# (prerequisite for the mood-at linker). Scope: spirituality, exercise,
# relationships. Emits a single canonical numeric key "mood".
# ═══════════════════════════════════════════════════════════════════════════


def _node_data_for_entry(conn, domain: str, entry_id: str) -> dict:
    """Read back the node's data JSON for a bridged domain entry."""
    import json as _json

    row = conn.execute(
        "SELECT n.data AS data FROM nodes n "
        "JOIN domain_node_map d ON d.node_id = n.id "
        "WHERE d.domain=? AND d.entry_id=? LIMIT 1",
        (domain, entry_id),
    ).fetchone()
    assert row is not None, f"no bridged node for {domain}/{entry_id}"
    return _json.loads(row["data"]) if row["data"] else {}


def test_spirituality_node_data_contains_mood():
    """MOOD-1 RED — spirituality entry with mood=7 → node data has "mood": 7."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    @dataclass
    class SpiritEntryStub:
        id: str = "sp-mood-1"
        kind: str = "reflection"
        raw_utterance: str | None = "hoy me sentí en paz"
        title: str | None = None
        mood: int | None = 7

    entry = SpiritEntryStub()
    with patch("axi.store.trigger_embed_for_node"):
        nid = create_fact_node_for_entry("spirituality", entry)
    assert nid is not None

    data = _node_data_for_entry(store._connect(), "spirituality", str(entry.id))
    assert data.get("mood") == 7


def test_spirituality_node_data_skips_mood_when_none():
    """MOOD-1 RED — spirituality entry with mood=None → no "mood" key."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    @dataclass
    class SpiritEntryStub:
        id: str = "sp-mood-none"
        kind: str = "reflection"
        raw_utterance: str | None = "una nota sin ánimo"
        title: str | None = None
        mood: int | None = None

    entry = SpiritEntryStub()
    with patch("axi.store.trigger_embed_for_node"):
        create_fact_node_for_entry("spirituality", entry)

    data = _node_data_for_entry(store._connect(), "spirituality", str(entry.id))
    assert "mood" not in data


def test_exercise_node_data_contains_mood_post():
    """MOOD-1 RED — exercise session → node data "mood" = mood_post (result state)."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    @dataclass
    class ExerciseStub:
        id: str = "ex-mood-1"
        kind: str = "run"
        duration_minutes: int = 30
        raw_utterance: str | None = "corrí 30 min"
        title: str | None = None
        mood_pre: int | None = 4
        mood_post: int | None = 8

    entry = ExerciseStub()
    with patch("axi.store.trigger_embed_for_node"):
        create_fact_node_for_entry("exercise", entry)

    data = _node_data_for_entry(store._connect(), "exercise", str(entry.id))
    assert data.get("mood") == 8


def test_relationships_node_data_contains_mood_and_preserves_fields():
    """MOOD-1 RED — relationships → "mood" = mood_post AND person_id/interaction_id preserved."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    @dataclass
    class InteractionStub:
        id: str = "rel-mood-1"
        kind: str = "call"
        raw_utterance: str | None = "hablé con Ana"
        title: str | None = None
        body: str | None = "buena charla"
        person_id: int | None = 99
        mood_pre: int | None = 5
        mood_post: int | None = 9

    entry = InteractionStub()
    with patch("axi.store.trigger_embed_for_node"):
        create_fact_node_for_entry("relationships", entry)

    data = _node_data_for_entry(store._connect(), "relationships", str(entry.id))
    assert data.get("mood") == 9
    assert data.get("person_id") == 99
    assert data.get("interaction_id") == "rel-mood-1"
    assert data.get("body") == "buena charla"
