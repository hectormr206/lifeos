"""Tests for the LLM schedule fallback wired into the chat handler.

When both regex parsers (parse_agentic_reminder, parse_reminder) return None
but the text still looks schedulish, the chat handler must invoke
parse_reminder_brain and, on a returned intent, create the reminder + reply
with a confirmation. Normal chat (not schedulish) must NOT trigger it.

The brain is mocked; reminders.create and the scheduler are stubbed so no DB
write or scheduling side effect happens.
"""

from __future__ import annotations

from datetime import datetime, timezone
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


def _stub_brain(monkeypatch):
    from axi import brain

    monkeypatch.setattr(brain, "ask", lambda *a, **k: "respuesta")
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **k: "respuesta")


def test_fallback_creates_agentic_reminder(client, monkeypatch):
    from axi import dashboard
    from lifeos.parser import ReminderIntent

    _stub_brain(monkeypatch)

    when = datetime(2026, 7, 1, 14, 0, tzinfo=timezone.utc)
    intent = ReminderIntent(
        message="las noticias",
        when=when,
        recurrence="0 8 * * *",
        action_kind="agentic",
        action_prompt="las noticias",
    )

    seen: dict = {}

    def fake_brain_parse(text, tz, **kw):
        seen["text"] = text
        return intent

    monkeypatch.setattr(
        "axi.reminder_brain.parse_reminder_brain", fake_brain_parse
    )

    fake_rem = MagicMock()
    fake_rem.id = "REMX"
    monkeypatch.setattr(dashboard.lifeos_reminders, "create", lambda **k: fake_rem)
    monkeypatch.setattr(dashboard, "get_scheduler", lambda: MagicMock())

    # Schedulish (recurrence word) but neither regex parser can build an intent.
    text = "todos los días poné al día mi bandeja de entrada"
    r = client.post("/api/chat/ask", json={"text": text})

    assert r.status_code == 200
    body = r.json()
    assert body.get("reminder_id") == "REMX"
    assert body.get("briefing") is True
    # Confirmation must state the schedule.
    assert "08:00" in body["answer"] or "todos los días" in body["answer"].lower()
    assert seen.get("text")


def test_non_schedulish_does_not_invoke_brain_fallback(client, monkeypatch):
    """Plain chat must NOT call parse_reminder_brain (keeps normal chat fast)."""
    from axi import dashboard

    _stub_brain(monkeypatch)

    called = {"n": 0}

    def fake_brain_parse(text, tz, **kw):
        called["n"] += 1
        return None

    monkeypatch.setattr(
        "axi.reminder_brain.parse_reminder_brain", fake_brain_parse
    )

    r = client.post("/api/chat/ask", json={"text": "hola cómo estás"})
    assert r.status_code == 200
    assert called["n"] == 0
