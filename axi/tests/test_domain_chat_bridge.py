"""The generic domain_chat register lane MUST bridge each created entry into the
knowledge graph (best-effort), so autoroute + every domain-chat tab populate the
graph — not just the health-only fast-paths.

Covers both the matching-key case (finance → 'finance') and the KEY MISMATCH
case (calendar → 'lifeos-events'), and proves a bridge failure never breaks the
register (the store write remains the source of truth).
"""
from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

from axi import domain_bridge, domain_chat, finance_chat
from axi.calendar_chat import CALENDAR_SPEC
from axi.finance_chat import FINANCE_SPEC

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Entry:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _brain(extract_json):
    def _ask(text, *, system=None, think=False, max_tokens=0):
        return "respuesta" if think else extract_json
    return _ask


def _spy_bridge(monkeypatch):
    calls: list[tuple] = []
    monkeypatch.setattr(
        domain_bridge, "bridge_entry",
        lambda domain, entry: calls.append((domain, entry)) or 1,
    )
    return calls


def test_register_bridges_matching_key(monkeypatch):
    """finance's registry key already matches the bridge config key."""
    created: list = []
    monkeypatch.setattr(
        finance_chat.finance_entries, "create",
        lambda **kw: created.append(kw) or _Entry(id="F1", **kw),
    )
    calls = _spy_bridge(monkeypatch)

    base = {"intent": "register", "kind": "expense", "amount": 200,
            "currency": "MXN", "category": "comida", "merchant": None,
            "title": "súper"}
    res = domain_chat.handle_message(
        FINANCE_SPEC, "gasté 200 en el súper", now=NOW,
        brain_ask=_brain(json.dumps(base)),
    )

    assert res["mode"] == "register"
    assert len(created) == 1
    assert len(calls) == 1
    domain, entry = calls[0]
    assert domain == "finance"
    assert entry.id == "F1"


def test_register_bridges_calendar_under_lifeos_events(monkeypatch):
    """KEY MISMATCH: registry key 'calendar' must bridge under 'lifeos-events'."""
    from axi import calendar_chat
    created: list = []
    monkeypatch.setattr(
        calendar_chat.events_entries, "create",
        lambda **kw: created.append(kw) or _Entry(id="EV1", **kw),
    )
    calls = _spy_bridge(monkeypatch)

    res = domain_chat.handle_message(
        CALENDAR_SPEC, "tengo viaje el 2026-07-15", now=NOW,
        brain_ask=_brain(json.dumps(
            {"intent": "register", "kind": "travel",
             "title": "viaje", "date": "2026-07-15"})),
    )

    assert res["mode"] == "register"
    assert len(created) == 1
    assert len(calls) == 1
    domain, entry = calls[0]
    assert domain == "lifeos-events"
    assert entry.id == "EV1"


def test_bridge_failure_never_breaks_register(monkeypatch):
    """A bridge exception must be swallowed; the store write still succeeds."""
    created: list = []
    monkeypatch.setattr(
        finance_chat.finance_entries, "create",
        lambda **kw: created.append(kw) or _Entry(id="F1", **kw),
    )

    def _boom(domain, entry):
        raise RuntimeError("graph down")

    monkeypatch.setattr(domain_bridge, "bridge_entry", _boom)

    base = {"intent": "register", "kind": "expense", "amount": 200,
            "currency": "MXN", "category": "comida", "merchant": None,
            "title": "súper"}
    res = domain_chat.handle_message(
        FINANCE_SPEC, "gasté 200 en el súper", now=NOW,
        brain_ask=_brain(json.dumps(base)),
    )

    assert res["mode"] == "register"
    assert res["entry_ids"] == ["F1"]
    assert len(created) == 1  # store write survived the bridge failure
