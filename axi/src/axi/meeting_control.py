"""Start and stop a meeting from the LifeOS app, not only from the tray.

WHY THIS IS A THIN LAYER. `meeting.py` is 1144 lines that took real work to get
right: two parallel ffmpeg pipelines — the mic and the system monitor, which IS
the V0 diarization (`mic` is Héctor, `system` is everyone else) — 60 s
segmentation, screenshots deduplicated by perceptual hash, a systemd inhibitor
so the laptop cannot sleep mid-meeting, disk-space guards, and a hallucination
filter. The daemon already drives all of it and already accepts `meeting_start`,
`meeting_stop` and `meeting_status` on its Unix socket.

Rewriting that capture pipeline in Dart would take weeks and land somewhere
strictly worse; on Linux it would end up shelling out to the same ffmpeg
anyway. So the app does not become a second recorder. It becomes another way to
press the same button — which is exactly what the migration is for: the feature
used to be reachable only from the laptop's tray.

THE RECORDER STAYS WHERE THE HARDWARE IS. A meeting needs the microphone, the
system-audio monitor and the screen OF THE MACHINE THE MEETING IS ON. That is a
property of the machine, so this module reports availability rather than
assuming it, and the app hides the control where no daemon answers.

NEVER AUTOMATIC, like game mode: reading the status starts nothing.
"""
from __future__ import annotations

import os
import re
import socket
from pathlib import Path
from typing import Any


class MeetingControlUnavailable(RuntimeError):
    """No daemon answered — there is nothing on this machine that records."""


class MeetingControlFailed(RuntimeError):
    """The daemon answered, and the answer was not success."""


def _socket_path() -> Path:
    root = os.environ.get("XDG_RUNTIME_DIR") or str(Path.home() / ".local/state")
    return Path(root) / "axi" / "voice.sock"


def _send(command: str) -> str:
    """One request/response over the daemon's Unix socket.

    The seam every test patches. 30 s: `meeting_stop` flushes the ffmpeg
    pipelines and closes the segment before answering.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(30.0)
    try:
        sock.connect(str(_socket_path()))
        sock.sendall(command.encode("utf-8"))
        return sock.recv(8192).decode("utf-8", errors="replace").strip()
    finally:
        sock.close()


# The daemon speaks human Spanish, not JSON — it was written for the tray. These
# read its answers rather than changing its protocol, because that protocol also
# serves the tray and the global shortcut, and a format change there would break
# both for no gain here.
_ID_RE = re.compile(r"#(\d+)")
_INACTIVE_MARKERS = ("no hay grabación activa", "no hay grabacion activa", "detenida")
_ERROR_MARKERS = ("error", "no se pudo", "insuficiente", "falló", "fallo")


def _meeting_id(text: str) -> int | None:
    match = _ID_RE.search(text)
    return int(match.group(1)) if match else None


def _looks_like_error(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in _ERROR_MARKERS)


def status() -> dict[str, Any]:
    """Whether a meeting can be recorded here, and whether one is running.

    Reads only. A status probe that could start a recording is how "automatic"
    behaviour arrives by accident — and a meeting starting on its own would be
    recording a room nobody agreed to record.
    """
    try:
        answer = _send("meeting_status")
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
        return {
            "available": False,
            "active": False,
            "meeting_id": None,
            "detail": "",
            "reason": "El daemon de axi no está corriendo en esta máquina, "
                      "así que no hay nada que pueda grabar una reunión.",
        }

    active = bool(answer) and not any(m in answer.lower() for m in _INACTIVE_MARKERS)
    return {
        "available": True,
        "active": active,
        "meeting_id": _meeting_id(answer) if active else None,
        "detail": answer,
        "reason": "",
    }


def set_active(active: bool) -> dict[str, Any]:
    """Start or stop the recording. The only thing that ever changes it.

    Sends the target state rather than a toggle: the tray and the app can
    disagree about whether one is running, and a toggle would then stop the
    meeting the user meant to start.
    """
    command = "meeting_start" if active else "meeting_stop"
    try:
        answer = _send(command)
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError) as exc:
        raise MeetingControlUnavailable(
            "El daemon de axi no está corriendo en esta máquina, así que no hay "
            "nada que pueda grabar una reunión."
        ) from exc

    if not answer:
        # A daemon that accepted the connection and said nothing has not told
        # us it started anything. Reporting success here would leave the user
        # believing a meeting is being captured when none is.
        raise MeetingControlFailed(
            f"El daemon no respondió a {command}; no se puede confirmar que la "
            "reunión haya cambiado de estado."
        )
    if _looks_like_error(answer):
        # meeting.py refuses on purpose in real cases — a full disk is one.
        raise MeetingControlFailed(answer)

    return {
        "available": True,
        "active": active,
        "meeting_id": _meeting_id(answer),
        "detail": answer,
        "reason": "",
    }
