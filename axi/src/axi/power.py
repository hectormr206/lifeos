"""Power-mode awareness for battery-aware behavior.

Axi is a pure CONSUMER of the system power profile, which is owned by the
external ``power-mode`` service (the single source of truth). We NEVER write the
state file or touch power profiles, RAPL, refresh rate, asusctl, etc.

Contract (locked with the power-mode owner):
  - State file: ``$XDG_RUNTIME_DIR/power-mode.state``, contents ``ac`` or
    ``battery`` (trailing newline from ``echo`` — we ``strip()``).
  - The file lives in tmpfs and may not exist yet if Axi starts before the
    power-mode service. Fallback: ``/sys/class/power_supply/AC0/online``
    (1=ac, 0=battery). If even that is missing, assume ``ac`` (full power —
    the safe default: we never throttle on uncertainty).
"""
from __future__ import annotations

import os
from pathlib import Path

AC = "ac"
BATTERY = "battery"

_AC_SYSFS = Path("/sys/class/power_supply/AC0/online")


def state_file_path() -> Path:
    """Canonical power-mode state file (owned by the external power-mode service).

    ``AXI_POWER_STATE_FILE`` overrides the path (used by tests).
    """
    override = os.environ.get("AXI_POWER_STATE_FILE")
    if override:
        return Path(override)
    root = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return Path(root) / "power-mode.state"


def _read_sysfs_ac() -> str | None:
    """AC adapter sysfs fallback: '1' -> ac, '0' -> battery, else None."""
    try:
        raw = _AC_SYSFS.read_text().strip()
    except OSError:
        return None
    if raw == "1":
        return AC
    if raw == "0":
        return BATTERY
    return None


def power_state() -> str:
    """Return ``"ac"`` or ``"battery"``.

    Reads the power-mode state file (stripped, lower-cased), falls back to the
    AC sysfs node, then assumes ``"ac"`` (never throttle on uncertainty).
    """
    try:
        raw = state_file_path().read_text().strip().lower()
    except OSError:
        raw = ""
    if raw in (AC, BATTERY):
        return raw
    fallback = _read_sysfs_ac()
    if fallback is not None:
        return fallback
    return AC


def on_battery() -> bool:
    """True iff the laptop is currently running on battery."""
    return power_state() == BATTERY


def battery_scaled(base_seconds: float, factor) -> float:
    """Multiply a loop interval by ``factor`` when on battery (fewer wakeups).

    Returns ``base_seconds`` unchanged on AC, when ``factor`` <= 1, or when
    ``factor`` is not a valid integer. Evaluate this each loop iteration so the
    interval adapts live as the laptop is plugged/unplugged.
    """
    try:
        f = int(factor)
    except (TypeError, ValueError):
        f = 1
    if f > 1 and on_battery():
        return base_seconds * f
    return base_seconds
