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
    assert _coref_score("Ana García", "Ana Ríos") >= 0.9
    assert _coref_score("Ana Garcia", "Ana Ríos") >= 0.9  # accent-insensitive


def test_coref_score_low_for_different_people():
    from axi.identity import _coref_score
    assert _coref_score("Juan García", "Pedro García") < 0.7


def test_resolve_coreference_strong_merges():
    from axi.identity import _resolve_coreference
    row = {"id": 5, "label": "Ana Ríos"}
    cands = [(row, {"ana ríos"})]
    assert _resolve_coreference("Ana García", "person", cands) is row  # >=0.9, no LLM


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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='tratada_con'",
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
    n = c.execute("SELECT COUNT(*) AS n FROM edges WHERE kind='tratada_con'").fetchone()
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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='padece'",
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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='padece'",
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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='esposa'",
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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='padece'",
        (hub, cond["id"]),
    ).fetchone() is not None
    assert c.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='diagnosticada_por'",
        (cond["id"], doc["id"]),
    ).fetchone() is not None
    assert c.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='tratada_con'",
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
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='esposa'",
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
