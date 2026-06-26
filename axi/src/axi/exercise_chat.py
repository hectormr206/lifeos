"""EJERCICIO domain chat — config for the generic engine. Semi-quantitative
(kind + optional duration), so it adapts the generic create call to
exercise_sessions.create() (which needs duration_minutes)."""
from __future__ import annotations

from typing import Any

from lifeos.exercise import sessions as ex_sessions

from axi.domain_chat import DomainSpec, num

_KINDS = {"walk", "run", "cardio", "strength", "yoga", "sports", "other"}

_EXTRACT_SYSTEM = """Eres el clasificador del chat de EJERCICIO de Axi. Tu ÚNICO
trabajo es leer el mensaje del usuario y devolver un objeto JSON estricto. NO
converses, NO expliques, NO uses Markdown: SOLO el JSON.

Esquema EXACTO (usa null cuando no aplique):
{
  "intent": "register" | "query" | "off_topic",
  "kind": "walk" | "run" | "cardio" | "strength" | "yoga" | "sports" | "other" | null,
  "duration_minutes": entero|null,   // duración en minutos, si se menciona
  "title": cadena|null               // resumen corto de la sesión o la pregunta
}

EJERCICIO = actividad física/entrenamiento: caminar, correr, cardio, pesas/fuerza,
yoga, deportes, gimnasio, entrenar. NO es de aquí: salud médica (presión/glucosa →
Salud), finanzas, relaciones, espiritualidad, aprendizaje, calendario.

Reglas de intent:
- "off_topic": el mensaje NO es de actividad física. Campos en null salvo intent.
- "query": PREGUNTA por sus sesiones ("cuánto corrí esta semana", "cuándo entrené
  pesas por última vez").
- "register": REPORTA actividad ("corrí 30 minutos", "fui al gym", "hice yoga").

Reglas de kind (solo register): walk=caminar; run=correr/trotar; cardio=cardio;
strength=pesas/fuerza/gym; yoga=yoga; sports=deportes; other=otro. Si dudas: "other".
Extrae duration_minutes solo si el usuario la menciona.

Devuelve SOLO el JSON, sin texto adicional."""


def _build_register_entries(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
    raw_kind = (extracted.get("kind") or "").strip().lower()
    kind = raw_kind if raw_kind in _KINDS else "other"
    dur = num(extracted.get("duration_minutes"))
    dur = int(dur) if dur is not None and 0 <= dur <= 1440 else 0
    title = (extracted.get("title") or raw_text).strip()[:120] or "ejercicio"
    frag = f"{title} ({dur} min)" if dur else title
    return [{"kind": kind, "title": title, "data": {"duration_minutes": dur}, "fragment": frag}]


def _store_create(*, kind, title, when, body, data, source, raw_utterance):
    """Adapter: generic engine call -> exercise_sessions.create (needs duration)."""
    d = data or {}
    return ex_sessions.create(
        kind=kind,
        title=title,
        duration_minutes=int(d.get("duration_minutes") or 0),
        when=when,
        body=body,
        source="chat",
        raw_utterance=raw_utterance,
    )


def _format_record(e: Any, local_date: str) -> str:
    dur = getattr(e, "duration_minutes", None)
    extra = f" {int(dur)}min" if dur else ""
    return f"- id={e.id} fecha={local_date} kind={e.kind} title={e.title}{extra}"


EXERCISE_SPEC = DomainSpec(
    key="exercise",
    name="Ejercicio",
    extract_system=_EXTRACT_SYSTEM,
    build_entries=_build_register_entries,
    format_record=_format_record,
    store_create=_store_create,
    store_list_recent=lambda **kw: ex_sessions.list_recent(**kw),
    register_prefix="Anotado en Ejercicio",
    off_topic_msg="Eso no es de Ejercicio. Probá en el apartado correspondiente.",
    router_hint="actividad física: caminar, correr, cardio, pesas/fuerza, yoga, "
                "deportes, gimnasio, entrenar",
    store_delete=lambda eid: ex_sessions.delete(eid),
)
