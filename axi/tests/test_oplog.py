"""Tests for M0-8: oplog scaffolding (config flag + no-op emission point).

Design D8/D10 describe the full append-only oplog table, HLC ordering, and
hash-chain verification — that logic (and the `oplog` DB table) is M3 work,
gated by the spec's `sync-oplog [M3]` requirement. M0 ships ONLY:

  1. The `oplog_enabled` config flag (default False).
  2. A named, safe no-op emission point (`oplog.emit`) that leaf helpers can
     eventually call (per D10: "inside leaf helper bodies AFTER the
     maybe_forward gate") — wiring that call site into store.py and giving
     it a real sink is M3, not this task.

These tests pin the M0 contract: enabling the flag today has ZERO
observable effect, so it's safe to flip before M3 lands.
"""
from __future__ import annotations

from axi import config, oplog


def test_oplog_disabled_by_default():
    assert oplog.enabled() is False


def test_oplog_enabled_reads_config_flag():
    config.save({"oplog_enabled": True})
    assert oplog.enabled() is True
    config.save({"oplog_enabled": False})
    assert oplog.enabled() is False


def test_oplog_enabled_never_raises_on_config_failure(monkeypatch):
    def _boom(*a, **kw):
        raise RuntimeError("boom")

    monkeypatch.setattr(config, "get", _boom)
    assert oplog.enabled() is False


def test_emit_is_noop_when_disabled():
    config.save({"oplog_enabled": False})
    assert oplog.emit("health", "row-uuid-1", "insert", {"weight": 70}) is None


def test_emit_is_noop_even_when_enabled():
    """M0 stub: flipping the flag today has zero effect until M3 wires a sink."""
    config.save({"oplog_enabled": True})
    assert oplog.emit("health", "row-uuid-1", "insert", {"weight": 70}) is None
    config.save({"oplog_enabled": False})


def test_emit_accepts_no_payload():
    assert oplog.emit("health", "row-uuid-1", "soft_delete") is None


def test_emit_never_raises_on_bad_input():
    """Emission must never crash a caller — matches every other kill-switch
    gate in this codebase (events.py, write_router.py)."""
    assert oplog.emit("", "", "") is None
