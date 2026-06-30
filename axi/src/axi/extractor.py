"""Fact extraction loop — long-term memory pump for Axi.

After every ask-flow exchange the daemon spawns a background thread that
asks the same local LLM (Qwen) to reflect: "of what just happened, what
is a durable fact about Héctor worth remembering?" Extracted facts become
graph nodes (`kind='fact'`) connected to the source conversation via a
`mentioned_in` edge.

Why a separate pass:
- The user-facing answer can stay terse and snappy
- Extraction can be slower (~3-5 s) without blocking the conversation
- Re-prompting with a strict JSON-only system message keeps the parsing
  trivial and the output focused

Heuristics to avoid hallucinated facts:
- The model only sees the most recent turn (no full history)
- Strict JSON schema; non-JSON output is discarded
- Empty/null result is the explicit "nothing worth remembering" path
"""
from __future__ import annotations

import json
import logging
import re
from typing import Any

from axi import config, store
from axi.brain import ask as brain_ask

log = logging.getLogger("axi.extractor")

# Structured domains own their own graph nodes (via domain_bridge); chat
# extraction skips these to avoid duplicating logged vitals/transactions and
# instead captures the REST (identity, preferences, biographical, relationships).
_STRUCTURED_DOMAINS = {"health", "finance"}

EXTRACTOR_SYSTEM = """Eres un extractor de hechos para la memoria de largo plazo de Axi.
Te paso un intercambio entre Héctor (usuario) y Axi (asistente).
Tu trabajo: identificar de 0 a 4 hechos DURADEROS sobre Héctor que valga la pena recordar
para futuras conversaciones (preferencias, datos biográficos, decisiones, planes,
configuración personal, salud, finanzas, relaciones, contexto profesional).

Cada hecho que guardes va a llevar automáticamente la fecha+hora exacta del momento.
Eso permite que en el futuro, si un hecho cambia (ej: "mic favorito" pasa de HyperX
a Huawei), las versiones nuevas superseden a las viejas por timestamp. Por eso es
importante que el `label` sea SIEMPRE en presente y específico — describiendo el estado
ACTUAL declarado por Héctor en este intercambio.

El `label` DEBE incluir los datos CONCRETOS textuales: nombres propios COMPLETOS,
fechas EXACTAS y cantidades. Ejemplo CORRECTO: "Esposa: Celia García Mateo (civil
06/09/2018, iglesia 26/01/2019)". Ejemplo MALO (pierde lo importante): "Esposa de
Héctor". NUNCA resumas quitando nombres, fechas o números — son lo más valioso de
recordar. Si no caben en el label, ponlos COMPLETOS en data.detail.

NO extraigas:
- Datos efímeros ("hoy hace frío")
- Especulaciones ("quizás Héctor está cansado")
- Hechos sobre el mundo en general
- Cosas que Axi dijo si NO confirmadas por Héctor

También extrae RELACIONES: cualquier ENTIDAD NOMBRADA y específica que aparezca y
los VÍNCULOS entre ellas, para que vivan en el grafo conectadas. No te limites a
personas: captura también medicamentos, enfermedades/condiciones, productos,
comidas, actividades, lugares, organizaciones, documentos, eventos, marcas y
herramientas — siempre que sean algo NOMBRADO y concreto.

Cada relación es un TRIPLE sujeto-predicado-objeto con el TIPO de cada extremo:
- El sujeto puede ser Héctor (usá "Héctor" o "yo") O otra entidad.
- Capturá relaciones ENTIDAD-A-ENTIDAD, no solo Héctor->entidad. Ej: una condición
  "diagnosticada_por" un doctor, o "tratada_con" un medicamento.

Tipos de entidad válidos (kind): person, place, org, medication, condition,
product, food, activity, document, event, brand, tool, thing.

Predicados típicos: padece, tiene, diagnosticada_por, tratada_con, recetado_por,
toma, comió, hizo, vive_en, trabaja_en, esposa, esposo, hijo, hija, madre, padre,
hermano, amigo, jefe, mascota, usa, compró…

Responde SOLO con JSON válido, sin texto antes ni después, exactamente este formato:
{"facts": [
  {"kind": "preference|biographical|decision|plan|setup|health|finance|work|relationship",
   "label": "descripción corta del hecho (máx 80 chars)",
   "data": {"detail": "explicación más larga si vale la pena"},
   "domain": "health|finance|work|home|setup|personal|null"}
],
 "relations": [
  {"subject": "<entidad sujeto, o 'Héctor'/'yo' si es el usuario>",
   "subject_kind": "<tipo del sujeto: person|condition|medication|…>",
   "relation": "<predicado: padece, diagnosticada_por, tratada_con, esposa, vive_en, …>",
   "object": "<NOMBRE de la entidad objeto, lo más completo posible>",
   "object_kind": "<tipo del objeto>",
   "aliases": ["apodos/diminutivos del OBJETO si los menciona (ej: 'Cely'); [] si no hay"]}
 ]}

Ejemplos de relations:
- "mi esposa Celia García Mateo, le dicen Cely" ->
  [{"subject":"Héctor","subject_kind":"person","relation":"esposa",
    "object":"Celia García Mateo","object_kind":"person","aliases":["Cely"]}]
- "hace 2 años la Dra Tere me diagnosticó hipertensión y me recetó losartán" ->
  [{"subject":"Héctor","subject_kind":"person","relation":"padece",
    "object":"hipertensión","object_kind":"condition","aliases":[]},
   {"subject":"hipertensión","subject_kind":"condition","relation":"diagnosticada_por",
    "object":"Dra. Tere","object_kind":"person","aliases":[]},
   {"subject":"hipertensión","subject_kind":"condition","relation":"tratada_con",
    "object":"losartán","object_kind":"medication","aliases":[]}]

Solo extrae una relación si hay una ENTIDAD NOMBRADA y concreta y un vínculo claro.
NUNCA inventes entidades de palabras genéricas ("agua", "cosas", "un rato") ni de
números de vitales sueltos. Ante la duda, omití. Si no hay relaciones, deja
"relations": [].
Si no hay nada que extraer, responde: {"facts": [], "relations": []}"""


def _parse_json_strict(text: str) -> dict[str, Any] | None:
    """Try to recover JSON even if the model added markdown fences or prose."""
    if not text:
        return None
    # Strip markdown code fences if present.
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, flags=re.DOTALL)
    if m:
        text = m.group(1)
    # Otherwise look for the first top-level object.
    if not text.lstrip().startswith("{"):
        idx = text.find("{")
        if idx == -1:
            return None
        text = text[idx:]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Try trimming trailing junk.
        last = text.rfind("}")
        if last != -1:
            try:
                return json.loads(text[: last + 1])
            except json.JSONDecodeError:
                return None
        return None


def extract_and_store(user_text: str, axi_text: str, conversation_node_id: int | None) -> int:
    """Run one extraction pass and persist any facts. Returns count of facts saved.

    Gated by the ``graph_bridge_chat_facts`` config flag (default False). When
    the flag is off the function returns 0 immediately without making the LLM
    call — keeping the semantic graph free of arbitrary-domain chat facts.
    """
    if not config.get("graph_bridge_chat_facts", False):
        return 0

    exchange = f"Héctor dijo: {user_text}\n\nAxi respondió: {axi_text}"
    raw = brain_ask(
        prompt=exchange,
        system=EXTRACTOR_SYSTEM,
        max_tokens=512,
        timeout=60.0,
        think=False,
        image_b64=None,
        history=None,
    )
    parsed = _parse_json_strict(raw)
    if not parsed:
        log.info("no extraction (raw=%r)", raw[:200] if raw else None)
        return 0
    facts = parsed.get("facts") if isinstance(parsed.get("facts"), list) else []
    relations = parsed.get("relations") if isinstance(parsed.get("relations"), list) else []

    saved = 0
    touched_facts: list[tuple[int, str]] = []  # (id, label) to link to entities below
    for f in facts:
        if not isinstance(f, dict):
            continue
        label = (f.get("label") or "").strip()
        if not label:
            continue
        kind = (f.get("kind") or "fact").strip()
        domain = f.get("domain") or None
        if domain == "null":
            domain = None
        # Structured domains (health, finance, …) own their own graph nodes via
        # the domain bridge — skip them here so free-chat extraction does not
        # duplicate logged vitals/transactions. Chat extraction captures the
        # REST: identity, preferences, biographical, decisions, relationships.
        if kind in _STRUCTURED_DOMAINS or (domain in _STRUCTURED_DOMAINS):
            continue
        data = f.get("data") if isinstance(f.get("data"), dict) else {}
        try:
            from axi import identity  # noqa: PLC0415 — lazy, avoids import cycle
            # Idempotency: a fact with this EXACT label already exists -> it's a
            # duplicate (timeless chat fact), not a new event. Ensure it's linked
            # to the hub and skip creating a copy.
            existing = store.find_fact_by_label(label)
            if existing is not None:
                identity.link_fact_to_user(existing)
                touched_facts.append((existing, label))
                continue
            fact_id = store.add_node(kind="fact", label=label, data={"category": kind, **data}, domain=domain)
            identity.link_fact_to_user(fact_id)  # connect every fact to the user hub
            if conversation_node_id is not None:
                store.add_edge(fact_id, conversation_node_id, "mentioned_in")
            saved += 1
            touched_facts.append((fact_id, label))
            log.info("fact saved [%s/%s]: %s", kind, domain or "—", label)
        except Exception as e:  # noqa: BLE001 — store can raise sqlite errors
            log.warning("could not save fact %r: %s", label, e)

    # Typed relations — create entity nodes + typed edges so any NAMED thing
    # (people, places, orgs, medications, conditions, products, …) becomes a
    # first-class graph entity, and ENTITY-TO-ENTITY links (e.g. hipertensión
    # --tratada_con--> losartán) are captured, not just Héctor->entity ones.
    #
    # Two relation shapes are accepted:
    #   NEW (preferred): {"subject","subject_kind","relation","object","object_kind"}
    #   OLD (back-compat): {"relation","entity","kind"} -> treated as user->entity.
    from axi import identity  # noqa: PLC0415 — lazy, avoids import cycle
    for rel in relations:
        if not isinstance(rel, dict):
            continue
        relation = (rel.get("relation") or "").strip()
        if not relation:
            continue
        try:
            if rel.get("subject") is not None or rel.get("object") is not None:
                # New subject-predicate-object triple shape.
                subject = (rel.get("subject") or "").strip()
                obj = (rel.get("object") or "").strip()
                if not subject or not obj:
                    continue
                subject_kind = (rel.get("subject_kind") or "thing").strip()
                object_kind = (rel.get("object_kind") or "thing").strip()
                identity.add_entity_relation(
                    subject, relation, obj,
                    subject_kind=subject_kind, object_kind=object_kind,
                )
                for al in (rel.get("aliases") or []):
                    al = str(al).strip()
                    if al:
                        identity.register_alias(obj, al, object_kind)
                log.info("relation saved: %s --%s--> %s (%s/%s)",
                         subject, relation, obj, subject_kind, object_kind)
            else:
                # Old hub-centric shape: Héctor --relation--> entity.
                entity = (rel.get("entity") or "").strip()
                if not entity:
                    continue
                ekind = (rel.get("kind") or "person").strip()
                identity.add_relation(relation, entity, ekind)
                for al in (rel.get("aliases") or []):
                    al = str(al).strip()
                    if al:
                        identity.register_alias(entity, al, ekind)
                log.info("relation saved: --%s--> %s (%s)", relation, entity, ekind)
        except Exception as e:  # noqa: BLE001
            log.warning("could not save relation %r: %s", rel, e)

    # Rich entity profiles: now that this turn's entities exist (relations
    # above), connect every fact touched this turn to the entities it mentions
    # (fact --mentions--> entity), so each entity aggregates the facts about it.
    for fid, lbl in touched_facts:
        identity.link_fact_to_entities(fid, lbl)
    return saved
