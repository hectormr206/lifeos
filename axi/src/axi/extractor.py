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
fechas EXACTAS y cantidades. Ejemplo CORRECTO: "Esposa: Ana Ríos (civil
14/03/2020, iglesia 08/06/2020)". Ejemplo MALO (pierde lo importante): "Esposa de
Héctor". NUNCA resumas quitando nombres, fechas o números — son lo más valioso de
recordar. Si no caben en el label, ponlos COMPLETOS en data.detail.

NO extraigas:
- Datos efímeros ("hoy hace frío")
- Especulaciones ("quizás Héctor está cansado")
- Hechos sobre el mundo en general
- Cosas que Axi dijo si NO confirmadas por Héctor

Responde SOLO con JSON válido, sin texto antes ni después, exactamente este formato:
{"facts": [
  {"kind": "preference|biographical|decision|plan|setup|health|finance|work|relationship",
   "label": "descripción corta del hecho (máx 80 chars)",
   "data": {"detail": "explicación más larga si vale la pena"},
   "domain": "health|finance|work|home|setup|personal|null"}
]}

Si no hay nada que extraer, responde: {"facts": []}"""


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
    if not parsed or not isinstance(parsed.get("facts"), list):
        log.info("no facts extracted (raw=%r)", raw[:200] if raw else None)
        return 0

    saved = 0
    for f in parsed["facts"]:
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
            fact_id = store.add_node(kind="fact", label=label, data={"category": kind, **data}, domain=domain)
            from axi import identity  # noqa: PLC0415 — lazy, avoids import cycle
            identity.link_fact_to_user(fact_id)  # connect every fact to the user hub
            if conversation_node_id is not None:
                store.add_edge(fact_id, conversation_node_id, "mentioned_in")
            saved += 1
            log.info("fact saved [%s/%s]: %s", kind, domain or "—", label)
        except Exception as e:  # noqa: BLE001 — store can raise sqlite errors
            log.warning("could not save fact %r: %s", label, e)
    return saved
