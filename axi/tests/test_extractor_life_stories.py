"""Tests for life-story fact capture in the chat extractor.

Goal: long narrative messages about Héctor's PEOPLE (family/friends/colleagues)
and their events/plans must reliably land in the knowledge graph — with
deterministic decoding (temperature=0.0, seed=0), an 800-token budget, exact
kinship predicates, and no invented relations. The LLM is mocked; the DB is
the per-test isolated temp store (see conftest.fresh_db).
"""
from __future__ import annotations


def _config_on(monkeypatch):
    from axi import config

    monkeypatch.setattr(
        config, "get",
        lambda k, d=None: True if k == "graph_bridge_chat_facts" else (d if d is not None else "America/Mexico_City"),
    )


_EMPTY_RESPONSE = '{"facts": [], "relations": []}'

# The exact shape the live 4B produces for the taquería message with the
# upgraded prompt (verified deterministic with temperature=0.0, seed=0).
_LIFE_STORY_RESPONSE = """{
  "facts": [
    {"kind": "biographical", "label": "Primo Rodrigo Zetina abrió una taquería en Querétaro (≈2026)", "data": {}, "domain": "personal"},
    {"kind": "plan", "label": "Invitado a la inauguración de la taquería de Rodrigo Zetina el 15/08/2026", "data": {}, "domain": "personal"}
  ],
  "relations": [
    {"subject": "Héctor", "subject_kind": "person", "relation": "primo", "object": "Rodrigo Zetina", "object_kind": "person", "aliases": []},
    {"subject": "Rodrigo Zetina", "subject_kind": "person", "relation": "dueño_de", "object": "taquería en Querétaro", "object_kind": "place", "aliases": []}
  ]
}"""


# ─────────────────────────────────────────────────────────────────────────────
# Deterministic decoding — temperature/seed/max_tokens forwarded to brain_ask
# ─────────────────────────────────────────────────────────────────────────────


def test_extract_calls_brain_with_deterministic_params(monkeypatch):
    from axi import extractor

    _config_on(monkeypatch)
    calls: list[dict] = []

    def _recorder(**kw):
        calls.append(kw)
        return _EMPTY_RESPONSE

    monkeypatch.setattr(extractor, "brain_ask", _recorder)
    extractor.extract_and_store("hola", "hola", None)

    assert len(calls) == 1
    kw = calls[0]
    assert kw["temperature"] == 0.0
    assert kw["seed"] == 0
    assert kw["max_tokens"] == 800


def test_brain_base_payload_forwards_temperature_and_seed():
    from axi.brain import _base_payload

    msgs = [{"role": "user", "content": "x"}]
    payload = _base_payload(msgs, max_tokens=800, think=False, temperature=0.0, seed=0)
    assert payload["temperature"] == 0.0
    assert payload["seed"] == 0
    assert payload["max_tokens"] == 800


def test_brain_base_payload_defaults_unchanged_when_overrides_none():
    from axi.brain import _base_payload

    msgs = [{"role": "user", "content": "x"}]
    payload = _base_payload(msgs, max_tokens=512, think=False)
    # 4B engine defaults (benchmark #555) stay intact for existing callers.
    assert payload["temperature"] == 0.7
    assert "seed" not in payload


# ─────────────────────────────────────────────────────────────────────────────
# Prompt contract — life-story rules present in the system template
# ─────────────────────────────────────────────────────────────────────────────


def test_prompt_has_life_story_rule_and_few_shot():
    from axi.extractor import _EXTRACTOR_SYSTEM_TEMPLATE as t

    assert "RELATOS DE VIDA" in t
    assert "EJEMPLO RELATO DE VIDA" in t
    # The few-shot teaches exact-date preservation and the target fact shapes.
    assert "15/08/2026" in t
    assert "Primo Rodrigo Zetina abrió una taquería" in t


def test_prompt_has_kinship_predicates_and_anti_invention_rules():
    from axi.extractor import _EXTRACTOR_SYSTEM_TEMPLATE as t

    # Kinship words enforced as predicates.
    for pred in ("primo", "prima", "tío", "tía", "cuñado", "vecino", "colega"):
        assert pred in t, f"predicate {pred!r} missing from typical-predicates list"
    # Anti-invention rule for relations.
    assert "SOLO relaciones dichas EXPLÍCITAMENTE" in t
    # Exact-bond rule: never downgrade a named kinship bond.
    assert "nunca la degrades" in t


# ─────────────────────────────────────────────────────────────────────────────
# Persistence — a mocked life-story extraction is fully stored
# ─────────────────────────────────────────────────────────────────────────────


def test_life_story_facts_and_relations_persisted(monkeypatch):
    from axi import extractor, store

    _config_on(monkeypatch)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: _LIFE_STORY_RESPONSE)

    n = extractor.extract_and_store(
        "Te cuento: mi primo Rodrigo Zetina abrió una taquería en Querétaro "
        "y me invitó a la inauguración el 15 de agosto",
        "¡Qué buena noticia!",
        None,
    )
    assert n == 2

    conn = store._connect()
    labels = {
        r["label"]
        for r in conn.execute("SELECT label FROM nodes WHERE kind='fact'").fetchall()
    }
    assert "Primo Rodrigo Zetina abrió una taquería en Querétaro (≈2026)" in labels
    assert "Invitado a la inauguración de la taquería de Rodrigo Zetina el 15/08/2026" in labels

    # Rodrigo Zetina exists as a person entity.
    rodrigo = conn.execute(
        "SELECT id FROM nodes WHERE kind='person' AND label='Rodrigo Zetina'"
    ).fetchone()
    assert rodrigo is not None, "Rodrigo Zetina entity must exist from the relations"

    # Héctor --primo--> Rodrigo Zetina (user-as-subject routes via the hub).
    primo_edge = conn.execute(
        "SELECT 1 FROM edges WHERE to_id=? AND kind='primo' LIMIT 1", (rodrigo["id"],)
    ).fetchone()
    assert primo_edge is not None, "primo edge to Rodrigo Zetina must exist"

    # Rodrigo Zetina --dueño_de--> taquería (entity-to-entity edge).
    taqueria = conn.execute(
        "SELECT id FROM nodes WHERE kind='place' AND label LIKE 'taquería%'"
    ).fetchone()
    assert taqueria is not None, "taquería place entity must exist"
    owner_edge = conn.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='dueño_de' LIMIT 1",
        (rodrigo["id"], taqueria["id"]),
    ).fetchone()
    assert owner_edge is not None, "dueño_de edge Rodrigo->taquería must exist"


def test_hallucinated_shape_stores_only_what_json_says(monkeypatch):
    """Malformed / partially hallucinated model output must not crash and must
    persist ONLY the valid entries the JSON actually contains."""
    from axi import extractor, store

    _config_on(monkeypatch)
    bad = """{
      "facts": [
        {"kind": "biographical", "label": "Primo Rodrigo Zetina abrió una taquería en Querétaro (≈2026)", "data": {}, "domain": "personal"},
        {"kind": "plan"},
        "not-a-dict",
        {"label": ""}
      ],
      "relations": [
        {"subject": "Héctor", "subject_kind": "person", "relation": "primo", "object": "Rodrigo Zetina", "object_kind": "person", "aliases": []},
        {"subject": "Héctor", "relation": "vive_en"},
        {"relation": ""},
        42
      ]
    }"""
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: bad)

    n = extractor.extract_and_store("mi primo Rodrigo abrió una taquería", "ok", None)
    assert n == 1  # only the one valid fact

    conn = store._connect()
    labels = {
        r["label"]
        for r in conn.execute("SELECT label FROM nodes WHERE kind='fact'").fetchall()
    }
    assert labels == {"Primo Rodrigo Zetina abrió una taquería en Querétaro (≈2026)"}

    # The valid relation persisted; the object-less vive_en triple did not.
    rodrigo = conn.execute(
        "SELECT id FROM nodes WHERE kind='person' AND label='Rodrigo Zetina'"
    ).fetchone()
    assert rodrigo is not None
    vive_en = conn.execute("SELECT 1 FROM edges WHERE kind='vive_en' LIMIT 1").fetchone()
    assert vive_en is None, "object-less vive_en relation must not create an edge"
