"""Voice command palette — intent classifier for dictated utterances (P1.2).

After Whisper transcribes a dictation, `classify(text)` decides whether the
utterance is a real command ("axi, abre el dashboard") or just dictation that
should be typed into the focused window.

The classifier is intentionally STRICT to avoid misfires when the user is
quoting somebody or simply talking *about* Axi rather than *to* it:

1. PREFIX GATE — text must start with `^\\s*axi[,:\\s]+`. "axi me dijo que…"
   passes this prefix but is filtered later because "me" is not an imperative.
2. IMPERATIVE GATE — within the first three tokens after the trigger there must
   be a Spanish imperative verb from a closed set (empieza, abre, activa, …).
3. REGEX → intent table — verb + object lookup.
4. BRAIN FALLBACK — if the gates pass but no regex intent matches, ask the
   brain with a 2-second hard timeout. On timeout/error, fall back to dictation.

Each new intent is a single new row in `INTENT_HANDLERS`. The classifier
NEVER raises; on any internal error it logs to `events` and returns None so
the dictation path keeps working.

Public surface:
    classify(text)                                  → (name, params) | None
    INTENT_HANDLERS: dict[str, Callable[[Daemon], str]]
"""
from __future__ import annotations

import logging
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from pathlib import Path
from typing import Any, Callable

log = logging.getLogger("axi.intents")


# ───────────────────────── classifier ─────────────────────────

# Closed set of imperative verbs we accept after the "axi" trigger.
# Includes infinitives + tú/vos imperatives because Whisper's punctuation
# of voice commands is unreliable ("axi empezar reunión" is common).
_IMPERATIVES = (
    "empieza", "empezar", "empezá", "empece",
    "inicia", "iniciar", "iniciá",
    "comienza", "comenzar", "comenzá",
    "termina", "terminar", "terminá",
    "abre", "abrir", "abrí",
    "detén", "detener", "deten",
    "para", "parar", "pará",
    "cierra", "cerrar", "cerrá",
    "activa", "activar", "activá",
    "desactiva", "desactivar", "desactivá",
    "reinicia", "reiniciar", "reiniciá",
    "borra", "borrar", "borrá",
    "limpia", "limpiar", "limpiá",
    "olvida", "olvidar", "olvidá",
    "sal", "salir", "salí",
)

# Trigger word at the start. We accept several Whisper-misheard variants
# of "axi" because Whisper interprets non-Spanish "Axi" as the nearest
# Spanish word that sounds similar: "así", "asi", "asís", "axí", "axis",
# "ax", "achi", "hachi", "hatxi". They all share the phoneme /a-ks-i/ or
# /a-s-i/. By matching variants here, we capture commands the user
# pronounced as "Axi" even when Whisper writes them as "Así".
_TRIGGER = r"(?:axi|así|asi|axí|asís|axis|hachi|achi|hatxi|ax|hace|hacé|haz|asx)"
_PREFIX_RE = re.compile(
    rf"^\s*{_TRIGGER}\s*[,:.\-\s]+\s*(?P<rest>.+)$",
    re.IGNORECASE | re.DOTALL,
)

# Short-form patterns that bypass the imperative-verb gate. These are
# extremely specific commands ("modo X") that users say without a verb.
# Each must be unambiguous on its own — "modo juego" can ONLY mean game_on.
_SHORT_FORMS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^modo\s+juego\b", re.IGNORECASE), "game_on"),
    (re.compile(r"^modo\s+normal\b", re.IGNORECASE), "game_off"),
    (re.compile(r"^modo\s+int[eé]rprete\b", re.IGNORECASE), "translate_on"),
    (re.compile(r"^dashboard\b", re.IGNORECASE), "open_dashboard"),
    (re.compile(r"^tablero\b", re.IGNORECASE), "open_dashboard"),
    (re.compile(r"^reuni[oó]n\b", re.IGNORECASE), "meeting_start"),
)

# Regex → intent mapping. Each entry says: when the post-prefix text matches
# this regex, this is the intent. Order matters — first match wins.
# We anchor every pattern so a "sal del modo juego" doesn't accidentally
# match a future broader "sal" rule.
_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    # meeting
    (re.compile(r"^(empieza|empezar|empezá|inicia|iniciar|iniciá|comienza|comenzar|comenzá)\s+(la\s+)?reuni[oó]n\b", re.IGNORECASE), "meeting_start"),
    (re.compile(r"^(termina|terminar|terminá|para|parar|pará|detén|detener|deten)\s+(la\s+)?reuni[oó]n\b", re.IGNORECASE), "meeting_stop"),
    # dashboard
    (re.compile(r"^(abre|abrir|abrí)\s+(el\s+)?(dashboard|tablero|panel)\b", re.IGNORECASE), "open_dashboard"),
    # translate / interpreter
    (re.compile(r"^(activa|activar|activá)\s+(el\s+)?(modo\s+)?int[eé]rprete\b", re.IGNORECASE), "translate_on"),
    (re.compile(r"^(desactiva|desactivar|desactivá)\s+(el\s+)?(modo\s+)?int[eé]rprete\b", re.IGNORECASE), "translate_off"),
    # game mode
    (re.compile(r"^(activa|activar|activá)\s+(el\s+)?(modo\s+)?juego\b", re.IGNORECASE), "game_on"),
    (re.compile(r"^(desactiva|desactivar|desactivá)\s+(el\s+)?(modo\s+)?juego\b", re.IGNORECASE), "game_off"),
    (re.compile(r"^(sal|salir|salí)\s+(del\s+)?(modo\s+)?juego\b", re.IGNORECASE), "game_off"),
    # conversation clear
    (re.compile(r"^(limpia|limpiar|limpiá|borra|borrar|borrá|olvida|olvidar|olvidá)\s+(la\s+)?(conversaci[oó]n|historial|memoria(\s+corta)?)\b", re.IGNORECASE), "clear_conversation"),
)


_KNOWN_INTENTS = (
    "dictation",
    "meeting_start",
    "meeting_stop",
    "open_dashboard",
    "translate_on",
    "translate_off",
    "game_on",
    "game_off",
    "clear_conversation",
)


def _has_imperative_prefix(rest: str) -> bool:
    """Return True if any of the first 3 tokens of `rest` is in _IMPERATIVES."""
    tokens = re.findall(r"[a-záéíóúñü]+", rest.lower(), flags=re.IGNORECASE)[:3]
    return any(t in _IMPERATIVES for t in tokens)


def _strip_prefix(text: str) -> str | None:
    """Return the post-`axi` part of `text` if it matches the strict prefix.

    Returns None when the utterance does not start with `axi[,:\\s]+`.
    """
    m = _PREFIX_RE.match(text or "")
    if not m:
        return None
    return m.group("rest").strip()


def classify(text: str, *, brain_ask: Callable[..., str] | None = None) -> tuple[str, dict[str, Any]] | None:
    """Classify `text` into an intent.

    Returns (intent_name, params) when the text is a command we should execute
    instead of typing. Returns None when the text is plain dictation.

    Order:
      1. Prefix gate (`^axi[,:\\s]+`).
      2. Imperative gate (verb in first 3 tokens).
      3. Regex rules.
      4. Brain fallback (2 s hard timeout). Only invoked when `brain_ask` is
         given AND gates pass AND no regex matched.
    """
    if not text or not isinstance(text, str):
        return None

    rest = _strip_prefix(text)
    if rest is None:
        return None

    # Short-forms bypass the imperative gate ("axi, modo juego" has no verb
    # but is unambiguous). Try these first.
    for pattern, name in _SHORT_FORMS:
        if pattern.search(rest):
            return name, {}

    if not _has_imperative_prefix(rest):
        return None

    for pattern, name in _RULES:
        if pattern.search(rest):
            return name, {}

    # Brain fallback. The prompt is intentionally tiny so the model can answer
    # in <1 s; we still cap with a 2 s wall clock because llama-server can
    # stall when busy with another request.
    if brain_ask is not None:
        try:
            label = _brain_classify(text, brain_ask)
        except Exception as e:  # noqa: BLE001
            log.warning("brain fallback failed: %s", e)
            return None
        if label and label != "dictation" and label in _KNOWN_INTENTS:
            return label, {"_source": "brain"}
        return None

    return None


def _brain_classify(text: str, brain_ask: Callable[..., str], timeout_s: float = 2.0) -> str | None:
    prompt = (
        "Clasifica este comando de voz en una de estas categorías "
        "[dictation, meeting_start, meeting_stop, open_dashboard, translate_on, "
        "translate_off, game_on, game_off, clear_conversation]. "
        "Responde SOLO con el nombre de la categoría. "
        f"Texto: {text}"
    )

    def _call() -> str:
        # max_tokens kwarg is best-effort — the brain.ask signature accepts it
        # explicitly. If a fake brain rejects it, fall back to a plain call.
        try:
            return brain_ask(prompt, max_tokens=20)
        except TypeError:
            return brain_ask(prompt)

    # We do NOT use `with ThreadPoolExecutor` because its __exit__ blocks on
    # worker shutdown — a hung brain call would defeat the timeout. Manual
    # submit + leak the worker as a daemon thread: process exit cleans it up.
    ex = ThreadPoolExecutor(max_workers=1)
    fut = ex.submit(_call)
    try:
        raw = fut.result(timeout=timeout_s)
    except FutureTimeout:
        log.info("brain classifier timeout (%.1fs)", timeout_s)
        ex.shutdown(wait=False, cancel_futures=True)
        return None
    finally:
        # Non-blocking shutdown — never wait on a possibly-hung worker.
        try:
            ex.shutdown(wait=False)
        except Exception:  # noqa: BLE001
            pass
    if not raw:
        return None
    # The model sometimes wraps the answer in punctuation or extra words.
    # Scan its response for the first known label.
    lower = raw.strip().lower()
    for label in _KNOWN_INTENTS:
        if label in lower:
            return label
    return None


# ───────────────────────── handlers ─────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent.parent.parent / "scripts"


def _send_cmd(daemon, cmd: str) -> str:
    """Reach into the daemon socket using the dashboard's protocol.

    The daemon already handles `meeting_start`, `meeting_stop`, `clear` via
    `_handle_cmd`. We invoke those directly on the in-process daemon so we
    don't open a socket from a thread the daemon itself owns.
    """
    from axi.daemon import _handle_cmd  # lazy — avoid import cycle
    response, _ = _handle_cmd(daemon, cmd)
    return response


def _popen(*args: str) -> str:
    """Spawn a detached process. Returns a short status string."""
    try:
        subprocess.Popen(  # noqa: S603
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return "spawned"
    except (FileNotFoundError, OSError) as e:
        return f"spawn-failed:{e}"


def _script(name: str) -> str:
    """Absolute path to an axi script under LifeOS/axi/scripts/."""
    return str(SCRIPT_DIR / name)


def _h_meeting_start(daemon) -> str:
    return _send_cmd(daemon, "meeting_start")


def _h_meeting_stop(daemon) -> str:
    return _send_cmd(daemon, "meeting_stop")


def _h_open_dashboard(daemon) -> str:
    return _popen(_script("axi-dashboard-open"))


def _h_translate_on(daemon) -> str:
    return _popen(_script("axi-translate-on"))


def _h_translate_off(daemon) -> str:
    return _popen(_script("axi-translate-off"))


def _h_game_on(daemon) -> str:
    return _popen(_script("axi-game-on"))


def _h_game_off(daemon) -> str:
    return _popen(_script("axi-game-off"))


def _h_clear_conversation(daemon) -> str:
    return _send_cmd(daemon, "clear")


INTENT_HANDLERS: dict[str, Callable[[Any], str]] = {
    "meeting_start": _h_meeting_start,
    "meeting_stop": _h_meeting_stop,
    "open_dashboard": _h_open_dashboard,
    "translate_on": _h_translate_on,
    "translate_off": _h_translate_off,
    "game_on": _h_game_on,
    "game_off": _h_game_off,
    "clear_conversation": _h_clear_conversation,
}
