"""Tests for the natural-language 'forget' feature.

Covers forget-intent detection, candidate search over the graph, and the
defensive store-level deletion helpers. All tests run against the per-test
isolated temp DB provided by conftest's ``fresh_db`` fixture — production
memory.db is never touched and no live services are used (the embed service
is down in tests, so candidate search exercises the FTS + edge lanes).
"""
from __future__ import annotations

import pytest

from axi import forget, store


# ─────────────────────────── detect_forget ──────────────────────────────

@pytest.mark.parametrize(
    "text, expected_substr",
    [
        ("olvidá que tomo losartán", "tomo losartán"),
        ("olvida que tomo losartán", "tomo losartán"),
        ("borra a Dra Tere de tu memoria", "Dra Tere"),
        ("borrá a Dra Tere de mi memoria", "Dra Tere"),
        ("elimina el dato de mi bicicleta", "bicicleta"),
        ("quita la relación Héctor toma losartán", "Héctor toma losartán"),
        ("sacá lo de mi bicicleta de tu memoria", "bicicleta"),
    ],
)
def test_detect_forget_positive(text, expected_substr):
    target = forget.detect_forget(text)
    assert target is not None
    assert expected_substr.lower() in target.lower()
    # The leading verb must be stripped.
    assert not target.lower().startswith(("olvid", "borr", "elimin", "quit", "sac"))


@pytest.mark.parametrize(
    "text",
    [
        "¿qué tomo?",
        "hola",
        "no olvides comprar pan",   # reminder, NOT a forget request
        "recuérdame tomar losartán",
        "",
        "   ",
        "dale",
    ],
)
def test_detect_forget_negative(text):
    assert forget.detect_forget(text) is None


# ─────────────────────── find_forget_candidates ─────────────────────────

@pytest.fixture
def seeded_graph():
    """Seed a small graph and return the relevant ids."""
    hub = store.add_node(kind="person", label="Héctor", data={"role": "user"})
    med = store.add_node(kind="medication", label="losartán de 50 mg", domain="health")
    doctor = store.add_node(kind="person", label="Dra Tere", data={"entity": True})
    cond = store.add_node(kind="condition", label="hipertensión", domain="health")
    fact = store.add_node(kind="fact", label="mi bicicleta es azul")

    toma = store.add_edge(hub, med, "toma", {})
    padece = store.add_edge(hub, cond, "padece", {})
    diag = store.add_edge(cond, doctor, "diagnosticada_por", {})
    # Structural edges that MUST be excluded from candidates.
    store.add_edge(hub, fact, "about", {})
    store.add_edge(hub, med, "same-day", {})
    store.add_edge(hub, doctor, "mentioned_in", {})

    return {
        "hub": hub, "med": med, "doctor": doctor, "cond": cond, "fact": fact,
        "toma": toma, "padece": padece, "diag": diag,
    }


def test_find_candidates_returns_edge(seeded_graph):
    cands = forget.find_forget_candidates("tomo losartán")
    edges = [c for c in cands if c["type"] == "edge"]
    assert any(c["id"] == seeded_graph["toma"] for c in edges)
    # The edge candidate is human-readable.
    toma_cand = next(c for c in edges if c["id"] == seeded_graph["toma"])
    assert "losartán" in toma_cand["label"].lower()
    assert "toma" in toma_cand["label"].lower()


def test_find_candidates_returns_node(seeded_graph):
    cands = forget.find_forget_candidates("Dra Tere")
    nodes = [c for c in cands if c["type"] == "node"]
    assert any(c["id"] == seeded_graph["doctor"] for c in nodes)


def test_find_candidates_excludes_structural_edges(seeded_graph):
    cands = forget.find_forget_candidates("bicicleta")
    # 'about' edge from hub->fact must NOT show up as a relation candidate.
    for c in cands:
        if c["type"] == "edge":
            assert "about" not in c["label"].lower()
            assert "same-day" not in c["label"].lower()
            assert "mentioned" not in c["label"].lower()


def test_find_candidates_excludes_hub(seeded_graph):
    # Even if the query matches the user's name, the hub is never deletable.
    cands = forget.find_forget_candidates("Héctor")
    assert all(
        not (c["type"] == "node" and c["id"] == seeded_graph["hub"])
        for c in cands
    )


def test_find_candidates_dedup_and_cap(seeded_graph):
    for i in range(20):
        store.add_node(kind="fact", label=f"nota bicicleta numero {i}")
    cands = forget.find_forget_candidates("bicicleta", limit=5)
    assert len(cands) <= 5
    ids = [(c["type"], c["id"]) for c in cands]
    assert len(ids) == len(set(ids))  # no duplicates


def test_find_candidates_none_for_unknown():
    assert forget.find_forget_candidates("xyzzy plugh inexistente") == []


def test_find_candidates_never_raises(monkeypatch):
    monkeypatch.setattr(store, "search_nodes_fts", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    assert forget.find_forget_candidates("losartán") == []


# ───────────────────────── store deletion helpers ───────────────────────

def test_delete_node_removes_node_edges_and_fts(seeded_graph):
    med = seeded_graph["med"]
    assert store.delete_node(med) is True
    # Node gone.
    assert store.get_node(med) is None
    # Its edges gone (toma: hub->med, same-day: hub->med).
    c = store._connect()
    remaining = c.execute(
        "SELECT COUNT(*) AS n FROM edges WHERE from_id=? OR to_id=?", (med, med)
    ).fetchone()["n"]
    assert remaining == 0
    # FTS row gone.
    fts = c.execute("SELECT COUNT(*) AS n FROM nodes_fts WHERE rowid=?", (med,)).fetchone()["n"]
    assert fts == 0


def test_delete_node_refuses_hub(seeded_graph):
    hub = seeded_graph["hub"]
    assert store.delete_node(hub) is False
    assert store.get_node(hub) is not None


def test_delete_node_missing_returns_false():
    assert store.delete_node(999999) is False


def test_delete_edge_removes_one_edge(seeded_graph):
    diag = seeded_graph["diag"]
    assert store.delete_edge(diag) is True
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=?", (diag,)).fetchone()["n"] == 0
    # Other edges untouched.
    assert c.execute("SELECT COUNT(*) AS n FROM edges WHERE id=?", (seeded_graph["toma"],)).fetchone()["n"] == 1


def test_delete_edge_missing_returns_false():
    assert store.delete_edge(999999) is False
