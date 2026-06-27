"""RELACIONES domain chat — config for the generic domain_chat engine.

Manages social interactions: calls, conversations, conflicts, quality time,
texts, and notes linked to people. Person resolution is handled in the
_store_create adapter via people.get_or_create so the engine never crashes
on a missing person_id.
"""
from __future__ import annotations

from typing import Any

from lifeos.relationships import interactions
from lifeos.relationships import people

from axi.domain_chat import DomainSpec, simple_format_record

# ─── classifier prompt ────────────────────────────────────────────────────────

_VALID_KINDS = {"conversation", "conflict", "quality_time", "call", "text", "note"}
_DEFAULT_KIND = "conversation"

_EXTRACT_SYSTEM = """Eres el clasificador del chat de RELACIONES de Axi. Tu ÚNICO
trabajo es leer el mensaje del usuario y devolver un objeto JSON estricto. NO
converses, NO expliques, NO uses Markdown: SOLO el JSON.

Esquema EXACTO (usa null cuando no aplique):
{
  "intent": "register" | "query" | "off_topic",
  "kind": "conversation" | "conflict" | "quality_time" | "call" | "text" | "note" | null,
  "person": cadena|null,   // nombre de la persona (ej. "Juan", "mamá") si se menciona
  "role": cadena|null,     // relación ("mamá","esposa","amigo") si no hay nombre propio
  "title": cadena|null     // resumen corto de la interacción o la pregunta
}

RELACIONES = interacciones con otras personas: llamadas, conversaciones,
encuentros, conflictos, mensajes, tiempo de calidad, notas sobre relaciones.
NO es de aquí: salud, ejercicio, finanzas, espiritualidad, aprendizaje, eventos
con fecha fija (calendario), clima.

Reglas de intent:
- "off_topic": el mensaje NO es sobre interacciones con personas. Campos en null.
- "query": PREGUNTA por sus relaciones ("cómo estuvo mi relación con mamá este mes",
  "cuándo llamé a Juan por última vez").
- "register": REPORTA una interacción ("hablé con mamá", "tuve una discusión con
  mi jefe", "tomé un café con Carlos", "mandé un mensaje a María").

Reglas de kind (solo para register): call=llamada; conversation=conversación/charla;
conflict=conflicto/discusión; quality_time=tiempo de calidad intencional; text=mensaje/WhatsApp;
note=observación sobre la relación. Si dudas, usa "conversation".

Devuelve SOLO el JSON, sin texto adicional."""


# ─── build entries ────────────────────────────────────────────────────────────


def _build_entries(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
    raw_kind = (extracted.get("kind") or "").strip().lower()
    kind = raw_kind if raw_kind in _VALID_KINDS else _DEFAULT_KIND
    title = (extracted.get("title") or raw_text).strip()[:120] or "interacción"
    person_name = (extracted.get("person") or "").strip()
    role = (extracted.get("role") or "").strip() or None
    return [{
        "kind": kind,
        "title": title,
        "data": {"person": person_name, "role": role},
        "fragment": title,
    }]


# ─── store adapter ────────────────────────────────────────────────────────────


def _store_create(*, kind, title, when, body, data, source, raw_utterance):
    """Adapter: generic engine call → interactions.create() via person resolution."""
    d = data or {}
    person_name = (d.get("person") or "").strip()
    role = d.get("role") or None

    # Resolve person name: fall back to role label, then derive from title.
    if not person_name:
        if role:
            person_name = str(role).capitalize()
        else:
            # Use first word of title as a best-effort label; never crash.
            words = title.split()
            person_name = words[0].capitalize() if words else "Persona"

    person_obj = people.get_or_create(name=person_name, role=role)
    return interactions.create(
        person_id=person_obj.id,
        kind=kind,
        title=title,
        when=when,
        body=body,
        source="chat",
        raw_utterance=raw_utterance,
    )


# ─── spec ─────────────────────────────────────────────────────────────────────


RELATIONSHIPS_SPEC = DomainSpec(
    key="relationships",
    name="Relaciones",
    extract_system=_EXTRACT_SYSTEM,
    build_entries=_build_entries,
    format_record=simple_format_record,
    store_create=_store_create,
    store_list_recent=lambda **kw: interactions.list_recent(**kw),
    register_prefix="Anotado en Relaciones",
    off_topic_msg="Eso no es de Relaciones. Probá en el apartado correspondiente.",
    router_hint="relaciones con personas: llamadas, mensajes, encuentros, "
                "conflictos, con familia/amigos/pareja",
    store_delete=lambda eid: interactions.delete(eid),
    store_update_title=lambda eid, title: interactions.update_title(eid, title),
)
