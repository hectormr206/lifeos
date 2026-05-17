"""Send text to clipboard and surface KDE notifications.

Clipboard is best-effort: we try several tools in order and never raise.
The transcription is also written to ~/.local/state/axi/last.txt as a
safety net, so the user can always recover the text.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "axi"


def _try(cmd: list[str], stdin: bytes) -> bool:
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        proc.communicate(stdin, timeout=3)
        return proc.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def to_clipboard(text: str) -> str:
    """Returns the name of the tool that succeeded, or "none"."""
    data = text.encode("utf-8")
    if shutil.which("wl-copy") and _try(["wl-copy"], data):
        return "wl-copy"
    if shutil.which("xclip") and _try(["xclip", "-selection", "clipboard"], data):
        return "xclip"
    if shutil.which("xsel") and _try(["xsel", "--clipboard", "--input"], data):
        return "xsel"
    if shutil.which("kdialog"):
        try:
            subprocess.run(["kdialog", "--setclipboard", text], check=True, timeout=3)
            return "kdialog"
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            pass
    return "none"


def type_to_focused(text: str) -> bool:
    """Trigger Ctrl+Shift+V on the focused window so it pastes from clipboard.

    Why not `ydotool type`? ydotool uses raw US scancodes and silently drops
    multi-byte UTF-8 characters like Spanish accented vowels (´í`, `é`, `ó`).
    The clipboard already holds the correct bytes, so we ride the desktop's
    own paste mechanism instead.

    Why Ctrl+Shift+V and not Ctrl+V? Terminals (Ghostty, Konsole, fish) reject
    Ctrl+V as "literal next char" — only Ctrl+Shift+V pastes there. In most
    GUI apps Ctrl+Shift+V also works (it's "paste plain text" or just paste).

    Linux input keycodes: LEFTCTRL=29, LEFTSHIFT=42, V=47.
    """
    if not shutil.which("ydotool"):
        return False
    try:
        subprocess.run(
            ["ydotool", "key", "29:1", "42:1", "47:1", "47:0", "42:0", "29:0"],
            check=True,
            timeout=2,
            capture_output=True,
        )
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return False


def save_last(text: str) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = STATE_DIR / "last.txt"
    path.write_text(text + "\n", encoding="utf-8")
    return path


def save_last_answer(question: str, answer: str) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = STATE_DIR / "last-answer.txt"
    path.write_text(f"Q: {question}\n\nA: {answer}\n", encoding="utf-8")
    return path


def notify(
    title: str,
    body: str = "",
    icon: str = "audio-input-microphone",
    transient: bool = False,
    timeout_ms: int | None = None,
) -> None:
    if not shutil.which("notify-send"):
        return
    args = ["notify-send", "-a", "Axi", "-i", icon, title]
    if transient:
        args.extend(["-h", "int:transient:1"])
    if timeout_ms is not None:
        args.extend(["-t", str(timeout_ms)])
    if body:
        args.append(body)
    try:
        subprocess.Popen(args)
    except (FileNotFoundError, OSError):
        pass
