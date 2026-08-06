"""Game mode as something the API can report and toggle.

The behaviour already exists as two shell scripts (`axi-game-on` / `axi-game-off`)
that relocate the VRAM holders — Whisper and the llama-server co-pilot — from the
GPU to CPU/RAM so a game gets the whole card. Today the only ways in are the
tray and a terminal. This module is what lets the LifeOS app offer it too.

TWO RULES THIS MODULE ENFORCES, both the user's:

1. HIDE IT WHERE IT IS USELESS. "Solo si tenemos VRAM; si todo está en CPU y RAM
   entonces no nos sirve el modo juego y lo ocultamos." On a machine with no GPU
   there is no VRAM to hand back, so the control must be ABSENT rather than
   present and inert.

2. NEVER AUTOMATIC. "Yo tengo que activarlo por mi cuenta." Nothing here detects
   a running game, guesses intent, or flips the switch on the user's behalf.
   Reading the state has no side effects, and the only way in is an explicit
   call.
"""
from __future__ import annotations

import pytest

from axi import game_mode


class _Flipping:
    """Reports the first value once, then the second — the state a script changed."""

    def __init__(self, before: bool, after: bool) -> None:
        self._values = [before]
        self._after = after

    def __call__(self) -> bool:
        return self._values.pop(0) if self._values else self._after


class _FakeRun:
    """Records what would have been executed instead of executing it."""

    def __init__(self, returncode: int = 0, stderr: str = "") -> None:
        self.calls: list[list[str]] = []
        self.returncode = returncode
        self.stderr = stderr

    def __call__(self, cmd, **kwargs):  # noqa: ANN001, ANN003
        self.calls.append(list(cmd))
        return type("R", (), {"returncode": self.returncode, "stderr": self.stderr})()


# --------------------------------------------------------------------------
# Availability — rule 1
# --------------------------------------------------------------------------

def test_no_gpu_means_game_mode_is_not_available(monkeypatch):
    # A machine running everything on CPU has nothing to free. Offering the
    # control there would promise the user FPS it cannot deliver.
    monkeypatch.setattr(game_mode, "_vram", lambda: None)

    availability = game_mode.availability()

    assert availability["available"] is False
    assert availability["gpu"] is None


def test_the_reason_says_WHY_it_is_unavailable(monkeypatch):
    # The app hides the control, but a support question ("why don't I have it?")
    # has to be answerable without reading this source.
    monkeypatch.setattr(game_mode, "_vram", lambda: None)

    assert "GPU" in game_mode.availability()["reason"]


def test_a_gpu_with_vram_makes_it_available(monkeypatch):
    monkeypatch.setattr(
        game_mode, "_vram",
        lambda: {"name": "NVIDIA GeForce RTX 5070 Ti", "total_mb": 12282, "used_mb": 4096},
    )

    availability = game_mode.availability()

    assert availability["available"] is True
    assert availability["gpu"]["name"] == "NVIDIA GeForce RTX 5070 Ti"
    assert availability["gpu"]["total_mb"] == 12282


def test_a_card_reporting_zero_vram_is_not_a_card_worth_offering(monkeypatch):
    # nvidia-smi answering with a total of 0 is a broken probe, not a GPU with
    # no memory. Treating it as available would show a control that frees
    # nothing.
    monkeypatch.setattr(game_mode, "_vram", lambda: {"name": "weird", "total_mb": 0})

    assert game_mode.availability()["available"] is False


# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

def test_state_follows_the_lock_file(monkeypatch):
    monkeypatch.setattr(game_mode, "_active", lambda: True)
    assert game_mode.state()["active"] is True

    monkeypatch.setattr(game_mode, "_active", lambda: False)
    assert game_mode.state()["active"] is False


def test_reading_the_state_changes_nothing(monkeypatch):
    # Rule 2. A status read that could flip the switch is how "automatic"
    # behaviour sneaks in.
    run = _FakeRun()
    monkeypatch.setattr(game_mode, "_run", run)
    monkeypatch.setattr(game_mode, "_active", lambda: False)
    monkeypatch.setattr(game_mode, "_vram", lambda: {"name": "gpu", "total_mb": 12282})

    game_mode.state()
    game_mode.availability()

    assert run.calls == []


# --------------------------------------------------------------------------
# Toggling — explicit only
# --------------------------------------------------------------------------

def test_turning_it_on_runs_the_game_on_script(monkeypatch):
    run = _FakeRun()
    monkeypatch.setattr(game_mode, "_run", run)
    monkeypatch.setattr(game_mode, "_vram", lambda: {"name": "gpu", "total_mb": 12282})
    # Off before, on after: the SCRIPT is what flips it, so the fake has to
    # flip too — pinning it to the target value would silently exercise the
    # idempotence short-circuit instead of the toggle.
    monkeypatch.setattr(game_mode, "_active", _Flipping(False, True))

    result = game_mode.set_active(True)

    assert result["active"] is True
    assert len(run.calls) == 1
    assert run.calls[0][0].endswith("axi-game-on")


def test_turning_it_off_runs_the_game_off_script(monkeypatch):
    run = _FakeRun()
    monkeypatch.setattr(game_mode, "_run", run)
    monkeypatch.setattr(game_mode, "_vram", lambda: {"name": "gpu", "total_mb": 12282})
    monkeypatch.setattr(game_mode, "_active", _Flipping(True, False))

    game_mode.set_active(False)

    assert run.calls[0][0].endswith("axi-game-off")


def test_it_refuses_to_toggle_where_there_is_no_GPU(monkeypatch):
    # Belt and braces with the hidden control: an app built before this
    # capability existed, or a hand-made request, must not run a script that
    # would stop the co-pilot for no gain.
    run = _FakeRun()
    monkeypatch.setattr(game_mode, "_run", run)
    monkeypatch.setattr(game_mode, "_vram", lambda: None)

    with pytest.raises(game_mode.GameModeUnavailable):
        game_mode.set_active(True)

    assert run.calls == []


def test_a_failing_script_is_reported_LOUDLY(monkeypatch):
    # The scripts relocate systemd units; a half-applied relocation is exactly
    # the state the user must be told about rather than left to discover when
    # their game stutters.
    run = _FakeRun(returncode=1, stderr="could not stop llama-server")
    monkeypatch.setattr(game_mode, "_run", run)
    monkeypatch.setattr(game_mode, "_vram", lambda: {"name": "gpu", "total_mb": 12282})

    with pytest.raises(game_mode.GameModeFailed) as excinfo:
        game_mode.set_active(True)

    assert "llama-server" in str(excinfo.value)


def test_setting_it_to_its_current_value_is_not_an_error(monkeypatch):
    # The app and the tray can both toggle; they can disagree about what the
    # current state is. Asking for the state it is already in must be a no-op,
    # not a failure the user has to interpret.
    run = _FakeRun()
    monkeypatch.setattr(game_mode, "_run", run)
    monkeypatch.setattr(game_mode, "_vram", lambda: {"name": "gpu", "total_mb": 12282})
    monkeypatch.setattr(game_mode, "_active", lambda: True)

    result = game_mode.set_active(True)

    assert result["active"] is True
    assert run.calls == [], "already on — running game-on again would clobber the saved brain id"
