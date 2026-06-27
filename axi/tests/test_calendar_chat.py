"""CALENDARIO domain chat — tests covering event creation and date handling."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from axi import domain_chat
from axi.calendar_chat import CALENDAR_SPEC

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Event:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _brain(extract_json):
    def _ask(text, *, system=None, think=False, max_tokens=0):
        return "respuesta" if think else extract_json
    return _ask


def _extract(**fields):
    base = {"intent": None, "kind": None, "title": None, "date": None}
    base.update(fields)
    return json.dumps(base)


def _patch_events(monkeypatch):
    from axi import calendar_chat
    created: list = []
    monkeypatch.setattr(
        calendar_chat.events_entries, "create",
        lambda **kw: created.append(kw) or _Event(id="EV1", **kw),
    )
    monkeypatch.setattr(
        calendar_chat.events_entries, "list_recent",
        lambda **kw: [],
    )
    return created


def test_register_with_explicit_date_sets_event_when(monkeypatch):
    """When an ISO date is extracted, the event's `when` should use that date (noon UTC)."""
    created = _patch_events(monkeypatch)

    res = domain_chat.handle_message(
        CALENDAR_SPEC, "tengo viaje el 2026-07-15", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="travel",
                                  title="viaje", date="2026-07-15")),
    )

    assert res["mode"] == "register"
    assert "Calendario" in res["answer"]
    assert len(created) == 1
    # The when should be 2026-07-15 at noon UTC, NOT the NOW fixture
    ev_when = created[0]["when"]
    assert ev_when.year == 2026
    assert ev_when.month == 7
    assert ev_when.day == 15
    assert ev_when.hour == 12
    assert ev_when.tzinfo is not None


def test_register_without_date_falls_back_to_now(monkeypatch):
    """When no date is extracted, the engine's `now` is used as the event timestamp."""
    created = _patch_events(monkeypatch)

    res = domain_chat.handle_message(
        CALENDAR_SPEC, "cumpleaños de mamá el viernes", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="birthday",
                                  title="cumpleaños mamá", date=None)),
    )

    assert res["mode"] == "register"
    assert len(created) == 1
    ev_when = created[0]["when"]
    # Should match NOW (engine-provided when, no event_date override)
    assert ev_when == NOW


def test_register_invalid_date_falls_back_to_now(monkeypatch):
    """A malformed date string falls back gracefully to now rather than crashing."""
    created = _patch_events(monkeypatch)

    res = domain_chat.handle_message(
        CALENDAR_SPEC, "reunión el próximo lunes", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="meeting",
                                  title="reunión", date="not-a-date")),
    )

    assert res["mode"] == "register"
    assert created[0]["when"] == NOW


def test_register_invalid_kind_falls_back(monkeypatch):
    """An unrecognised kind falls back to 'other'."""
    created = _patch_events(monkeypatch)

    domain_chat.handle_message(
        CALENDAR_SPEC, "evento raro", now=NOW,
        brain_ask=_brain(_extract(intent="register", kind="concierto",
                                  title="evento raro")),
    )

    assert created[0]["kind"] == "other"


def test_off_topic_saves_nothing(monkeypatch):
    """off_topic must not call events_entries.create."""
    from axi import calendar_chat

    calls: list = []
    monkeypatch.setattr(calendar_chat.events_entries, "create", lambda **kw: calls.append(kw))

    res = domain_chat.handle_message(
        CALENDAR_SPEC, "medité 20 minutos", now=NOW,
        brain_ask=_brain(_extract(intent="off_topic")),
    )

    assert res["mode"] == "off_topic"
    assert calls == []
