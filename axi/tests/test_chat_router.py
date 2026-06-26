"""General-chat auto-router: picks a domain (from the registry) and dispatches
to its spec, or yields to the general brain."""
from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

from axi import chat_router, finance_chat

NOW = datetime(2026, 6, 26, 12, 0, tzinfo=ZoneInfo("America/Mexico_City"))


class _Entry:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _brain(*, router_returns, extract=None, query_answer="ok"):
    """Fake brain: the router call (system mentions 'enrutador') returns the
    domain key; think=True is the query call; otherwise the domain extractor."""
    def _ask(text, *, system=None, think=False, max_tokens=0):
        if system and "enrutador" in system:
            return router_returns
        if think:
            return query_answer
        return extract or "{}"
    return _ask


def test_classify_returns_general_for_unknown(monkeypatch):
    assert chat_router.classify_domain("hola", _brain(router_returns="banana")) == "general"
    assert chat_router.classify_domain("hola", _brain(router_returns="general")) == "general"


def test_classify_returns_registered_key():
    assert chat_router.classify_domain("gasté 200", _brain(router_returns="finance")) == "finance"
    assert chat_router.classify_domain("glucosa 90", _brain(router_returns="health")) == "health"


def test_route_dispatches_to_finance(monkeypatch):
    created: list = []
    monkeypatch.setattr(finance_chat.finance_entries, "create",
                        lambda **kw: created.append(kw) or _Entry(id="F1", **kw))
    extract = json.dumps({"intent": "register", "kind": "expense", "amount": 200,
                          "currency": "MXN", "category": "comida", "merchant": None,
                          "title": "súper"})
    res = chat_router.route_and_handle(
        "gasté 200 en el súper", NOW,
        brain_ask=_brain(router_returns="finance", extract=extract),
    )
    assert res is not None
    assert res["domain"] == "finance"
    assert res["mode"] == "register"
    assert created[0]["kind"] == "expense"


def test_classify_returns_uncertain():
    assert chat_router.classify_domain("dato ambiguo", _brain(router_returns="uncertain")) == "uncertain"


def test_route_returns_clarify_when_uncertain():
    res = chat_router.route_and_handle(
        "me pasó algo importante hoy", NOW, brain_ask=_brain(router_returns="uncertain"),
    )
    assert res is not None
    assert res["mode"] == "clarify"
    assert res["original_text"] == "me pasó algo importante hoy"
    assert res["options"]                                  # has domain options
    assert any(o["key"] == "health" for o in res["options"])
    assert all("key" in o and "name" in o for o in res["options"])


def test_route_yields_to_general_when_classified_general():
    res = chat_router.route_and_handle(
        "contame un chiste", NOW, brain_ask=_brain(router_returns="general"),
    )
    assert res is None


def test_route_yields_when_domain_says_off_topic():
    # Router guessed finance, but the finance spec classifies it off_topic →
    # the router must yield (None) so the general brain handles it.
    extract = json.dumps({"intent": "off_topic"})
    res = chat_router.route_and_handle(
        "hoy medité", NOW,
        brain_ask=_brain(router_returns="finance", extract=extract),
    )
    assert res is None
