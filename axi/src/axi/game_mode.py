"""Game mode, as something the LifeOS app can see and toggle.

WHAT IT DOES. `axi-game-on` relocates the VRAM holders — Whisper (~2.3 GB) and
the llama-server co-pilot — from the GPU to CPU/RAM, so a demanding game gets
effectively the whole card. `axi-game-off` puts them back. Both work through
systemd drop-ins that persist across reboot, which is why the lock file, not a
running process, is the source of truth for "is it on".

WHY THIS MODULE. The scripts already exist and the tray already runs them. The
only ways in are the tray and a terminal — and the terminal is exactly what the
multiplatform app is meant to remove. This is the seam the API exposes so the
app can offer the same switch on the laptop and from the phone.

TWO RULES, both the user's, both enforced here rather than left to the caller:

1. HIDE IT WHERE IT IS USELESS. "Solo si tenemos VRAM; si todo está en CPU y RAM
   entonces no nos sirve el modo juego y lo ocultamos." [availability] answers
   that question, and [set_active] refuses outright on a machine with no GPU —
   because a hidden control is not the same as an unreachable one, and an old
   app build or a hand-made request must not stop the co-pilot for no gain.

2. NEVER AUTOMATIC. "Yo tengo que activarlo por mi cuenta." Nothing here watches
   for a game, infers intent, or flips the switch on anyone's behalf. Reading
   the state runs no scripts at all — a status probe with side effects is
   precisely how automatic behaviour arrives by accident.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Any

from . import heartbeat, interoception


class GameModeUnavailable(RuntimeError):
    """Raised when this machine has no GPU to free."""


class GameModeFailed(RuntimeError):
    """Raised when the relocation script failed — never swallowed.

    A half-applied relocation leaves some units on the GPU and others on the
    CPU. That is a state the user must be told about, not one they discover
    when their game stutters.
    """


# --- seams (patched in tests; each is one real dependency) ------------------

def _vram() -> dict[str, Any] | None:
    """Current GPU snapshot, or None on a machine without a working nvidia-smi."""
    snapshot = interoception._vram_snapshot()
    if snapshot.get("name") is None and not snapshot.get("total_mb"):
        return None
    return snapshot


def _active() -> bool:
    return heartbeat.game_mode_active()


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    # 120 s: the scripts stop and restart systemd units and wait for a model to
    # load into RAM. Shorter would report a failure for work still in progress.
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)


def _script(name: str) -> str:
    """Absolute path to one of the two scripts.

    Resolved relative to this file rather than trusting $PATH: the API runs
    under systemd, whose PATH is not the user's login PATH — a lookup that
    works in a terminal and fails in the service is the kind of difference
    nobody finds until it matters.
    """
    local = Path(__file__).resolve().parents[2] / "scripts" / name
    if local.exists():
        return str(local)
    found = shutil.which(name)
    if found:
        return found
    raise GameModeFailed(f"No se encontró el script {name}.")


# --- public surface ---------------------------------------------------------

def availability() -> dict[str, Any]:
    """Whether game mode is meaningful on this machine, and why not when it isn't.

    The `reason` is carried even in the available case so a support question
    ("¿por qué no me aparece?") is answerable without reading this source.
    """
    gpu = _vram()
    if gpu is None:
        return {
            "available": False,
            "gpu": None,
            "reason": "No hay GPU con VRAM en esta máquina: todo corre en CPU y RAM, "
                      "así que el modo juego no liberaría nada.",
        }
    total = int(gpu.get("total_mb") or 0)
    if total <= 0:
        # nvidia-smi answering 0 is a broken probe, not a card with no memory.
        return {
            "available": False,
            "gpu": None,
            "reason": "La GPU no reporta VRAM utilizable, así que no hay nada que liberar.",
        }
    return {
        "available": True,
        "gpu": {"name": gpu.get("name"), "total_mb": total, "used_mb": gpu.get("used_mb")},
        "reason": "",
    }


def state() -> dict[str, Any]:
    """Current game-mode state. Runs nothing and changes nothing."""
    return {"active": _active(), **availability()}


def set_active(active: bool) -> dict[str, Any]:
    """Turn game mode on or off. The ONLY way it ever changes.

    Idempotent: asking for the state it is already in does nothing. That is not
    politeness — `axi-game-on` saves the current brain id so `axi-game-off` can
    restore it, and running it twice would overwrite that backup with the
    already-swapped value.
    """
    ready = availability()
    if not ready["available"]:
        raise GameModeUnavailable(ready["reason"])

    if _active() == active:
        return state()

    script = _script("axi-game-on" if active else "axi-game-off")
    try:
        result = _run([script])
    except subprocess.TimeoutExpired as exc:
        raise GameModeFailed(
            f"{Path(script).name} no terminó a tiempo; el estado puede haber quedado a medias."
        ) from exc

    if result.returncode != 0:
        detail = (result.stderr or "").strip() or f"salió con código {result.returncode}"
        raise GameModeFailed(f"{Path(script).name} falló: {detail}")

    return state()
