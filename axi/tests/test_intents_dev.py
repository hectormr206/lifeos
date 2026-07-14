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


# ── dev_develop handler: files the request as a Desarrollo environment ───────

def test_dev_develop_handler_creates_env() -> None:
    """The hands-free dev request now creates a persistent environment (in the
    controlled /desarrollo workspace), not an inline ephemeral dev run."""
    fake_daemon = MagicMock()
    created: list[str] = []

    def fake_create(goal: str) -> str:
        created.append(goal)
        return "20260627-120000-abc123"

    with patch("axi.dev_env.create_env", side_effect=fake_create), \
         patch("axi.output.notify", return_value=None), \
         patch("axi.speak.speak", return_value=True):
        result = intents._h_dev_develop(  # noqa: SLF001
            fake_daemon, params={"goal": "una función de prueba"}
        )

    assert result == "dev_develop:env-created"
    assert created == ["una función de prueba"]


# ── dev_develop handler: confirmation localization ───────────────────────────

def _run_dev_develop(utterance_lang, params):
    """Run _h_dev_develop with a daemon carrying `_utterance_lang`.

    Returns (result, notify_bodies, speak_texts)."""
    fake_daemon = MagicMock()
    fake_daemon._utterance_lang = utterance_lang
    notify_bodies: list[str] = []
    speak_texts: list[str] = []

    def fake_notify(title, body, **kwargs):
        notify_bodies.append(body)

    def fake_speak(text, **kwargs):
        speak_texts.append(text)
        return True

    with patch("axi.dev_env.create_env", return_value="20260713-x"), \
         patch("axi.output.notify", side_effect=fake_notify), \
         patch("axi.speak.speak", side_effect=fake_speak):
        result = intents._h_dev_develop(fake_daemon, params=params)  # noqa: SLF001
    return result, notify_bodies, speak_texts


def test_dev_develop_english_confirmation():
    """English utterance → English notify + speak."""
    result, bodies, spoken = _run_dev_develop("en", {"goal": "a test function"})
    assert result == "dev_develop:env-created"
    assert bodies and "/desarrollo" in bodies[0]
    assert "Listo" not in bodies[0], f"expected English notify, got {bodies[0]!r}"
    assert spoken and "Listo" not in spoken[0], f"expected English speech, got {spoken[0]!r}"


def test_dev_develop_spanish_confirmation_unchanged():
    """Spanish utterance → the original Spanish strings, byte-for-byte."""
    result, bodies, spoken = _run_dev_develop("es", {"goal": "una función"})
    assert result == "dev_develop:env-created"
    assert bodies[0] == (
        "Listo, lo armé como ambiente en Desarrollo — entra a /desarrollo "
        "para probarlo y desplegarlo."
    )
    assert spoken[0] == (
        "Listo, lo armé como ambiente en Desarrollo. Entra a probarlo cuando quieras."
    )


def test_dev_develop_no_goal_english():
    """English utterance with empty goal → English 'didn't understand' notify."""
    result, bodies, _ = _run_dev_develop("en", {})
    assert "no-goal" in result
    assert bodies and bodies[0] == msg_en_no_goal()


def msg_en_no_goal() -> str:
    from lifeos.localize import msg
    return msg("dev_no_goal", "en")


def test_dev_develop_no_goal_spanish_unchanged():
    result, bodies, _ = _run_dev_develop("es", {})
    assert "no-goal" in result
    assert bodies[0] == "No entendí qué quieres que desarrolle."


def test_dev_develop_mock_daemon_lang_falls_back_safely():
    """A daemon without a real _utterance_lang string (MagicMock attr) must not
    crash — it falls back to the configured language."""
    fake_daemon = MagicMock()  # _utterance_lang is a MagicMock, not a str
    with patch("axi.dev_env.create_env", return_value="x"), \
         patch("axi.output.notify", return_value=None), \
         patch("axi.speak.speak", return_value=True), \
         patch("axi.config.get", side_effect=lambda k, d=None: {"language": "es-MX"}.get(k, d)):
        result = intents._h_dev_develop(fake_daemon, params={"goal": "algo"})  # noqa: SLF001
    assert result == "dev_develop:env-created"
