"""Graph linkage for family-subject entries.

- health/exercise bridge nodes carry {"subject": <label>} in node data.
- When the user hub has a typed relation edge (hub --esposa--> Ana), a
  bridged fact with subject="esposa" gains an involves edge fact -> Ana.
- Unresolvable subjects stay data-only (no edge, no raise).
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass

import pytest


@dataclass
class HealthEntryStub:
    id: str = "he-subj-001"
    kind: str = "vital"
    title: str | None = "presión 121/79, pulso 61"
    raw_utterance: str | None = "Mi esposa tuvo 121, 79, 61 pulsos"
    subject: str | None = "esposa"
    ts: float = 1750000000.0


@dataclass
class ExerciseSessionStub:
    id: str = "ex-subj-001"
    kind: str = "cardio"
    title: str | None = "cardio"
    raw_utterance: str | None = "30 min de cardio de mi esposa"
    duration_minutes: int = 30
    mood_post: int | None = None
    subject: str | None = "esposa"
    ts: float = 1750000000.0


@pytest.fixture()
def hub_with_wife(monkeypatch):
    """User hub 'Héctor' + person 'Ana' + typed edge hub --esposa--> Ana."""
    from axi import identity, store
    monkeypatch.setattr(identity, "user_name", lambda: "Héctor")
    hub = store.add_node(kind="person", label="Héctor",
                         data={"role": "user"}, domain=None)
    ana = store.add_node(kind="person", label="Ana",
                           data={"entity": True}, domain=None)
    store.add_edge(hub, ana, "esposa")
    return hub, ana


def _node_data(node_id: int) -> dict:
    from axi import store
    row = store._connect().execute(
        "SELECT data FROM nodes WHERE id=?", (node_id,)
    ).fetchone()
    return json.loads(row["data"] or "{}")


def _edges(from_id: int, kind: str) -> list[int]:
    from axi import store
    rows = store._connect().execute(
        "SELECT to_id FROM edges WHERE from_id=? AND kind=?", (from_id, kind)
    ).fetchall()
    return [r["to_id"] for r in rows]


def test_health_bridge_carries_subject(hub_with_wife) -> None:
    from axi import domain_bridge
    node_id = domain_bridge.create_fact_node_for_entry("health", HealthEntryStub())
    assert node_id is not None
    assert _node_data(node_id).get("subject") == "esposa"


def test_health_bridge_no_subject_key_when_absent(hub_with_wife) -> None:
    from axi import domain_bridge
    node_id = domain_bridge.create_fact_node_for_entry(
        "health", HealthEntryStub(id="he-subj-002", subject=None)
    )
    assert node_id is not None
    assert "subject" not in _node_data(node_id)


def test_exercise_bridge_carries_subject(hub_with_wife) -> None:
    from axi import domain_bridge
    node_id = domain_bridge.create_fact_node_for_entry(
        "exercise", ExerciseSessionStub()
    )
    assert node_id is not None
    assert _node_data(node_id).get("subject") == "esposa"


def test_involves_edge_created_when_relation_resolves(hub_with_wife) -> None:
    from axi import domain_bridge
    _hub, ana = hub_with_wife
    node_id = domain_bridge.create_fact_node_for_entry("health", HealthEntryStub())
    assert node_id is not None
    assert ana in _edges(node_id, "involves")


def test_involves_edge_resolves_relation_synonym(hub_with_wife, monkeypatch) -> None:
    """Graph edge typed 'mujer' still resolves canonical subject 'esposa'."""
    from axi import domain_bridge, store
    hub, ana = hub_with_wife
    with store._tx() as tx:  # retype the relation edge
        tx.execute("UPDATE edges SET kind='mujer' WHERE from_id=? AND to_id=?",
                   (hub, ana))
    node_id = domain_bridge.create_fact_node_for_entry(
        "health", HealthEntryStub(id="he-subj-003")
    )
    assert node_id is not None
    assert ana in _edges(node_id, "involves")


def test_no_involves_edge_when_unresolvable(monkeypatch) -> None:
    from axi import domain_bridge, identity, store
    monkeypatch.setattr(identity, "user_name", lambda: "Héctor")
    store.add_node(kind="person", label="Héctor", data={"role": "user"},
                   domain=None)  # hub without any typed relations
    node_id = domain_bridge.create_fact_node_for_entry(
        "health", HealthEntryStub(id="he-subj-004")
    )
    assert node_id is not None  # bridging still succeeds (data-only)
    assert _node_data(node_id).get("subject") == "esposa"
    assert _edges(node_id, "involves") == []


def _make_chat_client(monkeypatch):
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


def test_health_fast_path_passes_subject_end_to_end(monkeypatch) -> None:
    """Chat → REAL parse_health('Mi esposa tuvo 121, 79, 61 pulsos') →
    health_entries.create(subject='esposa') with the correct BP structure."""
    from types import SimpleNamespace
    from unittest.mock import MagicMock

    from axi import dashboard

    client = _make_chat_client(monkeypatch)
    mock_entry = SimpleNamespace(id="h-subj-1", kind="vital")
    create_spy = MagicMock(return_value=mock_entry)
    monkeypatch.setattr(dashboard.health_entries, "create", create_spy)

    r = client.post("/api/chat/ask", json={
        "text": "Mi esposa tuvo 121, 79, 61 pulsos", "logging_mode": False,
    })

    assert r.status_code == 200
    assert create_spy.called, "health fast-path did not persist the entry"
    _, kwargs = create_spy.call_args
    assert kwargs.get("subject") == "esposa"
    assert kwargs.get("kind") == "vital"
    assert kwargs.get("data") == {
        "type": "blood_pressure", "systolic": 96, "diastolic": 82,
        "pulse_bpm": 56, "unit": "mmHg",
    }


def test_exercise_fast_path_passes_subject_end_to_end(monkeypatch) -> None:
    """Chat → REAL parse_exercise('30 min de cardio de mi esposa') →
    ex_sessions.create(subject='esposa')."""
    from types import SimpleNamespace
    from unittest.mock import MagicMock

    from axi import dashboard

    client = _make_chat_client(monkeypatch)
    mock_sess = SimpleNamespace(id="ex-subj-1", kind="cardio")
    create_spy = MagicMock(return_value=mock_sess)
    monkeypatch.setattr(dashboard.ex_sessions, "create", create_spy)
    monkeypatch.setattr(dashboard.ex_sessions, "current_streak",
                        lambda **_k: 0)

    r = client.post("/api/chat/ask", json={
        "text": "30 min de cardio de mi esposa", "logging_mode": False,
    })

    assert r.status_code == 200
    assert create_spy.called, "exercise fast-path did not persist the session"
    _, kwargs = create_spy.call_args
    assert kwargs.get("subject") == "esposa"
    assert kwargs.get("kind") == "cardio"
    assert kwargs.get("duration_minutes") == 30


def test_involves_linkage_never_raises(hub_with_wife, monkeypatch) -> None:
    """A crashing resolver must not break the bridge write path."""
    from axi import domain_bridge, identity
    monkeypatch.setattr(
        identity, "_find_hub_row",
        lambda c: (_ for _ in ()).throw(RuntimeError("boom")),
    )
    node_id = domain_bridge.create_fact_node_for_entry(
        "health", HealthEntryStub(id="he-subj-005")
    )
    assert node_id is not None
