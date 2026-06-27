"""Tests for the dev_develop voice intent and handler signature compatibility."""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from axi import intents


# ── classify: dev_develop positive cases ────────────────────────────────────

@pytest.mark.parametrize("text,expected_goal_fragment", [
    ("axi, desarrollá una función que sume dos números", "una función que sume dos números"),
    ("Axi desarrolla un script de Python", "un script de Python"),
    ("axi, programá un módulo de logging", "un módulo de logging"),
    ("axi implementá el sistema de caché", "el sistema de caché"),
    ("axi, codeá una API REST", "una API REST"),
    ("axi, creá un programa que guarde notas", "guarde notas"),
    ("axi hacé una función que calcule fibonacci", "calcule fibonacci"),
])
def test_dev_develop_matches(text: str, expected_goal_fragment: str) -> None:
    result = intents.classify(text)
    assert result is not None, f"expected dev_develop match for {text!r}, got None"
    name, params = result
    assert name == "dev_develop", f"expected dev_develop, got {name!r}"
    assert "goal" in params, f"expected 'goal' in params, got {params!r}"
    assert expected_goal_fragment.lower() in params["goal"].lower(), (
        f"expected {expected_goal_fragment!r} in goal {params['goal']!r}"
    )


def test_dev_develop_goal_strip() -> None:
    result = intents.classify("axi, desarrollá una función que sume dos números")
    assert result is not None
    name, params = result
    assert name == "dev_develop"
    assert params["goal"] == "una función que sume dos números"


# ── classify: empty goal must NOT match ─────────────────────────────────────

@pytest.mark.parametrize("text", [
    "axi, desarrollá",
    "axi desarrollá ",
    "axi, programá",
])
def test_dev_develop_empty_goal_no_match(text: str) -> None:
    result = intents.classify(text)
    if result is not None:
        name, _ = result
        assert name != "dev_develop", f"dev_develop matched with empty goal for {text!r}"


# ── existing intents still classify correctly ────────────────────────────────

@pytest.mark.parametrize("text,expected", [
    ("axi, empieza la reunión", "meeting_start"),
    ("axi termina reunión", "meeting_stop"),
    ("axi, abre el dashboard", "open_dashboard"),
    ("axi activa modo juego", "game_on"),
    ("axi, limpia conversación", "clear_conversation"),
])
def test_existing_intents_unaffected(text: str, expected: str) -> None:
    result = intents.classify(text)
    assert result is not None, f"expected {expected!r} for {text!r}, got None"
    name, params = result
    assert name == expected


def test_existing_intent_params_empty_dict() -> None:
    result = intents.classify("axi, abre el dashboard")
    assert result is not None
    name, params = result
    assert name == "open_dashboard"
    assert params == {}


# ── existing handlers callable with new (daemon, params) signature ───────────

def test_all_existing_handlers_accept_params() -> None:
    """All handlers must accept (daemon, params) without TypeError."""
    fake_daemon = MagicMock()
    existing_handlers = [
        "meeting_start", "meeting_stop", "open_dashboard",
        "translate_on", "translate_off", "game_on", "game_off", "clear_conversation",
    ]
    for name in existing_handlers:
        handler = intents.INTENT_HANDLERS[name]
        # Should not raise TypeError when called with (daemon, params)
        try:
            with patch("axi.intents._send_cmd", return_value="ok"), \
                 patch("axi.intents._popen", return_value="spawned"):
                handler(fake_daemon, {"test": "param"})
        except Exception as exc:
            # We only care about TypeError (signature mismatch), not script-not-found
            assert not isinstance(exc, TypeError), (
                f"handler {name!r} raised TypeError with (daemon, params): {exc}"
            )


def test_handlers_table_contains_dev_develop() -> None:
    assert "dev_develop" in intents.INTENT_HANDLERS


# ── dev_develop handler: no-goal guard ──────────────────────────────────────

def test_dev_develop_handler_no_goal() -> None:
    fake_daemon = MagicMock()
    with patch("axi.output.notify", return_value=None):
        result = intents._h_dev_develop(fake_daemon, params={})  # noqa: SLF001
    assert "no-goal" in result


# ── dev_develop handler: calls dev_run.start_dev_run on valid goal ───────────

def test_dev_develop_handler_calls_start_dev_run() -> None:
    fake_daemon = MagicMock()
    started: list[str] = []

    def fake_start(goal: str) -> str:
        started.append(goal)
        return "20260625-120000-abc123"

    with patch("axi.dev_run.start_dev_run", side_effect=fake_start), \
         patch("axi.output.notify", return_value=None), \
         patch("axi.speak.speak", return_value=True):
        result = intents._h_dev_develop(  # noqa: SLF001
            fake_daemon, params={"goal": "una función de prueba"}
        )

    assert result == "dev_develop:started"
    assert started == ["una función de prueba"]
