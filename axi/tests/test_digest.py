"""Tests for the daily digest (P1.3)."""
from __future__ import annotations

import time

import pytest

from axi import digest, store


@pytest.fixture(autouse=True)
def _reset_digest_cache():
    digest._clear_cache_for_tests()
    yield
    digest._clear_cache_for_tests()


def test_empty_day():
    d = digest.build_today()
    assert d["conversations_count"] == 0
    assert d["meetings_count"] == 0
    assert d["facts_added_count"] == 0
    assert d["events_critical_count"] == 0
    assert d["events_error_count"] == 0
    assert d["top_facts"] == []
    assert d["generated_summary"] is None
    assert isinstance(d["date"], str) and len(d["date"]) == 10


def test_counts_reflect_today_activity():
    # Two conversation turns
    store.add_conversation("hola", "que tal", session_id="s1")
    store.add_conversation("otra", "respuesta", session_id="s1")
    # One meeting created today
    c = store._connect()
    now = time.time()
    c.execute(
        "INSERT INTO meetings(start_time, data_dir, status, created_at) "
        "VALUES (?, ?, 'done', ?)",
        (now, "/tmp/m1", now),
    )
    # Three facts created today
    for label in ("hecho 1", "hecho 2", "hecho 3"):
        store.add_node(kind="fact", label=label)

    d = digest.build_today()
    assert d["conversations_count"] == 2
    assert d["meetings_count"] == 1
    assert d["facts_added_count"] == 3
    assert {f["label"] for f in d["top_facts"]} == {"hecho 1", "hecho 2", "hecho 3"}


def test_summary_disabled_by_default(monkeypatch):
    # Even if brain were reachable, kill switch defaults to False.
    called = {"ask": 0}

    def fake_ask(*a, **kw):
        called["ask"] += 1
        return "should not be called"

    d = digest.build_today(brain_ask=fake_ask, brain_alive=lambda: True)
    assert d["generated_summary"] is None
    assert called["ask"] == 0


def test_summary_enabled_calls_brain(monkeypatch):
    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: True if key == "digest_brain_enabled" else default,
    )
    d = digest.build_today(
        brain_ask=lambda *a, **kw: "Resumen del día.",
        brain_alive=lambda: True,
    )
    assert d["generated_summary"] == "Resumen del día."


def test_summary_brain_down_returns_none(monkeypatch):
    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: True if key == "digest_brain_enabled" else default,
    )
    d = digest.build_today(
        brain_ask=lambda *a, **kw: "should not fire",
        brain_alive=lambda: False,
    )
    assert d["generated_summary"] is None
