"""Unit tests for eval layer-dispatch routing (_route_predict).

These tests are PURE — no live nano server required.  The extractor and
parse_finance callables are injected so the routing logic can be verified
in isolation.
"""

from __future__ import annotations

from lifeos.agents.eval._run_eval import _route_predict
from lifeos.finance.ingestion import FinanceIntent


# ---------------------------------------------------------------------------
# Helpers / fakes
# ---------------------------------------------------------------------------

def _make_finance_intent() -> FinanceIntent:
    return FinanceIntent(kind="expense", title="super", amount=500.0)


def _fake_extractor_finance(text: str):
    """Simulates the nano returning a finance domain result."""
    class _Result:
        domain = "finance"
    return _Result()


def _fake_extractor_none(text: str):
    return None


def _fake_parse_finance_match(text: str) -> FinanceIntent:
    return _make_finance_intent()


def _fake_parse_finance_no_match(text: str) -> None:
    return None


# ---------------------------------------------------------------------------
# regex layer — must route through parse_finance, never extractor
# ---------------------------------------------------------------------------

def test_regex_layer_returns_finance_when_parse_matches():
    result = _route_predict(
        "Gasté 500 en el super",
        layer="regex",
        extract_fn=_fake_extractor_none,   # must NOT be called
        parse_fn=_fake_parse_finance_match,
    )
    assert result == "finance"


def test_regex_layer_returns_none_when_parse_no_match():
    result = _route_predict(
        "ok",
        layer="regex",
        extract_fn=_fake_extractor_none,
        parse_fn=_fake_parse_finance_no_match,
    )
    assert result is None


def test_regex_layer_does_not_call_extractor():
    """Extractor raises if called — ensures it is never invoked for regex cases."""
    def _boom(text: str):
        raise AssertionError("extractor must not be called for regex layer")

    result = _route_predict(
        "Gasté 500 en el super",
        layer="regex",
        extract_fn=_boom,
        parse_fn=_fake_parse_finance_match,
    )
    assert result == "finance"


# ---------------------------------------------------------------------------
# nano layer — must route through extractor, never parse_finance
# ---------------------------------------------------------------------------

def test_nano_layer_uses_extractor():
    result = _route_predict(
        "Corrí 5km",
        layer="nano",
        extract_fn=_fake_extractor_finance,
        parse_fn=lambda t: (_ for _ in ()).throw(AssertionError("parse_finance must not be called for nano layer")),
    )
    assert result == "finance"


def test_nano_layer_returns_none_when_extractor_none():
    result = _route_predict(
        "ok",
        layer="nano",
        extract_fn=_fake_extractor_none,
        parse_fn=_fake_parse_finance_match,  # must NOT be called, but safe if it were
    )
    assert result is None


# ---------------------------------------------------------------------------
# guard layer — same path as nano (uses extractor)
# ---------------------------------------------------------------------------

def test_guard_layer_uses_extractor():
    result = _route_predict(
        "x",
        layer="guard",
        extract_fn=_fake_extractor_finance,
        parse_fn=_fake_parse_finance_no_match,
    )
    assert result == "finance"
