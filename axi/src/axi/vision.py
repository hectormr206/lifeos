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


# ─────────────────────────── P1.5 — screen OCR ──────────────────────────

def _ocr_image(png_bytes: bytes) -> str | None:
    """OCR via tesseract if available. Returns None silently if not.

    Strategy:
      1. If the `tesseract` binary is missing on $PATH → return None
         (no error, no event — user just hasn't installed it).
      2. If `pytesseract` or PIL aren't importable → same.
      3. Try Spanish+English (the user's normal screen content). If the
         es+eng language pack isn't installed Tesseract raises; fall back
         to the default language to keep some OCR output flowing.
      4. Any unexpected error → log a warning event and return None;
         OCR is opportunistic, never a hard dependency for capture.
    """
    import shutil  # noqa: PLC0415
    if not shutil.which("tesseract"):
        return None
    try:
        import io  # noqa: PLC0415
        import pytesseract  # noqa: PLC0415
        from PIL import Image  # noqa: PLC0415
    except ImportError:
        return None
    try:
        img = Image.open(io.BytesIO(png_bytes))
        try:
            return pytesseract.image_to_string(img, lang="es+eng", timeout=10) or None
        except pytesseract.TesseractError:
            return pytesseract.image_to_string(img, timeout=10) or None
    except Exception as e:  # noqa: BLE001
        try:
            from axi import events  # noqa: PLC0415
            events.log_warning("vision.ocr", f"OCR failed: {e}")
        except Exception:  # noqa: BLE001
            log.warning("OCR failed: %s", e)
        return None


def get_active_window_title() -> str | None:
    """Return the active window caption via qdbus6 on KDE/Wayland.

    Queries ``qdbus6 org.kde.KWin /KWin queryWindowInfo`` and parses the
    ``caption:`` line.  Returns None on any failure (qdbus6 absent, timeout,
    parse error, empty caption) so callers can fall back gracefully.

    The result is used only for building a text search query — the screenshot
    is never passed here.
    """
    if shutil.which("qdbus6") is None:
        return None
    try:
        result = subprocess.run(
            ["qdbus6", "org.kde.KWin", "/KWin", "queryWindowInfo"],
            capture_output=True,
            text=True,
            timeout=1.0,
        )
        for line in result.stdout.splitlines():
            if line.startswith("caption:"):
                caption = line.split(":", 1)[1].strip()
                return caption or None
    except Exception:  # noqa: BLE001
        pass
    return None


def ocr_from_b64(image_b64: str) -> str | None:
    """Decode a base64 PNG and run OCR on it (P1.5).

    Returns None when OCR is unavailable, the input is malformed, or
    the OCR result is effectively empty. Callers should treat the
    string as opportunistic context, not a guaranteed signal.
    """
    if not image_b64:
        return None
    try:
        png_bytes = base64.b64decode(image_b64)
    except (ValueError, TypeError):
        return None
    text = _ocr_image(png_bytes)
    if not text:
        return None
    text = text.strip()
    return text or None
