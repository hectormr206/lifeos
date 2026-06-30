"""Tests for agentic reminders (Briefings) — DB model round-trip (TDD).

An agentic reminder carries an `action_prompt` that, when it fires, runs
through the brain with web-search tools and stores a structured result on
the reminder row (`last_result`, `last_result_at`, `last_result_meta`).
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))
    from lifeos import store

    store.apply_migrations()
    yield


def test_default_action_kind_is_message() -> None:
    from lifeos import reminders

    when = datetime.now(timezone.utc) + timedelta(hours=1)
    rem = reminders.create(when=when, message="llamar dentista")

    assert rem.action_kind == "message"
    assert rem.action_prompt is None
    assert rem.last_result is None
    assert rem.last_result_at is None
    assert rem.last_result_meta is None


def test_create_agentic_reminder_roundtrip() -> None:
    from lifeos import reminders

    when = datetime.now(timezone.utc) + timedelta(hours=1)
    rem = reminders.create(
        when=when,
        message="noticias tech del día",
        recurrence="0 8 * * *",
        action_kind="agentic",
        action_prompt="tráeme las 10 noticias tech del día",
    )

    assert rem.action_kind == "agentic"
    assert rem.action_prompt == "tráeme las 10 noticias tech del día"
    assert rem.is_agentic is True

    fetched = reminders.get(rem.id)
    assert fetched is not None
    assert fetched.action_kind == "agentic"
    assert fetched.action_prompt == "tráeme las 10 noticias tech del día"
    assert fetched.recurrence == "0 8 * * *"


def test_set_last_result_persists_structured_meta() -> None:
    from lifeos import reminders

    when = datetime.now(timezone.utc) + timedelta(hours=1)
    rem = reminders.create(
        when=when, message="x", action_kind="agentic",
        action_prompt="tráeme las noticias",
    )

    meta = {
        "title": "Noticias tech",
        "summary": "10 titulares de hoy",
        "items": [
            {"title": "A", "summary": "resumen a", "url": "https://a.example"},
            {"title": "B", "summary": "resumen b", "url": "https://b.example"},
        ],
    }
    reminders.set_last_result(
        rem.id, result="markdown body", meta=json.dumps(meta),
    )

    fetched = reminders.get(rem.id)
    assert fetched is not None
    assert fetched.last_result == "markdown body"
    assert fetched.last_result_at is not None
    parsed = json.loads(fetched.last_result_meta)
    assert parsed["title"] == "Noticias tech"
    assert len(parsed["items"]) == 2
    assert parsed["items"][0]["url"] == "https://a.example"


def test_list_agentic_returns_only_agentic_reminders() -> None:
    from lifeos import reminders

    now = datetime.now(timezone.utc)
    plain = reminders.create(when=now + timedelta(hours=1), message="plain")
    ag = reminders.create(
        when=now + timedelta(hours=1), message="ag",
        action_kind="agentic", action_prompt="tráeme noticias",
        recurrence="0 8 * * *",
    )

    ids = [r.id for r in reminders.list_agentic()]
    assert ag.id in ids
    assert plain.id not in ids


def test_list_agentic_excludes_cancelled() -> None:
    from lifeos import reminders

    now = datetime.now(timezone.utc)
    active = reminders.create(
        when=now + timedelta(hours=1), message="active",
        action_kind="agentic", action_prompt="tráeme noticias",
        recurrence="0 8 * * *",
    )
    cancelled = reminders.create(
        when=now + timedelta(hours=1), message="cancelled",
        action_kind="agentic", action_prompt="tráeme clima",
        recurrence="0 9 * * *",
    )
    assert reminders.cancel(cancelled.id) is True

    ids = [r.id for r in reminders.list_agentic()]
    assert active.id in ids
    assert cancelled.id not in ids


def test_update_preserves_action_fields() -> None:
    from lifeos import reminders

    now = datetime.now(timezone.utc)
    rem = reminders.create(
        when=now + timedelta(hours=1), message="ag",
        action_kind="agentic", action_prompt="tráeme noticias",
        recurrence="0 8 * * *",
    )

    updated = reminders.update(
        rem.id,
        when=now + timedelta(hours=2),
        message="ag2",
        channel="push",
        recurrence="0 9 * * *",
    )

    assert updated is not None
    assert updated.action_kind == "agentic"
    assert updated.action_prompt == "tráeme noticias"
