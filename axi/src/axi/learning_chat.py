"""APRENDIZAJE domain chat — config for the generic engine. Qualitative domain
(kind + title), reuses the shared qualitative builders."""
from __future__ import annotations

from lifeos.learning import entries as learn_entries

from axi.domain_chat import DomainSpec, qualitative_build_entries, simple_format_record

_KINDS = {"book", "course", "article", "idea", "research_question", "note", "quote"}

_EXTRACT_SYSTEM = """Eres el clasificador del chat de APRENDIZAJE de Axi. Tu ÚNICO
trabajo es leer el mensaje del usuario y devolver un objeto JSON estricto. NO
converses, NO expliques, NO uses Markdown: SOLO el JSON.

Esquema EXACTO (usa null cuando no aplique):
{
  "intent": "register" | "query" | "off_topic",
  "kind": "book" | "course" | "article" | "idea" | "research_question" | "note" | "quote" | null,
  "title": cadena|null      // título del recurso, la idea, o la pregunta
}

APRENDIZAJE = conocimiento: libros, cursos, artículos, ideas, preguntas de
investigación, notas de estudio, citas. NO es de aquí: salud, ejercicio,
finanzas, relaciones, espiritualidad, calendario, clima.

Reglas de intent:
- "off_topic": el mensaje NO es de aprendizaje/conocimiento. Campos en null salvo intent.
- "query": PREGUNTA por sus registros ("qué libros empecé este mes", "cuál era
  esa idea que anoté sobre X").
- "register": REPORTA algo que aprende/lee/quiere estudiar ("empecé a leer Clean
  Code", "idea: usar specs reutilizables", "curso de Rust en Udemy").

Reglas de kind (solo para register): book=libro; course=curso; article=artículo;
idea=una idea; research_question=pregunta de investigación; quote=una cita;
note=nota de estudio. Si dudas, usa "note".

Devuelve SOLO el JSON, sin texto adicional."""


LEARN_SPEC = DomainSpec(
    key="learning",
    name="Aprendizaje",
    extract_system=_EXTRACT_SYSTEM,
    build_entries=qualitative_build_entries(_KINDS, "note"),
    format_record=simple_format_record,
    store_create=lambda **kw: learn_entries.create(**kw),
    store_list_recent=lambda **kw: learn_entries.list_recent(**kw),
    register_prefix="Anotado en Aprendizaje",
    off_topic_msg="Eso no es de Aprendizaje. Probá en el apartado correspondiente.",
    router_hint="conocimiento: libros, cursos, artículos, ideas, preguntas de "
                "investigación, notas de estudio, citas",
)
