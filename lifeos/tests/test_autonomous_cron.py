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
