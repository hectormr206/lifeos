"""Tests for the confirmation-gated forget flow in the chat handler.

Two layers:
  1. Unit tests on ``forget.handle_chat_forget`` — the session-scoped pending
     store, confirmation/negation handling, and the safety guarantee that NO
     deletion happens on the first turn.
  2. One integration test through the real ``/api/chat/ask`` endpoint with the
     brain mocked, proving the short-circuit happens before autoroute/brain.

All tests use the isolated temp DB (conftest ``fresh_db``) and never hit a
live LLM or the production database.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from axi import forget, store


@pytest.fixture(autouse=True)
def _clear_pending():
    forget._PENDING.clear()
    yield
    forget._PENDING.clear()


@pytest.fixture
def graph():
    hub = store.add_node(kind="person", label="Héctor", data={"role": "user"})
    med = store.add_node(kind="medication", label="losartán de 50 mg", domain="health")
    toma = store.add_edge(hub, med, "toma", {})
    return {"hub": hub, "med": med, "toma": toma}


# ─────────────────────────── handle_chat_forget ─────────────────────────

def test_forget_first_turn_sets_pending_no_deletion(graph):
    resp = forget.handle_chat_forget("olvidá que tomo losartán", "s1")
    assert resp is not None
    assert resp["mode"] == "forget_confirm"
    assert "losartán" in resp["answer"].lower()
    # Pending set for this session.
    assert "s1" in forget._PENDING
    # NOTHING deleted yet — safety guarantee.
    assert store.get_node(graph["med"]) is not None
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 1


def test_forget_confirm_deletes_and_clears_pending(graph):
    forget.handle_chat_forget("olvidá que tomo losartán", "s1")
    resp = forget.handle_chat_forget("sí", "s1")
    assert resp is not None
    assert resp["mode"] == "forget_done"
    assert "borré" in resp["answer"].lower()
    # The pending candidate edge is now gone.
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 0
    # Pending cleared.
    assert "s1" not in forget._PENDING


def test_forget_negation_deletes_nothing_and_clears(graph):
    forget.handle_chat_forget("olvidá que tomo losartán", "s1")
    resp = forget.handle_chat_forget("no", "s1")
    assert resp is not None
    assert resp["mode"] == "forget_cancelled"
    # Nothing deleted.
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 1
    assert "s1" not in forget._PENDING


def test_confirm_with_no_pending_falls_through(graph):
    # "sí" with no pending deletion must NOT be handled here — returns None so
    # the normal chat flow proceeds (and nothing is deleted).
    assert forget.handle_chat_forget("sí", "s1") is None
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 1


def test_forget_none_when_nothing_matches():
    resp = forget.handle_chat_forget("olvidá el dato de xyzzy plugh", "s1")
    assert resp is not None
    assert resp["mode"] == "forget_none"
    assert "s1" not in forget._PENDING


def test_pending_does_not_leak_across_sessions(graph):
    forget.handle_chat_forget("olvidá que tomo losartán", "s1")
    # A confirmation in a DIFFERENT session must not trigger s1's deletion.
    assert forget.handle_chat_forget("sí", "s2") is None
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 1
    assert "s1" in forget._PENDING


def test_ambiguous_keeps_pending_and_reasks(graph):
    forget.handle_chat_forget("olvidá que tomo losartán", "s1")
    resp = forget.handle_chat_forget("a ver qué dices", "s1")
    assert resp is not None
    assert resp["mode"] == "forget_confirm"
    assert "s1" in forget._PENDING  # still pending
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 1


def test_expired_pending_pruned(graph, monkeypatch):
    forget.handle_chat_forget("olvidá que tomo losartán", "s1")
    # Fast-forward past the TTL.
    pend = forget._PENDING["s1"]
    pend["ts"] -= forget._PENDING_TTL_S + 1
    # A confirmation now finds no live pending → falls through.
    assert forget.handle_chat_forget("sí", "s1") is None
    assert "s1" not in forget._PENDING


# ─────────────────────── subset selection by index ──────────────────────

def _seed_three_pending(session: str = "s1") -> list[int]:
    """Create 3 deletable fact nodes and mark them pending for *session*."""
    import time as _t
    ids = [store.add_node(kind="fact", label=f"hecho {i}", domain="health")
           for i in (1, 2, 3)]
    cands = [{"type": "node", "id": nid, "label": f"hecho {i}", "detail": f"hecho {i}"}
             for i, nid in zip((1, 2, 3), ids)]
    forget._PENDING[session] = {"candidates": cands, "ts": _t.monotonic()}
    return ids


def _alive(nid: int) -> bool:
    """PR7: "alive" means the row exists AND carries no tombstone.

    Before PR7 a deleted node had no row at all, so row-existence was a
    sufficient test. It no longer is — the row survives so the delete can be
    replicated — and leaving this helper as a bare COUNT would have made every
    forget test in this file report that nothing was ever deleted.
    """
    c = store._connect()
    return c.execute(
        "SELECT COUNT(*) AS n FROM nodes WHERE id=? AND deleted_at IS NULL", (nid,)
    ).fetchone()["n"] == 1


def test_parse_indices_unit():
    assert forget._parse_indices("solo el 2", 3) == [2]
    assert forget._parse_indices("el 1 y el 3", 3) == [1, 3]
    assert forget._parse_indices("borrá el 2 y 3", 3) == [2, 3]
    assert forget._parse_indices("el 2 y el 2", 3) == [2]      # deduped
    assert forget._parse_indices("el 9", 3) == []              # out of range
    assert forget._parse_indices("sí", 3) is None              # no digits
    assert forget._parse_indices("dale", 3) is None


def test_forget_subset_single_index_deletes_only_that_one():
    ids = _seed_three_pending("s1")
    resp = forget.handle_chat_forget("solo el 2", "s1")
    assert resp["mode"] == "forget_done"
    assert _alive(ids[0]) and not _alive(ids[1]) and _alive(ids[2])
    assert "s1" not in forget._PENDING


def test_forget_subset_multi_index():
    ids = _seed_three_pending("s1")
    resp = forget.handle_chat_forget("el 1 y el 3", "s1")
    assert resp["mode"] == "forget_done"
    assert not _alive(ids[0]) and _alive(ids[1]) and not _alive(ids[2])
    assert "s1" not in forget._PENDING


def test_forget_out_of_range_index_reasks_and_deletes_nothing():
    ids = _seed_three_pending("s1")
    resp = forget.handle_chat_forget("borrá el 9", "s1")
    assert resp["mode"] == "forget_confirm"          # re-ask, not a deletion
    assert all(_alive(nid) for nid in ids)           # nothing removed
    assert "s1" in forget._PENDING                   # still pending


def test_forget_confirm_all_still_deletes_everything():
    ids = _seed_three_pending("s1")
    resp = forget.handle_chat_forget("sí", "s1")
    assert resp["mode"] == "forget_done"
    assert all(not _alive(nid) for nid in ids)
    assert "s1" not in forget._PENDING


def test_forget_negation_before_index_cancels_safely():
    """'no, el 2' must cancel (safe) — negation is checked before selection."""
    ids = _seed_three_pending("s1")
    resp = forget.handle_chat_forget("no, el 2", "s1")
    assert resp["mode"] == "forget_cancelled"
    assert all(_alive(nid) for nid in ids)
    assert "s1" not in forget._PENDING


# ─────────────────────────── integration (endpoint) ─────────────────────

@pytest.fixture
def client(monkeypatch):
    from axi import dashboard, brain
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    # Brain must never be hit by the forget short-circuit; stub anyway.
    monkeypatch.setattr(brain, "ask", lambda *a, **k: "no debería llamarse")
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **k: "no debería llamarse")
    return TestClient(dashboard.app)


def test_endpoint_forget_then_confirm(client, graph):
    r1 = client.post("/api/chat/ask", json={"text": "olvidá que tomo losartán", "session_id": "sess"})
    assert r1.status_code == 200
    b1 = r1.json()
    assert b1.get("mode") == "forget_confirm"
    assert "losartán" in b1["answer"].lower()
    # Still present after the first turn.
    assert store.get_node(graph["med"]) is not None

    r2 = client.post("/api/chat/ask", json={"text": "sí", "session_id": "sess"})
    assert r2.status_code == 200
    b2 = r2.json()
    assert b2.get("mode") == "forget_done"
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (graph["toma"],)).fetchone()["n"] == 0
