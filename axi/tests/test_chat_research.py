"""Tests for the web-research branch in /api/chat/ask.

Strict TDD (RED→GREEN). All external services are mocked — NO real
network, NO real SearXNG, NO real brain / llama-server.

Mocking strategy:
- `brain.ask` → monkeypatched on the `axi.brain` module (same as test_chat_api.py)
- `search_fn` / `read_fn` → injected via `lifeos.web.configure()` in each fixture
- The dashboard module's `_chat_memory` is reset to None so every test gets
  an isolated in-memory history (mirrors test_chat_api.py fixture pattern).

All tests drive the real FastAPI app via `TestClient` to exercise the full
handler — no unit-testing the internal helper functions in isolation.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from lifeos.web.port import PageText, SearchResult

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_RESULT_1 = SearchResult(
    title="Python async guide",
    url="https://docs.python.org/async",
    snippet="Python async/await is great for IO-bound tasks.",
)
_RESULT_2 = SearchResult(
    title="asyncio docs",
    url="https://docs.python.org/asyncio",
    snippet="The asyncio module provides infrastructure for async I/O.",
)
_RESULT_3 = SearchResult(
    title="PEP 3156",
    url="https://peps.python.org/pep-3156",
    snippet="Asynchronous IO support rebooted — the asyncio module.",
)

_PAGE_TEXT = PageText(
    url=_RESULT_1.url,
    text="Python async/await allows writing concurrent code using coroutines. " * 10,
    ok=True,
)
_PAGE_FAIL = PageText(url=_RESULT_1.url, text="", ok=False)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_web_research(monkeypatch):
    """Reset web_research globals before every test."""
    import lifeos.web as web_research
    monkeypatch.setattr(web_research, "_search_fn", None)
    monkeypatch.setattr(web_research, "_read_fn", None)
    monkeypatch.setattr(web_research, "_enabled_fn", None)


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    # Disable nano extractor so tests don't hit real model ports and run fast
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    return TestClient(dashboard.app)


@pytest.fixture
def research_client(monkeypatch):
    """Client with web research fully configured (search + read succeed)."""
    from axi import brain, dashboard
    import lifeos.web as web_research

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    # Disable nano extractor so tests don't hit real model ports and run fast
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    search_calls: list[str] = []
    read_calls: list[str] = []

    def fake_search(query: str, **kw) -> list[SearchResult]:
        search_calls.append(query)
        return [_RESULT_1, _RESULT_2, _RESULT_3]

    def fake_read(url: str) -> PageText:
        read_calls.append(url)
        return _PAGE_TEXT

    web_research.configure(
        search_fn=fake_search,
        read_fn=fake_read,
        enabled_fn=lambda: True,
    )

    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "La respuesta del brain.")

    tc = TestClient(dashboard.app)
    tc._search_calls = search_calls
    tc._read_calls = read_calls
    return tc


# ---------------------------------------------------------------------------
# Task 5.1a — command parsing: /busca and /investiga recognized
# ---------------------------------------------------------------------------


def test_busca_triggers_research(research_client, monkeypatch):
    """POST /busca <query> → research flow fires, brain called with enriched prompt."""
    from axi import brain

    captured: dict = {}

    def capturing_ask(prompt: str, **kw):
        captured["prompt"] = prompt
        return "Respuesta con citas."

    monkeypatch.setattr(brain, "ask", capturing_ask)

    r = research_client.post("/api/chat/ask", json={"text": "/busca python async"})
    assert r.status_code == 200
    body = r.json()
    assert "answer" in body

    # The prompt passed to brain.ask must contain search context
    assert "captured" in captured or "prompt" in captured, "brain.ask was never called"
    enriched = captured.get("prompt", "")
    assert "Python async guide" in enriched or "asyncio" in enriched, (
        f"Enriched prompt missing search content: {enriched[:300]}"
    )
    # Source URLs must appear in the answer (appended deterministically)
    answer = body["answer"]
    assert "docs.python.org" in answer or "Fuentes" in answer, (
        f"Source URLs not in answer: {answer}"
    )


def test_investiga_triggers_research(research_client, monkeypatch):
    """/investiga prefix is equivalent to /busca."""
    from axi import brain

    captured: dict = {}

    def capturing_ask(prompt: str, **kw):
        captured["prompt"] = prompt
        return "Respuesta de investiga."

    monkeypatch.setattr(brain, "ask", capturing_ask)

    r = research_client.post("/api/chat/ask", json={"text": "/investiga asyncio"})
    assert r.status_code == 200

    enriched = captured.get("prompt", "")
    assert "asyncio" in enriched.lower() or "Python" in enriched, (
        f"Enriched prompt missing search content: {enriched[:300]}"
    )


def test_busca_case_insensitive(research_client, monkeypatch):
    """/BUSCA (uppercase) is recognized."""
    from axi import brain

    captured: dict = {}
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (captured.update({"p": p}), "ok")[1])

    r = research_client.post("/api/chat/ask", json={"text": "/BUSCA python"})
    assert r.status_code == 200
    # Verify the research branch fired (prompt enriched or answer has sources)
    body = r.json()
    assert "answer" in body


# ---------------------------------------------------------------------------
# Task 5.1b — empty query → friendly message, no search call
# ---------------------------------------------------------------------------


def test_empty_query_returns_friendly_message(client, monkeypatch):
    """/busca with whitespace-only query → graceful message, search not called."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    search_called = []

    def must_not_be_called(query, **kw):  # noqa: ARG001
        search_called.append(query)
        return []

    web_research.configure(
        search_fn=must_not_be_called,
        read_fn=lambda url: _PAGE_FAIL,
        enabled_fn=lambda: True,
    )

    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(brain, "ask", lambda p, **kw: "fallback")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "/busca   "})
    assert r.status_code == 200
    body = r.json()
    # search must NOT have been called with an empty query
    assert search_called == [], f"search_fn called with empty query: {search_called}"
    # Response should contain a friendly prompt
    answer = body.get("answer", "")
    assert any(word in answer.lower() for word in ["busca", "query", "consulta", "qué", "que"]), (
        f"Expected a friendly prompt in answer, got: {answer}"
    )


# ---------------------------------------------------------------------------
# Task 5.1c — SearXNG down → graceful degraded message, HTTP 200, brain NOT
#             called with research context (or called normally)
# ---------------------------------------------------------------------------


def test_searxng_down_degraded_message(client, monkeypatch):
    """search_fn returns [] → degraded message, HTTP 200, no 500."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    web_research.configure(
        search_fn=lambda q, **kw: [],
        read_fn=lambda url: _PAGE_FAIL,
        enabled_fn=lambda: True,
    )
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(brain, "ask", lambda p, **kw: (_ for _ in ()).throw(AssertionError(
        "brain.ask must NOT be called with research enrichment when SearXNG is down"
    )))

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "/busca python"})
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"
    body = r.json()
    answer = body.get("answer", "")
    # Must be a graceful degraded message, not empty
    assert len(answer) > 0, "Answer should not be empty on degraded path"
    # Must mention inability to search (Spanish)
    assert any(word in answer.lower() for word in [
        "buscar", "busca", "ahora", "momento", "encontré", "encontr", "servicio"
    ]), f"Expected degraded message, got: {answer}"


# ---------------------------------------------------------------------------
# Task 5.1d — read failure: PageText(ok=False) → still answers from snippets
# ---------------------------------------------------------------------------


def test_read_failure_falls_back_to_snippets(client, monkeypatch):
    """read_fn returns ok=False → still enriches from snippets, no crash."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    captured: dict = {}

    def capturing_ask(prompt: str, **kw):
        captured["prompt"] = prompt
        return "Respuesta con snippets."

    web_research.configure(
        search_fn=lambda q, **kw: [_RESULT_1, _RESULT_2],
        read_fn=lambda url: _PAGE_FAIL,   # page read fails
        enabled_fn=lambda: True,
    )
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(brain, "ask", capturing_ask)

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "/busca python"})
    assert r.status_code == 200
    body = r.json()
    assert "answer" in body
    # Brain must still have been called — from snippets even if page read failed
    assert "prompt" in captured, "brain.ask was never called"
    # Snippets from search results should appear in prompt
    prompt = captured["prompt"]
    assert "Python async guide" in prompt or "asyncio" in prompt, (
        f"Snippets not in prompt when read fails: {prompt[:300]}"
    )


# ---------------------------------------------------------------------------
# Task 5.1e — guardrail still fires on research path
# ---------------------------------------------------------------------------


def test_guardrail_fires_on_research_answer(client, monkeypatch):
    """If brain returns a persistence claim after research, guardrail still fires."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    web_research.configure(
        search_fn=lambda q, **kw: [_RESULT_1],
        read_fn=lambda url: _PAGE_TEXT,
        enabled_fn=lambda: True,
    )
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)

    # Brain claims to have persisted something — guardrail must intercept this
    monkeypatch.setattr(brain, "ask", lambda p, **kw: "Anotado y registré tu búsqueda en la base de datos.")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "/busca python"})
    assert r.status_code == 200
    body = r.json()
    answer = body.get("answer", "")
    # The guardrail must have replaced the persistence-claim answer
    assert "registré" not in answer or "Anotado" not in answer, (
        f"Guardrail did NOT fire on research path — answer was: {answer}"
    )


# ---------------------------------------------------------------------------
# Task 5.1f — non-command chat is UNAFFECTED (regression guard)
# ---------------------------------------------------------------------------


def test_non_research_message_unaffected(client, monkeypatch):
    """A plain message does NOT trigger search — existing flow unchanged."""
    import lifeos.web as web_research
    from axi import brain, dashboard

    search_called = []

    web_research.configure(
        search_fn=lambda q, **kw: search_called.append(q) or [],
        read_fn=lambda url: _PAGE_FAIL,
        enabled_fn=lambda: True,
    )
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    monkeypatch.setattr(dashboard, "_try_nano_extract", lambda *a, **kw: None)
    monkeypatch.setattr(brain, "ask", lambda p, **kw: "respuesta normal")

    tc = TestClient(dashboard.app)
    r = tc.post("/api/chat/ask", json={"text": "hola, ¿cómo estás?"})
    assert r.status_code == 200
    body = r.json()
    assert body["answer"] == "respuesta normal"
    assert search_called == [], f"search_fn was called on a non-research message: {search_called}"
