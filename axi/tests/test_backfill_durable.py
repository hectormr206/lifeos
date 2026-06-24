"""Tests for backfill_all_domains durability — checkpoint before return.

TDD order: RED first, then GREEN after implementation.

Tasks covered:
  D.1 — backfill_all_domains calls store.checkpoint() after bridging
  D.2 — checkpoint failure does not suppress the result dict
  D.3 — CLI entrypoint (__main__) calls backfill_all_domains + checkpoint + close in order
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import patch, MagicMock, call


# ─── helpers ────────────────────────────────────────────────────────────────


@dataclass
class FakeEntry:
    """Minimal duck-typed domain entry for testing."""
    id: Any = "e-001"
    kind: str = "test"
    raw_utterance: str | None = None
    title: str | None = "Test entry"


# ═══════════════════════════════════════════════════════════════════════════
# D.1 — backfill_all_domains checkpoints before returning
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_all_domains_checkpoints_after_bridging():
    """D.1 RED — backfill_all_domains must call store.checkpoint() before returning.

    Strategy: patch _fetch_domain_entries to return one unbridged entry, patch
    create_fact_node_for_entry so no real DB write happens, patch store.checkpoint
    to a spy, then assert the spy was called exactly once.

    RED discriminator: current code has no checkpoint() call in backfill_all_domains,
    so this test fails until the checkpoint call is added.
    """
    from axi import domain_bridge

    checkpoint_calls: list[str] = []

    def spy_checkpoint():
        checkpoint_calls.append("checkpoint")

    fake_entry = FakeEntry(id="e-001", title="BP 120/80")

    def fake_fetch(domain, *, days, limit=None):
        if domain == "health":
            return [fake_entry]
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=fake_fetch), \
         patch("axi.store.get_node_for_domain_entry", return_value=None), \
         patch("axi.domain_bridge.create_fact_node_for_entry"), \
         patch("axi.store.checkpoint", side_effect=spy_checkpoint):
        result = domain_bridge.backfill_all_domains(
            days=1, node_limit=5, domains=["health"], sleep_s=0
        )

    assert "checkpoint" in checkpoint_calls, (
        "backfill_all_domains must call store.checkpoint() before returning; "
        f"got checkpoint_calls={checkpoint_calls!r}"
    )
    assert checkpoint_calls.count("checkpoint") == 1, (
        f"expected exactly one checkpoint call, got {checkpoint_calls.count('checkpoint')}"
    )
    assert result == {"health": 1}


def test_backfill_all_domains_checkpoints_even_when_no_entries_bridged():
    """D.1 triangulation — checkpoint is called even when all entries are already bridged.

    Ensures the checkpoint call is unconditional, not guarded by total_created > 0.
    """
    from axi import domain_bridge

    checkpoint_calls: list[str] = []

    def spy_checkpoint():
        checkpoint_calls.append("checkpoint")

    def fake_fetch(domain, *, days, limit=None):
        return []  # nothing pending

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=fake_fetch), \
         patch("axi.store.checkpoint", side_effect=spy_checkpoint):
        result = domain_bridge.backfill_all_domains(
            days=1, node_limit=5, domains=["health"], sleep_s=0
        )

    assert "checkpoint" in checkpoint_calls, (
        "checkpoint must be called even when 0 entries are bridged"
    )
    assert result == {"health": 0}


# ═══════════════════════════════════════════════════════════════════════════
# D.2 — checkpoint failure does not suppress the result dict
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_all_domains_returns_result_when_checkpoint_raises():
    """D.2 RED — if store.checkpoint() raises, backfill_all_domains still returns results.

    Strategy: patch checkpoint to raise RuntimeError.  Assert that:
    - No exception propagates to the caller.
    - The per-domain result dict is still returned with correct counts.

    RED discriminator: if checkpoint is called without a try/except wrapper in
    backfill_all_domains, any exception from checkpoint would propagate and the
    test would see a RuntimeError instead of a clean return.
    """
    from axi import domain_bridge

    fake_entry = FakeEntry(id="e-002", title="HR 72")

    def fake_fetch(domain, *, days, limit=None):
        if domain == "health":
            return [fake_entry]
        return []

    def checkpoint_that_raises():
        raise RuntimeError("simulated checkpoint failure")

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=fake_fetch), \
         patch("axi.store.get_node_for_domain_entry", return_value=None), \
         patch("axi.domain_bridge.create_fact_node_for_entry"), \
         patch("axi.store.checkpoint", side_effect=checkpoint_that_raises):
        # Must NOT raise:
        result = domain_bridge.backfill_all_domains(
            days=1, node_limit=5, domains=["health"], sleep_s=0
        )

    assert result == {"health": 1}, (
        "result dict must be returned even when checkpoint raises; "
        f"got {result!r}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# D.3 — CLI __main__ entrypoint calls backfill + checkpoint + close in order
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_main_calls_backfill_then_checkpoint_then_close():
    """D.3 RED — axi.backfill __main__ module calls backfill_all_domains,
    then store.checkpoint(), then store.close(), in that order.

    Strategy: import axi.backfill (the new CLI module), patch all three
    callables, run its main() function, and assert the call order.

    RED discriminator: the module does not exist yet — ImportError is the
    initial RED signal (or, once the module exists, the order assertion fails
    if the module omits checkpoint or close).
    """
    import axi.backfill as backfill_mod

    call_order: list[str] = []

    def fake_backfill(**kwargs):
        call_order.append("backfill")
        return {"health": 3, "relationships": 0}

    def fake_checkpoint():
        call_order.append("checkpoint")

    def fake_close():
        call_order.append("close")

    with patch("axi.backfill.backfill_all_domains", side_effect=fake_backfill), \
         patch("axi.backfill.store") as mock_store:
        mock_store.checkpoint.side_effect = fake_checkpoint
        mock_store.close.side_effect = fake_close
        backfill_mod.main([])

    assert call_order == ["backfill", "checkpoint", "close"], (
        f"expected [backfill, checkpoint, close] in order, got {call_order}"
    )
