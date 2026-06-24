"""Tests for the backfill CLI argument handling and defaults.

The CLI previously hardcoded days=90 / node_limit=500, so a one-shot run could
not capture older history and could not be overridden without editing source.
"""
from __future__ import annotations

from axi import backfill


def test_default_days_covers_full_history():
    # 90 days dropped everything older than a quarter; a one-shot backfill
    # should reach all practical history by default.
    assert backfill._DEFAULT_DAYS >= 3650


def test_default_node_limit_is_unbounded():
    # Round-robin fairness makes an unbounded run safe; the default should
    # bridge everything rather than stopping at a small cap.
    assert backfill._DEFAULT_NODE_LIMIT is None


def test_main_passes_parsed_args_to_backfill(monkeypatch):
    captured: dict = {}

    def _fake_backfill(*, days, node_limit, sleep_s):
        captured["days"] = days
        captured["node_limit"] = node_limit
        return {}

    monkeypatch.setattr(backfill, "backfill_all_domains", _fake_backfill)
    monkeypatch.setattr(backfill.store, "checkpoint", lambda: None)
    monkeypatch.setattr(backfill.store, "close", lambda: None)
    monkeypatch.setattr(backfill, "setup_logging", lambda: None, raising=False)

    backfill.main(["--days", "5", "--node-limit", "10"])

    assert captured["days"] == 5
    assert captured["node_limit"] == 10
