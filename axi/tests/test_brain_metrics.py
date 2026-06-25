"""Tests for P0.2 — brain latency & cost metrics.

Covers:
- Store round-trip (insert / recent / trim).
- `brain.ask` wrapper: kill switch skips metric, records on success and on
  error (re-raising the exception), and extracts token usage when present.
"""
from __future__ import annotations

import io
import json
import time
from unittest.mock import patch

import pytest

from axi import brain, config, store


# ───────────────────────── store layer ─────────────────────────


def test_insert_brain_metric_round_trip():
    ts = time.time()
    store.insert_brain_metric(
        ts=ts, latency_ms=123, model="qwen3",
        prompt_tokens=10, completion_tokens=20, total_tokens=30,
        ok=1, error=None,
    )
    rows = store.recent_brain_metrics(limit=10)
    assert len(rows) == 1
    r = rows[0]
    assert r["latency_ms"] == 123
    assert r["model"] == "qwen3"
    assert r["prompt_tokens"] == 10
    assert r["completion_tokens"] == 20
    assert r["total_tokens"] == 30
    assert r["ok"] == 1
    assert r["error"] is None


def test_recent_brain_metrics_filter_by_since_ts():
    now = time.time()
    # Three rows: one old, two recent.
    store.insert_brain_metric(now - 3600, 100, None, None, None, None, 1, None)
    store.insert_brain_metric(now - 10, 200, None, None, None, None, 1, None)
    store.insert_brain_metric(now - 1, 300, None, None, None, None, 1, None)

    all_rows = store.recent_brain_metrics(limit=10)
    assert len(all_rows) == 3

    recent = store.recent_brain_metrics(limit=10, since_ts=now - 60)
    assert len(recent) == 2
    assert all(r["ts"] >= now - 60 for r in recent)


def test_trim_brain_metrics_keeps_n_rows():
    for i in range(20):
        store.insert_brain_metric(time.time() + i, i, None, None, None, None, 1, None)
    store.trim_brain_metrics(keep=5)
    rows = store.recent_brain_metrics(limit=100)
    assert len(rows) == 5
    # Newest five preserved (ts incremented by i).
    latencies = [r["latency_ms"] for r in rows]
    assert sorted(latencies, reverse=True) == latencies
    assert min(latencies) == 15


# ───────────────────────── brain.ask wrapper ─────────────────────────


def _flush_metric_threads(timeout: float = 2.0) -> None:
    """Wait for daemon metric-writer threads to drain."""
    import threading
    deadline = time.time() + timeout
    while time.time() < deadline:
        active = [
            t for t in threading.enumerate()
            if t.name == "axi-brain-metric" and t.is_alive()
        ]
        if not active:
            return
        time.sleep(0.02)


def test_ask_records_metric_with_usage_tokens(monkeypatch):
    monkeypatch.setattr(config, "get", lambda k, default=None: True if k == "brain_metrics_enabled" else default)
    monkeypatch.setattr(brain, "_BG_WORKERS_DISABLED", False)  # test requires metric threads

    def fake_impl(prompt, **kw):
        return "hola", {
            "model": "qwen3-test",
            "usage": {"prompt_tokens": 11, "completion_tokens": 22, "total_tokens": 33},
            "choices": [{"message": {"content": "hola"}}],
        }

    monkeypatch.setattr(brain, "_ask_impl", fake_impl)
    out = brain.ask("ping")
    assert out == "hola"
    _flush_metric_threads()

    rows = store.recent_brain_metrics(limit=5)
    assert len(rows) == 1
    r = rows[0]
    assert r["ok"] == 1
    assert r["error"] is None
    assert r["model"] == "qwen3-test"
    assert r["prompt_tokens"] == 11
    assert r["completion_tokens"] == 22
    assert r["total_tokens"] == 33
    assert isinstance(r["latency_ms"], int)


def test_ask_records_null_usage_when_absent(monkeypatch):
    monkeypatch.setattr(config, "get", lambda k, default=None: True if k == "brain_metrics_enabled" else default)
    monkeypatch.setattr(brain, "_BG_WORKERS_DISABLED", False)  # test requires metric threads

    def fake_impl(prompt, **kw):
        return "ok", {"choices": [{"message": {"content": "ok"}}]}

    monkeypatch.setattr(brain, "_ask_impl", fake_impl)
    brain.ask("ping")
    _flush_metric_threads()

    rows = store.recent_brain_metrics(limit=5)
    assert len(rows) == 1
    r = rows[0]
    assert r["ok"] == 1
    assert r["prompt_tokens"] is None
    assert r["completion_tokens"] is None
    assert r["total_tokens"] is None
    assert r["model"] is None


def test_ask_records_metric_on_error_and_reraises(monkeypatch):
    monkeypatch.setattr(config, "get", lambda k, default=None: True if k == "brain_metrics_enabled" else default)
    monkeypatch.setattr(brain, "_BG_WORKERS_DISABLED", False)  # test requires metric threads

    def boom(prompt, **kw):
        raise RuntimeError("brain exploded")

    monkeypatch.setattr(brain, "_ask_impl", boom)
    with pytest.raises(RuntimeError, match="brain exploded"):
        brain.ask("ping")
    _flush_metric_threads()

    rows = store.recent_brain_metrics(limit=5)
    assert len(rows) == 1
    r = rows[0]
    assert r["ok"] == 0
    assert r["error"] is not None
    assert "brain exploded" in r["error"]


def test_ask_kill_switch_skips_metric(monkeypatch):
    # brain_metrics_enabled=False → no rows written.
    def fake_get(k, default=None):
        if k == "brain_metrics_enabled":
            return False
        return default

    monkeypatch.setattr(config, "get", fake_get)

    def fake_impl(prompt, **kw):
        return "ok", {"usage": {"total_tokens": 5}}

    monkeypatch.setattr(brain, "_ask_impl", fake_impl)
    brain.ask("ping")
    _flush_metric_threads()

    rows = store.recent_brain_metrics(limit=5)
    assert rows == []
