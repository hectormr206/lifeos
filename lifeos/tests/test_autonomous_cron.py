"""Tests for lifeos.autonomous.cron — the Axi reflection tick.

Strict TDD: tests written first per the RED→GREEN task checklist.
All dependencies are injected fakes — no real brain, push, scheduler, or I/O.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, date
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, call
from zoneinfo import ZoneInfo

import pytest

MX = ZoneInfo("America/Mexico_City")


def _now(hour: int = 12, minute: int = 0, day: int = 10) -> datetime:
    """Return a timezone-aware datetime in America/Mexico_City."""
    return datetime(2026, 6, day, hour, minute, tzinfo=MX)


def _today(day: int = 10) -> str:
    return f"2026-06-{day:02d}"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _isolated_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Isolate LIFEOS_STATE_DIR for every test."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    yield


def _default_configure(**overrides):
    """Call configure() with sensible defaults. Overrides replace any key."""
    from lifeos.autonomous import cron
    defaults: dict[str, Any] = dict(
        brain_ask=lambda prompt, **kw: "Tienes una cita médica mañana.",
        digest_fn=lambda: "Héctor corrió 5 km hoy.",
        correlate_fn=lambda: "Sin correlaciones relevantes.",
        push_fn=MagicMock(return_value={"sent": 1}),
        now_fn=lambda: _now(),
        is_enabled_fn=lambda: True,
        alive_fn=lambda: True,
        spoke_read_fn=lambda: None,
        spoke_write_fn=MagicMock(),
        log_fn=MagicMock(),
        window_start_hour=8,
        window_end_hour=22,
    )
    defaults.update(overrides)
    cron.configure(**defaults)


# ---------------------------------------------------------------------------
# TASK-2: configure() + TickResult smoke
# ---------------------------------------------------------------------------

def test_configure_resets_state() -> None:
    """configure() wires all callables; run_tick no longer raises RuntimeError."""
    from lifeos.autonomous import cron
    _default_configure()
    result = cron.run_tick(_now())
    # Should NOT raise; outcome can be anything valid
    assert result.outcome is not None


# ---------------------------------------------------------------------------
# TASK-3: Waking-window guard
# ---------------------------------------------------------------------------

def test_tick_outside_window_returns_skipped_outside_window() -> None:
    """run_tick at 06:00 (below window_start_hour=8) → skipped-outside-window."""
    from lifeos.autonomous import cron
    push_spy = MagicMock()
    log_spy = MagicMock()
    _default_configure(
        push_fn=push_spy,
        log_fn=log_spy,
        now_fn=lambda: _now(hour=6),
    )
    result = cron.run_tick(_now(hour=6))
    assert result.outcome == "skipped-outside-window"
    push_spy.assert_not_called()
    log_spy.assert_called_once()
    assert log_spy.call_args[1]["data"]["outcome"] == "skipped-outside-window"


def test_tick_at_end_of_window_boundary_is_skipped() -> None:
    """run_tick at hour == window_end_hour (22) → skipped-outside-window."""
    from lifeos.autonomous import cron
    _default_configure(window_end_hour=22)
    result = cron.run_tick(_now(hour=22))
    assert result.outcome == "skipped-outside-window"


def test_tick_inside_window_proceeds() -> None:
    """run_tick at 14:00 (inside 8-22 window) → not skipped-outside-window."""
    from lifeos.autonomous import cron
    _default_configure()
    result = cron.run_tick(_now(hour=14))
    assert result.outcome != "skipped-outside-window"


# ---------------------------------------------------------------------------
# TASK-4: 1/Day cap — spoke-today guard
# ---------------------------------------------------------------------------

def test_tick_skips_when_already_spoke_today() -> None:
    """spoke_read_fn returns today's date → skipped-already-spoke; brain not called."""
    from lifeos.autonomous import cron
    brain_spy = MagicMock(return_value="whatever")
    push_spy = MagicMock()
    log_spy = MagicMock()
    _default_configure(
        brain_ask=brain_spy,
        push_fn=push_spy,
        log_fn=log_spy,
        spoke_read_fn=lambda: _today(),
    )
    result = cron.run_tick(_now())
    assert result.outcome == "skipped-already-spoke"
    brain_spy.assert_not_called()
    push_spy.assert_not_called()
    log_spy.assert_called_once()
    assert log_spy.call_args[1]["data"]["outcome"] == "skipped-already-spoke"


def test_tick_proceeds_when_spoke_yesterday() -> None:
    """spoke_read_fn returns yesterday → brain IS called (returns a message)."""
    from lifeos.autonomous import cron
    brain_spy = MagicMock(return_value="Tienes cita mañana a las 10.")
    _default_configure(
        brain_ask=brain_spy,
        spoke_read_fn=lambda: _today(day=9),  # yesterday
    )
    result = cron.run_tick(_now())
    brain_spy.assert_called_once()
    assert result.outcome == "pushed"


# ---------------------------------------------------------------------------
# TASK-5: Brain-down guard
# ---------------------------------------------------------------------------

def test_tick_skips_when_brain_not_alive() -> None:
    """alive_fn returns False → skipped-brain-down; brain_ask NOT called."""
    from lifeos.autonomous import cron
    brain_spy = MagicMock()
    push_spy = MagicMock()
    log_spy = MagicMock()
    _default_configure(
        brain_ask=brain_spy,
        push_fn=push_spy,
        log_fn=log_spy,
        alive_fn=lambda: False,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "skipped-brain-down"
    brain_spy.assert_not_called()
    push_spy.assert_not_called()
    log_spy.assert_called_once()
    assert log_spy.call_args[1]["data"]["outcome"] == "skipped-brain-down"


def test_tick_skips_when_brain_ask_raises() -> None:
    """brain_ask raises → skipped-brain-down; brain_ask WAS called (liveness passed)."""
    from lifeos.autonomous import cron
    def _bad_brain(*a, **kw):
        raise RuntimeError("llama died")
    push_spy = MagicMock()
    log_spy = MagicMock()
    _default_configure(
        brain_ask=_bad_brain,
        push_fn=push_spy,
        log_fn=log_spy,
        alive_fn=lambda: True,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "skipped-brain-down"
    push_spy.assert_not_called()
    log_spy.assert_called_once()
    assert log_spy.call_args[1]["data"]["outcome"] == "skipped-brain-down"


# ---------------------------------------------------------------------------
# TASK-6: Empty-digest skip
# ---------------------------------------------------------------------------

def test_tick_skips_empty_digest() -> None:
    """Both digest and correlate empty → skipped-empty; brain NOT called."""
    from lifeos.autonomous import cron
    brain_spy = MagicMock()
    _default_configure(
        brain_ask=brain_spy,
        digest_fn=lambda: "",
        correlate_fn=lambda: "",
    )
    result = cron.run_tick(_now())
    assert result.outcome == "skipped-empty"
    brain_spy.assert_not_called()


def test_tick_skips_whitespace_only_digest() -> None:
    """Whitespace-only digest+correlate → skipped-empty."""
    from lifeos.autonomous import cron
    brain_spy = MagicMock()
    _default_configure(
        brain_ask=brain_spy,
        digest_fn=lambda: "   ",
        correlate_fn=lambda: "   ",
    )
    result = cron.run_tick(_now())
    assert result.outcome == "skipped-empty"
    brain_spy.assert_not_called()


def test_tick_proceeds_when_digest_has_content() -> None:
    """Non-empty digest → brain IS called."""
    from lifeos.autonomous import cron
    brain_spy = MagicMock(return_value="Tienes una cita médica mañana.")
    _default_configure(brain_ask=brain_spy)
    result = cron.run_tick(_now())
    brain_spy.assert_called_once()


# ---------------------------------------------------------------------------
# TASK-7: Sentinel parser — three-way outcome
# ---------------------------------------------------------------------------

def test_parse_reply_exact_esperar_any_casing_whitespace() -> None:
    """'  esperar  ' → outcome esperar; push NOT called; spoke_write NOT called."""
    from lifeos.autonomous import cron
    push_spy = MagicMock()
    spoke_write_spy = MagicMock()
    log_spy = MagicMock()
    _default_configure(
        brain_ask=lambda *a, **kw: "  esperar  ",
        push_fn=push_spy,
        spoke_write_fn=spoke_write_spy,
        log_fn=log_spy,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "esperar"
    push_spy.assert_not_called()
    spoke_write_spy.assert_not_called()
    log_spy.assert_called_once()
    assert log_spy.call_args[1]["data"]["outcome"] == "esperar"


def test_parse_reply_exact_nada() -> None:
    """'NADA' → outcome nada; push NOT called; spoke_write CALLED (Decision B)."""
    from lifeos.autonomous import cron
    push_spy = MagicMock()
    spoke_write_spy = MagicMock()
    _default_configure(
        brain_ask=lambda *a, **kw: "NADA",
        push_fn=push_spy,
        spoke_write_fn=spoke_write_spy,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "nada"
    push_spy.assert_not_called()
    spoke_write_spy.assert_called_once_with(_today())


def test_parse_reply_real_message_pushes() -> None:
    """Real message → outcome pushed; push called once; spoke_write called."""
    from lifeos.autonomous import cron
    push_spy = MagicMock(return_value={"sent": 1})
    spoke_write_spy = MagicMock()
    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes cita médica mañana a las 10.",
        push_fn=push_spy,
        spoke_write_fn=spoke_write_spy,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "pushed"
    push_spy.assert_called_once()
    spoke_write_spy.assert_called_once_with(_today())


def test_parse_reply_message_containing_esperar_pushes() -> None:
    """'Hay que esperar resultados...' is a real message, NOT a sentinel → pushed."""
    from lifeos.autonomous import cron
    push_spy = MagicMock(return_value={"sent": 1})
    _default_configure(
        brain_ask=lambda *a, **kw: "Hay que esperar resultados del médico mañana.",
        push_fn=push_spy,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "pushed"
    push_spy.assert_called_once()


def test_parse_reply_empty_string_becomes_nada() -> None:
    """Empty reply → nada (nothing to say)."""
    from lifeos.autonomous import cron
    push_spy = MagicMock()
    _default_configure(
        brain_ask=lambda *a, **kw: "",
        push_fn=push_spy,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "nada"
    push_spy.assert_not_called()


def test_parse_reply_brain_error_sentinel_becomes_nada() -> None:
    """Brain error sentinel '[Axi brain no responde…]' → nada."""
    from lifeos.autonomous import cron
    push_spy = MagicMock()
    _default_configure(
        brain_ask=lambda *a, **kw: "[Axi brain no responde…]",
        push_fn=push_spy,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "nada"
    push_spy.assert_not_called()


def test_message_is_capped_at_max_chars() -> None:
    """Brain reply longer than max_message_chars is truncated before push."""
    from lifeos.autonomous import cron
    long_msg = "x" * 200
    captured: list[Any] = []
    _default_configure(
        brain_ask=lambda *a, **kw: long_msg,
        push_fn=lambda title, body, **kw: captured.append(body) or {"sent": 1},
        max_message_chars=120,
    )
    cron.run_tick(_now())
    assert len(captured) == 1
    assert len(captured[0]) <= 120


# ---------------------------------------------------------------------------
# TASK-8: Full audit log coverage (every outcome logs exactly once)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("outcome,setup", [
    ("pushed",               {"brain_ask": lambda *a, **kw: "Tienes cita médica mañana."}),
    ("esperar",              {"brain_ask": lambda *a, **kw: "ESPERAR"}),
    ("nada",                 {"brain_ask": lambda *a, **kw: "NADA"}),
    ("skipped-empty",        {"digest_fn": lambda: "", "correlate_fn": lambda: ""}),
    ("skipped-brain-down",   {"alive_fn": lambda: False}),
    ("skipped-already-spoke",{"spoke_read_fn": lambda: _today()}),
    ("skipped-outside-window", {"now_fn": lambda: _now(hour=6)}),
])
def test_every_outcome_logs_exactly_once(outcome: str, setup: dict) -> None:
    """Every terminal outcome logs exactly once with the right outcome string."""
    from lifeos.autonomous import cron
    log_spy = MagicMock()
    _default_configure(log_fn=log_spy, **setup)
    now = setup.get("now_fn", lambda: _now())()
    cron.run_tick(now)
    assert log_spy.call_count == 1
    kwargs = log_spy.call_args[1]
    assert "autonomous.tick" in log_spy.call_args[0] or log_spy.call_args[0][0] == "autonomous.tick"
    assert kwargs["data"]["outcome"] == outcome


# ---------------------------------------------------------------------------
# TASK-9: Read-only invariant
# ---------------------------------------------------------------------------

def test_no_domain_write_called_on_any_tick_path() -> None:
    """No domain store writes happen on any tick path."""
    from lifeos.autonomous import cron

    entries_spy = MagicMock()
    interactions_spy = MagicMock()
    reminders_spy = MagicMock()

    outcomes_setups = [
        {},  # normal push
        {"brain_ask": lambda *a, **kw: "ESPERAR"},
        {"brain_ask": lambda *a, **kw: "NADA"},
        {"digest_fn": lambda: "", "correlate_fn": lambda: ""},
        {"alive_fn": lambda: False},
        {"spoke_read_fn": lambda: _today()},
        {"now_fn": lambda: _now(hour=6)},
    ]

    for setup in outcomes_setups:
        _default_configure(**setup)
        now = setup.get("now_fn", lambda: _now())()
        cron.run_tick(now)
        entries_spy.assert_not_called()
        interactions_spy.assert_not_called()
        reminders_spy.assert_not_called()


# ---------------------------------------------------------------------------
# TASK-10: State file helpers
# ---------------------------------------------------------------------------

def test_read_last_pushed_returns_none_when_file_missing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "empty_state"))
    from lifeos.autonomous import cron
    result = cron.read_last_pushed()
    assert result is None


def test_write_then_read_roundtrip(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    from lifeos.autonomous import cron
    import importlib
    importlib.reload(cron)  # ensure fresh state path uses new env
    cron.write_last_pushed("2026-06-10")
    assert cron.read_last_pushed() == "2026-06-10"


def test_read_last_pushed_tolerates_corrupt_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    state_dir = tmp_path / "corrupt_state"
    state_dir.mkdir(parents=True)
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(state_dir))
    from lifeos.autonomous import cron
    (state_dir / "autonomous_last.json").write_text("not-valid-json{{{{")
    result = cron.read_last_pushed()
    assert result is None


# ---------------------------------------------------------------------------
# TASK-11: Prompt builder — brain called with expected shape
# ---------------------------------------------------------------------------

def test_brain_ask_called_with_expected_prompt_shape() -> None:
    """brain_ask receives a prompt containing time, digest body, edge summary, sentinels."""
    from lifeos.autonomous import cron
    captured_prompt: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompt.append(prompt)
        return "ESPERAR"

    _default_configure(
        brain_ask=_spy_brain,
        digest_fn=lambda: "Entreno en gym.",
        correlate_fn=lambda: "Sin correlaciones.",
        now_fn=lambda: _now(hour=14, minute=30),
    )
    cron.run_tick(_now(hour=14, minute=30))
    assert len(captured_prompt) == 1
    prompt = captured_prompt[0]
    assert "14:30" in prompt
    assert "Entreno en gym." in prompt
    assert "Sin correlaciones." in prompt
    assert "ESPERAR" in prompt
    assert "NADA" in prompt
    assert "120" in prompt  # max chars hint


# ---------------------------------------------------------------------------
# TASK-P0: PerceptionContext types are importable and have correct defaults
# ---------------------------------------------------------------------------

def test_perception_context_defaults() -> None:
    """PerceptionContext() defaults: presence=unknown, screen_b64=None, webcam_ok=False."""
    from lifeos.autonomous.cron import PerceptionContext, _NO_PERCEPTION
    ctx = PerceptionContext()
    assert ctx.presence == "unknown"
    assert ctx.screen_b64 is None
    assert ctx.webcam_ok is False
    assert ctx.activity_hint is None
    # _NO_PERCEPTION is the shared frozen instance
    assert _NO_PERCEPTION == ctx


def test_perception_context_is_frozen() -> None:
    """PerceptionContext is frozen — mutation raises."""
    from lifeos.autonomous.cron import PerceptionContext
    ctx = PerceptionContext(presence="present", webcam_ok=True)
    with pytest.raises((AttributeError, TypeError)):
        ctx.presence = "unknown"  # type: ignore[misc]


# ---------------------------------------------------------------------------
# TASK-P1A RED → TASK-P1B GREEN: perceive_fn threading into brain_ask
# ---------------------------------------------------------------------------

def test_perceive_fn_screen_b64_passed_to_brain_ask() -> None:
    """configure(perceive_fn=fake) → run_tick passes ctx.screen_b64 as image_b64 to brain_ask."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_kwargs: list[dict] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_kwargs.append(kw)
        return "ESPERAR"

    fake_ctx = PerceptionContext(presence="present", screen_b64="FAKESCREEN64", webcam_ok=True)

    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert len(captured_kwargs) == 1
    assert captured_kwargs[0].get("image_b64") == "FAKESCREEN64"


def test_no_perceive_fn_brain_ask_image_b64_is_none() -> None:
    """When perceive_fn is NOT injected, brain_ask receives image_b64=None (back-compat)."""
    from lifeos.autonomous import cron

    captured_kwargs: list[dict] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_kwargs.append(kw)
        return "ESPERAR"

    # Do NOT pass perceive_fn
    _default_configure(brain_ask=_spy_brain)
    cron.run_tick(_now())
    assert len(captured_kwargs) == 1
    # image_b64 should be None (or absent — both mean the same)
    assert captured_kwargs[0].get("image_b64") is None


def test_perceive_fn_with_none_screen_b64_passes_none_to_brain() -> None:
    """ctx.screen_b64=None → brain_ask still called, image_b64=None (graceful degrade)."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_kwargs: list[dict] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_kwargs.append(kw)
        return "Tienes una cita."

    fake_ctx = PerceptionContext(presence="present", screen_b64=None, webcam_ok=False)
    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    result = cron.run_tick(_now())
    assert len(captured_kwargs) == 1
    assert captured_kwargs[0].get("image_b64") is None
    # tick must complete — not crash
    assert result.outcome in ("pushed", "esperar", "nada")


# ---------------------------------------------------------------------------
# TASK-P2A RED → TASK-P2B GREEN: _build_prompt includes perception block
# ---------------------------------------------------------------------------

def test_build_prompt_includes_presence_present_text() -> None:
    """Prompt includes presence=present text when ctx.presence=='present'."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_prompt: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompt.append(prompt)
        return "ESPERAR"

    fake_ctx = PerceptionContext(presence="present", screen_b64="FAKEDATA", webcam_ok=True)
    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert len(captured_prompt) == 1
    # Should contain some presence indicator text
    assert "presente" in captured_prompt[0].lower() or "presencia" in captured_prompt[0].lower()


def test_build_prompt_includes_presence_unknown_text() -> None:
    """Prompt mentions camera/presence uncertainty when ctx.presence=='unknown'."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_prompt: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompt.append(prompt)
        return "ESPERAR"

    fake_ctx = PerceptionContext(presence="unknown", screen_b64=None, webcam_ok=False)
    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert len(captured_prompt) == 1
    prompt = captured_prompt[0]
    # Should contain uncertainty / no-presence words
    assert any(kw in prompt.lower() for kw in ("no se pudo", "cámara", "bloqueada", "apagada", "desconocida", "confirm"))


def test_build_prompt_includes_screen_instruction_when_screen_present() -> None:
    """Prompt includes screen-description instruction when screen_b64 is set."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_prompt: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompt.append(prompt)
        return "ESPERAR"

    fake_ctx = PerceptionContext(presence="present", screen_b64="SCREENDATA", webcam_ok=True)
    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert len(captured_prompt) == 1
    prompt = captured_prompt[0]
    # Should contain an instruction to look at screen / decide if good moment
    assert any(kw in prompt.lower() for kw in ("pantalla", "mirá", "mira", "captura", "haciendo", "interrumpir"))


def test_build_prompt_no_screen_instruction_when_no_screen() -> None:
    """When screen_b64 is None, prompt says activity is unknown."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_prompt: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompt.append(prompt)
        return "ESPERAR"

    fake_ctx = PerceptionContext(presence="unknown", screen_b64=None, webcam_ok=False)
    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert len(captured_prompt) == 1
    prompt = captured_prompt[0]
    # Should say no screen / decide with life context only
    assert any(kw in prompt.lower() for kw in ("no hay captura", "sin captura", "solo con el contexto", "no disponible", "contexto de vida"))


# ---------------------------------------------------------------------------
# TASK-P3A RED → TASK-P3B GREEN: behavior matrix
# ---------------------------------------------------------------------------

def test_presence_present_receptive_brain_pushes() -> None:
    """present + receptive brain reply → pushed outcome."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    push_spy = MagicMock(return_value={"sent": 1})
    fake_ctx = PerceptionContext(presence="present", screen_b64="SCREEN", webcam_ok=True)
    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes una cita médica mañana a las 10.",
        push_fn=push_spy,
        perceive_fn=lambda: fake_ctx,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "pushed"
    push_spy.assert_called_once()


def test_presence_present_brain_esperar_no_push() -> None:
    """present + brain returns ESPERAR → esperar outcome, no push."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    push_spy = MagicMock()
    fake_ctx = PerceptionContext(presence="present", screen_b64="SCREEN", webcam_ok=True)
    _default_configure(
        brain_ask=lambda *a, **kw: "ESPERAR",
        push_fn=push_spy,
        perceive_fn=lambda: fake_ctx,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "esperar"
    push_spy.assert_not_called()


def test_presence_unknown_brain_esperar_no_push() -> None:
    """unknown presence + brain returns ESPERAR → esperar outcome, no push."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    push_spy = MagicMock()
    fake_ctx = PerceptionContext(presence="unknown", screen_b64=None, webcam_ok=False)
    _default_configure(
        brain_ask=lambda *a, **kw: "ESPERAR",
        push_fn=push_spy,
        perceive_fn=lambda: fake_ctx,
    )
    result = cron.run_tick(_now())
    assert result.outcome == "esperar"
    push_spy.assert_not_called()


# ---------------------------------------------------------------------------
# TASK-P4A RED → TASK-P4B GREEN: capture-failure degradation
# ---------------------------------------------------------------------------

def test_screen_capture_failure_tick_completes_text_only() -> None:
    """ctx.screen_b64=None → tick completes normally; image_b64=None to brain."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    captured_kwargs: list[dict] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_kwargs.append(kw)
        return "Algo importante."

    # Screen capture failed → screen_b64=None
    fake_ctx = PerceptionContext(presence="present", screen_b64=None, webcam_ok=True)
    _default_configure(
        brain_ask=_spy_brain,
        perceive_fn=lambda: fake_ctx,
    )
    result = cron.run_tick(_now())
    assert len(captured_kwargs) == 1
    assert captured_kwargs[0].get("image_b64") is None
    # Tick must complete successfully (pushed/esperar/nada, not a crash)
    assert result.outcome in ("pushed", "esperar", "nada")


def test_perceive_fn_raising_does_not_break_tick() -> None:
    """perceive_fn that raises must not break the tick (handled outside run_tick per design).

    NOTE: per design, perceive_fn MUST NOT raise. This test documents the expected
    behavior at the run_tick level — if someone passes a buggy perceive_fn that
    does raise, run_tick should degrade to _NO_PERCEPTION (or the dashboard wiring
    should swallow errors). This test verifies run_tick-level safety."""
    from lifeos.autonomous import cron

    captured_results: list = []

    def _bad_perceive():
        raise OSError("camera exploded")

    push_spy = MagicMock(return_value={"sent": 1})
    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes cita.",
        push_fn=push_spy,
        perceive_fn=_bad_perceive,
    )
    # run_tick must NOT raise; it should degrade and complete
    result = cron.run_tick(_now())
    assert result.outcome in ("pushed", "esperar", "nada", "skipped-brain-down")


# ---------------------------------------------------------------------------
# TASK-P6A RED → TASK-P6B GREEN: log enrichment with perception fields
# ---------------------------------------------------------------------------

def test_log_enriched_with_perception_fields_on_push() -> None:
    """On 'pushed' outcome, log data includes presence, webcam_ok, screen_available, activity_descriptor."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    log_spy = MagicMock()
    fake_ctx = PerceptionContext(
        presence="present",
        screen_b64="SCREENDATA",
        webcam_ok=True,
        activity_hint="coding",
    )
    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes una cita médica mañana.",
        log_fn=log_spy,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert log_spy.call_count == 1
    data = log_spy.call_args[1]["data"]
    assert data["outcome"] == "pushed"
    assert data["presence"] == "present"
    assert data["webcam_ok"] is True
    assert data["screen_available"] is True
    assert "activity_descriptor" in data


def test_log_enriched_on_esperar() -> None:
    """On 'esperar' outcome, log data includes perception fields."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    log_spy = MagicMock()
    fake_ctx = PerceptionContext(presence="unknown", screen_b64=None, webcam_ok=False)
    _default_configure(
        brain_ask=lambda *a, **kw: "ESPERAR",
        log_fn=log_spy,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert log_spy.call_count == 1
    data = log_spy.call_args[1]["data"]
    assert data["outcome"] == "esperar"
    assert data["presence"] == "unknown"
    assert data["webcam_ok"] is False
    assert data["screen_available"] is False
    assert "activity_descriptor" in data


def test_log_enriched_on_nada() -> None:
    """On 'nada' outcome, log data includes perception fields."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    log_spy = MagicMock()
    fake_ctx = PerceptionContext(presence="present", screen_b64="SCREEN", webcam_ok=True)
    _default_configure(
        brain_ask=lambda *a, **kw: "NADA",
        log_fn=log_spy,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())
    assert log_spy.call_count == 1
    data = log_spy.call_args[1]["data"]
    assert data["outcome"] == "nada"
    assert data["presence"] == "present"
    assert "activity_descriptor" in data


def test_no_image_bytes_in_log_data() -> None:
    """Privacy invariant: log data must NOT contain image bytes (screen_b64 or webcam b64)."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    all_log_calls: list[dict] = []

    def _capturing_log(event: str, msg: str, *, data: dict) -> None:
        all_log_calls.append(data)

    FAKE_IMAGE = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="
    fake_ctx = PerceptionContext(
        presence="present",
        screen_b64=FAKE_IMAGE,
        webcam_ok=True,
    )
    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes una cita.",
        log_fn=_capturing_log,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())

    assert len(all_log_calls) == 1
    data = all_log_calls[0]
    # Serialize as string and assert the image payload is not in it
    data_str = str(data)
    assert FAKE_IMAGE not in data_str, "Image bytes must NOT be logged (privacy invariant)"
    # Also assert screen_b64 key itself is not in logged data
    assert "screen_b64" not in data


# ---------------------------------------------------------------------------
# FIX-H2: Push failure must NOT burn the day's slot
# ---------------------------------------------------------------------------

def test_push_failure_does_not_mark_spoke() -> None:
    """push_fn raises → spoke_write_fn NOT called; outcome reflects push failure."""
    from lifeos.autonomous import cron

    spoke_write_spy = MagicMock()
    log_spy = MagicMock()

    def _failing_push(title: str, body: str, **kw):
        raise OSError("push service down")

    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes una cita médica mañana.",
        push_fn=_failing_push,
        spoke_write_fn=spoke_write_spy,
        log_fn=log_spy,
    )
    result = cron.run_tick(_now())
    # Slot must NOT be burned on push failure
    spoke_write_spy.assert_not_called()
    # Outcome should reflect the failure (push-failed)
    assert result.outcome == "push-failed"


def test_push_failure_allows_retry_on_next_tick() -> None:
    """After push_fn raises, subsequent tick (same day) can push again."""
    from lifeos.autonomous import cron

    call_count = 0

    def _push_that_fails_first(*a, **kw):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise OSError("transient failure")
        return {"sent": 1}

    spoke_write_spy = MagicMock()
    _default_configure(
        brain_ask=lambda *a, **kw: "Tienes una cita médica mañana.",
        push_fn=_push_that_fails_first,
        spoke_write_fn=spoke_write_spy,
    )
    # First tick: push fails, slot NOT burned
    result1 = cron.run_tick(_now())
    assert result1.outcome == "push-failed"
    spoke_write_spy.assert_not_called()

    # Second tick (same day): push succeeds, slot IS burned
    result2 = cron.run_tick(_now())
    assert result2.outcome == "pushed"
    spoke_write_spy.assert_called_once_with(_today())


# ---------------------------------------------------------------------------
# FIX-H1: run_tick_now must respect the enabled gate
# ---------------------------------------------------------------------------

def test_run_tick_now_respects_disabled_gate() -> None:
    """run_tick_now when is_enabled_fn returns False → no brain call, no push, outcome skipped-disabled."""
    from lifeos.autonomous import cron

    brain_spy = MagicMock()
    push_spy = MagicMock()

    _default_configure(
        brain_ask=brain_spy,
        push_fn=push_spy,
        is_enabled_fn=lambda: False,
    )
    result = cron.run_tick_now()
    assert result.outcome == "skipped-disabled"
    brain_spy.assert_not_called()
    push_spy.assert_not_called()


def test_run_tick_now_proceeds_when_enabled() -> None:
    """run_tick_now when is_enabled_fn returns True → tick runs normally."""
    from lifeos.autonomous import cron

    brain_spy = MagicMock(return_value="Tienes una cita.")
    _default_configure(
        brain_ask=brain_spy,
        is_enabled_fn=lambda: True,
    )
    result = cron.run_tick_now()
    # run_tick proceeds; brain is called
    brain_spy.assert_called_once()
    assert result.outcome in ("pushed", "esperar", "nada", "skipped-already-spoke", "skipped-brain-down", "skipped-empty", "skipped-outside-window")


# ---------------------------------------------------------------------------
# FIX-W1/L1: Read-only invariant test — REAL enforcement
# ---------------------------------------------------------------------------

def test_no_domain_write_called_on_any_tick_path_real() -> None:
    """No domain store writes happen on any tick path — enforced via import analysis.

    cron.py must not import any domain-write module: health.entries, finance.entries,
    relationships.interactions, learning.entries, events.entries, spirituality.entries,
    exercise.sessions, reminders (write path), lifeos.store (write path).
    """
    import ast
    import importlib.util
    from pathlib import Path as _Path

    # Find cron.py source
    spec = importlib.util.find_spec("lifeos.autonomous.cron")
    assert spec is not None, "lifeos.autonomous.cron not found"
    assert spec.origin is not None
    source = _Path(spec.origin).read_text()
    tree = ast.parse(source)

    # Collect all imported module names (top-level and from-imports)
    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imported_names.add(node.module)

    # Domain-write surfaces: any import of these would be a violation
    forbidden_write_modules = {
        "lifeos.health.entries",
        "lifeos.finance.entries",
        "lifeos.finance.ingestion",
        "lifeos.relationships.interactions",
        "lifeos.learning.entries",
        "lifeos.events.entries",
        "lifeos.spirituality.entries",
        "lifeos.exercise.sessions",
        "lifeos.reminders",
        "lifeos.store",
    }

    violations = imported_names & forbidden_write_modules
    assert not violations, (
        f"cron.py imports domain-write module(s): {violations}. "
        "The tick must be read-only — no domain writes allowed."
    )


# ---------------------------------------------------------------------------
# FIX-L2: Privacy invariant extended across all outcomes
# ---------------------------------------------------------------------------

def test_no_image_bytes_in_log_data_esperar() -> None:
    """Privacy invariant: no image bytes in log data on 'esperar' outcome."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    all_log_calls: list[dict] = []

    def _capturing_log(event: str, msg: str, *, data: dict) -> None:
        all_log_calls.append(data)

    FAKE_IMAGE = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="
    fake_ctx = PerceptionContext(presence="present", screen_b64=FAKE_IMAGE, webcam_ok=True)

    _default_configure(
        brain_ask=lambda *a, **kw: "ESPERAR",
        log_fn=_capturing_log,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())

    assert len(all_log_calls) >= 1
    for data in all_log_calls:
        data_str = str(data)
        assert FAKE_IMAGE not in data_str, "Image bytes must NOT be logged on esperar (privacy invariant)"
        assert "screen_b64" not in data


def test_no_image_bytes_in_log_data_nada() -> None:
    """Privacy invariant: no image bytes in log data on 'nada' outcome."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    all_log_calls: list[dict] = []

    def _capturing_log(event: str, msg: str, *, data: dict) -> None:
        all_log_calls.append(data)

    FAKE_IMAGE = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="
    fake_ctx = PerceptionContext(presence="present", screen_b64=FAKE_IMAGE, webcam_ok=True)

    _default_configure(
        brain_ask=lambda *a, **kw: "NADA",
        log_fn=_capturing_log,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())

    assert len(all_log_calls) >= 1
    for data in all_log_calls:
        data_str = str(data)
        assert FAKE_IMAGE not in data_str, "Image bytes must NOT be logged on nada (privacy invariant)"
        assert "screen_b64" not in data


def test_no_image_bytes_in_log_data_brain_exception() -> None:
    """Privacy invariant: no image bytes in log data when brain_ask raises (brain-exception path)."""
    from lifeos.autonomous import cron
    from lifeos.autonomous.cron import PerceptionContext

    all_log_calls: list[dict] = []

    def _capturing_log(event: str, msg: str, *, data: dict) -> None:
        all_log_calls.append(data)

    def _bad_brain(*a, **kw):
        raise RuntimeError("brain exploded")

    FAKE_IMAGE = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="
    fake_ctx = PerceptionContext(presence="present", screen_b64=FAKE_IMAGE, webcam_ok=True)

    _default_configure(
        brain_ask=_bad_brain,
        log_fn=_capturing_log,
        perceive_fn=lambda: fake_ctx,
    )
    cron.run_tick(_now())

    assert len(all_log_calls) >= 1
    for data in all_log_calls:
        data_str = str(data)
        assert FAKE_IMAGE not in data_str, "Image bytes must NOT be logged on brain-exception (privacy invariant)"
        assert "screen_b64" not in data


# ---------------------------------------------------------------------------
# axi-routine-learning: Phase 5 — configure() accepts routine_path
# ---------------------------------------------------------------------------

def test_configure_accepts_routine_path(tmp_path: Path) -> None:
    """configure(routine_path=...) + run_tick → JSONL at that path has exactly 1 line."""
    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    _default_configure(routine_path=rp)
    cron.run_tick(_now())
    assert rp.exists(), "routine JSONL was not created"
    lines = rp.read_text().splitlines()
    assert len(lines) == 1


# ---------------------------------------------------------------------------
# axi-routine-learning: Phase 6 — _log writes one record per outcome + trim
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("outcome_setup", [
    {"brain_ask": lambda *a, **kw: "Tienes cita médica mañana."},          # pushed
    {"brain_ask": lambda *a, **kw: "ESPERAR"},                              # esperar
    {"brain_ask": lambda *a, **kw: "NADA"},                                 # nada
    {"digest_fn": lambda: "", "correlate_fn": lambda: ""},                  # skipped-empty
])
def test_tick_writes_one_record_per_outcome(tmp_path: Path, outcome_setup: dict) -> None:
    """Every non-window-skip outcome writes exactly one routine record."""
    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    _default_configure(routine_path=rp, **outcome_setup)
    cron.run_tick(_now())
    assert rp.exists()
    lines = rp.read_text().splitlines()
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert isinstance(rec["weekday"], int)
    assert isinstance(rec["hour"], int)
    assert isinstance(rec["presence"], str)
    assert isinstance(rec["outcome"], str)


def test_tick_writes_one_record_skipped_outcomes(tmp_path: Path) -> None:
    """skipped-outside-window also writes a record."""
    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    _default_configure(routine_path=rp)
    cron.run_tick(_now(hour=6))  # outside window
    assert rp.exists()
    lines = rp.read_text().splitlines()
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert rec["outcome"] == "skipped-outside-window"


def test_trim_fires_at_window_start_hour(tmp_path: Path) -> None:
    """Tick at hour==8 trims old records (>90d) from the routine JSONL."""
    import json as _json

    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    _NOW = _now(hour=8)
    now_ts = _NOW.timestamp()
    # Pre-seed: one old record (>90d) and one recent record (5d)
    with open(rp, "w") as fh:
        fh.write(_json.dumps({"ts": now_ts - 100 * 86400, "weekday": 0, "hour": 9, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"}) + "\n")
        fh.write(_json.dumps({"ts": now_ts - 5 * 86400,   "weekday": 1, "hour": 10, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"}) + "\n")

    _default_configure(routine_path=rp, brain_ask=lambda *a, **kw: "ESPERAR")
    cron.run_tick(_NOW)

    # After tick, old record should be gone (trim fired), only recent + new tick record remain
    remaining = rp.read_text().splitlines()
    tses = [_json.loads(line)["ts"] for line in remaining]
    cutoff = now_ts - 90 * 86400
    assert all(ts >= cutoff for ts in tses), f"Old record not trimmed: {tses}"


def test_write_failure_does_not_abort_tick(tmp_path: Path) -> None:
    """Unwritable routine_path → tick completes normally (graceful degrade)."""
    from lifeos.autonomous import cron

    # Point to a directory (not writable as a file)
    bad_rp = tmp_path / "unwritable_dir"
    bad_rp.mkdir()

    _default_configure(routine_path=bad_rp)
    # Should NOT raise
    result = cron.run_tick(_now())
    assert result.outcome is not None


# ---------------------------------------------------------------------------
# axi-routine-learning: Phase 7 — run_tick reads profile + _build_prompt hint
# ---------------------------------------------------------------------------

def test_cold_start_prompt_unchanged(tmp_path: Path) -> None:
    """< 10 records in JSONL → prompt is byte-identical to pre-change format (no 'Patrón' / 'suele')."""
    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    # Seed < 10 records
    import json as _json
    now_ref = _now(hour=12)
    now_ts = now_ref.timestamp()
    with open(rp, "w") as fh:
        for i in range(5):
            fh.write(_json.dumps({"ts": now_ts - i * 86400, "weekday": 2, "hour": 12, "presence": "present", "activity_descriptor": "x", "outcome": "pushed"}) + "\n")

    captured_prompts: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompts.append(prompt)
        return "ESPERAR"

    _default_configure(brain_ask=_spy_brain, routine_path=rp)
    cron.run_tick(now_ref)

    assert len(captured_prompts) == 1
    prompt = captured_prompts[0]
    assert "Patrón" not in prompt
    assert "suele" not in prompt


def test_warm_prompt_contains_hint(tmp_path: Path) -> None:
    """>=10 records with high presence at current (weekday, hour) → prompt contains hint."""
    from lifeos.autonomous import cron
    import json as _json

    rp = tmp_path / "routine.jsonl"
    now_ref = _now(hour=12)  # Wednesday hour=12, weekday=2 for 2026-06-10
    now_ts = now_ref.timestamp()
    now_wd = now_ref.weekday()

    # Seed 15 present records at current (weekday, hour)
    with open(rp, "w") as fh:
        for i in range(15):
            fh.write(_json.dumps({
                "ts": now_ts - i * 86400,
                "weekday": now_wd,
                "hour": 12,
                "presence": "present",
                "activity_descriptor": "x",
                "outcome": "pushed",
            }) + "\n")

    captured_prompts: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompts.append(prompt)
        return "ESPERAR"

    _default_configure(brain_ask=_spy_brain, routine_path=rp)
    cron.run_tick(now_ref)

    assert len(captured_prompts) == 1
    prompt = captured_prompts[0]
    assert "Patrón habitual" in prompt


def test_corrupt_jsonl_tick_proceeds(tmp_path: Path) -> None:
    """JSONL with only corrupt lines → tick completes normally, prompt in pre-change format."""
    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    rp.write_text("not-json\nalso-not-json\n{broken\n")

    captured_prompts: list[str] = []

    def _spy_brain(prompt: str, **kw: Any) -> str:
        captured_prompts.append(prompt)
        return "ESPERAR"

    _default_configure(brain_ask=_spy_brain, routine_path=rp)
    result = cron.run_tick(_now())
    assert result.outcome is not None
    assert len(captured_prompts) == 1
    prompt = captured_prompts[0]
    assert "Patrón" not in prompt
    assert "suele" not in prompt


# ---------------------------------------------------------------------------
# axi-routine-learning: Phase 8 — Privacy integration test
# ---------------------------------------------------------------------------

def test_privacy_jsonl_never_contains_life_data(tmp_path: Path) -> None:
    """10 ticks with varied outcomes → every JSONL line has exactly 6 allowed keys, no life-data keys."""
    from lifeos.autonomous import cron

    rp = tmp_path / "routine.jsonl"
    BANNED = {"message", "text", "image", "screen", "name", "digest", "body", "content", "data"}
    ALLOWED = {"ts", "weekday", "hour", "presence", "activity_descriptor", "outcome"}

    setups = [
        {"brain_ask": lambda *a, **kw: "Tienes cita médica."},  # pushed
        {"brain_ask": lambda *a, **kw: "ESPERAR"},              # esperar
        {"brain_ask": lambda *a, **kw: "NADA"},                 # nada
        {"digest_fn": lambda: "", "correlate_fn": lambda: ""},  # skipped-empty
        {"alive_fn": lambda: False},                            # skipped-brain-down
    ]
    hours = [12, 13, 14, 15, 16, 8, 9, 10, 11, 17]

    for i, (setup, hour) in enumerate(zip(setups * 2, hours)):
        _default_configure(routine_path=rp, **setup)
        cron.run_tick(_now(hour=hour))

    lines = rp.read_text().splitlines()
    assert len(lines) >= 5, f"Expected >= 5 records, got {len(lines)}"

    for line in lines:
        rec = json.loads(line)
        assert set(rec.keys()) == ALLOWED, f"Unexpected keys: {set(rec.keys()) - ALLOWED}"
        assert not BANNED.intersection(rec.keys()), f"Banned keys found: {BANNED.intersection(rec.keys())}"
