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
}


def msg(key: str, lang: str | None, **fmt) -> str:
    """Render a localized message template with `fmt` substitutions.

    Falls back to Spanish if the (key, lang) pair is missing.
    """
    fam = lang_family(lang)
    template = _TEMPLATES.get((key, fam)) or _TEMPLATES.get((key, "es")) or ""
    return template.format(**fmt)
