"""Deterministic web-search pipeline for the Axi gaming co-pilot (Slice 2).

Answers "what is this / what do I do" during game-mode by:
  1. Intent gate  — cheap regex check (no model call)
  2. Window title — qdbus6 subprocess for game name (never raises)
  3. Entity extraction — short constrained brain_ask with screenshot
  4. SearXNG search  — text-only query (image NEVER leaves device)
  5. Interim TTS     — "Buscando…" so user isn't left in silence
  6. Synthesis       — brain_ask with snippets injected as context

All external dependencies (brain_ask, search_fn, window_title_fn, speak_interim)
are injected so the pipeline is fully testable without real model/network/subprocess.

Privacy guarantee:
  - The screenshot (image_b64) is passed only to the local brain_ask (on-device model).
  - It is NEVER included in the search query or sent to SearXNG.
  - Only a short text query (game title + entity name + question) reaches SearXNG.
"""
from __future__ import annotations

import logging
import re
import threading
from typing import Callable

log = logging.getLogger("axi.copilot_search")

# ---------------------------------------------------------------------------
# Intent gate — pure, zero I/O, testable in isolation
# ---------------------------------------------------------------------------

# Patterns that indicate the user wants an action/information search.
_SEARCH_INTENT_RE = re.compile(
    r"\b("
    r"qué\s+hago"
    r"|para\s+qué\s+sirve"
    r"|cómo\s+(?:uso|resuelvo|abro|activo|funciona)"
    r"|qué\s+es\s+esto"
    r"|cómo\s+se\s+usa"
    r"|dónde\s+(?:llevo|uso|pongo)"
    r"|what\s+(?:do\s+I\s+do|is\s+this|should\s+I)"
    r"|how\s+(?:do\s+I|to)"
    r")\b",
    re.IGNORECASE,
)

# Patterns that indicate the user only wants visual description (no search needed).
_VISUAL_ONLY_RE = re.compile(
    r"\b("
    r"qué\s+(?:veo|ves)"    # "qué veo/ves" — what do I/you see
    r"|describe"
    r"|qué\s+hay"
    r"|qué\s+aparece"
    r"|what\s+(?:do\s+I\s+see|is\s+on\s+screen)"
    r")\b",
    re.IGNORECASE,
)

# Prompt for entity extraction — constrained output, max_tokens ~30.
_ENTITY_EXTRACTION_PROMPT = (
    "Look at this game screenshot. Name the key object or entity the player is "
    "examining or interacting with in 3-5 words. Reply with only the entity name, "
    "no extra text."
)

# Brief interim spoken cue by locale.
_INTERIM_CUE: dict[str, str] = {
    "es": "Buscando…",
    "en": "Searching…",
}


def needs_search(question: str) -> bool:
    """Return True when the question warrants a web search.

    Pure function — no I/O, no side effects.

    Logic:
      - Visual-only patterns ("qué veo", "describe", …) → always False.
      - Search-intent patterns ("qué hago", "how do I", …) → True.
      - Neither pattern matched → False (conservative default: only search
        when the user explicitly asks for help with an in-game object/action).
        This ensures generic utterances ("hola", "gracias", etc.) never trigger
        the web-search pipeline and keep using the existing vision-only path.
    """
    if _VISUAL_ONLY_RE.search(question):
        return False
    if _SEARCH_INTENT_RE.search(question):
        return True
    # Default: no explicit search intent → use existing vision-only path.
    return False


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

def run(
    question: str,
    screenshot: str | None,
    lang: str,
    *,
    brain_ask: Callable,
    search_fn: Callable[[str], list],
    window_title_fn: Callable[[], str | None],
    speak_interim: Callable[[str], None],
) -> str:
    """Execute the deterministic web-search pipeline and return the spoken answer.

    Parameters
    ----------
    question:
        Transcribed user question.
    screenshot:
        Base64-encoded PNG of the current game frame.  Passed ONLY to the
        local brain_ask — never included in the SearXNG query.
    lang:
        User language code (e.g. "es-MX", "en").  Controls system prompt
        selection and the interim TTS cue language.
    brain_ask:
        Injected callable with signature
        ``brain_ask(prompt, *, system, image_b64, max_tokens, **kw) -> str``.
    search_fn:
        Injected callable ``(query: str) -> list[SearchResult]``.
        Must never raise — returns [] on any failure (SearXNG contract).
    window_title_fn:
        Injected callable ``() -> str | None``.
        Returns the active window caption or None (qdbus6 fallback).
    speak_interim:
        Injected callable ``(text: str) -> None``.
        Called after entity extraction to emit the "Buscando…" cue while
        the SearXNG round-trip happens in a background thread.

    Returns
    -------
    str
        The final spoken answer — either web-grounded or vision-only fallback.
    """
    # Stage 1: window title (game name for the search query, zero-hallucination).
    window_title = window_title_fn()

    # Stage 2: entity extraction — short brain_ask with the screenshot.
    # This is the ONLY time the screenshot touches an external (local) model.
    entity = ""
    try:
        entity = brain_ask(
            _ENTITY_EXTRACTION_PROMPT,
            system="You are a game screenshot analyzer. Reply with only the entity name.",
            image_b64=screenshot,
            max_tokens=30,
        ).strip()
    except Exception as exc:  # noqa: BLE001
        log.warning("entity extraction failed: %s", exc)

    # Stage 3: build the text-only search query and kick off search in background.
    # The screenshot is intentionally NOT included here — only text.
    query_parts = [p for p in [window_title or "", entity, question] if p]
    query = " ".join(query_parts).strip()

    search_results: list = []
    search_done = threading.Event()

    def _do_search() -> None:
        nonlocal search_results
        try:
            search_results = search_fn(query) or []
        except Exception as exc:  # noqa: BLE001
            log.warning("search_fn failed: %s", exc)
            search_results = []
        finally:
            search_done.set()

    search_thread = threading.Thread(target=_do_search, daemon=True)
    search_thread.start()

    # Stage 4 (parallel): emit interim TTS cue while the search runs.
    locale_key = "en" if (lang or "").startswith("en") else "es"
    interim_cue = _INTERIM_CUE.get(locale_key, _INTERIM_CUE["es"])
    try:
        speak_interim(interim_cue)
    except Exception as exc:  # noqa: BLE001
        log.warning("speak_interim failed: %s", exc)

    # Wait for search to complete.
    search_done.wait(timeout=10.0)

    # Stage 5: if no results, fall back to the existing vision-only path.
    if not search_results:
        log.info("copilot_search: no results for %r, falling back to vision-only", query)
        return _vision_only_fallback(question, screenshot, lang, brain_ask)

    # Stage 6: synthesis — inject snippets into the prompt.
    synthesis_prompt = _build_synthesis_prompt(question, search_results[:3])
    synthesis_system = _build_synthesis_system(lang)

    try:
        answer = brain_ask(
            synthesis_prompt,
            system=synthesis_system,
            image_b64=screenshot,
            max_tokens=256,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("synthesis brain_ask failed: %s", exc)
        answer = _vision_only_fallback(question, screenshot, lang, brain_ask)

    return answer


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _build_synthesis_prompt(question: str, results: list) -> str:
    """Build the synthesis prompt with search snippets injected as context."""
    snippets = []
    for i, r in enumerate(results, 1):
        title = getattr(r, "title", "")
        snippet = getattr(r, "snippet", "")
        snippets.append(f"[{i}] {title}: {snippet}")
    context = "\n".join(snippets)
    return (
        f"Contexto de búsqueda:\n{context}\n\n"
        f"Pregunta del jugador: {question}\n\n"
        f"Responde brevemente basándote en el contexto anterior."
    )


def _build_synthesis_system(lang: str) -> str:
    """Return the synthesis system prompt in the user's language."""
    if (lang or "").startswith("en"):
        return (
            "You are the game co-pilot. Answer briefly and directly using the search "
            "context and the game screenshot. No Markdown. One or two sentences."
        )
    return (
        "Eres el co-piloto de juegos. Responde de forma breve y directa usando el contexto de "
        "búsqueda y lo que ves en pantalla. Sin Markdown. Una o dos frases."
    )


def _vision_only_fallback(
    question: str,
    screenshot: str | None,
    lang: str,
    brain_ask: Callable,
) -> str:
    """Call brain_ask with vision only (no snippets) — the existing path."""
    system = _build_synthesis_system(lang)
    try:
        return brain_ask(
            question,
            system=system,
            image_b64=screenshot,
            max_tokens=256,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("vision_only_fallback failed: %s", exc)
        return ""
