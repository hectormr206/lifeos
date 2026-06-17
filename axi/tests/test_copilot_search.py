"""Tests for the deterministic gaming co-pilot web-search pipeline (Slice 2).

TDD RED → GREEN cycle:
- needs_search() intent gate: search phrases→True, visual-only→False (ES+EN)
- get_active_window_title(): valid caption→str, failure/absent→None
- copilot_search.run() pipeline: fake brain_ask + fake search → correct behavior
- Empty-results fallback: search returns [] → falls back to vision-only answer
- Interim speak fired after entity extraction
"""
from __future__ import annotations

from typing import Callable
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Imports under test (fail until copilot_search.py exists — RED phase)
# ---------------------------------------------------------------------------
from axi.copilot_search import needs_search, run as copilot_search_run
from axi.vision import get_active_window_title


# ---------------------------------------------------------------------------
# Task 1: needs_search() intent gate
# ---------------------------------------------------------------------------

class TestNeedsSearch:
    """Unit tests for the pure needs_search() function."""

    # ── Spanish search-intent phrases ──
    @pytest.mark.parametrize("question", [
        "qué hago con esto",
        "¿qué hago?",
        "para qué sirve esta cosa",
        "cómo uso esto",
        "cómo resuelvo el puzzle",
        "cómo abro la puerta",
        "cómo activo el mecanismo",
        "qué es esto",
        "qué es esto que tengo aquí",
        "dónde llevo esto",
        "dónde uso la llave",
        "dónde pongo el objeto",
        "cómo funciona",
    ])
    def test_returns_true_for_spanish_search_phrases(self, question: str):
        """Spanish search-intent phrases should return True."""
        assert needs_search(question) is True, f"Expected True for: {question!r}"

    # ── English search-intent phrases ──
    @pytest.mark.parametrize("question", [
        "what do I do with this",
        "what do I do here",
        "what is this",
        "what should I do",
        "how do I open the door",
        "how do I solve this puzzle",
        "how to use this item",
    ])
    def test_returns_true_for_english_search_phrases(self, question: str):
        """English search-intent phrases should return True."""
        assert needs_search(question) is True, f"Expected True for: {question!r}"

    # ── Visual-only patterns → False ──
    @pytest.mark.parametrize("question", [
        "qué veo en pantalla",
        "qué ves en pantalla",
        "describe lo que hay",
        "qué hay en la pantalla",
        "qué aparece ahí",
        "what do I see on screen",
        "what is on screen",
    ])
    def test_returns_false_for_visual_only_phrases(self, question: str):
        """Visual-only phrases should return False — stay on vision-only path."""
        assert needs_search(question) is False, f"Expected False for: {question!r}"

    def test_default_no_match_returns_false(self):
        """When neither pattern matches, needs_search returns False (conservative default).
        Generic utterances like 'hola' or 'gracias' stay on the vision-only path."""
        assert needs_search("axi ayudame") is False
        assert needs_search("hola mundo") is False
        assert needs_search("gracias") is False

    def test_case_insensitive(self):
        """Pattern matching must be case-insensitive."""
        assert needs_search("QUÉ HAGO CON ESTO") is True
        assert needs_search("QUÉ VEO EN PANTALLA") is False


# ---------------------------------------------------------------------------
# Task 2: get_active_window_title() — window title via qdbus6
# ---------------------------------------------------------------------------

class TestGetActiveWindowTitle:
    """Unit tests for vision.get_active_window_title()."""

    def test_returns_caption_when_qdbus6_present(self):
        """When qdbus6 is present and returns a valid output, extract caption."""
        fake_output = (
            "caption: Resident Evil Village\n"
            "desktop: 1\n"
            "resourceClass: wine\n"
        )
        with patch("shutil.which", return_value="/usr/bin/qdbus6"), \
             patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout=fake_output,
                returncode=0,
            )
            result = get_active_window_title()
        assert result == "Resident Evil Village"

    def test_returns_none_when_qdbus6_absent(self):
        """When qdbus6 is not installed, return None gracefully."""
        with patch("shutil.which", return_value=None):
            result = get_active_window_title()
        assert result is None

    def test_returns_none_on_subprocess_exception(self):
        """When subprocess raises (timeout, OSError, etc.), return None."""
        with patch("shutil.which", return_value="/usr/bin/qdbus6"), \
             patch("subprocess.run", side_effect=Exception("qdbus6 crashed")):
            result = get_active_window_title()
        assert result is None

    def test_returns_none_when_caption_line_missing(self):
        """When output has no caption: line, return None."""
        fake_output = "desktop: 1\nresourceClass: wine\n"
        with patch("shutil.which", return_value="/usr/bin/qdbus6"), \
             patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=fake_output, returncode=0)
            result = get_active_window_title()
        assert result is None

    def test_returns_none_when_caption_empty(self):
        """When caption line exists but is blank, return None."""
        fake_output = "caption: \ndesktop: 1\n"
        with patch("shutil.which", return_value="/usr/bin/qdbus6"), \
             patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=fake_output, returncode=0)
            result = get_active_window_title()
        assert result is None


# ---------------------------------------------------------------------------
# Task 3: copilot_search.run() pipeline — full happy path
# ---------------------------------------------------------------------------

class TestCopilotSearchRun:
    """Unit tests for the copilot_search.run() deterministic pipeline."""

    def _fake_brain_ask_factory(self, entity_reply: str, synthesis_reply: str):
        """Return a fake brain_ask that returns entity then synthesis on successive calls."""
        calls = []

        def fake_brain_ask(prompt, *, system="", image_b64=None, max_tokens=256, **kw):
            calls.append({"prompt": prompt, "system": system, "image_b64": image_b64, "max_tokens": max_tokens})
            if len(calls) == 1:
                # First call = entity extraction
                return entity_reply
            # Second call = synthesis
            return synthesis_reply

        return fake_brain_ask, calls

    def _fake_search_fn(self, results):
        """Return a fake search function that records the query and returns results."""
        queries = []

        def search(query: str):
            queries.append(query)
            return results

        return search, queries

    def test_run_happy_path_returns_synthesis_answer(self):
        """Full pipeline with valid search results returns synthesis answer."""
        from lifeos.web.port import SearchResult

        brain_ask, brain_calls = self._fake_brain_ask_factory(
            entity_reply="severed hand",
            synthesis_reply="Llevá la mano al altar del norte.",
        )
        search_fn, search_queries = self._fake_search_fn([
            SearchResult(title="RE Village Guide", url="https://example.com/1", snippet="The severed hand is used at the altar."),
            SearchResult(title="Wiki", url="https://example.com/2", snippet="Bring the hand to the stone door."),
        ])
        speak_calls = []
        speak_interim = lambda text: speak_calls.append(text)

        answer = copilot_search_run(
            question="qué hago con la mano",
            screenshot="fake_b64",
            lang="es-MX",
            brain_ask=brain_ask,
            search_fn=search_fn,
            window_title_fn=lambda: "Resident Evil Village",
            speak_interim=speak_interim,
        )

        assert answer == "Llevá la mano al altar del norte."

    def test_run_builds_query_with_window_title_and_entity(self):
        """Search query must include window title + extracted entity."""
        from lifeos.web.port import SearchResult

        brain_ask, _ = self._fake_brain_ask_factory(
            entity_reply="strange key",
            synthesis_reply="Use the strange key on the chest.",
        )
        search_fn, search_queries = self._fake_search_fn([
            SearchResult(title="Guide", url="https://example.com/1", snippet="The key opens the red chest."),
        ])

        copilot_search_run(
            question="what do I do with this",
            screenshot="fake_b64",
            lang="en",
            brain_ask=brain_ask,
            search_fn=search_fn,
            window_title_fn=lambda: "Dark Souls III",
            speak_interim=lambda t: None,
        )

        assert len(search_queries) == 1
        query = search_queries[0]
        assert "Dark Souls III" in query
        assert "strange key" in query

    def test_run_synthesis_receives_snippets_as_context(self):
        """Brain synthesis call must include the search snippets in the prompt."""
        from lifeos.web.port import SearchResult

        brain_ask, brain_calls = self._fake_brain_ask_factory(
            entity_reply="red medallion",
            synthesis_reply="Coloca el medallón en la puerta roja.",
        )
        search_fn, _ = self._fake_search_fn([
            SearchResult(title="Guide", url="https://example.com", snippet="Place the red medallion in the door slot."),
        ])

        copilot_search_run(
            question="qué hago con esto",
            screenshot="fake_b64",
            lang="es-MX",
            brain_ask=brain_ask,
            search_fn=search_fn,
            window_title_fn=lambda: None,
            speak_interim=lambda t: None,
        )

        # Second brain call is synthesis — its prompt must contain snippet text
        assert len(brain_calls) >= 2
        synthesis_call = brain_calls[1]
        assert "Place the red medallion in the door slot." in synthesis_call["prompt"]

    def test_image_never_passed_to_search_fn(self):
        """The screenshot (image_b64) must NEVER reach the search function — privacy."""
        from lifeos.web.port import SearchResult

        screenshot_value = "SENSITIVE_IMAGE_B64_DATA"
        received_queries = []
        received_search_args = []

        def spy_search(query: str):
            received_queries.append(query)
            received_search_args.append({"query": query})
            return [SearchResult(title="t", url="u", snippet="s")]

        brain_ask, _ = self._fake_brain_ask_factory("item", "answer")

        copilot_search_run(
            question="qué hago",
            screenshot=screenshot_value,
            lang="es-MX",
            brain_ask=brain_ask,
            search_fn=spy_search,
            window_title_fn=lambda: None,
            speak_interim=lambda t: None,
        )

        # The screenshot value must not appear in any search query
        for call in received_search_args:
            assert screenshot_value not in call["query"], (
                "Screenshot data leaked into search query — privacy violation"
            )

    def test_interim_speak_fired_during_search(self):
        """speak_interim must be called once during the pipeline."""
        from lifeos.web.port import SearchResult

        brain_ask, _ = self._fake_brain_ask_factory("entity", "final answer")
        search_fn, _ = self._fake_search_fn([
            SearchResult(title="t", url="u", snippet="s"),
        ])
        speak_calls = []

        copilot_search_run(
            question="qué hago",
            screenshot="fake_b64",
            lang="es-MX",
            brain_ask=brain_ask,
            search_fn=search_fn,
            window_title_fn=lambda: None,
            speak_interim=lambda t: speak_calls.append(t),
        )

        assert len(speak_calls) >= 1, "speak_interim was never called"
        # Interim message should be a non-empty string
        assert speak_calls[0], "speak_interim called with empty string"


# ---------------------------------------------------------------------------
# Task 4: Empty-results fallback → vision-only answer
# ---------------------------------------------------------------------------

class TestCopilotSearchEmptyResultsFallback:
    """When search returns [], run() must fall back to a vision-only brain call."""

    def test_empty_results_falls_back_to_vision_only(self):
        """When search_fn returns [], the pipeline must call brain_ask once more
        WITHOUT search snippets and return that answer (vision-only fallback)."""
        calls = []

        def brain_ask(prompt, *, system="", image_b64=None, max_tokens=256, **kw):
            calls.append({"prompt": prompt, "system": system, "image_b64": image_b64})
            if len(calls) == 1:
                return "extracted entity"  # entity extraction
            # Vision-only fallback call
            return "respuesta solo por visión"

        copilot_search_run(
            question="qué hago con esto",
            screenshot="fake_b64",
            lang="es-MX",
            brain_ask=brain_ask,
            search_fn=lambda q: [],   # empty results
            window_title_fn=lambda: None,
            speak_interim=lambda t: None,
        )

        # Last call should be the vision-only fallback
        assert len(calls) >= 2
        fallback_call = calls[-1]
        # The fallback call must have the screenshot (vision path)
        assert fallback_call["image_b64"] == "fake_b64"

    def test_empty_results_fallback_returns_vision_answer(self):
        """The return value must be the vision-only brain answer, not None."""
        calls = []

        def brain_ask(prompt, *, system="", image_b64=None, max_tokens=256, **kw):
            calls.append(1)
            if len(calls) == 1:
                return "entity"
            return "respuesta sin web"

        result = copilot_search_run(
            question="qué hago",
            screenshot="fake_b64",
            lang="es-MX",
            brain_ask=brain_ask,
            search_fn=lambda q: [],
            window_title_fn=lambda: None,
            speak_interim=lambda t: None,
        )

        assert result == "respuesta sin web"
