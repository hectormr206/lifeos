"""Tests for the learned schedule-parse cache orchestrator.

`cached_or_brain_parse(text, tz, *, ask=...)` resolves a recurring schedule from
the DB cache when a near-identical phrasing was previously parsed by the 4B,
avoiding a second LLM call. One-shot intents are never cached. Cache/log
failures must never break the flow.

The 4B is mocked via the injectable `ask` callable — no real LLM/network.
Per-test DB isolation comes from the autouse `fresh_db` fixture in conftest.py,
which also applies the lifeos migrations (incl. schedule_cache) to the tmp DB.
"""

from __future__ import annotations

import json

import pytest


def _ask_returning(payload: dict):
    """Build a fake `ask` that returns `payload` as JSON, counting its calls."""
    calls = {"n": 0}

    def _ask(*, prompt, system, max_tokens, timeout, think):  # noqa: ANN001
        calls["n"] += 1
        return json.dumps(payload)

    return _ask, calls


_TZ = "America/Mexico_City"

_RECURRING_PAYLOAD = {
    "is_reminder": True,
    "kind": "agentic",
    "recurring": True,
    "cron": "0 9 * * *",
    "when_iso": None,
    "content": "las noticias",
}

_ONESHOT_PAYLOAD = {
    "is_reminder": True,
    "kind": "message",
    "recurring": False,
    "cron": None,
    "when_iso": "2099-01-01T09:00:00-06:00",
    "content": "llamar al dentista",
}

_NOT_REMINDER_PAYLOAD = {
    "is_reminder": False,
    "kind": "message",
    "recurring": False,
    "cron": None,
    "when_iso": None,
    "content": "",
}


def test_miss_calls_brain_caches_recurring_and_logs_resolved() -> None:
    from axi.reminder_brain import cached_or_brain_parse
    from lifeos import store
    from lifeos.parser import normalize_schedule_text

    ask, calls = _ask_returning(_RECURRING_PAYLOAD)
    text = "quiero que todos los dias me mandes las noticias"

    ri = cached_or_brain_parse(text, _TZ, ask=ask)

    assert ri is not None
    assert ri.recurrence == "0 9 * * *"
    assert ri.action_kind == "agentic"
    assert calls["n"] == 1

    norm = normalize_schedule_text(text)
    cached = store.schedule_cache_get(norm)
    assert cached is not None
    assert cached["recurrence"] == "0 9 * * *"

    with store.connect() as conn:
        row = conn.execute(
            "SELECT resolved FROM schedule_miss_log ORDER BY id DESC LIMIT 1"
        ).fetchone()
    assert row["resolved"] == 1


def test_second_identical_call_served_from_cache_without_brain() -> None:
    from axi.reminder_brain import cached_or_brain_parse

    ask, calls = _ask_returning(_RECURRING_PAYLOAD)

    first = cached_or_brain_parse(
        "quiero que todos los días me mandes las noticias", _TZ, ask=ask
    )
    # Near-identical phrasing (case, accents, trailing punctuation, spacing).
    second = cached_or_brain_parse(
        "Quiero que  todos los dias me mandes las noticias.", _TZ, ask=ask
    )

    assert first is not None and second is not None
    assert second.recurrence == "0 9 * * *"
    assert second.action_kind == "agentic"
    # The brain was invoked exactly once across BOTH calls.
    assert calls["n"] == 1


def test_one_shot_result_is_not_cached() -> None:
    from axi.reminder_brain import cached_or_brain_parse
    from lifeos import store
    from lifeos.parser import normalize_schedule_text

    ask, calls = _ask_returning(_ONESHOT_PAYLOAD)
    text = "recordame llamar al dentista mañana a las 9"

    ri = cached_or_brain_parse(text, _TZ, ask=ask)
    assert ri is not None
    assert ri.recurrence is None

    # Not cached → a second call hits the brain again.
    assert store.schedule_cache_get(normalize_schedule_text(text)) is None
    cached_or_brain_parse(text, _TZ, ask=ask)
    assert calls["n"] == 2


def test_none_result_logs_unresolved_and_caches_nothing() -> None:
    from axi.reminder_brain import cached_or_brain_parse
    from lifeos import store
    from lifeos.parser import normalize_schedule_text

    ask, calls = _ask_returning(_NOT_REMINDER_PAYLOAD)
    text = "todos los dias hola que tal"

    ri = cached_or_brain_parse(text, _TZ, ask=ask)
    assert ri is None
    assert calls["n"] == 1

    assert store.schedule_cache_get(normalize_schedule_text(text)) is None
    with store.connect() as conn:
        row = conn.execute(
            "SELECT resolved FROM schedule_miss_log ORDER BY id DESC LIMIT 1"
        ).fetchone()
    assert row["resolved"] == 0


def test_corrupt_cache_row_falls_back_to_brain_without_raising() -> None:
    from axi.reminder_brain import cached_or_brain_parse
    from lifeos import store
    from lifeos.parser import normalize_schedule_text

    text = "quiero que todos los dias me mandes las noticias"
    norm = normalize_schedule_text(text)

    # Seed a corrupt row: an invalid cron that _next_cron_match cannot resolve.
    store.schedule_cache_put(
        norm, kind="agentic", recurrence="not a cron at all", content="las noticias"
    )

    ask, calls = _ask_returning(_RECURRING_PAYLOAD)
    ri = cached_or_brain_parse(text, _TZ, ask=ask)

    # Corrupt cache → fell through to the brain (no raise) and got a valid intent.
    assert ri is not None
    assert ri.recurrence == "0 9 * * *"
    assert calls["n"] == 1
