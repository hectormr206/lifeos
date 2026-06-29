"""Tests for axi.identity — user-hub name extraction + onboarding guard."""
from __future__ import annotations

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
