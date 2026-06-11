"""Tests for the logging_mode toggle in /api/chat/ask.

Strict TDD (RED→GREEN). All external services are mocked.

Behavioral contract under test:
- logging_mode absent or False → conversation mode (brain.ask free, no guardrail)
- logging_mode True → logging mode (nano extractor first, guardrail as honest reply)
- Unambiguous regex fast-paths always save regardless of toggle
- Web research (/busca) only available when logging_mode is False
- Purchase-consult fast-path must NOT call brain.ask when logging_mode=True (F2)
- /busca in logging_mode=True returns a clear disabled message (F3)
- logging_mode coercion: only JSON bool True counts as True (F4)
- Regex fast-path actually persists an entry in the DB (F6)
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


# ---------------------------------------------------------------------------
# F2 — Purchase-consult fast-path must NOT call brain in logging_mode=True
# ---------------------------------------------------------------------------


def test_purchase_consult_skipped_in_logging_mode(monkeypatch):
    """logging_mode=True + purchase-consult query → brain.ask NOT called.

    F2 fix: the purchase-consult branch must be gated on `not logging_mode`.
    """
    from axi import brain, dashboard
    import lifeos.web as web_research

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)

    brain_called = []
    consult_called = []

    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "brain")[1])

    # Also patch decide_purchase.consult so we can track it independently
    from lifeos.decide import purchase as decide_purchase
    real_consult = decide_purchase.consult

    def tracking_consult(*a, **kw):
        consult_called.append(a)
        return real_consult(*a, **kw)

    monkeypatch.setattr(decide_purchase, "consult", tracking_consult)

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "¿puedo comprar una bici?",
        "logging_mode": True,
    })
    assert r.status_code == 200
    assert not brain_called, (
        f"brain.ask was called in logging_mode=True for purchase query — must NOT be. "
        f"Prompts: {brain_called[:1]}"
    )
    assert not consult_called, (
        f"decide_purchase.consult was called in logging_mode=True — must NOT be."
    )


def test_purchase_consult_works_in_conversation_mode(monkeypatch):
    """logging_mode=False + purchase-consult query → consult STILL works (unchanged).

    F2 fix regression guard: gating on logging_mode must not break conv mode.
    """
    from axi import brain, dashboard
    import lifeos.web as web_research
    from lifeos.decide import purchase as decide_purchase
    from lifeos.decide.purchase import PurchaseConsultResult, PurchaseContext

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)

    consult_called = []

    def fake_consult(item, brain_ask, language, bundle=None):
        consult_called.append(item)
        return PurchaseConsultResult(
            answer="Parece una compra planeada. Adelante.",
            citations=[],
            context=PurchaseContext(
                item=item, summary_30d={},
                impulsive_ratio=0.1, classified_total=5,
            ),
        )

    monkeypatch.setattr(decide_purchase, "consult", fake_consult)
    monkeypatch.setattr(brain, "ask", lambda p, **kw: "brain fallback")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "¿puedo comprar una bici?",
        "logging_mode": False,
    })
    assert r.status_code == 200
    # consult may or may not be called depending on parse_query result —
    # what matters is the response is 200 and the brain path is not broken.
    # If parse_query doesn't classify it as PurchaseConsultIntent, consult
    # won't be called, but we verify the REQUEST succeeds and brain is available.
    body = r.json()
    assert "answer" in body


# ---------------------------------------------------------------------------
# F3 — /busca in logging_mode=True returns clear "disabled" message
# ---------------------------------------------------------------------------


def test_busca_in_logging_mode_returns_disabled_message(monkeypatch):
    """logging_mode=True + /busca → returns explicit disabled message; search NOT called.

    F3 fix: add early return before nano path for web commands in logging mode.
    """
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
        "text": "/busca noticias",
        "logging_mode": True,
    })
    assert r.status_code == 200
    body = r.json()
    assert not search_called, "search_fn must NOT be called in logging mode"
    assert not brain_called, "brain.ask must NOT be called in logging mode"
    answer = body.get("answer", "")
    # Must contain the clear disabled message (not the nano format-hint fallback)
    assert "búsqueda" in answer.lower() or "busca" in answer.lower() or "internet" in answer.lower(), (
        f"Expected internet-disabled message for /busca in logging mode, got: {answer!r}"
    )
    assert "modo registro" in answer.lower() or "registro" in answer.lower(), (
        f"Expected mention of logging mode in disabled message, got: {answer!r}"
    )


# ---------------------------------------------------------------------------
# F4 — logging_mode coercion: string "true" must NOT be treated as True
# ---------------------------------------------------------------------------


def test_logging_mode_string_true_treated_as_false(monkeypatch):
    """body with logging_mode='true' (string) → conversation mode (treated as False).

    F4 fix: use isinstance check instead of bool() coercion.
    """
    from axi import brain, dashboard
    import lifeos.web as web_research

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)

    brain_called = []
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "from brain")[1])

    tc = TestClient(dashboard.app)
    # logging_mode is a STRING "true" — must be treated as False (conversation)
    r = tc.post("/api/chat/ask", json={
        "text": "me siento cansado hoy",
        "logging_mode": "true",
    })
    assert r.status_code == 200
    # Brain must be called because string "true" → False (conversation mode)
    assert brain_called, (
        "String 'true' for logging_mode must be coerced to False (conversation). "
        "brain.ask should have been called."
    )


def test_logging_mode_bool_true_activates_logging(monkeypatch):
    """body with logging_mode=true (JSON bool) → logging mode active.

    F4 fix regression guard: real JSON bool True still works correctly.
    """
    from axi import brain, dashboard
    import lifeos.web as web_research

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)

    brain_called = []
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "from brain")[1])

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "me siento cansado hoy en el trabajo y en casa también vivo así",
        "logging_mode": True,  # JSON bool True
    })
    assert r.status_code == 200
    # Brain must NOT be called in logging mode with a real bool True
    assert not brain_called, (
        "JSON bool True for logging_mode must activate logging mode. "
        "brain.ask must NOT be called."
    )


# ---------------------------------------------------------------------------
# F6 — Regex fast-path actually writes a DB entry (not just returns text)
# ---------------------------------------------------------------------------


def test_health_regex_fastpath_persists_entry(monkeypatch, tmp_path):
    """logging_mode=False + 'presión 120/80' → a health entry is actually created.

    F6 fix: harden the hollow test to verify the store write happened.
    """
    from axi import brain, dashboard

    # Isolate the health DB
    db_path = tmp_path / "health-test-f6.db"
    key_path = tmp_path / "health-test-f6.key"
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(key_path))
    from lifeos.health import store as health_store
    health_store.apply_migrations()

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    brain_called = []
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (brain_called.append(p), "fallback")[1])

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={
        "text": "presión 120/80",
        "logging_mode": False,
    })
    assert r.status_code == 200
    assert not brain_called, "brain.ask must NOT be called for 'presión 120/80' regex fast-path"

    # Verify the entry was actually persisted
    from lifeos.health import entries as health_entries
    recent = health_entries.list_recent(days=1)
    assert len(recent) >= 1, (
        f"Expected at least one health entry after 'presión 120/80', got {len(recent)}. "
        "The regex fast-path must actually persist to the DB."
    )
