"""Tests for axi.identity — user-hub name extraction + onboarding guard."""
from __future__ import annotations

import json

from axi import identity


def test_extract_name_preferred_wins_over_full():
    assert identity._extract_name("Soy Héctor Martínez Reséndiz, decime Hec") == "Hec"


def test_extract_name_me_llamo():
    assert identity._extract_name("Me llamo Juan") == "Juan"


def test_extract_name_soy_strips_greeting():
    assert identity._extract_name("Hola, soy Ana") == "Ana"


def test_extract_name_bare_short_message():
    assert identity._extract_name("Carlos") == "Carlos"


def test_extract_name_none_for_long_non_introduction():
    assert identity._extract_name(
        "hoy fui al super y compré muchas cosas para la cena de mañana"
    ) == ""


def test_onboarding_capture_noop_when_name_already_set(monkeypatch):
    monkeypatch.setattr(identity, "user_name", lambda: "Héctor")
    assert identity.onboarding_capture("soy Juan") is None


def test_extract_and_store_processes_relations(monkeypatch):
    """The extractor's 'relations' are turned into typed hub edges."""
    from axi import extractor, identity, config
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: True if k == "graph_bridge_chat_facts" else d)
    monkeypatch.setattr(
        extractor, "brain_ask",
        lambda **kw: '{"facts": [], "relations": '
                     '[{"relation": "esposa", "entity": "Ana Ríos", "kind": "person"}]}',
    )
    seen = []
    monkeypatch.setattr(identity, "add_relation",
                        lambda rel, ent, kind="person": seen.append((rel, ent, kind)))
    extractor.extract_and_store("mi esposa es Ana Ríos", "ok", None)
    assert ("esposa", "Ana Ríos", "person") in seen


def test_extract_processes_relation_aliases(monkeypatch):
    """Aliases on an extracted relation are registered on the entity."""
    from axi import extractor, identity, config
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: True if k == "graph_bridge_chat_facts" else d)
    monkeypatch.setattr(
        extractor, "brain_ask",
        lambda **kw: '{"facts":[],"relations":[{"relation":"esposa",'
                     '"entity":"Ana Ríos","kind":"person","aliases":["Ani"]}]}',
    )
    rels, aliases = [], []
    monkeypatch.setattr(identity, "add_relation",
                        lambda r, e, k="person": rels.append((r, e, k)))
    monkeypatch.setattr(identity, "register_alias",
                        lambda c, a, k="person": aliases.append((c, a, k)))
    extractor.extract_and_store("mi esposa Ana, le dicen Ani", "ok", None)
    assert ("esposa", "Ana Ríos", "person") in rels
    assert ("Ana Ríos", "Ani", "person") in aliases


def test_extract_links_facts_to_entities(monkeypatch):
    """Facts created during extraction get linked to the entities they mention."""
    from axi import extractor, identity, store, config
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: True if k == "graph_bridge_chat_facts" else d)
    monkeypatch.setattr(
        extractor, "brain_ask",
        lambda **kw: '{"facts":[{"kind":"biographical","label":"Esposa: Ana","domain":"personal"}],'
                     '"relations":[]}',
    )
    monkeypatch.setattr(store, "find_fact_by_label", lambda label, conn=None: None)
    monkeypatch.setattr(store, "add_node", lambda **kw: 50)
    monkeypatch.setattr(store, "add_edge", lambda *a, **k: 1)
    monkeypatch.setattr(identity, "link_fact_to_user", lambda *a, **k: None)
    linked = []
    monkeypatch.setattr(identity, "link_fact_to_entities",
                        lambda fid, text, conn=None: linked.append((fid, text)))
    extractor.extract_and_store("mi esposa Ana", "ok", None)
    assert (50, "Esposa: Ana") in linked


def test_coref_score_strong_for_name_subset_and_accents():
    from axi.identity import _coref_score
    assert _coref_score("Ana Ríos", "Ana Ríos López") >= 0.9
    assert _coref_score("Ana Rios", "Ana Ríos López") >= 0.9  # accent-insensitive


def test_coref_score_low_for_different_people():
    from axi.identity import _coref_score
    assert _coref_score("Juan García", "Pedro García") < 0.7


def test_resolve_coreference_strong_merges():
    from axi.identity import _resolve_coreference
    row = {"id": 5, "label": "Ana Ríos López"}
    cands = [(row, {"ana ríos lópez"})]
    assert _resolve_coreference("Ana Ríos", "person", cands) is row  # >=0.9, no LLM


def test_resolve_coreference_no_merge_for_distinct():
    from axi.identity import _resolve_coreference
    row = {"id": 5, "label": "Ana Ríos"}
    cands = [(row, {"ana ríos"})]
    assert _resolve_coreference("Roberto Sánchez Díaz", "person", cands) is None  # <0.7


# --- add_entity_relation: universal entity-to-entity edges -------------------

def test_add_entity_relation_creates_both_nodes_and_edge():
    from axi import store
    identity.add_entity_relation(
        "hipertensión", "tratada_con", "losartán",
        subject_kind="condition", object_kind="medication",
    )
    c = store._connect()
    cond = c.execute(
        "SELECT id FROM nodes WHERE kind='condition' AND label='hipertensión'"
    ).fetchone()
    med = c.execute(
        "SELECT id FROM nodes WHERE kind='medication' AND label='losartán'"
    ).fetchone()
    assert cond is not None and med is not None
    edge = c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='tratada_con'",
        (cond["id"], med["id"]),
    ).fetchone()
    assert edge is not None


def test_add_entity_relation_is_idempotent():
    from axi import store
    for _ in range(2):
        identity.add_entity_relation(
            "hipertensión", "tratada_con", "losartán",
            subject_kind="condition", object_kind="medication",
        )
    c = store._connect()
    n = c.execute("SELECT COUNT(*) AS n FROM edges WHERE relation='tratada_con'").fetchone()
    assert n["n"] == 1


def test_add_entity_relation_user_subject_routes_to_hub(monkeypatch):
    from axi import config, store
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: "Héctor" if k == "user_name" else d)
    identity.add_entity_relation("Héctor", "padece", "hipertensión",
                                 object_kind="condition")
    hub = identity.ensure_user_hub()
    ent = identity.ensure_entity("hipertensión", "condition")
    c = store._connect()
    edge = c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='padece'",
        (hub, ent),
    ).fetchone()
    assert edge is not None
    # the user must NOT also exist as an 'other' condition/thing entity
    assert c.execute(
        "SELECT 1 FROM nodes WHERE label='Héctor' AND kind!='person'"
    ).fetchone() is None


def test_add_entity_relation_yo_pronoun_routes_to_hub(monkeypatch):
    from axi import config, store
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: "Héctor" if k == "user_name" else d)
    identity.add_entity_relation("yo", "padece", "hipertensión",
                                 object_kind="condition")
    hub = identity.ensure_user_hub()
    ent = identity.ensure_entity("hipertensión", "condition")
    c = store._connect()
    assert c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='padece'",
        (hub, ent),
    ).fetchone() is not None


def test_add_entity_relation_unknown_kind_falls_back_to_thing():
    from axi import store
    identity.add_entity_relation("Quux", "rel", "Zorp",
                                 subject_kind="banana", object_kind="banana")
    c = store._connect()
    assert c.execute("SELECT 1 FROM nodes WHERE kind='thing' AND label='Zorp'").fetchone()
    assert c.execute("SELECT 1 FROM nodes WHERE kind='thing' AND label='Quux'").fetchone()


def test_add_entity_relation_never_raises(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("boom")
    monkeypatch.setattr(identity, "ensure_entity", boom)
    # must not propagate
    identity.add_entity_relation("a", "rel", "b",
                                 subject_kind="thing", object_kind="thing")


def test_add_relation_still_works(monkeypatch):
    """Back-compat: the original hub->entity helper is unchanged."""
    from axi import config, store
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: "Héctor" if k == "user_name" else d)
    identity.add_relation("esposa", "Ana Ríos", "person")
    hub = identity.ensure_user_hub()
    ent = identity.ensure_entity("Ana Ríos", "person")
    c = store._connect()
    assert c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='esposa'",
        (hub, ent),
    ).fetchone() is not None


# --- extractor: universal triple extraction ----------------------------------

def test_extract_and_store_hypertension_entity_graph(monkeypatch):
    """The motivating bug: condition + medication entities AND entity->entity edges."""
    from axi import extractor, config, store
    def cfg(k, d=None):
        if k == "graph_bridge_chat_facts":
            return True
        if k == "user_name":
            return "Héctor"
        return d
    monkeypatch.setattr(config, "get", cfg)
    raw = json.dumps({"facts": [], "relations": [
        {"subject": "Héctor", "subject_kind": "person", "relation": "padece",
         "object": "hipertensión", "object_kind": "condition"},
        {"subject": "hipertensión", "subject_kind": "condition",
         "relation": "diagnosticada_por", "object": "Dra. López", "object_kind": "person"},
        {"subject": "hipertensión", "subject_kind": "condition",
         "relation": "tratada_con", "object": "losartán", "object_kind": "medication"},
    ]}, ensure_ascii=False)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: raw)
    extractor.extract_and_store(
        "hace 2 años la Dra Tere me diagnosticó hipertensión y me recetó losartán",
        "ok", None,
    )
    c = store._connect()
    cond = c.execute(
        "SELECT id FROM nodes WHERE kind='condition' AND label='hipertensión'"
    ).fetchone()
    med = c.execute(
        "SELECT id FROM nodes WHERE kind='medication' AND label='losartán'"
    ).fetchone()
    doc = c.execute(
        "SELECT id FROM nodes WHERE kind='person' AND label='Dra. López'"
    ).fetchone()
    assert cond is not None and med is not None and doc is not None
    hub = identity.ensure_user_hub()
    assert c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='padece'",
        (hub, cond["id"]),
    ).fetchone() is not None
    assert c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='diagnosticada_por'",
        (cond["id"], doc["id"]),
    ).fetchone() is not None
    assert c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='tratada_con'",
        (cond["id"], med["id"]),
    ).fetchone() is not None


def test_extract_old_shape_creates_user_to_entity_edge(monkeypatch):
    from axi import extractor, config, store
    def cfg(k, d=None):
        if k == "graph_bridge_chat_facts":
            return True
        if k == "user_name":
            return "Héctor"
        return d
    monkeypatch.setattr(config, "get", cfg)
    raw = json.dumps({"facts": [], "relations": [
        {"relation": "esposa", "entity": "Ana", "kind": "person"},
    ]}, ensure_ascii=False)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: raw)
    extractor.extract_and_store("mi esposa Ana", "ok", None)
    c = store._connect()
    hub = identity.ensure_user_hub()
    ana = c.execute("SELECT id FROM nodes WHERE kind='person' AND label='Ana'").fetchone()
    assert ana is not None
    assert c.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation='esposa'",
        (hub, ana["id"]),
    ).fetchone() is not None


def test_extract_skips_incomplete_relations(monkeypatch):
    from axi import extractor, config, store
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: True if k == "graph_bridge_chat_facts" else d)
    raw = json.dumps({"facts": [], "relations": [
        {"subject": "", "relation": "toma", "object": "agua", "object_kind": "thing"},
        {"subject": "yo", "relation": "", "object": "algo"},
        {"subject": "yo", "relation": "rel", "object": "", "object_kind": "thing"},
    ]}, ensure_ascii=False)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: raw)
    extractor.extract_and_store("x", "ok", None)
    c = store._connect()
    assert c.execute("SELECT COUNT(*) AS n FROM edges").fetchone()["n"] == 0
    assert c.execute("SELECT 1 FROM nodes WHERE label='agua'").fetchone() is None


def test_register_alias_merge_dual_writes_edge_endpoint_uuids():
    """Task 5.8: the alias-merge endpoint rewrite re-points every edge of the
    merged-away node at the CANONICAL node's uuid.

    PR5 wrote this as a DUAL update, kept in one transaction so a crash could
    not leave `from_id` and `src_uuid` disagreeing. PR8 removed `from_id`, so
    the dual-representation drift design-schema.md flagged is gone by
    construction rather than by transactional discipline. What is asserted is
    unchanged: after the merge, no edge still points at the loser."""
    from axi import store

    canonical_id = identity.ensure_entity("Ana Ríos", "person")
    assert canonical_id is not None

    # A separate node, labelled with the alias, that will be MERGED away.
    alias_id = store.add_node("person", "Ani")
    other_id = store.add_node("fact", "some other node")
    # `add_node` has assigned a uuid at insert time since task 5.14; this
    # backfill call is a no-op kept only because it also proves the migration
    # stays idempotent on an already-converged database.
    store.migrate_nodes_edges_sync_columns()
    canonical_uuid = store._connect().execute(
        "SELECT uuid FROM nodes WHERE id=?", (canonical_id,)
    ).fetchone()[0]
    # Edges on BOTH sides of the alias node, so both rewrite statements
    # (from_id and to_id) are exercised.
    e_out = store.add_edge(alias_id, other_id, "mentioned_in")
    e_in = store.add_edge(other_id, alias_id, "caused_by")

    identity.register_alias("Ana Ríos", "Ani", "person")

    c = store._connect()
    # PR7 changed this expectation deliberately. It used to read "the alias
    # node itself is gone (merged)" and assert the row was absent. A merge is
    # a delete, and PR7 makes every node delete a tombstone: the row survives
    # carrying `deleted_at`, because sync cannot replicate an absence — a peer
    # that never sees the row would treat it as not-yet-received and push the
    # merged-away duplicate straight back. Asserting absence again would
    # assert the old hard delete, so the check moves to what the merge is
    # actually claiming: the node is no longer LIVE.
    assert c.execute(
        "SELECT 1 FROM nodes WHERE id=? AND deleted_at IS NULL", (alias_id,)
    ).fetchone() is None
    assert c.execute(
        "SELECT deleted_at FROM nodes WHERE id=?", (alias_id,)
    ).fetchone()["deleted_at"] is not None

    row_out = c.execute("SELECT src_uuid FROM edges WHERE id=?", (e_out,)).fetchone()
    row_in = c.execute("SELECT dst_uuid FROM edges WHERE id=?", (e_in,)).fetchone()

    assert row_out["src_uuid"] == canonical_uuid
    assert row_in["dst_uuid"] == canonical_uuid

    # No lingering drift anywhere in the graph after the merge.
    store.verify_edge_endpoint_convergence()


def test_extract_structured_domain_facts_still_skipped(monkeypatch):
    """health/finance vitals are NOT duplicated as chat facts, but relations run."""
    from axi import extractor, config, store
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: True if k == "graph_bridge_chat_facts" else d)
    raw = json.dumps({"facts": [
        {"kind": "health", "label": "Presión 130/85", "domain": "health"},
    ], "relations": []}, ensure_ascii=False)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: raw)
    saved = extractor.extract_and_store("mi presión fue 130/85", "ok", None)
    assert saved == 0
    c = store._connect()
    assert c.execute("SELECT 1 FROM nodes WHERE kind='fact'").fetchone() is None


# ─────────── PR6a: reader rewrite to src_uuid/dst_uuid/relation ───────────
#
# Every read site listed in task 6a.5 is a "does this edge already exist?"
# guard or an endpoint resolution. These tests used to desync the OLD integer
# endpoint from the NEW uuid endpoint, so the function's answer named which
# column it followed. PR8 removed the integer endpoint entirely: there is one
# representation, so the desync is not expressible and the guard cannot read
# the wrong column. What still matters, and is what these tests now assert, is
# the CONSEQUENCE the desync was standing in for — a guard that fails to
# recognise an edge it wrote itself appends a duplicate on every pass, and the
# user's graph grows a second copy of every relation, forever.

def _stored_edge(from_id: int, to_id: int, kind: str) -> int:
    """Store a real `from_id -> to_id` edge through the production writer."""
    from axi import store

    return store.add_edge(from_id, to_id, kind)


def _edge_count() -> int:
    from axi import store

    return store._connect().execute("SELECT COUNT(*) FROM edges").fetchone()[0]


def test_add_relation_dedupe_resolves_through_endpoint_uuids():
    """identity.py:408 — the hub--relation-->entity duplicate guard."""
    from axi import store  # noqa: F401

    hub = identity.ensure_user_hub()
    ent = identity.ensure_entity("Ana Ríos", "person")
    _stored_edge(hub, ent, "esposa")
    before = _edge_count()

    identity.add_relation("esposa", "Ana Ríos", "person")

    assert _edge_count() == before


def test_add_entity_relation_dedupe_resolves_through_endpoint_uuids():
    """identity.py:469 — the entity--relation-->entity duplicate guard."""
    subj = identity.ensure_entity("hipertensión", "condition")
    obj = identity.ensure_entity("losartán", "medication")
    _stored_edge(subj, obj, "tratada_con")
    before = _edge_count()

    identity.add_entity_relation(
        "hipertensión", "tratada_con", "losartán",
        subject_kind="condition", object_kind="medication",
    )

    assert _edge_count() == before


def test_link_fact_to_entities_dedupe_resolves_through_endpoint_uuids():
    """identity.py:517 — the fact--mentions-->entity duplicate guard."""
    from axi import store

    ent = identity.ensure_entity("losartán", "medication")
    fact = store.add_node("fact", "toma losartán por la mañana")
    _stored_edge(fact, ent, "mentions")
    before = _edge_count()

    identity.link_fact_to_entities(fact, "toma losartán por la mañana")

    assert _edge_count() == before


def test_link_fact_to_involved_person_dedupe_resolves_through_endpoint_uuids():
    """identity.py:612 — the fact--involves-->person duplicate guard."""
    from axi import store

    identity.add_relation("esposa", "Ana Ríos", "person")
    person = identity.ensure_entity("Ana Ríos", "person")
    fact = store.add_node("fact", "cumple años en marzo")
    _stored_edge(fact, person, "involves")
    before = _edge_count()

    identity.link_fact_to_involved_person(fact, "esposa")

    assert _edge_count() == before


def test_link_fact_to_user_dedupe_resolves_through_endpoint_uuids():
    """identity.py:644 — the hub--about-->fact duplicate guard."""
    from axi import store

    hub = identity.ensure_user_hub()
    fact = store.add_node("fact", "usa CachyOS")
    _stored_edge(hub, fact, "about")
    before = _edge_count()

    identity.link_fact_to_user(fact)

    assert _edge_count() == before


def test_backfill_subject_person_links_dedupe_resolves_through_endpoint_uuids():
    """identity.py:706 — the repair pass's own duplicate guard. Re-linking an
    already-linked fact is the one thing this deliberately-run repair must
    never do."""
    from axi import store

    identity.add_relation("esposa", "Ana Ríos", "person")
    person = identity.ensure_entity("Ana Ríos", "person")
    fact = store.add_node("fact", "cumple años en marzo", {"subject": "esposa"})
    _stored_edge(fact, person, "involves")

    assert identity.backfill_subject_person_links() == 0


def test_resolve_relation_person_resolves_through_endpoint_uuids():
    """identity.py:571-577 — resolving "esposa" to the person node walks the
    hub's outgoing edges, so it must walk them by uuid.

    The integer `to_id` this test used to desync is gone (PR8), so `dst_uuid`
    is the only thing that can answer. Asserted by moving it: the resolution
    follows the uuid endpoint and nothing else. Getting this wrong links the
    user's fact to the WRONG person — a wrong answer in their own memory, not
    a missing one.
    """
    from axi import store

    hub = identity.ensure_user_hub()
    ana = identity.ensure_entity("Ana Ríos", "person")
    decoy = identity.ensure_entity("Dra Tere", "person")
    eid = store.add_edge(hub, ana, "esposa")
    c = store._connect()

    assert identity._resolve_relation_person("esposa", hub, c) == ana
    c.execute(
        "UPDATE edges SET dst_uuid=(SELECT uuid FROM nodes WHERE id=?) WHERE id=?",
        (decoy, eid),
    )
    assert identity._resolve_relation_person("esposa", hub, c) == decoy


def test_identity_read_sites_identical_to_pre_rewrite_queries(pr6a_graph):
    """6a.5's "identical results on the seeded fixture": the shared existence
    guard and the relation resolver, compared against the literal pre-rewrite
    SQL over a graph containing a self-edge, a duplicate-kind pair, a
    tombstoned endpoint and a dangling one."""
    from axi import store

    c = store._connect()
    # The ghost is excluded on purpose and asserted separately below: it is
    # the ONE input on which the rewrite genuinely does not agree with the old
    # query, and hiding that inside a passing loop would be the dishonest way
    # to report it.
    ids = [i for k, i in pr6a_graph.items() if k != "ghost"]
    for a in ids:
        for b in ids:
            for kind in ("about", "mentions", "involves", "esposa", "same-day"):
                old = c.execute(
                    "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation=? LIMIT 1",
                    (a, b, kind),
                ).fetchone() is not None
                assert identity._edge_exists(c, a, b, kind) is old, (
                    f"identity._edge_exists({a}, {b}, {kind!r}) diverged"
                )

    for hub in ids:
        old_rows = c.execute(
            "SELECT e.relation AS rel, n.id AS to_id FROM edges e "
            "JOIN nodes n ON n.uuid = e.dst_uuid "
            "WHERE e.src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND n.kind = 'person'",
            (hub,),
        ).fetchall()
        expected = None
        for r in old_rows:
            if identity._norm(r["rel"] or "").replace(" ", "_") in \
                    identity._relation_terms("esposa"):
                expected = r["to_id"]
                break
        assert identity._resolve_relation_person("esposa", hub, c) == expected


def test_edge_exists_disagrees_only_for_an_endpoint_id_that_no_longer_exists(pr6a_graph):
    """The single documented behaviour change of 6a.5, pinned rather than hidden.

    The old guard matched on `to_id`, an integer the edge row still carried
    after its node row was gone. The new guard resolves the caller's id to a
    `uuid` first, and a deleted node has no uuid to resolve to — so the answer
    is False for a dangling endpoint.

    It is unreachable from every caller: all six call sites pass ids they just
    obtained from `ensure_entity`/`ensure_user_hub`/a node they created, so a
    caller cannot hold the id of a row that no longer exists. It is asserted
    here so the difference stays a stated property of the design rather than a
    surprise. PR8 note: the edge still carries the ghost's `src_uuid`/
    `dst_uuid` — that is the dangling endpoint mobile's model declares LEGAL,
    and `report_dangling_edges()` is what makes it visible instead of silent.
    """
    from axi import store

    c = store._connect()
    hub, ghost = pr6a_graph["hub"], pr6a_graph["ghost"]

    assert identity._edge_exists(c, hub, ghost, "about") is False
    assert any(f"id=" in line for line in store.report_dangling_edges()), (
        "the edge to the vanished node must be REPORTED, not silently ignored"
    )


# ═══════════════════════════════════════════════════════════════════════════
# PR7 — tombstones in the alias-merge path (tasks 7.7, 7.13) and the read
# filters that keep a tombstoned entity out of identity resolution.
# ═══════════════════════════════════════════════════════════════════════════


def _merge_fixture():
    """Two person nodes for the same human, plus edges on the LOSER.

    `register_alias` merges the node labelled with the alias into the canonical
    one: it rewrites both endpoint representations of every edge, then removes
    the loser. PR7 turns that removal into a tombstone.
    """
    from axi import store

    canonical = store.add_node("person", "Ana Ríos", {"entity": True})
    loser = store.add_node("person", "Ani", {"entity": True})
    hub = store.add_node("person", "Héctor", {"role": "user"})
    fact = store.add_node("fact", "cumple en mayo")
    e_in = store.add_edge(hub, loser, "esposa")      # loser as dst
    e_out = store.add_edge(loser, fact, "mentions")  # loser as src
    return {
        "canonical": canonical, "loser": loser, "hub": hub, "fact": fact,
        "e_in": e_in, "e_out": e_out,
    }


def test_alias_merge_tombstones_the_loser_node_instead_of_deleting_it():
    """7.7: the merged-away node row survives carrying `deleted_at`."""
    from axi import store

    f = _merge_fixture()
    identity.register_alias("Ana Ríos", "Ani", kind="person")

    row = store._connect().execute(
        "SELECT id, deleted_at FROM nodes WHERE id=?", (f["loser"],)
    ).fetchone()
    assert row is not None, "the alias-merge loser was hard-deleted"
    assert row["deleted_at"] is not None


def test_alias_merge_hard_deletes_the_loser_fts_and_vec_rows():
    """7.7: `nodes_fts` and `vec_nodes` stay HARD deletes — pinned deliberately.

    They are local derived state and are never synced. Leaving the FTS row
    behind is the named worst case: search would keep offering a node the
    graph has merged away.
    """
    from axi import store

    f = _merge_fixture()
    c = store._connect()
    store.create_vec_nodes_table(c)
    store.upsert_vec_node(c, node_id=f["loser"], vector=[0.2] * 512)

    identity.register_alias("Ana Ríos", "Ani", kind="person")

    assert c.execute(
        "SELECT count(*) FROM nodes_fts WHERE rowid=?", (f["loser"],)
    ).fetchone()[0] == 0, "the merged-away node kept its FTS row"
    assert c.execute(
        "SELECT count(*) FROM vec_nodes WHERE node_id=?", (f["loser"],)
    ).fetchone()[0] == 0, "the merged-away node kept its vec row"


def test_alias_merge_leaves_no_edge_pointing_at_the_tombstoned_loser():
    """7.13, half one: every edge now resolves to the SURVIVING node's uuid."""
    from axi import store

    f = _merge_fixture()
    identity.register_alias("Ana Ríos", "Ani", kind="person")

    c = store._connect()
    loser_uuid = c.execute(
        "SELECT uuid FROM nodes WHERE id=?", (f["loser"],)
    ).fetchone()[0]
    canonical_uuid = c.execute(
        "SELECT uuid FROM nodes WHERE id=?", (f["canonical"],)
    ).fetchone()[0]
    assert loser_uuid and canonical_uuid and loser_uuid != canonical_uuid

    stragglers = c.execute(
        "SELECT id, src_uuid, dst_uuid FROM edges "
        "WHERE src_uuid = ? OR dst_uuid = ?",
        (loser_uuid, loser_uuid),
    ).fetchall()
    assert stragglers == [], (
        "edges still point at the tombstoned loser: "
        + ", ".join(f"id={r[0]} src={r[1]!r} dst={r[2]!r}" for r in stragglers)
    )

    for eid, column in ((f["e_in"], "dst_uuid"), (f["e_out"], "src_uuid")):
        row = c.execute(
            f"SELECT {column} AS u FROM edges WHERE id=?", (eid,)
        ).fetchone()
        assert row["u"] == canonical_uuid, (
            f"edge id={eid} {column}={row['u']!r} expected={canonical_uuid!r}"
        )


def test_alias_merge_keeps_both_endpoint_representations_converged():
    """7.13, half two: `src_uuid`/`dst_uuid` still agree with `from_id`/`to_id`.

    Written with an explicit `IS NOT`-free comparison per side and an explicit
    NULL check, because a bare `IS NOT` predicate reads NULL-vs-NULL as
    agreement — the blind spot this chain has already been bitten by twice.
    """
    from axi import store

    f = _merge_fixture()
    identity.register_alias("Ana Ríos", "Ani", kind="person")

    c = store._connect()
    rows = c.execute(
        "SELECT e.id, e.src_uuid, n1.uuid AS n1u, e.dst_uuid, n2.uuid AS n2u "
        "FROM edges e "
        "JOIN nodes n1 ON n1.uuid = e.src_uuid "
        "JOIN nodes n2 ON n2.uuid = e.dst_uuid"
    ).fetchall()
    assert rows, "the fixture produced no edges to check"
    for r in rows:
        assert r["src_uuid"] is not None, f"edge id={r['id']} has a NULL src_uuid"
        assert r["dst_uuid"] is not None, f"edge id={r['id']} has a NULL dst_uuid"
        assert r["src_uuid"] == r["n1u"], (
            f"edge id={r['id']} src_uuid={r['src_uuid']!r} expected={r['n1u']!r}"
        )
        assert r["dst_uuid"] == r["n2u"], (
            f"edge id={r['id']} dst_uuid={r['dst_uuid']!r} expected={r['n2u']!r}"
        )

    # The standalone guard must agree, on the same database.
    store.verify_edge_endpoint_convergence()


def test_identity_edge_exists_ignores_a_tombstoned_edge():
    """A deleted relation must not stop the linkers from re-creating it.

    `_edge_exists` is the duplicate guard in front of every `add_*`/`link_*`
    helper. If it kept matching tombstones, a relation the user deleted could
    never come back and nothing would report why.
    """
    import time as _t

    from axi import store

    hub = store.add_node("person", "Héctor", {"role": "user"})
    ana = store.add_node("person", "Ana Ríos")
    eid = store.add_edge(hub, ana, "esposa")
    c = store._connect()
    assert identity._edge_exists(c, hub, ana, "esposa") is True

    c.execute(
        "UPDATE edges SET deleted_at=?, updated_at=? WHERE id=?", (_t.time(), _t.time(), eid)
    )
    assert identity._edge_exists(c, hub, ana, "esposa") is False


def test_entity_lookup_does_not_resurrect_a_tombstoned_person():
    """`ensure_entity` must not hand back a node the user deleted.

    Returning the tombstoned id would silently re-attach new facts to a memory
    that is supposed to be gone, and every one of them would then be invisible
    behind the same tombstone.
    """
    import time as _t

    from axi import store

    ana = identity.ensure_entity("Ana Ríos", "person")
    assert ana is not None
    store._connect().execute(
        "UPDATE nodes SET deleted_at=? WHERE id=?", (_t.time(), ana)
    )

    again = identity.ensure_entity("Ana Ríos", "person")
    assert again != ana
    assert store.get_node(again) is not None


def test_resolve_relation_person_skips_a_tombstoned_target():
    """A tombstoned person must not be the answer to "who is my esposa?"."""
    import time as _t

    from axi import store

    hub = store.add_node("person", "Héctor", {"role": "user"})
    ana = store.add_node("person", "Ana Ríos")
    store.add_edge(hub, ana, "esposa")
    c = store._connect()
    assert identity._resolve_relation_person("esposa", hub, c) == ana

    c.execute("UPDATE nodes SET deleted_at=? WHERE id=?", (_t.time(), ana))
    assert identity._resolve_relation_person("esposa", hub, c) is None


def test_find_hub_row_ignores_a_tombstoned_hub():
    """The hub guard refuses to delete the hub, so this can only arrive by sync.

    It must still not be resolved as the live hub: a tombstoned hub answering
    identity questions would attach the user's whole graph to a deleted node.
    """
    import time as _t

    from axi import store

    hub = store.add_node("person", "Héctor", {"role": "user"})
    c = store._connect()
    assert identity._find_hub_row(c) is not None

    c.execute("UPDATE nodes SET deleted_at=? WHERE id=?", (_t.time(), hub))
    assert identity._find_hub_row(c) is None
