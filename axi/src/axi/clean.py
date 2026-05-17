"""Conservative rule-based cleanup for Whisper output.

This is the v1 nanoagent — pure Python, zero ML, instant. Designed to be
portable (anyone can install Axi and benefit) instead of personalized
(would need fine-tuning on per-user data).

What it does
------------
- Apply a vocabulary substitution dict (loaded from `~/.config/axi/vocab.json`,
  falling back to a built-in default). Whole-word, case-insensitive match,
  case preserved on the replacement side.
- Normalize whitespace and spacing around punctuation.
- Capitalize the first letter of every sentence (after `.`, `!`, `?`).
- Append a trailing `.` if the text ends without sentence-terminal punctuation.

What it does NOT do
-------------------
- Remove fillers (`este`, `o sea`, `eh`). In Spanish these collide with
  legitimate words too often; safer to leave them.
- Voice commands ("punto" → ".", "nueva línea" → newline). Ambiguous in
  Spanish — "ese es el punto" should stay as text.
- Grammar rewriting. That needs an LLM.

The full pipeline output and the raw Whisper output are both kept (the daemon
logs them), so anything wrong here is debuggable without re-running Whisper.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "axi"
VOCAB_PATH = CONFIG_DIR / "vocab.json"

# Default vocab: case-insensitive on the LHS, exact case preserved on the RHS.
# Whisper tends to lowercase technical jargon and to spell out symbols, so we
# undo that here. Edit `~/.config/axi/vocab.json` to add your own.
DEFAULT_VOCAB: dict[str, str] = {
    # Hector's stack — proper names that Whisper lowercases
    "axi": "Axi",
    "lifeos": "LifeOS",
    "life os": "LifeOS",
    "cachyos": "CachyOS",
    "cachy os": "CachyOS",
    "cacho os": "CachyOS",
    "cacho ios": "CachyOS",
    "catchy os": "CachyOS",
    "cachi os": "CachyOS",
    "kde": "KDE",
    "kde plasma": "KDE Plasma",
    "plasma": "Plasma",
    "wayland": "Wayland",
    "pipewire": "PipeWire",
    "pulseaudio": "PulseAudio",
    "systemd": "systemd",
    "whisper": "Whisper",
    "qwen": "Qwen",
    "claude": "Claude",
    "github": "GitHub",
    "gitlab": "GitLab",
    "huggingface": "HuggingFace",
    "hugging face": "HuggingFace",
    "openai": "OpenAI",
    "anthropic": "Anthropic",
    "python": "Python",
    "javascript": "JavaScript",
    "typescript": "TypeScript",
    "rust": "Rust",
    "linux": "Linux",
    "docker": "Docker",
    "kubernetes": "Kubernetes",
    "nvidia": "NVIDIA",
    "cuda": "CUDA",
    "gpu": "GPU",
    "cpu": "CPU",
    "ram": "RAM",
    "vram": "VRAM",
    "api": "API",
    "url": "URL",
    "json": "JSON",
    "yaml": "YAML",
    "toml": "TOML",
    "sdk": "SDK",
    "cli": "CLI",
    "ssh": "SSH",
    "http": "HTTP",
    "https": "HTTPS",
    "tcp": "TCP",
    "udp": "UDP",
    "dns": "DNS",
    "pr": "PR",
    "ci": "CI",
    "ide": "IDE",
    "ui": "UI",
    "ux": "UX",
    "llm": "LLM",
    "ia": "IA",
    "stt": "STT",
    "tts": "TTS",
    "vad": "VAD",
    "wl copy": "wl-copy",
    "wlcopy": "wl-copy",
    "wl paste": "wl-paste",
    "ydotool": "ydotool",
    "ydotoold": "ydotoold",
    "xclip": "xclip",
    "ghostty": "Ghostty",
    "konsole": "Konsole",
    "dolphin": "Dolphin",
    "fish": "fish",
    "zsh": "zsh",
    "bash": "bash",
    # Shortcut phrases Whisper transcribes as "X más Y"
    "control más c": "Ctrl+C",
    "control más v": "Ctrl+V",
    "control más x": "Ctrl+X",
    "control más z": "Ctrl+Z",
    "control más a": "Ctrl+A",
    "control más s": "Ctrl+S",
    "control más f": "Ctrl+F",
    "control más shift v": "Ctrl+Shift+V",
    "control shift v": "Ctrl+Shift+V",
    "meta más espacio": "Meta+Espacio",
    "meta espacio": "Meta+Espacio",
    "super más espacio": "Super+Espacio",
    "super espacio": "Super+Espacio",
}


def load_vocab() -> dict[str, str]:
    """Load user vocab, merging with defaults. Missing/invalid file → defaults."""
    if not VOCAB_PATH.exists():
        return dict(DEFAULT_VOCAB)
    try:
        user = json.loads(VOCAB_PATH.read_text(encoding="utf-8"))
        if not isinstance(user, dict):
            return dict(DEFAULT_VOCAB)
        merged = dict(DEFAULT_VOCAB)
        merged.update({str(k): str(v) for k, v in user.items()})
        return merged
    except (OSError, json.JSONDecodeError):
        return dict(DEFAULT_VOCAB)


def write_default_vocab() -> Path:
    """Create the user vocab file with defaults if it does not exist."""
    if not VOCAB_PATH.exists():
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        VOCAB_PATH.write_text(json.dumps(DEFAULT_VOCAB, ensure_ascii=False, indent=2), encoding="utf-8")
    return VOCAB_PATH


def _apply_vocab(text: str, vocab: dict[str, str]) -> str:
    """Whole-word, case-insensitive substitution. Longer keys match first to
    handle multi-word entries before their single-word constituents."""
    if not vocab:
        return text
    for key in sorted(vocab.keys(), key=len, reverse=True):
        pattern = re.compile(rf"\b{re.escape(key)}\b", re.IGNORECASE)
        text = pattern.sub(vocab[key], text)
    return text


_MULTISPACE = re.compile(r"[ \t]+")
_SPACE_BEFORE_PUNCT = re.compile(r"\s+([,;.:!?])")


def _normalize_whitespace(text: str) -> str:
    text = _MULTISPACE.sub(" ", text)
    text = _SPACE_BEFORE_PUNCT.sub(r"\1", text)
    return text.strip()


_SENTENCE_BOUNDARY = re.compile(r"([.!?]\s+)([a-záéíóúüñ])")


def _capitalize_sentences(text: str) -> str:
    if not text:
        return text
    # Capitalize first character.
    text = text[0].upper() + text[1:]
    # Capitalize after sentence-terminal punctuation.
    return _SENTENCE_BOUNDARY.sub(lambda m: m.group(1) + m.group(2).upper(), text)


def _ensure_terminal_punctuation(text: str) -> str:
    if not text:
        return text
    if text[-1] in ".!?…":
        return text
    return text + "."


def clean(text: str, vocab: dict[str, str] | None = None) -> str:
    """Run the full cleanup pipeline."""
    if not text:
        return text
    vocab = vocab if vocab is not None else load_vocab()
    text = _apply_vocab(text, vocab)
    text = _normalize_whitespace(text)
    text = _capitalize_sentences(text)
    text = _ensure_terminal_punctuation(text)
    return text
