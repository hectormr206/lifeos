"""ESPIRITUALIDAD domain chat — config for the generic engine. Qualitative
domain (kind + title), so it reuses the shared qualitative builders."""
from __future__ import annotations

from lifeos.spirituality import entries as spirit_entries

from axi.domain_chat import DomainSpec, qualitative_build_entries, simple_format_record

_KINDS = {"reflection", "gratitude", "meditation", "value", "retro", "question"}

_EXTRACT_SYSTEM = """Eres el clasificador del chat de ESPIRITUALIDAD de Axi. Tu
ÚNICO trabajo es leer el mensaje del usuario y devolver un objeto JSON estricto.
NO converses, NO expliques, NO uses Markdown: SOLO el JSON.

Esquema EXACTO (usa null cuando no aplique):
{
  "intent": "register" | "query" | "off_topic",
  "kind": "reflection" | "gratitude" | "meditation" | "value" | "retro" | "question" | null,
  "title": cadena|null      // resumen corto del registro o la pregunta
}

ESPIRITUALIDAD = vida interior: reflexión, gratitud, meditación, oración,
mindfulness, valores, propósito, paz, retrospectivas personales. NO es de aquí:
salud física/médica, ejercicio físico, finanzas, relaciones, aprendizaje técnico,
calendario, clima.

Reglas de intent:
- "off_topic": el mensaje NO es de vida interior/espiritual. Campos en null salvo intent.
- "query": PREGUNTA por sus registros ("¿por qué agradecí la semana pasada?",
  "cuándo medité por última vez").
- "register": REPORTA o reflexiona ("hoy medité 20 minutos", "agradezco por mi
  familia", "reflexioné sobre la paciencia").

Reglas de kind (solo para register): gratitude=agradecer; meditation=meditar/orar;
reflection=reflexión general; value=un valor/propósito; retro=retrospectiva;
question=una pregunta espiritual abierta. Si dudas, usa "reflection".

Devuelve SOLO el JSON, sin texto adicional."""


SPIRIT_SPEC = DomainSpec(
    key="spirituality",
    name="Espiritualidad",
    extract_system=_EXTRACT_SYSTEM,
    build_entries=qualitative_build_entries(_KINDS, "reflection"),
    format_record=simple_format_record,
    store_create=lambda **kw: spirit_entries.create(**kw),
    store_list_recent=lambda **kw: spirit_entries.list_recent(**kw),
    register_prefix="Anotado en Espiritualidad",
    off_topic_msg="Eso no es de Espiritualidad. Probá en el apartado correspondiente.",
    router_hint="vida interior: reflexión, gratitud, meditación, oración, "
                "mindfulness, valores, propósito, paz",
)
