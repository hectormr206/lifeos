"""RELACIONES domain chat — tests covering person resolution + interaction create."""
from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

from axi import domain_chat
from axi.relationships_chat import RELATIONSHIPS_SPEC

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Person:
    def __init__(self, pid="P1", name="Juan"):
        self.id = pid
        self.name = name


class _Interaction:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _brain(extract_json):
    def _ask(text, *, system=None, think=False, max_tokens=0, task=None):
        return "respuesta" if think else extract_json
    return _ask


def _extract(**fields):
    base = {"intent": None, "kind": None, "person": None, "role": None, "title": None}
    base.update(fields)
    return json.dumps(base)


def test_register_creates_interaction(monkeypatch):
    """register intent resolves person via get_or_create and calls interactions.create."""
    from axi import relationships_chat

    persons_created: list = []
    interactions_created: list = []

    person = _Person()

    monkeypatch.setattr(
        relationships_chat.people, "get_or_create",
        lambda name, role=None: persons_created.append(name) or person,
    )
    monkeypatch.setattr(
        relationships_chat.interactions, "create",
        lambda **kw: interactions_created.append(kw) or _Interaction(id="I1", **kw),
    )

    res = domain_chat.handle_message(
        RELATIONSHIPS_SPEC, "hablé con Juan esta tarde", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="conversation", person="Juan",
                                  title="hablé con Juan")),
    )

    assert res["mode"] == "register"
    assert "Relaciones" in res["answer"]
    assert len(interactions_created) == 1
    assert interactions_created[0]["person_id"] == "P1"
    assert interactions_created[0]["kind"] == "conversation"
    assert "Juan" in persons_created


def test_register_with_role_no_name(monkeypatch):
    """When person is empty but role is given, role becomes the person name."""
    from axi import relationships_chat

    persons_created: list = []
    interactions_created: list = []

    person = _Person(pid="P2", name="Mamá")

    monkeypatch.setattr(
        relationships_chat.people, "get_or_create",
        lambda name, role=None: persons_created.append(name) or person,
    )
    monkeypatch.setattr(
        relationships_chat.interactions, "create",
        lambda **kw: interactions_created.append(kw) or _Interaction(id="I2", **kw),
    )

    res = domain_chat.handle_message(
        RELATIONSHIPS_SPEC, "hablé con mi mamá", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="call", person="",
                                  role="mamá", title="llamé a mamá")),
    )

    assert res["mode"] == "register"
    assert interactions_created[0]["kind"] == "call"
    # Role "mamá" should be capitalized to "Mamá" as the person name
    assert persons_created[0] == "Mamá"


def test_invalid_kind_falls_back_to_default(monkeypatch):
    """An unrecognised kind falls back to 'conversation'."""
    from axi import relationships_chat

    interactions_created: list = []
    person = _Person()

    monkeypatch.setattr(
        relationships_chat.people, "get_or_create",
        lambda name, role=None: person,
    )
    monkeypatch.setattr(
        relationships_chat.interactions, "create",
        lambda **kw: interactions_created.append(kw) or _Interaction(id="I3", **kw),
    )

    domain_chat.handle_message(
        RELATIONSHIPS_SPEC, "algo con alguien", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="videoconferencia",
                                  person="Pedro", title="algo")),
    )

    assert interactions_created[0]["kind"] == "conversation"


def test_off_topic_saves_nothing(monkeypatch):
    """off_topic intent must not call interactions.create or people.get_or_create."""
    from axi import relationships_chat

    calls: list = []
    monkeypatch.setattr(
        relationships_chat.interactions, "create",
        lambda **kw: calls.append(kw),
    )
    monkeypatch.setattr(
        relationships_chat.people, "get_or_create",
        lambda name, role=None: calls.append(name),
    )

    res = domain_chat.handle_message(
        RELATIONSHIPS_SPEC, "gasté 200 pesos en el super", now=NOW,
        brain_ask=_brain(_extract(intent="off_topic")),
    )

    assert res["mode"] == "off_topic"
    assert calls == []
