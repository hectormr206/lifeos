"""Tests for the Briefings dashboard wiring (dispatcher, API, page) — TDD.

The agentic-reminder dispatcher branch, the /api/briefings + /briefings
endpoints, the agentic POST /api/reminders path, and the chat intent capture
that creates an agentic reminder. Brain/web/push calls are mocked — no
network, no real LLM, no real notifications.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient


class _FakeScheduler:
    def __init__(self):
        self.scheduled: list = []
        self.cancelled: list = []

    def schedule(self, rem):
        self.scheduled.append(rem)

    def cancel(self, rid: str):
        self.cancelled.append(rid)


@pytest.fixture
def fake_scheduler(monkeypatch):
    from axi import dashboard
    sched = _FakeScheduler()
    monkeypatch.setattr(dashboard, "get_scheduler", lambda: sched)
    return sched


@pytest.fixture
def lifeos_isolated_db(tmp_path, monkeypatch):
    db_path = tmp_path / "lifeos-test.db"
    key_path = tmp_path / "lifeos-test.key"
    monkeypatch.setenv("LIFEOS_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(key_path))
    from lifeos import store as lifeos_store
    if hasattr(lifeos_store, "_conn"):
        try:
            if lifeos_store._conn is not None:
                lifeos_store._conn.close()
        except Exception:
            pass
        monkeypatch.setattr(lifeos_store, "_conn", None)
    lifeos_store.apply_migrations()
    yield


@pytest.fixture
def client(monkeypatch, lifeos_isolated_db, fake_scheduler):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    return TestClient(dashboard.app)


def _future_iso(hours: int = 2) -> str:
    return (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()


# ── dispatcher routing ──────────────────────────────────────────────────────

def test_dispatcher_runs_agentic_and_persists_and_pushes(
    lifeos_isolated_db, monkeypatch
):
    from axi import dashboard
    from lifeos import reminders

    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="noticias tech",
        recurrence="0 8 * * *",
        action_kind="agentic",
        action_prompt="tráeme las noticias tech del día",
    )

    fake_digest = {
        "title": "Noticias tech del día",
        "summary": "2 titulares de hoy.",
        "items": [{"title": "A", "summary": "s", "url": "https://a.example"}],
        "markdown": "## Noticias tech del día\n- [A](https://a.example) — s",
        "ok": True,
    }
    monkeypatch.setattr(
        dashboard.briefing, "run_agentic_briefing", lambda *_a, **_k: fake_digest
    )
    # Route by prompt only: pin the multi-source config flag OFF so this test is
    # hermetic (the live machine may have briefing_multi_source enabled, which
    # would otherwise route to the multi-source pipeline and bypass this mock).
    from axi import config
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: False if k == "briefing_multi_source" else d)
    pushes: list = []
    monkeypatch.setattr(
        dashboard.lifeos_push, "send_to_all",
        lambda **kw: pushes.append(kw) or {"sent": 1, "failed": 0, "gone": 0},
    )

    dashboard._lifeos_push_dispatcher(rem)

    # Result persisted on the reminder row.
    fetched = reminders.get(rem.id)
    assert fetched.last_result_at is not None
    meta = json.loads(fetched.last_result_meta)
    assert meta["items"][0]["url"] == "https://a.example"
    # Push deep-links to the card.
    assert len(pushes) == 1
    assert pushes[0]["url"] == f"/briefings#{rem.id}"
    assert pushes[0]["title"] == "Noticias tech del día"


def test_dispatcher_message_branch_unchanged(lifeos_isolated_db, monkeypatch):
    from axi import dashboard
    from lifeos import reminders

    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="llamar dentista",
    )
    pushes: list = []
    monkeypatch.setattr(
        dashboard.lifeos_push, "send_to_all",
        lambda **kw: pushes.append(kw) or {"sent": 1, "failed": 0, "gone": 0},
    )
    # Agentic engine must NOT be called for a plain message reminder.
    monkeypatch.setattr(
        dashboard.briefing, "run_agentic_briefing",
        lambda *_a, **_k: pytest.fail("agentic engine called for message reminder"),
    )

    dashboard._lifeos_push_dispatcher(rem)
    assert pushes[0]["body"] == "llamar dentista"


def test_dispatcher_agentic_failure_pushes_graceful(lifeos_isolated_db, monkeypatch):
    from axi import dashboard
    from lifeos import reminders

    rem = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="x", action_kind="agentic", action_prompt="tráeme noticias",
    )
    failed_digest = {
        "title": "Briefing", "summary": "No pude generar el briefing.",
        "items": [], "markdown": "No pude generar el briefing.", "ok": False,
    }
    monkeypatch.setattr(
        dashboard.briefing, "run_agentic_briefing", lambda *_a, **_k: failed_digest
    )
    pushes: list = []
    monkeypatch.setattr(
        dashboard.lifeos_push, "send_to_all",
        lambda **kw: pushes.append(kw) or {"sent": 1, "failed": 0, "gone": 0},
    )

    # Must not raise.
    dashboard._lifeos_push_dispatcher(rem)
    assert len(pushes) == 1
    assert pushes[0]["url"] == f"/briefings#{rem.id}"


# ── API + page ──────────────────────────────────────────────────────────────

def test_api_briefings_returns_agentic_cards(client):
    from lifeos import reminders

    ag = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="noticias", recurrence="0 8 * * *",
        action_kind="agentic", action_prompt="tráeme noticias",
    )
    reminders.set_last_result(
        ag.id, result="## body",
        meta=json.dumps({"title": "T", "summary": "S",
                         "items": [{"title": "i", "summary": "s",
                                    "url": "https://x.example"}]}),
    )
    # A plain reminder must NOT appear in briefings.
    reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1), message="plain"
    )

    r = client.get("/api/briefings")
    assert r.status_code == 200
    cards = r.json()["briefings"]
    assert len(cards) == 1
    card = cards[0]
    assert card["id"] == ag.id
    assert card["action_prompt"] == "tráeme noticias"
    assert card["result"]["items"][0]["url"] == "https://x.example"


def test_briefings_page_renders(client):
    r = client.get("/briefings")
    assert r.status_code == 200
    assert "Boletines" in r.text


def test_post_reminders_creates_agentic(client, fake_scheduler):
    payload = {
        "when": _future_iso(2),
        "message": "noticias tech",
        "channel": "log",
        "recurrence": "0 8 * * *",
        "action_kind": "agentic",
        "action_prompt": "tráeme las noticias tech del día",
    }
    r = client.post("/api/reminders", json=payload)
    assert r.status_code == 200
    data = r.json()
    assert data["action_kind"] == "agentic"
    assert data["action_prompt"] == "tráeme las noticias tech del día"

    # And it shows up in /api/briefings.
    r2 = client.get("/api/briefings")
    assert any(c["id"] == data["id"] for c in r2.json()["briefings"])


# ── chat intent capture ─────────────────────────────────────────────────────

def test_chat_creates_agentic_reminder(client, fake_scheduler, monkeypatch):
    from axi import brain, dashboard
    # Brain is stubbed (a background memory-extract thread may call it); the
    # agentic fast-path returns before any brain fallback regardless.
    monkeypatch.setattr(brain, "ask", lambda *a, **k: "null")
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **k: "null")
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)

    r = client.post("/api/chat/ask", json={
        "text": "tráeme las 10 noticias tech del día todos los días a las 8",
    })
    assert r.status_code == 200
    body = r.json()
    assert body.get("briefing") is True
    rid = body["reminder_id"]

    from lifeos import reminders
    rem = reminders.get(rid)
    assert rem is not None
    assert rem.action_kind == "agentic"
    assert "noticias" in rem.action_prompt
    assert rem.recurrence == "0 8 * * *"


# ── on-demand summary endpoints (boletín v2 final slice) ─────────────────────
#
# Two POST endpoints let the reader expand a stored briefing item on demand:
# an article summary (fetch + brain, es-MX) and an HN comments summary. Both
# are SSRF/guard-protected: the url / hn_id must belong to a STORED briefing
# item, else 400. Fetch/brain/HTTP are injected — no network, no real LLM.

def _seed_briefing_item(item: dict) -> str:
    """Create an agentic reminder carrying `item` in its stored result meta."""
    from lifeos import reminders
    ag = reminders.create(
        when=datetime.now(timezone.utc) + timedelta(hours=1),
        message="noticias", recurrence="0 8 * * *",
        action_kind="agentic", action_prompt="tráeme noticias",
    )
    reminders.set_last_result(
        ag.id, result="## body",
        meta=json.dumps({"title": "T", "summary": "S", "items": [item]}),
    )
    return ag.id


# article-summary ------------------------------------------------------------

def test_article_summary_rejects_url_not_in_any_stored_item(client):
    _seed_briefing_item({"title": "i", "url": "https://good.example/a"})
    r = client.post("/api/briefings/article-summary",
                    json={"url": "https://evil.example/ssrf"})
    assert r.status_code == 400


def test_article_summary_accepts_stored_url_and_summarizes_es(client, monkeypatch):
    from axi import brain, dashboard
    _seed_briefing_item({"title": "i", "url": "https://good.example/a"})
    monkeypatch.setattr(dashboard, "_briefing_read_article",
                        lambda url: "Full english article body about GPUs.")
    seen: dict = {}

    def _fake_ask(p, **k):
        seen["prompt"] = p
        return "Resumen en español del artículo."

    monkeypatch.setattr(brain, "ask", _fake_ask)
    r = client.post("/api/briefings/article-summary",
                    json={"url": "https://good.example/a"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["summary"] == "Resumen en español del artículo."
    assert "GPUs" in seen["prompt"]  # article text was handed to the brain


def test_article_summary_graceful_when_fetch_fails(client, monkeypatch):
    from axi import brain, dashboard
    _seed_briefing_item({"title": "i", "url": "https://good.example/a"})
    monkeypatch.setattr(dashboard, "_briefing_read_article", lambda url: "")
    monkeypatch.setattr(brain, "ask",
                        lambda *a, **k: pytest.fail("brain called despite empty fetch"))
    r = client.post("/api/briefings/article-summary",
                    json={"url": "https://good.example/a"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body.get("error")


def test_article_summary_graceful_when_brain_raises(client, monkeypatch):
    from axi import brain, dashboard
    _seed_briefing_item({"title": "i", "url": "https://good.example/a"})
    monkeypatch.setattr(dashboard, "_briefing_read_article", lambda url: "body text")

    def boom(*a, **k):
        raise RuntimeError("brain down")

    monkeypatch.setattr(brain, "ask", boom)
    r = client.post("/api/briefings/article-summary",
                    json={"url": "https://good.example/a"})
    assert r.status_code == 200
    assert r.json()["ok"] is False


# comments-summary -----------------------------------------------------------

def test_comments_summary_rejects_unknown_hn_id(client):
    _seed_briefing_item({"title": "i", "url": "https://x.example", "hn_id": "111"})
    r = client.post("/api/briefings/comments-summary", json={"hn_id": "999"})
    assert r.status_code == 400


def test_comments_summary_strips_html_and_summarizes_es(client, monkeypatch):
    from axi import brain, dashboard
    _seed_briefing_item({"title": "i", "url": "https://x.example", "hn_id": "111"})
    fake_item = {
        "children": [
            {"text": "<p>I <i>love</i> this &amp; agree</p>", "author": "a"},
            {"text": "Second <a href='x'>comment</a> here", "author": "b"},
        ]
    }
    monkeypatch.setattr(dashboard, "_briefing_fetch_hn_item", lambda hid: fake_item)
    seen: dict = {}

    def _fake_ask(p, **k):
        seen["prompt"] = p
        return "La gente debate sobre GPUs."

    monkeypatch.setattr(brain, "ask", _fake_ask)
    r = client.post("/api/briefings/comments-summary", json={"hn_id": "111"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["summary"] == "La gente debate sobre GPUs."
    # HTML tags were stripped before hitting the brain; entities decoded.
    assert "<" not in seen["prompt"]
    assert "love" in seen["prompt"] and "agree" in seen["prompt"]


def test_comments_summary_no_comments_returns_sin_comentarios(client, monkeypatch):
    from axi import brain, dashboard
    _seed_briefing_item({"title": "i", "url": "https://x.example", "hn_id": "111"})
    monkeypatch.setattr(dashboard, "_briefing_fetch_hn_item", lambda hid: {"children": []})
    monkeypatch.setattr(brain, "ask",
                        lambda *a, **k: pytest.fail("brain called with no comments"))
    r = client.post("/api/briefings/comments-summary", json={"hn_id": "111"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body["error"] == "sin comentarios"


def test_comments_summary_graceful_when_fetch_fails(client, monkeypatch):
    from axi import dashboard
    _seed_briefing_item({"title": "i", "url": "https://x.example", "hn_id": "111"})
    monkeypatch.setattr(dashboard, "_briefing_fetch_hn_item", lambda hid: None)
    r = client.post("/api/briefings/comments-summary", json={"hn_id": "111"})
    assert r.status_code == 200
    assert r.json()["ok"] is False


# template renders the on-demand buttons -------------------------------------

def test_briefings_template_has_on_demand_summary_buttons(client):
    r = client.get("/briefings")
    assert r.status_code == 200
    assert "Ver resumen completo" in r.text
    assert "Ver resumen de comentarios" in r.text
    assert "/api/briefings/article-summary" in r.text
    assert "/api/briefings/comments-summary" in r.text
