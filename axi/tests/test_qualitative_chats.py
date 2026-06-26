"""Espiritualidad + Aprendizaje: qualitative domains driven by the generic
engine + the shared qualitative builders, from config alone."""
from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

from axi import domain_chat, learning_chat, spirituality_chat
from axi.learning_chat import LEARN_SPEC
from axi.spirituality_chat import SPIRIT_SPEC

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Entry:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _brain(extract_json, capture=None):
    def _ask(text, *, system=None, think=False, max_tokens=0):
        if capture is not None:
            capture.append({"think": think, "system": system})
        return "respuesta" if think else extract_json
    return _ask


def _extract(**fields):
    base = {"intent": None, "kind": None, "title": None}
    base.update(fields)
    return json.dumps(base)


def test_spirituality_register(monkeypatch):
    created: list = []
    monkeypatch.setattr(spirituality_chat.spirit_entries, "create",
                        lambda **kw: created.append(kw) or _Entry(id="S1", **kw))
    res = domain_chat.handle_message(
        SPIRIT_SPEC, "hoy medité 20 minutos", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="meditation", title="medité 20 min")),
    )
    assert res["mode"] == "register"
    assert "Espiritualidad" in res["answer"]
    assert created[0]["kind"] == "meditation"


def test_spirituality_invalid_kind_falls_back(monkeypatch):
    created: list = []
    monkeypatch.setattr(spirituality_chat.spirit_entries, "create",
                        lambda **kw: created.append(kw) or _Entry(id="S2", **kw))
    res = domain_chat.handle_message(
        SPIRIT_SPEC, "pensaba en la paciencia", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="banana", title="paciencia")),
    )
    assert res["mode"] == "register"
    assert created[0]["kind"] == "reflection"  # default for an invalid kind


def test_learning_register(monkeypatch):
    created: list = []
    monkeypatch.setattr(learning_chat.learn_entries, "create",
                        lambda **kw: created.append(kw) or _Entry(id="L1", **kw))
    res = domain_chat.handle_message(
        LEARN_SPEC, "empecé a leer Clean Code", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="book", title="Clean Code")),
    )
    assert res["mode"] == "register"
    assert "Aprendizaje" in res["answer"]
    assert created[0]["kind"] == "book"
    assert created[0]["title"] == "Clean Code"


def test_learning_query_passes_records(monkeypatch):
    capture: list = []
    recent = [_Entry(id="L9", ts=datetime(2026, 6, 1, tzinfo=ZoneInfo("UTC")),
                     kind="book", title="Clean Code")]
    monkeypatch.setattr(learning_chat.learn_entries, "list_recent", lambda **kw: recent)
    res = domain_chat.handle_message(
        LEARN_SPEC, "qué libros empecé", now=NOW,
        brain_ask=_brain(_extract(intent="query"), capture=capture),
    )
    assert res["mode"] == "query"
    qsys = [c for c in capture if c["think"]][0]["system"]
    assert "L9" in qsys and "Clean Code" in qsys


def test_off_topic_saves_nothing(monkeypatch):
    created: list = []
    monkeypatch.setattr(spirituality_chat.spirit_entries, "create",
                        lambda **kw: created.append(kw))
    res = domain_chat.handle_message(
        SPIRIT_SPEC, "gasté 200 pesos", now=NOW,
        brain_ask=_brain(_extract(intent="off_topic")),
    )
    assert res["mode"] == "off_topic"
    assert created == []
