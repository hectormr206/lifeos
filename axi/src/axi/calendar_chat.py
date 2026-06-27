"""CALENDARIO domain chat — config for the generic domain_chat engine.

Manages date-anchored events: trips, birthdays, anniversaries, meetings,
deadlines, milestones, parties. The key difference from other domains is that
the event date lives in the message (often a future date), NOT "now". The
_store_create adapter reads an optional ISO date string from data['event_date']
and uses it as the event's `when`; if absent, falls back to the passed `when`
(= now from the engine).
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from lifeos.events import entries as events_entries

from axi.domain_chat import DomainSpec, simple_format_record

# ─── classifier prompt ────────────────────────────────────────────────────────

_VALID_KINDS = {
    "travel", "party", "milestone", "anniversary",
    "birthday", "meeting", "deadline", "other",
}
_DEFAULT_KIND = "other"

_WEEKDAYS_ES = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]


def _extract_system(now) -> str:
    """Dynamic prompt — injects TODAY so the model resolves relative dates
    ("el viernes", "mañana") to a real YYYY-MM-DD."""
    today = now.strftime("%Y-%m-%d")
    weekday = _WEEKDAYS_ES[now.weekday()]
    return f"""Eres el clasificador del chat de CALENDARIO de Axi. Tu ÚNICO
trabajo es leer el mensaje del usuario y devolver un objeto JSON estricto. NO
converses, NO expliques, NO uses Markdown: SOLO el JSON.

HOY es {today} ({weekday}).

Esquema EXACTO (usa null cuando no aplique):
{{
  "intent": "register" | "query" | "off_topic",
  "kind": "travel" | "party" | "milestone" | "anniversary" | "birthday" | "meeting" | "deadline" | "other" | null,
  "title": cadena|null,   // resumen corto del evento
  "date": cadena|null     // fecha del evento en formato YYYY-MM-DD
}}

CALENDARIO = eventos y fechas: viajes, cumpleaños, aniversarios, fiestas,
reuniones, hitos de vida, plazos/deadlines. NO es de aquí: salud, ejercicio,
finanzas, relaciones cotidianas sin fecha fija, espiritualidad, aprendizaje.

Reglas de intent:
- "off_topic": el mensaje NO es un evento. Campos en null salvo intent.
- "query": PREGUNTA por eventos ("qué tengo esta semana", "cuándo es el viaje").
- "register": REPORTA un evento ("tengo viaje el viernes", "cumpleaños de mamá
  el 10 de julio", "reunión el 2026-07-15").

Reglas de kind (solo para register): travel=viaje; birthday=cumpleaños;
anniversary=aniversario; party=fiesta/celebración; meeting=reunión/cita;
milestone=hito de vida; deadline=plazo/entrega; other=otro. Si dudas: "other".

Regla de date — RESOLVÉ contra HOY ({today}) y escribí SIEMPRE YYYY-MM-DD:
- "hoy" → {today}; "mañana" → HOY+1 día; "pasado mañana" → HOY+2.
- "el viernes" / "el próximo viernes" → el próximo viernes EN O DESPUÉS de HOY
  (igual para cualquier día de la semana).
- "la próxima semana" → mismo día de la semana, 7 días después de HOY.
- "10 de julio" / "el 10/7" → ese día; si el año no se dice, usá el más próximo
  que sea HOY o futuro.
- Si de verdad NO hay ninguna fecha mencionada ni inferible, usa null.

Devuelve SOLO el JSON, sin texto adicional."""


# ─── build entries ────────────────────────────────────────────────────────────


def _build_entries(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
    raw_kind = (extracted.get("kind") or "").strip().lower()
    kind = raw_kind if raw_kind in _VALID_KINDS else _DEFAULT_KIND
    title = (extracted.get("title") or raw_text).strip()[:120] or "evento"
    event_date = (extracted.get("date") or "").strip() or None
    data: dict[str, Any] = {}
    if event_date:
        data["event_date"] = event_date
    return [{
        "kind": kind,
        "title": title,
        "data": data if data else None,
        "fragment": title,
    }]


# ─── store adapter ────────────────────────────────────────────────────────────


def _store_create(*, kind, title, when, body, data, source, raw_utterance):
    """Adapter: generic engine call → events_entries.create().

    If data['event_date'] contains a YYYY-MM-DD string, parse it and use noon
    UTC as the event time instead of the engine's `now`. This allows the chat
    to capture future events ("tengo viaje el 15 de julio") with the correct date.
    """
    d = data or {}
    event_date_str = d.get("event_date")
    event_when = when  # default: now (from engine)
    if event_date_str:
        try:
            dt = datetime.strptime(str(event_date_str).strip(), "%Y-%m-%d")
            event_when = dt.replace(hour=12, minute=0, second=0, microsecond=0,
                                    tzinfo=timezone.utc)
        except (ValueError, TypeError):
            pass  # bad format → fall back to now
    return events_entries.create(
        kind=kind,
        title=title,
        when=event_when,
        body=body,
        source="chat",
        raw_utterance=raw_utterance,
    )


def _store_list_recent(**kw) -> list:
    """Adapter: the generic engine passes days= but events.list_recent uses
    days_back/days_ahead. Use a wide window (±365 d) so both past and future
    events appear in the data view."""
    return events_entries.list_recent(
        days_back=365,
        days_ahead=365,
        limit=kw.get("limit", 200),
    )


# ─── spec ─────────────────────────────────────────────────────────────────────


CALENDAR_SPEC = DomainSpec(
    key="calendar",
    name="Calendario",
    extract_system=_extract_system,
    build_entries=_build_entries,
    format_record=simple_format_record,
    store_create=_store_create,
    store_list_recent=_store_list_recent,
    register_prefix="Anotado en Calendario",
    off_topic_msg="Eso no es de Calendario. Probá en el apartado correspondiente.",
    router_hint="eventos y fechas: viajes, cumpleaños, aniversarios, fiestas, "
                "hitos, citas con fecha, deadlines",
    store_delete=lambda eid: events_entries.delete(eid),
    store_update_title=lambda eid, title: events_entries.update_title(eid, title),
)
