"""Webcam capture for Axi — the second 'visual' sense, complementing screen vision.

Strategy A (zero-conflict): the webcam is taken as a quick single-frame
snapshot via ffmpeg. Before capturing, we check whether any other process
already holds the device (Meet, Zoom, etc.) and back off cleanly if so.
This means Axi never fights a meeting for the camera.

V2 (if the conflict matters): set up `v4l2loopback` to multiplex one
physical camera into two virtual sources, one for the meeting and one
for Axi. Out of scope for V0.
"""
from __future__ import annotations

import base64
import logging
import shutil
import subprocess
import tempfile
from pathlib import Path

log = logging.getLogger("axi.eyes")


def _log_capture_error(msg: str) -> None:
    """Surface camera capture failures to the dashboard event log (PRD §9.4)."""
    try:
        from axi import events  # noqa: PLC0415
        events.log_error("eyes", msg)
    except Exception:  # noqa: BLE001
        pass

WEBCAM_DEV = "/dev/video0"
CAPTURE_WIDTH = 1280
CAPTURE_HEIGHT = 720


def _camera_busy() -> tuple[bool, str]:
    """Returns (busy, who). 'who' is a process name or 'unknown' on success."""
    if not Path(WEBCAM_DEV).exists():
        return True, "no existe el dispositivo"
    if shutil.which("fuser") is None:
        return False, ""  # can't tell — assume free
    try:
        proc = subprocess.run(
            ["fuser", "-v", WEBCAM_DEV],
            capture_output=True, text=True, timeout=3,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False, ""
    # fuser puts PIDs on stdout, the verbose table on stderr, and exits 0
    # only when the device is in use.
    if proc.returncode != 0 or not proc.stdout.strip():
        return False, ""
    # Try to extract a recognizable process name from the verbose output.
    who = "otra app"
    for line in proc.stderr.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] != "USER":
            who = parts[-1]
            break
    return True, who


def _ffmpeg_capture(out_path: Path) -> bool:
    if shutil.which("ffmpeg") is None:
        log.warning("ffmpeg not in PATH")
        _log_capture_error("ffmpeg not in PATH")
        return False
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "v4l2",
        "-video_size", f"{CAPTURE_WIDTH}x{CAPTURE_HEIGHT}",
        "-i", WEBCAM_DEV,
        # Skip the first few frames — most webcams autoexpose for ~0.5 s.
        "-vf", "select=eq(n\\,5)",
        "-frames:v", "1",
        str(out_path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=8)
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("ffmpeg failed: %s", e)
        _log_capture_error(f"ffmpeg failed: {e}")
        return False
    if proc.returncode != 0:
        err = proc.stderr.decode(errors="replace")[:200]
        log.warning("ffmpeg rc=%d stderr=%s", proc.returncode, err)
        _log_capture_error(f"ffmpeg rc={proc.returncode}: {err}")
        return False
    return out_path.exists() and out_path.stat().st_size > 0


def capture_b64() -> tuple[str | None, str]:
    """Snapshot the webcam and return (base64_png, status).

    Status is one of:
      - 'ok'           on success
      - 'busy:<who>'   when the camera is held by another process
      - 'no-device'    when /dev/video0 is missing
      - 'failed'       when capture itself errors out
    """
    if not Path(WEBCAM_DEV).exists():
        return None, "no-device"
    busy, who = _camera_busy()
    if busy:
        return None, f"busy:{who}"
    out = Path(tempfile.gettempdir()) / "axi-webcam.png"
    if not _ffmpeg_capture(out):
        return None, "failed"
    data = out.read_bytes()
    try:
        out.unlink(missing_ok=True)
    except OSError:
        pass
    return base64.b64encode(data).decode("ascii"), "ok"
