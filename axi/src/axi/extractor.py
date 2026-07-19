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

import datetime
import json
import logging
import re
from typing import Any
from zoneinfo import ZoneInfo

from axi import config, store
from axi.brain import ask as brain_ask

log = logging.getLogger("axi.extractor")

# Structured domains own their own graph nodes (via domain_bridge); chat
# extraction skips these to avoid duplicating logged vitals/transactions and
# instead captures the REST (identity, preferences, biographical, relationships).
_STRUCTURED_DOMAINS = {"health", "finance"}

# A fact is skipped only when it is a PURE NUMERIC VITAL/MEASUREMENT that the
# domain bridge already logs (presión 120/80, glucosa 95, peso 64, dormí 7h, a
# bare NNN/NN). Narrative health/finance facts — diagnoses, medications + doses,
# treatment status, temporal qualifiers, doctors, plans — are NOT vitals and are
# kept as durable graph facts. These patterns intentionally match the LOGGED
# measurement shapes only, never prose.
_VITAL_PATTERNS: tuple[re.Pattern[str], ...] = (
    # Blood pressure "120/80", "114/81". Negative look-around so calendar dates
    # like "14/03/2020" (three groups) are NOT mistaken for a reading.
    re.compile(r"(?<![\d/])\d{2,3}\s*/\s*\d{2,3}(?![\d/])"),
    # "presión 120", "tensión 120/80"
    re.compile(r"\b(?:presi[oó]n|tensi[oó]n)\b[^.\d]{0,12}\d", re.IGNORECASE),
    # "glucosa 95", "glucemia 110", "azúcar 90"
    re.compile(r"\b(?:glucosa|glucemia|az[uú]car)\b[^.\d]{0,12}\d", re.IGNORECASE),
    # "peso 64", "pesé 64"
    re.compile(r"\b(?:peso|pes[ée])\b[^.\d]{0,12}\d", re.IGNORECASE),
    # "temperatura 36.8"
    re.compile(r"\btemperatura\b[^.\d]{0,12}\d", re.IGNORECASE),
    # "pulso 70", "frecuencia cardíaca 72", "72 bpm"
    re.compile(r"\b(?:pulso|frecuencia\s+card[ií]aca|fc|bpm)\b[^.\d]{0,12}\d", re.IGNORECASE),
    re.compile(r"\b\d{2,3}\s*bpm\b", re.IGNORECASE),
    # "dormí 7h", "dormí 8 horas"
    re.compile(r"\bdorm[ií]\w*\b[^.\d]{0,12}\d+\s*h", re.IGNORECASE),
    re.compile(r"\b\d+\s*h(?:oras)?\s+de\s+sue[ñn]o\b", re.IGNORECASE),
)


def _is_logged_vital(label: str, kind: str | None = None, domain: str | None = None) -> bool:
    """True only when *label* is a pure numeric vital/measurement the domain
    bridge already logs (e.g. "presión 120/80", "glucosa 95", "dormí 7h",
    "114/81"). Narrative facts ("diagnosticada hace ~2 años", "le recetaron
    losartán", "hipertensión") return False so they are kept.

    ``kind``/``domain`` are accepted for call-site symmetry and future tuning but
    the decision is driven by the measurement-shaped regexes, which never match
    prose.
    """
    del kind, domain  # reserved; decision is regex-driven
    text = (label or "").strip()
    if not text:
        return False
    return any(p.search(text) for p in _VITAL_PATTERNS)

_EXTRACTOR_SYSTEM_TEMPLATE = """Eres un extractor de hechos para la memoria de largo plazo de Axi.
HOY es {HOY}. Usa esta fecha para convertir tiempos RELATIVOS en una referencia
absoluta APROXIMADA (ver más abajo). NUNCA inventes una fecha exacta.
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
fechas EXACTAS y cantidades. Ejemplo CORRECTO: "Esposa: Ana Ríos (civil
14/03/2020, iglesia 08/06/2020)". Ejemplo MALO (pierde lo importante): "Esposa de
Héctor". NUNCA resumas quitando nombres, fechas o números — son lo más valioso de
recordar. Si no caben en el label, ponlos COMPLETOS en data.detail.

CAPTURA explícitamente, como HECHOS, los matices TEMPORALES, de ESTADO y de
PRESCRIPCIÓN cuando aparezcan en temas de salud/finanzas — NO los descartes:
- TEMPORAL: "hace ~2 años", duraciones, "desde ~2024", "todas las mañanas". Si
  Héctor da un tiempo RELATIVO ("hace más de 2 años") y conoces HOY, el label
  debe registrar AMBOS: la frase relativa Y un absoluto APROXIMADO y EXPLÍCITAMENTE
  difuso. Ej: "Hipertensión diagnosticada hace ~2 años (≈2024)". NUNCA pongas una
  fecha exacta inventada (nada de "15/03/2024"): siempre "≈AAAA" o "hace ~N años".
- ESTADO: "medicación suspendida", "dejó el losartán", "estable sin medicamento",
  "automonitoreo matutino". Es un hecho duradero por sí mismo.
- PRESCRIPCIÓN como HISTORIA, distinta del uso actual: si le recetaron algo aunque
  lo haya suspendido, guarda un hecho tipo "Le recetaron media pastilla de losartán
  50 mg (suspendido)" para que "¿qué me recetó?" sea respondible aunque ya no lo tome.
El label de cada uno de estos hechos DEBE MENCIONAR el/los nombres de las entidades
relevantes (hipertensión / losartán / Dra. López) para que queden conectados en el grafo.
Sé conciso y factual; no inundes el grafo: captura solo los matices con valor.

RELATOS DE VIDA: cuando Héctor narra eventos de vida que involucran a SU gente
(familia, amigos, colegas) o planes/eventos (aperturas, invitaciones, viajes,
mudanzas), esos SÍ son hechos DURADEROS sobre la vida de Héctor — guárdalos
como facts, no solo como relaciones. Si Héctor dijo una fecha EXACTA ("el 15 de
agosto"), mantenla EXACTA en el label completándola con el año usando HOY
(ej: 15/08/2026); ≈ es solo para tiempos relativos.

NO extraigas:
- Mediciones numéricas sueltas de vitales ("presión 120/80", "glucosa 95",
  "peso 64", "dormí 7h"): esas las registra otro canal; aquí NO las repitas. Pero
  SÍ guarda el diagnóstico, la condición, la medicación y su estado/temporalidad.
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
- El sujeto puede ser Héctor (usa "Héctor" o "yo") O otra entidad.
- Captura relaciones ENTIDAD-A-ENTIDAD, no solo Héctor->entidad. Ej: una condición
  "diagnosticada_por" un doctor, o "tratada_con" un medicamento.

Tipos de entidad válidos (kind): person, place, org, medication, condition,
product, food, activity, document, event, brand, tool, thing.

Predicados típicos: padece, tiene, diagnosticada_por, tratada_con, recetado_por,
toma, comió, hizo, vive_en, trabaja_en, esposa, esposo, hijo, hija, madre, padre,
hermano, primo, prima, tío, tía, cuñado, vecino, colega, amigo, jefe, mascota,
dueño_de, usa, compró…

REGLAS ESTRICTAS para relations:
- SOLO relaciones dichas EXPLÍCITAMENTE. Si un lugar aparece asociado a OTRA
  persona o negocio, NO crees relaciones de Héctor con ese lugar (nada de
  Héctor--vive_en-->lugar si Héctor no dijo que vive ahí).
- Si Héctor nombra el vínculo (primo, tía, jefe, vecino), usa EXACTAMENTE esa
  palabra como relation — nunca la degrades a 'conoce' o 'amigo'.

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
   "aliases": ["apodos/diminutivos del OBJETO si los menciona (ej: 'Ani'); [] si no hay"]}
 ]}

Ejemplos de relations:
- "mi esposa Ana Ríos, le dicen Ani" ->
  [{"subject":"Héctor","subject_kind":"person","relation":"esposa",
    "object":"Ana Ríos","object_kind":"person","aliases":["Ani"]}]
- "hace 2 años la Dra Tere me diagnosticó hipertensión y me recetó losartán" ->
  [{"subject":"Héctor","subject_kind":"person","relation":"padece",
    "object":"hipertensión","object_kind":"condition","aliases":[]},
   {"subject":"hipertensión","subject_kind":"condition","relation":"diagnosticada_por",
    "object":"Dra. López","object_kind":"person","aliases":[]},
   {"subject":"hipertensión","subject_kind":"condition","relation":"tratada_con",
    "object":"losartán","object_kind":"medication","aliases":[]}]

Solo extrae una relación si hay una ENTIDAD NOMBRADA y concreta y un vínculo claro.
NUNCA inventes entidades de palabras genéricas ("agua", "cosas", "un rato") ni de
números de vitales sueltos. Ante la duda, omití. Si no hay relaciones, deja
"relations": [].
Si no hay nada que extraer, responde: {"facts": [], "relations": []}

EJEMPLO COMPLETO (temporal + estado + prescripción). Si HOY fuera 2026-06-30 y
Héctor dijera: "hace más de 2 años la Dra Tere me diagnosticó hipertensión, me
recetó media pastilla de losartán de 50 mg pero la dejé y me reviso casi todas
las mañanas, estable sin medicamento" -> responder:
{"facts": [
  {"kind":"health","label":"Hipertensión diagnosticada hace ~2 años (≈2024) por la Dra. López","data":{},"domain":"health"},
  {"kind":"health","label":"Le recetaron media pastilla de losartán 50 mg (suspendido)","data":{},"domain":"health"},
  {"kind":"health","label":"Hipertensión estable sin medicamento, automonitoreo matutino","data":{},"domain":"health"}
 ],
 "relations": [
  {"subject":"Héctor","subject_kind":"person","relation":"padece","object":"hipertensión","object_kind":"condition","aliases":[]},
  {"subject":"hipertensión","subject_kind":"condition","relation":"diagnosticada_por","object":"Dra. López","object_kind":"person","aliases":[]},
  {"subject":"hipertensión","subject_kind":"condition","relation":"tratada_con","object":"losartán","object_kind":"medication","aliases":[]}
 ]}
Notá: NINGÚN hecho repite el vital numérico, pero el diagnóstico (con su
temporalidad ≈2024), la prescripción suspendida y el estado SÍ se guardan.

EJEMPLO RELATO DE VIDA. Si HOY fuera 2026-06-30 y Héctor dijera: "mi primo
Rodrigo Zetina abrió una taquería en Querétaro y me invitó a la inauguración
el 15 de agosto" -> responder:
{"facts": [
  {"kind":"biographical","label":"Primo Rodrigo Zetina abrió una taquería en Querétaro (≈2026)","data":{},"domain":"personal"},
  {"kind":"plan","label":"Invitado a la inauguración de la taquería de Rodrigo Zetina el 15/08/2026","data":{},"domain":"personal"}
 ],
 "relations": [
  {"subject":"Héctor","subject_kind":"person","relation":"primo","object":"Rodrigo Zetina","object_kind":"person","aliases":[]},
  {"subject":"Rodrigo Zetina","subject_kind":"person","relation":"dueño_de","object":"taquería en Querétaro","object_kind":"place","aliases":[]}
 ]}
Notá: NO hay Héctor--vive_en-->Querétaro (nadie dijo que Héctor viva ahí); el
vínculo es "primo" (la palabra EXACTA que usó Héctor, no "conoce"); la fecha
15/08/2026 queda EXACTA porque Héctor dijo "el 15 de agosto" y HOY da el año."""


def _build_extractor_system(today_str: str) -> str:
    """Build the extractor system prompt with today's date injected so the model
    can turn relative times ("hace 2 años") into an approximate absolute (≈2024).
    The date is only a reference for fuzzy approximation — the prompt forbids
    fabricating exact dates.
    """
    return _EXTRACTOR_SYSTEM_TEMPLATE.replace("{HOY}", today_str)


def _today_str() -> str:
    """Today's date (YYYY-MM-DD) in the user's configured timezone."""
    tz_name = config.get("timezone", "America/Mexico_City") or "America/Mexico_City"
    try:
        tz = ZoneInfo(str(tz_name))
    except Exception:  # noqa: BLE001
        tz = ZoneInfo("UTC")
    return datetime.datetime.now(tz).strftime("%Y-%m-%d")


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
    system = _build_extractor_system(_today_str())
    # Deterministic decoding (temperature=0.0, seed=0): the extractor must be
    # reproducible — sampling variance made identical messages extract different
    # (or zero) facts across runs. Mirrors the nano eval change (3f3e3ac4).
    # max_tokens=800: long multi-topic life-story messages overflow 512.
    raw = brain_ask(
        prompt=exchange,
        system=system,
        max_tokens=800,
        timeout=60.0,
        think=False,
        image_b64=None,
        history=None,
        temperature=0.0,
        seed=0,
        task="extraction",
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
        # Narrowed skip: drop ONLY pure numeric vitals/measurements that the
        # domain bridge already logs (presión 120/80, glucosa 95, dormí 7h, …).
        # NARRATIVE health/finance facts — diagnoses, medications + doses,
        # treatment status, temporal qualifiers, doctors, plans — are kept as
        # durable graph facts so questions like "¿hace cuánto me diagnosticaron?"
        # are answerable from memory.
        if _is_logged_vital(label, kind, domain):
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
