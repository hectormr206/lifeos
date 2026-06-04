"""Tests for the MCP tool implementations (T2).

These cover the pure tool functions in ``axi.mcp_tools`` — the data layer the
MCP server exposes to local agents. The MCP transport itself (FastMCP/stdio) is
a thin wrapper and is not exercised here; these tests pin the behaviour and the
JSON-serialisable shapes.

Scope (v1): read + additive-write tools. No destructive operations exist.
"""
from __future__ import annotations

import json

import pytest

from axi import store


@pytest.fixture
def lifeos_isolated(tmp_path, monkeypatch):
    """Redirect every lifeos domain store to per-test temp DBs."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    from lifeos import store as lstore
    from lifeos.finance import store as fstore
    from lifeos.health import store as hstore
    lstore.apply_migrations()
    fstore.apply_migrations()
    hstore.apply_migrations()
    yield


def _is_jsonable(obj) -> bool:
    try:
        json.dumps(obj)
        return True
    except (TypeError, ValueError):
        return False


# ─────────────────────────── memory (axi.store) ───────────────────────────

def test_memory_search_returns_jsonable_hits():
    from axi import mcp_tools
    store.add_node("fact", "Axi runs on CachyOS", domain="setup")
    hits = mcp_tools.memory_search("Axi")
    assert isinstance(hits, list)
    assert _is_jsonable(hits)
    assert any("Axi" in h["label"] for h in hits)


def test_recent_conversations_oldest_first():
    from axi import mcp_tools
    store.add_conversation("hola", "qué tal")
    store.add_conversation("hora?", "07:30")
    rows = mcp_tools.recent_conversations(limit=10)
    assert _is_jsonable(rows)
    assert [r["user_text"] for r in rows] == ["hola", "hora?"]


def test_add_fact_is_searchable_roundtrip():
    from axi import mcp_tools
    out = mcp_tools.add_fact("Héctor prefers voseo", domain="prefs")
    assert isinstance(out["id"], int) and out["id"] > 0
    hits = mcp_tools.memory_search("voseo")
    assert any("voseo" in h["label"] for h in hits)


def test_add_fact_accepts_structured_data():
    from axi import mcp_tools
    out = mcp_tools.add_fact("laptop", data={"brand": "Lenovo"}, domain="setup")
    node = store.get_node(out["id"])
    assert node is not None
    assert json.loads(node["data"]) == {"brand": "Lenovo"}


# ─────────────────────────── reminders (lifeos) ───────────────────────────

def test_create_then_list_reminder(lifeos_isolated):
    from axi import mcp_tools
    created = mcp_tools.create_reminder(
        message="call the dentist", when_iso="2026-12-01T09:00:00+00:00"
    )
    assert _is_jsonable(created)
    assert created["message"] == "call the dentist"
    pending = mcp_tools.list_reminders()
    assert _is_jsonable(pending)
    assert any(r["id"] == created["id"] for r in pending)


def test_create_reminder_defaults_to_now_when_no_time(lifeos_isolated):
    from axi import mcp_tools
    created = mcp_tools.create_reminder(message="soon")
    assert created["message"] == "soon"
    assert created["id"]


# ─────────────────────────── finance (lifeos) ───────────────────────────

def test_log_finance_entry_then_summary(lifeos_isolated):
    from axi import mcp_tools
    out = mcp_tools.log_finance_entry(kind="expense", title="tacos", amount=120.0)
    assert _is_jsonable(out)
    assert out["title"] == "tacos"
    summary = mcp_tools.finance_summary(days=30)
    assert _is_jsonable(summary)
    assert isinstance(summary, dict)


def test_log_finance_entry_rejects_bad_kind(lifeos_isolated):
    from axi import mcp_tools
    with pytest.raises(ValueError):
        mcp_tools.log_finance_entry(kind="bogus", title="x", amount=1.0)


# ─────────────────────────── health (lifeos) ───────────────────────────

def test_log_health_entry_then_recent(lifeos_isolated):
    from axi import mcp_tools
    out = mcp_tools.log_health_entry(kind="symptom", title="headache")
    assert _is_jsonable(out)
    assert out["title"] == "headache"
    recent = mcp_tools.health_recent(days=30)
    assert _is_jsonable(recent)
    assert any(e["title"] == "headache" for e in recent)


# ─────────────────────── server smoke (registration) ───────────────────────

def test_mcp_server_registers_all_tools():
    """The FastMCP server should import and expose every v1 tool."""
    from axi import mcp_server
    names = mcp_server.tool_names()
    for expected in (
        "memory_search", "recent_conversations", "add_fact",
        "list_reminders", "create_reminder",
        "finance_summary", "log_finance_entry",
        "health_recent", "log_health_entry",
    ):
        assert expected in names
