"""Ejercicio: semi-quantitative domain (kind + duration) driven by the generic
engine via a store adapter."""
from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

from axi import domain_chat, exercise_chat
from axi.exercise_chat import EXERCISE_SPEC

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Sess:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _brain(extract_json, capture=None):
    def _ask(text, *, system=None, think=False, max_tokens=0):
        if capture is not None:
            capture.append({"think": think, "system": system})
        return "respuesta" if think else extract_json
    return _ask


def _extract(**fields):
    base = {"intent": None, "kind": None, "duration_minutes": None, "title": None}
    base.update(fields)
    return json.dumps(base)


def test_register_with_duration(monkeypatch):
    created: list = []
    monkeypatch.setattr(exercise_chat.ex_sessions, "create",
                        lambda **kw: created.append(kw) or _Sess(id="E1", **kw))
    res = domain_chat.handle_message(
        EXERCISE_SPEC, "corrí 30 minutos en el parque", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="run",
                                  duration_minutes=30, title="corrí en el parque")),
    )
    assert res["mode"] == "register"
    assert "Ejercicio" in res["answer"]
    assert created[0]["kind"] == "run"
    assert created[0]["duration_minutes"] == 30


def test_register_without_duration_defaults_zero(monkeypatch):
    created: list = []
    monkeypatch.setattr(exercise_chat.ex_sessions, "create",
                        lambda **kw: created.append(kw) or _Sess(id="E2", **kw))
    res = domain_chat.handle_message(
        EXERCISE_SPEC, "fui al gym", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="strength", title="gym")),
    )
    assert res["mode"] == "register"
    assert created[0]["duration_minutes"] == 0
    assert created[0]["kind"] == "strength"


def test_invalid_kind_falls_back_to_other(monkeypatch):
    created: list = []
    monkeypatch.setattr(exercise_chat.ex_sessions, "create",
                        lambda **kw: created.append(kw) or _Sess(id="E3", **kw))
    domain_chat.handle_message(
        EXERCISE_SPEC, "hice algo raro", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="banana", title="algo")),
    )
    assert created[0]["kind"] == "other"


def test_off_topic_saves_nothing(monkeypatch):
    created: list = []
    monkeypatch.setattr(exercise_chat.ex_sessions, "create",
                        lambda **kw: created.append(kw))
    res = domain_chat.handle_message(
        EXERCISE_SPEC, "gasté 200 pesos", now=NOW,
        brain_ask=_brain(_extract(intent="off_topic")),
    )
    assert res["mode"] == "off_topic"
    assert created == []
