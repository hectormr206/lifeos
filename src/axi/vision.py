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
            log.warning("spectacle returned %d: %s", proc.returncode, proc.stderr.decode(errors="replace")[:200])
            return None
        return out_path.read_bytes() if out_path.exists() and out_path.stat().st_size > 0 else None
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("spectacle failed: %s", e)
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
