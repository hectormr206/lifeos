"""Screen capture for Axi — feeds the multimodal brain.

Uses KDE's `spectacle` in CLI mode, which on Wayland natively asks KWin for
the active window's frame without GUI or permission prompts (for the user's
own session). Returns the PNG bytes as base64 ready for the OpenAI vision
request shape.
"""
from __future__ import annotations

import base64
import logging
import shutil
import subprocess
import tempfile
from pathlib import Path

log = logging.getLogger("axi.vision")


def _log_capture_error(msg: str, active_only: bool) -> None:
    """Surface capture failures to the dashboard event log (PRD §9.4).
    Lazy import to avoid circular deps and never crash the caller."""
    try:
        from axi import events  # noqa: PLC0415
        events.log_error(
            "vision",
            f"capture failed ({'active' if active_only else 'full'}): {msg}",
        )
    except Exception:  # noqa: BLE001
        pass


def _spectacle_capture(active_only: bool) -> bytes | None:
    if shutil.which("spectacle") is None:
        return None
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        out_path = Path(tmp.name)
    try:
        args = ["spectacle", "-b", "-n", "-o", str(out_path)]
        args.append("-a" if active_only else "-f")
        proc = subprocess.run(args, capture_output=True, timeout=5, check=False)
        if proc.returncode != 0:
            err = proc.stderr.decode(errors="replace")[:200]
            log.warning("spectacle returned %d: %s", proc.returncode, err)
            _log_capture_error(f"spectacle returned {proc.returncode}: {err}", active_only)
            return None
        return out_path.read_bytes() if out_path.exists() and out_path.stat().st_size > 0 else None
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("spectacle failed: %s", e)
        _log_capture_error(f"spectacle failed: {e}", active_only)
        return None
    finally:
        out_path.unlink(missing_ok=True)


def capture_active_window_b64() -> str | None:
    """Returns base64-encoded PNG of the active window, or None on failure."""
    data = _spectacle_capture(active_only=True)
    if not data:
        # Fallback to fullscreen if active-window capture fails (some apps
        # don't expose a window handle KWin can map).
        data = _spectacle_capture(active_only=False)
    if not data:
        return None
    return base64.b64encode(data).decode("ascii")
