"""End-to-end smoke: parser → reminders → scheduler → dispatcher.

This exercises every layer of P1 in one go, without standing up FastAPI or
the dashboard. The Web Push leg requires a real PWA subscription and is
exercised manually from Héctor's Pixel.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Event

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    from lifeos import store
    store.apply_migrations()
    yield


def test_chat_phrase_to_dispatched_reminder():
    """Simulates the full chat path: parse → create → schedule → fire."""
    import time
    from lifeos import reminders
    from lifeos.parser import parse_reminder
    from lifeos.scheduler import Scheduler

    # 1. User types this into the chat
    user_text = "recordame estirar la espalda en 2 segundos"

    # 2. Chat fast-path parses
    ri = parse_reminder(user_text)
    assert ri is not None, "parser did not catch the reminder phrase"
    assert "estirar" in ri.message.lower()
    delta = (ri.when - datetime.now(timezone.utc)).total_seconds()
    assert 1.5 < delta < 2.5, f"parsed time off: {delta}s"

    # 3. Dashboard creates the reminder + schedules it
    fired = Event()
    seen: list[str] = []

    def dispatcher(rem):
        seen.append(rem.message)
        fired.set()

    sched = Scheduler(dispatcher=dispatcher)
    sched.start()
    try:
        rem = reminders.create(when=ri.when, message=ri.message, channel="log")
        sched.schedule(rem)

        # 4. Within ~3 seconds, dispatcher must have fired
        assert fired.wait(timeout=4.0), "reminder never fired through full pipeline"
        assert seen == [rem.message]

        # 5. DAO reflects fired status (poll briefly for the post-callback update)
        for _ in range(20):
            after = reminders.get(rem.id)
            if after and after.status == "fired":
                break
            time.sleep(0.1)
        after = reminders.get(rem.id)
        assert after is not None and after.status == "fired"
    finally:
        sched.shutdown(wait=True)
