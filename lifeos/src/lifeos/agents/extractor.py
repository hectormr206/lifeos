"""Entity extractor nano-agent.

Receives free-form Spanish text and returns a structured dict with the
detected domain, people, amounts, dates, etc. Wraps the nano llama-server
(Qwen3.5-0.8B by default) with a curated few-shot prompt.

Public API:
    extract(text) → ExtractionResult | None

The result has the same shape regardless of which domain matched —
callers inspect `.domain` and route to the appropriate store.

This is the FALLBACK path called from dashboard.py when none of the
regex-based domain parsers (health, finance, etc.) matched. It's not a
replacement for the regex path — that's still fastest (~10ms vs ~1000ms
here). It's a safety net for the natural-language inputs the regex
can't handle.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any

from lifeos.agents import runtime

log = logging.getLogger("lifeos.agents.extractor")


@dataclass(frozen=True, slots=True)
class ExtractionResult:
    domain: str | None             # finance|relationships|exercise|learning|health|events|spirituality|null
    amount: float | None = None
    currency: str | None = None
    merchant: str | None = None
    people: list[str] = field(default_factory=list)
    dates_text: list[str] = field(default_factory=list)
    duration_minutes: float | None = None
    items: list[dict[str, Any]] = field(default_factory=list)
    title: str | None = None
    kind: str | None = None
    # Structured vitals — only populated when domain=health and kind=vital
    # and the model detected a specific vital reading.
    systolic: int | None = None
    diastolic: int | None = None
    pulse_bpm: int | None = None
    # Non-BP vitals (Task 2: sleep, weight, glucose)
    sleep_hours: float | None = None
    weight_kg: float | None = None
    glucose_mg_dl: float | None = None
    raw_json: str | None = None      # for debugging
    confidence: float = 0.6          # nano agents start at moderate confidence


# Few-shot prompt curated for Qwen3.5-0.8B. The examples cover the main
# domain shapes; the rules at the bottom prevent common confusions
# (e.g., "caminé con mi esposa" goes to exercise not relationships).
_SYSTEM_PROMPT = """Sos un extractor de entidades para LifeOS. Recibís un mensaje en español y devolvés EXCLUSIVAMENTE un JSON válido con esta forma exacta (sin texto antes ni después):

{
  "domain": "finance|relationships|exercise|learning|health|events|spirituality|null",
  "amount": number|null,
  "currency": "MXN"|"USD"|null,
  "merchant": string|null,
  "people": [string],
  "dates_text": [string],
  "duration_minutes": number|null,
  "items": [{"name": string, "amount": number|null, "category": string|null}],
  "title": string|null,
  "kind": string|null,
  "systolic": number|null,
  "diastolic": number|null,
  "pulse_bpm": number|null,
  "sleep_hours": number|null,
  "weight_kg": number|null,
  "glucose_mg_dl": number|null
}

Reglas de DOMAIN (uno solo, no listes opciones):
- Actividad física (caminé, corrí, gym, ejercicio, entrenar): "exercise"
  AUNQUE mencione personas o lugares.
- Dinero / compras (gasté, compré, pagué, costó): "finance".
  Servicios del hogar en contexto mexicano (gas, luz/CFE, agua, internet,
  teléfono, renta): kind="bill", category="servicios". Gasolina/combustible
  sigue siendo "expense" con category="transporte". merchant= nombre del
  servicio (Gas, CFE, Telmex, etc.), NO el texto completo del mensaje.
- Interacción humana (hablé, discutí, conocí, casarse, llamé): "relationships".
  PERO solo si hay foco en la INTERACCIÓN, no si la persona es contexto
  secundario de otra actividad.
- Aprender, estudiar, leer libro, idea: "learning".
- Síntoma, medicación, vital (presión, glucosa, peso, sueño): "health".
  IMPORTANTE: números como "122/81" o "113, 82" son presión arterial (health),
  NO son fechas ni eventos. Si aparece "pulso", "pulsos" o "pulsaciones"
  junto a números de presión, es siempre "health" con kind="vital".
  Sueño (dormí, me dormí, me acosté → desperté): kind="vital", sleep_hours=horas SI Y SOLO SI el usuario DIJO EXPLÍCITAMENTE cuántas horas (ej. "dormí 8 horas" → 8.0). Si solo da horarios de entrada/salida (ej. "me dormí a las 11, desperté a las 7"), sleep_hours=null — NO calcules la diferencia.
  Peso corporal (pesé, peso X kg): kind="vital", weight_kg=número.
  Glucosa (glucosa X, azúcar X): kind="vital", glucose_mg_dl=número.
- Aniversario, cumple, fecha importante a futuro: "events".
- Reflexión espiritual, agradecimiento EXPLÍCITO a Dios/lo divino, meditación,
  oración, "gracias a Dios", expresión de fe o paz interior deliberada:
  "spirituality". SOLO cuando el texto expresa fe, oración o gratitud espiritual
  EXPLÍCITA del usuario. NO confundas con salud: "me siento bien/en paz/agradecido"
  sin síntoma físico → spirituality si hay intención espiritual; health solo si
  hay síntoma o vital. IMPORTANTE — NO es spirituality: observaciones del clima
  o temperatura ("hace calor", "llueve", "el cielo está nublado"), hechos del
  mundo no personales ("el sol sale por el este", "el agua hierve a 100°C"),
  ni datos sin contexto. Esos son null.
- Texto sin contenido de dominio vital (saludos, risas, fillers como "ok",
  "jajaja", "sí claro", "jeje que raro", confirmaciones de conversación,
  números sueltos sin contexto, observaciones ambientales del clima, hechos
  generales del mundo sin participación personal): null. Si dudás entre un
  dominio y null, elegí null.
- Nada aplica claramente: null.

Reglas CRÍTICAS de PEOPLE — leelas dos veces:
- Solo metés en "people" un nombre propio que APAREZCA LITERALMENTE en
  el texto, escrito con MAYÚSCULA inicial. Ejemplos válidos: "Daniela",
  "Diego", "María".
- NUNCA pongas "mi mamá", "mi papá", "mi esposa", "mi hermano", "mi vieja",
  "mi novia", "mi suegra", etc. Esos son ROLES, NO personas. Si el texto
  SOLO menciona el rol y no el nombre, dejá people=[].
- NUNCA inventes nombres que no aparezcan literalmente. Si el texto dice
  "Claude Code" eso es un PRODUCTO/TECNOLOGÍA, no una persona.
- Si dudás si una palabra es nombre propio, NO la incluyas. Mejor false
  negative que false positive.

Reglas de OTROS campos:
- amount: el TOTAL gastado/cobrado. Solo número, sin moneda.
- items: cada producto con su precio individual si está dado. Cada item
  tiene name (obligatorio), amount (opcional), category (opcional).
- dates_text: copia el texto LITERAL de cada fecha (no normalices).
- duration_minutes: total en minutos (1 hora = 60).
- systolic / diastolic / pulse_bpm: SOLO cuando domain=health y kind=vital
  y el mensaje contiene una lectura de presión arterial. Extraé los valores
  enteros exactos. Si no hay lectura de presión, ponelos null.
- sleep_hours: SOLO cuando domain=health y kind=vital y hay info de sueño.
  Calculá las horas (número decimal). Si no hay dato de sueño, null.
- weight_kg: SOLO cuando domain=health y kind=vital y hay peso corporal en kg.
  Si no hay dato de peso, null.
- glucose_mg_dl: SOLO cuando domain=health y kind=vital y hay glucosa en mg/dL.
  Si no hay dato de glucosa, null.
- Si un campo no aplica, ponelo null o [] (NUNCA lo omitas).

Ejemplos:

INPUT: "Hablé con Diego en la oficina ayer"
OUTPUT: {"domain":"relationships","amount":null,"currency":null,"merchant":null,"people":["Diego"],"dates_text":["ayer"],"duration_minutes":null,"items":[],"title":"conversación con Diego","kind":"conversation","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Tuve una discusión fuerte con mi mamá esta tarde"
OUTPUT: {"domain":"relationships","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":["esta tarde"],"duration_minutes":null,"items":[],"title":"discusión con mi mamá","kind":"conflict","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Gasté 1850 en Aurrera: 320 detergente, 450 papel higiénico, 500 cable HDMI"
OUTPUT: {"domain":"finance","amount":1850,"currency":"MXN","merchant":"Aurrera","people":[],"dates_text":[],"duration_minutes":null,"items":[{"name":"detergente","amount":320,"category":"hogar"},{"name":"papel higiénico","amount":450,"category":"hogar"},{"name":"cable HDMI","amount":500,"category":"electrónica"}],"title":"compra en Aurrera","kind":"expense","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Caminé en el parque con mi esposa Daniela durante 45 minutos"
OUTPUT: {"domain":"exercise","amount":null,"currency":null,"merchant":null,"people":["Daniela"],"dates_text":[],"duration_minutes":45,"items":[],"title":"caminata en el parque","kind":"walk","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Hicimos una caminata familiar de 1 hora en el parque"
OUTPUT: {"domain":"exercise","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":60,"items":[],"title":"caminata familiar","kind":"walk","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Estoy aprendiendo Claude Code para LifeOS"
OUTPUT: {"domain":"learning","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"aprendiendo Claude Code","kind":"study","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Empecé el libro Atomic Habits de James Clear"
OUTPUT: {"domain":"learning","amount":null,"currency":null,"merchant":null,"people":["James Clear"],"dates_text":[],"duration_minutes":null,"items":[],"title":"Atomic Habits","kind":"book","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Mi esposa Daniela y yo nos casamos el 15 de junio de 2018"
OUTPUT: {"domain":"events","amount":null,"currency":null,"merchant":null,"people":["Daniela"],"dates_text":["15 de junio de 2018"],"duration_minutes":null,"items":[],"title":"casamiento con Daniela","kind":"milestone","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "jajaja sí claro"
OUTPUT: {"domain":null,"amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":null,"kind":null,"systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "hace mucho calor hoy"
OUTPUT: {"domain":null,"amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":null,"kind":null,"systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "el sol sale por el este"
OUTPUT: {"domain":null,"amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":null,"kind":null,"systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "42"
OUTPUT: {"domain":null,"amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":null,"kind":null,"systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "gracias a Dios por este día"
OUTPUT: {"domain":"spirituality","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"agradecimiento del día","kind":"gratitude","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "pagué el gas, 580 pesos"
OUTPUT: {"domain":"finance","amount":580,"currency":"MXN","merchant":"Gas","people":[],"dates_text":[],"duration_minutes":null,"items":[{"name":"gas","amount":580,"category":"servicios"}],"title":"pago de gas","kind":"bill","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "pagué la luz, 340"
OUTPUT: {"domain":"finance","amount":340,"currency":"MXN","merchant":"CFE","people":[],"dates_text":[],"duration_minutes":null,"items":[{"name":"luz","amount":340,"category":"servicios"}],"title":"pago de luz","kind":"bill","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "cargué gasolina, 800 pesos"
OUTPUT: {"domain":"finance","amount":800,"currency":"MXN","merchant":"Gasolinera","people":[],"dates_text":[],"duration_minutes":null,"items":[{"name":"gasolina","amount":800,"category":"transporte"}],"title":"gasolina","kind":"expense","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "122/81 53 pulsos"
OUTPUT: {"domain":"health","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"presión 122/81, pulso 53","kind":"vital","systolic":122,"diastolic":81,"pulse_bpm":53,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "113, 82 y 55 de pulso."
OUTPUT: {"domain":"health","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"presión 113/82, pulso 55","kind":"vital","systolic":113,"diastolic":82,"pulse_bpm":55,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "me duele mucho la cabeza desde esta mañana"
OUTPUT: {"domain":"health","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":["esta mañana"],"duration_minutes":null,"items":[],"title":"dolor de cabeza","kind":"symptom","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "Me dormí a las 11 pm y acabo de despertar"
OUTPUT: {"domain":"health","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"registro de sueño","kind":"note","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "dormí ocho horas"
OUTPUT: {"domain":"health","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"dormí 8h","kind":"vital","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":8.0,"weight_kg":null,"glucose_mg_dl":null}

INPUT: "pesé 64.5 kg hoy en ayunas, glucosa 95"
OUTPUT: {"domain":"health","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":["hoy"],"duration_minutes":null,"items":[],"title":"peso 64.5 kg, glucosa 95","kind":"vital","systolic":null,"diastolic":null,"pulse_bpm":null,"sleep_hours":null,"weight_kg":64.5,"glucose_mg_dl":95.0}

Respondé EXCLUSIVAMENTE con el JSON. Nada más."""


def _try_parse_json(content: str) -> dict | None:
    """Extract the first {...} block from the model's response and parse it.
    The model sometimes wraps the JSON in markdown fences or adds trailing
    text despite instructions. We grab the first balanced object."""
    content = content.strip()
    if content.startswith("```"):
        # strip ```json...``` fences
        content = re.sub(r"^```(?:json)?\s*\n?", "", content)
        content = re.sub(r"\n?```\s*$", "", content)
    # Greedy match to first balanced top-level object.
    start = content.find("{")
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(content)):
        c = content[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(content[start:i + 1])
                except json.JSONDecodeError:
                    return None
    return None


# Deterministic conversational acks/fillers. A standalone message that is
# nothing but one of these carries no life-domain data, so we short-circuit to
# null BEFORE paying for a nano call. This is the cheap deterministic layer the
# 0.8B prompt should NOT grow to cover: e.g. "dale" → spirituality was a model
# quirk at the prompt-capacity ceiling (~3900 tokens), and patching it into the
# monolith would just trade one regression for another. Whole-message match
# only — "dale" filters, but "dale, gasté 200" still reaches the model.
_ACK_FILLERS = frozenset({
    "ok", "okay", "okey", "oka", "ok ya", "ya", "dale", "va", "bueno",
    "listo", "perfecto", "perfecto gracias", "ok gracias", "gracias",
    "de una", "sale", "vale", "joya", "barbaro", "genial", "claro",
    "si", "sí", "si claro", "sí claro", "no", "aja", "ajá", "ah",
    "jaja", "jajaja", "jeje", "jejeje", "jiji", "jaj", "jajaj",
})

# Leading/trailing punctuation and whitespace to peel off before matching.
_ACK_STRIP = " \t\n\r.,;:!¡¿?…\"'"


def _is_ack_filler(text: str) -> bool:
    """True when the whole message is just a conversational ack/filler.

    Normalizes case, strips surrounding punctuation, and collapses internal
    whitespace, then checks membership in the closed `_ACK_FILLERS` set. Any
    message carrying real content (extra tokens, internal punctuation) falls
    through to the model unchanged.
    """
    norm = " ".join(text.lower().strip(_ACK_STRIP).split())
    return norm in _ACK_FILLERS


def extract(
    text: str,
    *,
    timeout_s: float = 5.0,
    retry_timeout_s: float = 15.0,
    retries: int = 1,
    temperature: float = 0.1,
    seed: int | None = None,
) -> ExtractionResult | None:
    """Run the entity extractor over `text`. Returns None on:
      - empty input
      - nano service unreachable (after exhausting retries)
      - model returned garbage / unparseable JSON
      - domain came back as null (no useful extraction)

    Callers should treat None as "fast-path didn't help; fall through to
    the main brain as before". This keeps the regex → nano → brain
    cascade safe by default.

    Transient-failure retry: a nano *transport* failure (timeout, service
    unreachable) is NOT a "no domain here" decision — it's infra noise from
    CPU contention or an input too long to finish inside `timeout_s`. Since
    the brain fallback does NOT persist, a swallowed timeout silently drops
    the user's data. So on `r.ok == False` we retry up to `retries` times
    with the larger `retry_timeout_s` budget before giving up. A clean
    answer (parse failure, null domain) is NOT retried — that's a real
    decision and burning a 15s retry on it would only add latency."""
    if not text or not text.strip():
        return None

    # Deterministic short-circuit: a bare ack/filler ("ok", "dale", "listo")
    # has no life-domain data. Resolve it here instead of spending a nano call
    # and risking a model misclassification at the prompt-capacity ceiling.
    if _is_ack_filler(text):
        return None

    r = runtime.call_nano(
        system=_SYSTEM_PROMPT,
        user=text,
        temperature=temperature,
        max_tokens=800,
        timeout_s=timeout_s,
        seed=seed,
    )
    attempt = 0
    while not r.ok and attempt < retries:
        attempt += 1
        log.warning(
            "nano extractor: call failed (%s, %dms) — retry %d/%d (timeout=%.0fs)",
            r.error, r.latency_ms, attempt, retries, retry_timeout_s,
        )
        r = runtime.call_nano(
            system=_SYSTEM_PROMPT,
            user=text,
            temperature=temperature,
            max_tokens=800,
            timeout_s=retry_timeout_s,
            seed=seed,
        )
    if not r.ok:
        log.warning(
            "nano extractor: call failed after %d attempt(s) (%s, %dms)",
            attempt + 1, r.error, r.latency_ms,
        )
        return None

    parsed = _try_parse_json(r.content)
    if not parsed:
        log.warning("nano extractor: JSON parse failed. raw=%r", r.content[:200])
        return None

    domain = parsed.get("domain")
    if domain in ("null", "", None):
        return None
    # Validate the domain value
    if domain not in {
        "finance", "relationships", "exercise", "learning",
        "health", "events", "spirituality",
    }:
        log.warning("nano extractor: bad domain %r", domain)
        return None

    def _str_list(v) -> list[str]:
        if not isinstance(v, list):
            return []
        return [str(x).strip() for x in v if x and str(x).strip()]

    def _items(v) -> list[dict]:
        if not isinstance(v, list):
            return []
        out = []
        for it in v:
            if not isinstance(it, dict):
                continue
            name = str(it.get("name", "")).strip()
            if not name:
                continue
            try:
                amt = float(it["amount"]) if it.get("amount") is not None else None
            except (TypeError, ValueError):
                amt = None
            out.append({
                "name": name,
                "amount": amt,
                "category": (str(it["category"]).strip() if it.get("category") else None),
            })
        return out

    try:
        amount = float(parsed["amount"]) if parsed.get("amount") is not None else None
    except (TypeError, ValueError):
        amount = None
    try:
        dur = float(parsed["duration_minutes"]) if parsed.get("duration_minutes") is not None else None
    except (TypeError, ValueError):
        dur = None

    def _int_or_none(v) -> int | None:
        if v is None:
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    def _float_or_none(v) -> float | None:
        if v is None:
            return None
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    return ExtractionResult(
        domain=str(domain),
        amount=amount,
        currency=(str(parsed.get("currency")).strip() if parsed.get("currency") else None),
        merchant=(str(parsed.get("merchant")).strip() if parsed.get("merchant") else None),
        people=_str_list(parsed.get("people")),
        dates_text=_str_list(parsed.get("dates_text")),
        duration_minutes=dur,
        items=_items(parsed.get("items")),
        title=(str(parsed.get("title")).strip() if parsed.get("title") else None),
        kind=(str(parsed.get("kind")).strip() if parsed.get("kind") else None),
        systolic=_int_or_none(parsed.get("systolic")),
        diastolic=_int_or_none(parsed.get("diastolic")),
        pulse_bpm=_int_or_none(parsed.get("pulse_bpm")),
        sleep_hours=_float_or_none(parsed.get("sleep_hours")),
        weight_kg=_float_or_none(parsed.get("weight_kg")),
        glucose_mg_dl=_float_or_none(parsed.get("glucose_mg_dl")),
        raw_json=r.content[:1000],
        confidence=0.65,
    )
