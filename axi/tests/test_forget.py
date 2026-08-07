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

def test_delete_node_tombstones_node_and_edges_and_removes_fts(seeded_graph):
    """PR7 changed this expectation deliberately.

    It used to assert the node row and its edge rows were ABSENT. They are now
    tombstoned instead: sync cannot replicate an absence, so a removed row
    comes back from the next peer that still has it. The user-visible contract
    is unchanged and is what this test now asserts — the node is unreachable
    and no live edge touches it — plus the one thing that is still a hard
    delete, the `nodes_fts` row.

    The old assertion was not merely stricter, it asserted the hard delete,
    which is exactly the behaviour PR7 exists to remove. Renamed so the file
    does not keep a name promising something it no longer checks.
    """
    med = seeded_graph["med"]
    assert store.delete_node(med) is True
    # Node unreachable through every read path.
    assert store.get_node(med) is None
    c = store._connect()
    # …but still on disk, carrying its tombstone.
    assert c.execute(
        "SELECT deleted_at FROM nodes WHERE id=?", (med,)
    ).fetchone()["deleted_at"] is not None
    # Its edges (toma: hub->med, same-day: hub->med) are tombstoned, not gone.
    live = c.execute(
        "SELECT COUNT(*) AS n FROM edges WHERE (from_id=? OR to_id=?) "
        "AND deleted_at IS NULL", (med, med)
    ).fetchone()["n"]
    assert live == 0
    assert c.execute(
        "SELECT COUNT(*) AS n FROM edges WHERE from_id=? OR to_id=?", (med, med)
    ).fetchone()["n"] > 0, "the edges were hard-deleted instead of tombstoned"
    # FTS row gone — still a HARD delete, deliberately.
    fts = c.execute("SELECT COUNT(*) AS n FROM nodes_fts WHERE rowid=?", (med,)).fetchone()["n"]
    assert fts == 0


def test_delete_node_refuses_hub(seeded_graph):
    hub = seeded_graph["hub"]
    assert store.delete_node(hub) is False
    assert store.get_node(hub) is not None


def test_delete_node_missing_returns_false():
    assert store.delete_node(999999) is False


def test_delete_edge_tombstones_exactly_one_edge(seeded_graph):
    """Same deliberate change of expectation as the node case above."""
    diag = seeded_graph["diag"]
    assert store.delete_edge(diag) is True
    c = store._connect()
    assert c.execute(
        "SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL", (diag,)
    ).fetchone()["n"] == 0
    assert c.execute(
        "SELECT deleted_at FROM edges WHERE id=?", (diag,)
    ).fetchone()["deleted_at"] is not None, "the edge was hard-deleted, not tombstoned"
    # Other edges untouched.
    assert c.execute(
        "SELECT COUNT(*) AS n FROM edges WHERE id=? AND deleted_at IS NULL",
        (seeded_graph["toma"],),
    ).fetchone()["n"] == 1


def test_delete_edge_missing_returns_false():
    assert store.delete_edge(999999) is False


# ─────────── PR6a: reader rewrite to src_uuid/dst_uuid/relation ───────────

def _old_forget_edge_lane(c, target: str, limit: int) -> list[tuple[int, str]]:
    """The pre-rewrite EDGE lane, kept verbatim as the equivalence oracle:
    the same dynamic WHERE, the same `from_id`/`to_id` joins, the same
    post-filter. 6a.2 claims the rewrite returns identical results — this is
    what "identical" is measured against."""
    words = forget._target_words(target)
    if not words:
        return []
    where: list[str] = []
    params: list = []
    for w in words:
        where.append(
            "(LOWER(nf.label) LIKE ? OR LOWER(nt.label) LIKE ? OR LOWER(e.kind) LIKE ?)"
        )
        like = f"%{w}%"
        params.extend([like, like, like])
    sql = (
        "SELECT e.id AS eid, e.kind AS k, nf.label AS f, nt.label AS t "
        "FROM edges e "
        "JOIN nodes nf ON e.from_id = nf.id "
        "JOIN nodes nt ON e.to_id = nt.id "
        f"WHERE ({' OR '.join(where)}) "
        "LIMIT ?"
    )
    params.append(limit * 4)
    out: dict[int, str] = {}
    for row in c.execute(sql, params).fetchall():
        k = (row["k"] or "").strip()
        if not k or k in forget._STRUCTURAL_EDGE_KINDS:
            continue
        f = (row["f"] or "").strip()
        t = (row["t"] or "").strip()
        if not f or not t:
            continue
        out.setdefault(row["eid"], f"{f} {k.replace('_', ' ')} {t}")
    return sorted(out.items())


def test_forget_edge_lane_resolves_through_endpoint_uuids():
    """RED for 6a.2: the forget EDGE lane describes each deletion candidate
    with its two endpoint labels, so it must resolve them through
    `src_uuid`/`dst_uuid`.

    The edge's integer `from_id` is pointed at a decoy while `src_uuid` still
    names the real source, so the candidate's label reveals which column the
    join actually followed. Reading the wrong one offers the user a deletion
    described with the WRONG endpoint — worse than offering nothing.
    """
    src = store.add_node("person", "Ana Ríos")
    dst = store.add_node("medication", "losartán")
    decoy = store.add_node("person", "Dra Tere")
    eid = store.add_edge(src, dst, "toma")
    store._connect().execute("UPDATE edges SET from_id=? WHERE id=?", (decoy, eid))

    edges = [c for c in forget.find_forget_candidates("losartán")
             if c["type"] == "edge"]
    assert edges, "the edge lane returned nothing for a matching relation"
    assert "Ana Ríos" in edges[0]["label"]
    assert "Dra Tere" not in edges[0]["label"]


def test_forget_edge_lane_identical_to_pre_rewrite_query(pr6a_graph):
    """6a.2's "identical results on a seeded fixture DB", taken literally:
    production output compared against the pre-rewrite oracle above, over a
    fixture that carries a self-edge, a duplicate-kind pair, a tombstoned
    endpoint and a dangling one."""
    c = store._connect()
    for target in ("Ana", "hipertensión", "CachyOS", "lápida", "desaparece"):
        new = sorted(
            (cand["id"], cand["label"])
            for cand in forget.find_forget_candidates(target, limit=50)
            if cand["type"] == "edge"
        )
        assert new == _old_forget_edge_lane(c, target, 50), (
            f"forget edge lane diverged from the pre-rewrite query for {target!r}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# PR7 — tombstone filters on the forget candidate lanes (task 7.9/7.10).
#
# This surface literally offers rows to the user for deletion. Offering an
# already-deleted one lets them "delete" something twice and be told it
# worked, which is a lie about their own memory.
# ═══════════════════════════════════════════════════════════════════════════


def _tombstone_node_row(nid: int) -> None:
    import time as _t

    store._connect().execute(  # noqa: SLF001
        "UPDATE nodes SET deleted_at=? WHERE id=?", (_t.time(), nid)
    )


def _tombstone_edge_row(eid: int) -> None:
    import time as _t

    store._connect().execute(  # noqa: SLF001
        "UPDATE edges SET deleted_at=?, updated_at=? WHERE id=?", (_t.time(), _t.time(), eid)
    )


def test_forget_edge_lane_does_not_offer_a_tombstoned_edge():
    hub = store.add_node("person", "Héctor", {"role": "user"})
    ana = store.add_node("person", "Ana Ríos")
    eid = store.add_edge(hub, ana, "esposa")

    found = forget.find_forget_candidates("Ana")
    assert any(c["type"] == "edge" and c["id"] == eid for c in found)

    _tombstone_edge_row(eid)
    found = forget.find_forget_candidates("Ana")
    assert not any(c["type"] == "edge" and c["id"] == eid for c in found), (
        "forget offered an already-deleted relation as a deletion candidate"
    )


def test_forget_edge_lane_drops_an_edge_whose_endpoint_is_tombstoned():
    """Both endpoint labels are shown to the user; a deleted one must not be."""
    hub = store.add_node("person", "Héctor", {"role": "user"})
    ana = store.add_node("person", "Ana Ríos")
    eid = store.add_edge(hub, ana, "esposa")

    _tombstone_node_row(ana)
    found = forget.find_forget_candidates("Ana")
    assert not any(c["type"] == "edge" and c["id"] == eid for c in found)


def test_forget_node_lane_does_not_offer_a_tombstoned_node():
    """Covered through `search_nodes_fts`, the lane that carries this in tests.

    A node tombstoned WITHOUT a local delete (the sync shape) keeps its FTS
    row, so only the read filter stops it from being offered.
    """
    nid = store.add_node("fact", "toma losartán")
    found = forget.find_forget_candidates("losartán")
    assert any(c["type"] == "node" and c["id"] == nid for c in found)

    _tombstone_node_row(nid)
    found = forget.find_forget_candidates("losartán")
    assert not any(c["type"] == "node" and c["id"] == nid for c in found)
