"""Unit tests for `axi.pairing` — in-memory pairing-code sessions (M0-5,
design D6: "pairing code 5-min TTL, single-use, in-memory").

Pure unit tests, no FastAPI/TestClient involved: the module has no I/O and
must never persist a code to disk (only the resulting device bearer token,
hashed, is ever persisted — via store.device_add, a later step).
"""
from __future__ import annotations

import pytest

from axi import pairing


@pytest.fixture(autouse=True)
def _reset_pairing_state():
    """Isolate every test from codes minted by other tests in this module."""
    pairing._reset_for_tests()
    yield
    pairing._reset_for_tests()


def test_create_code_returns_code_and_expiry():
    session = pairing.create_code()
    assert isinstance(session["code"], str) and session["code"]
    assert isinstance(session["expires_at"], float)


def test_create_code_ttl_is_five_minutes():
    before = pairing.time.time()
    session = pairing.create_code()
    assert 299 <= (session["expires_at"] - before) <= 301


def test_create_code_is_unique_per_call():
    a = pairing.create_code()
    b = pairing.create_code()
    assert a["code"] != b["code"]


def test_redeem_code_valid_once():
    session = pairing.create_code()
    assert pairing.redeem_code(session["code"]) is True


def test_redeem_code_second_use_fails():
    session = pairing.create_code()
    assert pairing.redeem_code(session["code"]) is True
    assert pairing.redeem_code(session["code"]) is False


def test_redeem_code_unknown_fails():
    assert pairing.redeem_code("not-a-real-code") is False


def test_redeem_code_empty_string_fails():
    assert pairing.redeem_code("") is False


def test_redeem_code_none_fails():
    assert pairing.redeem_code(None) is False


def test_redeem_code_expired_fails(monkeypatch):
    session = pairing.create_code()
    # Jump the module's clock past the 5-minute TTL.
    monkeypatch.setattr(
        pairing.time, "time", lambda: session["expires_at"] + 1
    )
    assert pairing.redeem_code(session["code"]) is False
