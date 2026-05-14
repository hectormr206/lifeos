"""Mic source detection and priority selection via PipeWire/PulseAudio.

Priority: USB > Bluetooth/headphones > built-in. Monitors and outputs are
skipped. Returns the PulseAudio source name; the caller sets PULSE_SOURCE
in the environment before opening the InputStream.
"""
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class MicSource:
    name: str
    description: str
    score: int


_BLOCK_SEP = re.compile(r"\n(?=Source #)")


def _score(name: str, description: str, state: str) -> int:
    """Higher = prefer. Bluetooth deliberately scored LOW when SUSPENDED:
    a paired-but-disconnected BT mic returns silence and is the #1 cause
    of "I recorded but got nothing"."""
    lname, ldesc = name.lower(), description.lower()
    is_bt = "bluez" in lname or "bluetooth" in ldesc or "headset" in ldesc
    if "usb" in lname or "usb" in ldesc:
        return 100
    if is_bt:
        # Only trust a BT mic that's actively engaged (RUNNING).
        # SUSPENDED/IDLE bluez is usually "paired but no audio path."
        return 60 if state == "RUNNING" else 5
    if "pci" in lname or "internal" in ldesc or "built-in" in ldesc or "analog" in lname:
        return 50
    return 1


def list_mics() -> list[MicSource]:
    try:
        out = subprocess.run(
            ["pactl", "list", "sources"],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return []

    mics: list[MicSource] = []
    for block in _BLOCK_SEP.split(out):
        name_m = re.search(r"^\s*Name:\s*(.+)$", block, re.MULTILINE)
        if not name_m:
            continue
        name = name_m.group(1).strip()
        if name.endswith(".monitor"):
            continue
        desc_m = re.search(r"^\s*Description:\s*(.+)$", block, re.MULTILINE)
        desc = desc_m.group(1).strip() if desc_m else ""
        state_m = re.search(r"^\s*State:\s*(\w+)", block, re.MULTILINE)
        state = state_m.group(1).strip().upper() if state_m else "UNKNOWN"
        mics.append(MicSource(name=name, description=desc, score=_score(name, desc, state)))
    return mics


def pick_best() -> MicSource | None:
    mics = list_mics()
    if not mics:
        return None
    return max(mics, key=lambda m: m.score)
