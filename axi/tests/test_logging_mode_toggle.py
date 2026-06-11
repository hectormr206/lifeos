"""Tests for the logging_mode toggle in /api/chat/ask.

Strict TDD (RED→GREEN). All external services are mocked.

Behavioral contract under test:
- logging_mode absent or False → conversation mode (brain.ask free, no guardrail)
- logging_mode True → logging mode (nano extractor first, guardrail as honest reply)
- Unambiguous regex fast-paths always save regardless of toggle
- Web research (/busca) only available when logging_mode is False
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def client_base(monkeypatch):
    """Base client with memory/lock reset and nano extractor disabled."""
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    # Disable nano by default; individual tests override as needed.
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    return monkeypatch


@pytest.fixture
def conv_client(client_base, monkeypatch):
    """TestClient for conversation-mode tests. Brain is mocked."""
    from axi import brain, dashboard
    import lifeos.web as web_research

    # Reset web research so it doesn't accidentally gate
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)

    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "respuesta libre del brain")
    return TestClient(dashboard.app)


# ---------------------------------------------------------------------------
# T1 — logging_mode=False (default): brain answers freely, no guardrail
# ---------------------------------------------------------------------------


def test_conversation_mode_brain_returns_persistence_word_unchanged(conv_client, monkeypatch):
    """logging_mode=False + brain returns 'anotado' → answer NOT clobbered.

    This is the exact regression: Héctor asked for a gym routine; the brain
    non-deterministically used 'anotado' and the guardrail replaced it with
    the canned 'no pude registrar' message.
    """
    from axi import brain

    gym_answer = (
        "Te recomiendo este plan de gym: Lunes pecho, martes espalda. "
        "Ya lo tenés anotado como referencia."
    )
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: gym_answer)

    r = conv_client.post("/api/chat/ask", json={
        "text": "dame una rutina de gym",
        "logging_mode": False,
    })
    assert r.status_code == 200
    body = r.json()
    # The full brain answer must be returned unchanged — guardrail must NOT fire.
    assert body["answer"] == gym_answer, (
        f"Guardrail fired in conversation mode — clobbered answer.\n"
        f"Expected: {gym_answer!r}\nGot: {body['answer']!r}"
    )


def test_conversation_mode_default_no_logging_mode_field(conv_client, monkeypatch):
    """logging_mode absent in body → defaults to False (conversation mode).

    Guardrail must NOT fire even if brain answer contains persistence words.
    """
    from axi import brain

    answer_with_persistence = "Guardé esto en mi memoria para futuras consultas."
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: answer_with_persistence)

    r = conv_client.post("/api/chat/ask", json={
        "text": "recuerda que prefiero el gym los lunes",
    })
    assert r.status_code == 200
    body = r.json()
    assert body["answer"] == answer_with_persistence, (
        f"Default mode should be conversation (no guardrail). Got: {body['answer']!r}"
    )


def test_conversation_mode_brain_is_called(conv_client, monkeypatch):
    """logging_mode=False → brain.ask MUST be called for ambiguous messages."""
    from axi import brain

    brain_called = []

    def tracking_brain(prompt, **kw):
        brain_called.append(prompt)
        return "ok"

    monkeypatch.setattr(brain, "ask", tracking_brain)

    r = conv_client.post("/api/chat/ask", json={
        "text": "cuéntame sobre machine learning",
        "logging_mode": False,
    })
    assert r.status_code == 200
    assert brain_called, "brain.ask was NOT called in conversation mode"


# ---------------------------------------------------------------------------
# T2 — logging_mode=False: regex fast-path still auto-saves (always-on rule)
# ---------------------------------------------------------------------------


def test_conversation_mode_health_regex_still_saves(monkeypatch):
    """logging_mode=False + 'presión 120/80' → regex fast-path fires, saved.

    Unambiguous structured input ALWAYS auto-saves regardless of toggle.
    """
    from axi import brain, dashboard

    brain_called = []
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "fallback")[1])

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "presión 120/80",
        "logging_mode": False,
    })
    # The regex fast-path should have handled this (health domain)
    assert r.status_code == 200
    body = r.json()
    # Health fast-path returns an "anotado" confirmation — brain NOT called
    assert not brain_called, (
        f"brain.ask called for 'presión 120/80' — should have been handled by regex fast-path. "
        f"brain prompts: {brain_called[:1]}"
    )
    # The answer should be a health confirmation, not a conversation answer
    answer = body.get("answer", "")
    assert any(w in answer.lower() for w in ["salud", "vital", "anotado", "pressure", "presión"]), (
        f"Regex fast-path answer expected for 'presión 120/80', got: {answer!r}"
    )


# ---------------------------------------------------------------------------
# T3 — logging_mode=False: /busca triggers web research
# ---------------------------------------------------------------------------


def test_conversation_mode_busca_triggers_web_research(monkeypatch):
    """logging_mode=False + /busca → web research IS available."""
    from axi import brain, dashboard
    import lifeos.web as web_research
    from lifeos.web.port import SearchResult

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    search_called = []

    web_research.configure(
        search_fn=lambda q, **kw: (search_called.append(q), [
            SearchResult(title="Python docs", url="https://docs.python.org", snippet="Python docs.")
        ])[1],
        read_fn=lambda url: __import__("lifeos.web.port", fromlist=["PageText"]).PageText(
            url=url, text="", ok=False
        ),
        enabled_fn=lambda: True,
    )
    monkeypatch.setattr(brain, "ask", lambda p, **kw: "respuesta con fuente")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "/busca python async",
        "logging_mode": False,
    })
    assert r.status_code == 200
    assert search_called, "search_fn NOT called — web research unavailable in conversation mode"


# ---------------------------------------------------------------------------
# T4 — logging_mode=True: ambiguous message + nano can't parse → honest reply
# ---------------------------------------------------------------------------


def test_logging_mode_nano_fails_returns_format_message(monkeypatch):
    """logging_mode=True + nano extractor returns None → _suggested_format_message returned.

    The brain must NOT be called for conversation.
    """
    from axi import brain, dashboard

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    # Nano returns None → nothing was parsed/saved
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    brain_called = []
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "SHOULD NOT APPEAR")[1])

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "esto es algo que no parece un dato estructurado en lo absoluto",
        "logging_mode": True,
    })
    assert r.status_code == 200
    body = r.json()
    # Brain must NOT be called for conversation in logging mode
    assert not brain_called, (
        f"brain.ask was called in logging mode — should NOT be. Prompts: {brain_called[:1]}"
    )
    # The response should be the honest "couldn't parse" format message
    answer = body.get("answer", "")
    assert len(answer) > 0, "Answer is empty in logging mode nano-fail path"
    # It should be the format hint message (not a conversational brain answer)
    assert "SHOULD NOT APPEAR" not in answer, (
        "Brain answer leaked into logging mode nano-fail response"
    )


def test_logging_mode_nano_saves_returns_nano_answer(monkeypatch):
    """logging_mode=True + nano extractor succeeds → nano answer returned, brain NOT called.

    Uses text that does NOT match any regex fast-path (no digits, no recognized
    keywords) so it falls through to the nano extractor.
    """
    from axi import brain, dashboard

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)

    nano_answer = "Anotado: nota de salud sin formato estándar."
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: {
        "answer": nano_answer,
        "domain": "health",
        "entry_ids": [42],
    })

    brain_called = []
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "SHOULD NOT APPEAR")[1])

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        # Text with no digits and no regex-matched keywords — bypasses all fast-paths
        "text": "hoy me sentí algo cansado después de caminar bastante",
        "logging_mode": True,
    })
    assert r.status_code == 200
    body = r.json()
    assert body["answer"] == nano_answer, (
        f"Expected nano answer in logging mode, got: {body['answer']!r}"
    )
    assert not brain_called, "brain.ask was called — must not in logging mode when nano saves"


# ---------------------------------------------------------------------------
# T5 — logging_mode=True: /busca does NOT trigger web research
# ---------------------------------------------------------------------------


def test_logging_mode_busca_no_web_research(monkeypatch):
    """logging_mode=True + /busca → web research is DISABLED, falls to logging path."""
    from axi import brain, dashboard
    import lifeos.web as web_research

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    search_called = []
    web_research.configure(
        search_fn=lambda q, **kw: (search_called.append(q), []),
        read_fn=lambda url: __import__("lifeos.web.port", fromlist=["PageText"]).PageText(
            url=url, text="", ok=False
        ),
        enabled_fn=lambda: True,
    )

    brain_called = []
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "brain")[1])

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "/busca python async",
        "logging_mode": True,
    })
    assert r.status_code == 200
    assert not search_called, (
        f"search_fn was called in logging mode — internet should be DISABLED. "
        f"Calls: {search_called}"
    )
    # Brain should also NOT be called (logging mode routes to nano/format message)
    assert not brain_called, (
        f"brain.ask was called in logging mode — should NOT be. Calls: {brain_called[:1]}"
    )


# ---------------------------------------------------------------------------
# T6 — logging_mode absent defaults to False (regression + API contract)
# ---------------------------------------------------------------------------


def test_logging_mode_absent_defaults_to_conversation(monkeypatch):
    """logging_mode absent → equivalent to logging_mode=False (conversation mode).

    - Brain is called
    - Persistence words in brain answer are NOT clobbered
    """
    from axi import brain, dashboard
    import lifeos.web as web_research

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)

    answer_with_persistence_verb = "Anotado y registré la información en tu perfil."
    monkeypatch.setattr(brain, "ask", lambda p, **kw: answer_with_persistence_verb)

    tc = TestClient(dashboard.app)
    # No logging_mode field at all
    r = tc.post("/api/chat/ask", json={"text": "cómo guardar mis notas"})
    assert r.status_code == 200
    body = r.json()
    assert body["answer"] == answer_with_persistence_verb, (
        f"Absent logging_mode should default to conversation (no guardrail). "
        f"Got: {body['answer']!r}"
    )
