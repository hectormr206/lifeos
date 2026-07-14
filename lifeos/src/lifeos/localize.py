"""Tiny locale helper — formats datetimes and looks up message templates.

No external i18n library: we support just `es-*` and `en-*` for now. When
a third language shows up, swap in babel/gettext. Keeping it inline keeps
the dep surface flat and the LLM-generated code easy to audit.
"""

from __future__ import annotations

from datetime import datetime

_SPANISH_WEEKDAYS = {
    0: "lunes", 1: "martes", 2: "miércoles", 3: "jueves",
    4: "viernes", 5: "sábado", 6: "domingo",
}
_SPANISH_MONTHS = {
    1: "ene", 2: "feb", 3: "mar", 4: "abr", 5: "may", 6: "jun",
    7: "jul", 8: "ago", 9: "sep", 10: "oct", 11: "nov", 12: "dic",
}
_ENGLISH_WEEKDAYS = {
    0: "Monday", 1: "Tuesday", 2: "Wednesday", 3: "Thursday",
    4: "Friday", 5: "Saturday", 6: "Sunday",
}
_ENGLISH_MONTHS = {
    1: "Jan", 2: "Feb", 3: "Mar", 4: "Apr", 5: "May", 6: "Jun",
    7: "Jul", 8: "Aug", 9: "Sep", 10: "Oct", 11: "Nov", 12: "Dec",
}
_SPANISH_WEEKDAY_ABBR = {
    0: "lun", 1: "mar", 2: "mié", 3: "jue", 4: "vie", 5: "sáb", 6: "dom",
}
_ENGLISH_WEEKDAY_ABBR = {
    0: "Mon", 1: "Tue", 2: "Wed", 3: "Thu", 4: "Fri", 5: "Sat", 6: "Sun",
}


def lang_family(lang: str | None) -> str:
    """Reduce 'es-MX' → 'es', 'en-US' → 'en'. Defaults to 'es'."""
    if not lang:
        return "es"
    return lang.split("-")[0].lower()


def format_local_when(dt: datetime, lang: str | None = None) -> str:
    """Render `dt` like 'jueves 21 may 09:00' (es) or 'Thursday 21 May 09:00' (en).

    `dt` should already be in the user's local TZ — we don't convert here.
    """
    fam = lang_family(lang)
    if fam == "es":
        wd = _SPANISH_WEEKDAYS[dt.weekday()]
        mo = _SPANISH_MONTHS[dt.month]
    else:
        wd = _ENGLISH_WEEKDAYS[dt.weekday()]
        mo = _ENGLISH_MONTHS[dt.month]
    return f"{wd} {dt.day} {mo} {dt.strftime('%H:%M')}"


def format_short_when(dt: datetime, lang: str | None = None) -> str:
    """Render `dt` like 'sáb 23 14:00' (es) or 'Sat 23 14:00' (en).

    Locale-independent replacement for strftime('%a %d %H:%M') — the day is
    zero-padded exactly like %d. `dt` should already be in the user's local TZ.
    """
    fam = lang_family(lang)
    if fam == "es":
        wd = _SPANISH_WEEKDAY_ABBR[dt.weekday()]
    else:
        wd = _ENGLISH_WEEKDAY_ABBR[dt.weekday()]
    return f"{wd} {dt.strftime('%d %H:%M')}"


# Daemon voice-loop notification strings.
# Keys: (message_key, lang_family).
# Added for i18n EN MVP (Approach B): daemon.py uses these instead of
# hardcoded Spanish strings so EN users see English feedback notifications.
#
# ES strings must be byte-for-byte identical to the originals in daemon.py.

# Reminder confirmation templates.
# Keys: ('reminder_one_shot' | 'reminder_recurring', lang_family).
_TEMPLATES: dict[tuple[str, str], str] = {
    ("reminder_one_shot", "es"): (
        'Listo. Recordatorio programado para {when}: "{message}". '
        "Te aviso en laptop y celular."
    ),
    ("reminder_one_shot", "en"): (
        'Got it. Reminder set for {when}: "{message}". '
        "I'll ping your laptop and phone."
    ),
    ("reminder_recurring", "es"): (
        "Listo. Recordatorio recurrente programado ({cron}). "
        "Primera vez: {when}. Te aviso en laptop y celular."
    ),
    ("reminder_recurring", "en"): (
        "Got it. Recurring reminder set ({cron}). "
        "First time: {when}. I'll ping your laptop and phone."
    ),
    # Daemon voice-loop feedback notifications
    ("too_short", "es"): "Pregunta muy corta",
    ("too_short", "en"): "Too short — try again",
    ("silence", "es"): "No oí pregunta",
    ("silence", "en"): "No audio detected",
    ("no_audio", "es"): "No oí nada",
    ("no_audio", "en"): "Nothing heard",
    ("thinking", "es"): "Pensando…",
    ("thinking", "en"): "Thinking…",
    ("listening", "es"): "Escuchando",
    ("listening", "en"): "Listening",
    ("too_short_recording", "es"): "Grabación muy corta",
    ("too_short_recording", "en"): "Recording too short",
    ("transcribing", "es"): "Transcribiendo…",
    ("transcribing", "en"): "Transcribing…",
    ("nothing_to_transcribe", "es"): "Nada que transcribir",
    ("nothing_to_transcribe", "en"): "Nothing to transcribe",
    # Used by _stop_and_transcribe (dictation silence, distinct from ask-mode silence)
    ("silence_dictation", "es"): "No oí nada (silencio)",
    ("silence_dictation", "en"): "No audio detected",
    # Voice-path confirmations (utterance-language-aware where possible).
    # ES strings must stay byte-for-byte identical to the historical hardcoded
    # Spanish so es behavior does not change.
    ("reminder_created", "es"): "Recordatorio: {message} — {when}",
    ("reminder_created", "en"): "Reminder: {message} — {when}",
    ("intent_executed", "es"): "Acción ejecutada: {intent}",
    ("intent_executed", "en"): "Action executed: {intent}",
    ("camera_busy", "es"): "📷 No puedo ver — la cámara la usa {who} (¿reunión activa?)",
    ("camera_busy", "en"): "📷 Can't see — the camera is in use by {who} (meeting in progress?)",
    ("camera_busy_other_app", "es"): "otra app",
    ("camera_busy_other_app", "en"): "another app",
    ("meeting_active", "es"): "🎙️📷 Modo reunión activo (id #{mid})",
    ("meeting_active", "en"): "🎙️📷 Meeting mode active (id #{mid})",
    # Hands-free dev intent (_h_dev_develop)
    ("dev_no_goal", "es"): "No entendí qué quieres que desarrolle.",
    ("dev_no_goal", "en"): "I didn't catch what you want me to build.",
    ("dev_env_created", "es"): (
        "Listo, lo armé como ambiente en Desarrollo — entra a /desarrollo "
        "para probarlo y desplegarlo."
    ),
    ("dev_env_created", "en"): (
        "Done — I set it up as an environment in Development. "
        "Open /desarrollo to test and deploy it."
    ),
    ("dev_env_created_speak", "es"): (
        "Listo, lo armé como ambiente en Desarrollo. Entra a probarlo cuando quieras."
    ),
    ("dev_env_created_speak", "en"): (
        "Done — I set it up as an environment in Development. "
        "Try it out whenever you want."
    ),
}


def msg(key: str, lang: str | None, **fmt) -> str:
    """Render a localized message template with `fmt` substitutions.

    Falls back to Spanish if the (key, lang) pair is missing.
    """
    fam = lang_family(lang)
    template = _TEMPLATES.get((key, fam)) or _TEMPLATES.get((key, "es")) or ""
    return template.format(**fmt)
