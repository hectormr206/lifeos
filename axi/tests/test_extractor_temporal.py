"""Tests for temporal / status / prescription fact capture in the extractor.

Goal: the extractor must keep NARRATIVE health/finance facts (diagnoses,
medications + doses, treatment status, temporal qualifiers, doctors) as durable
graph facts, while still skipping pure numeric vitals that the domain bridge
already logs. The LLM is mocked; the DB is the per-test isolated temp store
(see conftest.fresh_db).
"""
from __future__ import annotations

import pytest


# ─────────────────────────────────────────────────────────────────────────────
# _is_logged_vital — the narrowed skip rule
# ─────────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "label",
    [
        "presión 120/80",
        "glucosa 95",
        "peso 64",
        "dormí 7h",
        "114/81",
    ],
)
def test_is_logged_vital_true_for_numeric_vitals(label):
    from axi.extractor import _is_logged_vital

    assert _is_logged_vital(label, "health", "health") is True


@pytest.mark.parametrize(
    "label",
    [
        "Hipertensión diagnosticada hace ~2 años (≈2024)",
        "Le recetaron media pastilla de losartán 50 mg (suspendido)",
        "hipertensión",
        "Esposa: Celia García Mateo (civil 06/09/2018, iglesia 26/01/2019)",
        "Hipertensión estable sin medicamento, automonitoreo matutino",
    ],
)
def test_is_logged_vital_false_for_narrative_facts(label):
    from axi.extractor import _is_logged_vital

    assert _is_logged_vital(label, "health", "health") is False


# ─────────────────────────────────────────────────────────────────────────────
# extract_and_store — narrative health facts survive, vitals skipped
# ─────────────────────────────────────────────────────────────────────────────


_FAKE_RESPONSE = """{
  "facts": [
    {"kind": "health", "label": "Hipertensión diagnosticada hace ~2 años (≈2024) por la Dra. Tere", "data": {}, "domain": "health"},
    {"kind": "health", "label": "Le recetaron media pastilla de losartán 50 mg (suspendido)", "data": {}, "domain": "health"},
    {"kind": "health", "label": "Hipertensión estable sin medicamento, automonitoreo matutino", "data": {}, "domain": "health"},
    {"kind": "health", "label": "presión 120/80", "data": {}, "domain": "health"}
  ],
  "relations": [
    {"subject": "Héctor", "subject_kind": "person", "relation": "padece", "object": "hipertensión", "object_kind": "condition", "aliases": []},
    {"subject": "hipertensión", "subject_kind": "condition", "relation": "diagnosticada_por", "object": "Dra. Tere", "object_kind": "person", "aliases": []},
    {"subject": "hipertensión", "subject_kind": "condition", "relation": "tratada_con", "object": "losartán", "object_kind": "medication", "aliases": []}
  ]
}"""


def _config_on(monkeypatch):
    from axi import config

    monkeypatch.setattr(
        config, "get",
        lambda k, d=None: True if k == "graph_bridge_chat_facts" else (d if d is not None else "America/Mexico_City"),
    )


def test_extract_keeps_narrative_health_facts_and_skips_vital(monkeypatch):
    from axi import extractor, store

    _config_on(monkeypatch)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: _FAKE_RESPONSE)

    n = extractor.extract_and_store(
        "hace mas de 2 años la Dra Tere me diagnosticó hipertensión, me recetó media "
        "pastilla de losartán de 50 mg pero la dejé y estoy estable sin medicamento",
        "Entendido.",
        None,
    )

    # 3 narrative facts saved, the numeric vital "presión 120/80" skipped.
    assert n == 3

    conn = store._connect()
    labels = {
        r["label"]
        for r in conn.execute("SELECT label FROM nodes WHERE kind='fact'").fetchall()
    }
    assert "Hipertensión diagnosticada hace ~2 años (≈2024) por la Dra. Tere" in labels
    assert "Le recetaron media pastilla de losartán 50 mg (suspendido)" in labels
    assert "Hipertensión estable sin medicamento, automonitoreo matutino" in labels
    assert "presión 120/80" not in labels  # logged vital → skipped


def test_temporal_fact_linked_to_user_and_entities(monkeypatch):
    from axi import extractor, store

    _config_on(monkeypatch)
    monkeypatch.setattr(extractor, "brain_ask", lambda **kw: _FAKE_RESPONSE)
    extractor.extract_and_store("diagnóstico", "ok", None)

    conn = store._connect()
    row = conn.execute(
        "SELECT id FROM nodes WHERE kind='fact' AND label LIKE 'Hipertensión diagnosticada%'"
    ).fetchone()
    assert row is not None
    fact_id = row["id"]

    # Linked to the user hub (edge kind 'about', hub -> fact).
    about = conn.execute(
        "SELECT 1 FROM edges WHERE to_id=? AND kind='about' LIMIT 1", (fact_id,)
    ).fetchone()
    assert about is not None, "temporal fact must be linked to the user hub"

    # Linked to the hipertensión entity (edge kind 'mentions').
    hyp = conn.execute(
        "SELECT id FROM nodes WHERE kind='condition' AND label LIKE 'hipertensi%'"
    ).fetchone()
    assert hyp is not None, "hipertensión entity must exist from the relations"
    mentions = conn.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='mentions' LIMIT 1",
        (fact_id, hyp["id"]),
    ).fetchone()
    assert mentions is not None, "temporal fact must mention the hipertensión entity"


# ─────────────────────────────────────────────────────────────────────────────
# Retrieval sanity — a temporal fact mentioning a condition entity links to it
# ─────────────────────────────────────────────────────────────────────────────


def test_link_fact_to_entities_covers_condition_entities(monkeypatch):
    from axi import identity, store

    # Create the hipertensión condition entity (as the relations pipeline would).
    identity.add_entity_relation(
        "Héctor", "padece", "hipertensión",
        subject_kind="person", object_kind="condition",
    )
    fact_id = store.add_node(
        kind="fact",
        label="Hipertensión diagnosticada hace ~2 años (≈2024)",
        data={"category": "health"},
        domain="health",
    )
    identity.link_fact_to_entities(fact_id, "Hipertensión diagnosticada hace ~2 años (≈2024)")

    conn = store._connect()
    hyp = conn.execute(
        "SELECT id FROM nodes WHERE kind='condition' AND label LIKE 'hipertensi%'"
    ).fetchone()
    assert hyp is not None
    mentions = conn.execute(
        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='mentions' LIMIT 1",
        (fact_id, hyp["id"]),
    ).fetchone()
    assert mentions is not None, (
        "link_fact_to_entities must connect facts to condition/medication entities, "
        "not only person/place/org"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Prompt — temporal/status/prescription guidance + example + current date
# ─────────────────────────────────────────────────────────────────────────────


def test_extractor_prompt_has_temporal_status_guidance():
    from axi.extractor import _build_extractor_system

    sys = _build_extractor_system("2026-06-30")
    low = sys.lower()
    assert "hace ~2 años" in low or "hace ~" in low
    assert "suspend" in low  # medication status guidance
    assert "recet" in low    # prescription-as-history guidance
    # The hypertension worked example is present.
    assert "hipertensión" in low
    assert "losartán" in low


def test_extractor_prompt_injects_current_date():
    from axi.extractor import _build_extractor_system

    sys = _build_extractor_system("2024-06-30")
    assert "2024-06-30" in sys


def test_extract_and_store_threads_today_into_prompt(monkeypatch):
    from axi import extractor

    _config_on(monkeypatch)
    captured = {}

    def _capture(**kw):
        captured["system"] = kw.get("system", "")
        return '{"facts": [], "relations": []}'

    monkeypatch.setattr(extractor, "brain_ask", _capture)
    extractor.extract_and_store("hola", "qué tal", None)

    import datetime
    from zoneinfo import ZoneInfo
    today = datetime.datetime.now(ZoneInfo("America/Mexico_City")).strftime("%Y-%m-%d")
    assert today in captured["system"], "today's date must be threaded into the extractor prompt"
