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
  "kind": string|null
}

Reglas de DOMAIN (uno solo, no listes opciones):
- Actividad física (caminé, corrí, gym, ejercicio, entrenar): "exercise"
  AUNQUE mencione personas o lugares.
- Dinero / compras (gasté, compré, pagué, costó): "finance".
- Interacción humana (hablé, discutí, conocí, casarse, llamé): "relationships".
  PERO solo si hay foco en la INTERACCIÓN, no si la persona es contexto
  secundario de otra actividad.
- Aprender, estudiar, leer libro, idea: "learning".
- Síntoma, medicación, vital (presión, glucosa, peso, sueño): "health".
- Aniversario, cumple, fecha importante a futuro: "events".
- Reflexión espiritual, agradecimiento, meditación: "spirituality".
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
- Si un campo no aplica, ponelo null o [] (NUNCA lo omitas).

Ejemplos:

INPUT: "Hablé con Diego en la oficina ayer"
OUTPUT: {"domain":"relationships","amount":null,"currency":null,"merchant":null,"people":["Diego"],"dates_text":["ayer"],"duration_minutes":null,"items":[],"title":"conversación con Diego","kind":"conversation"}

INPUT: "Tuve una discusión fuerte con mi mamá esta tarde"
OUTPUT: {"domain":"relationships","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":["esta tarde"],"duration_minutes":null,"items":[],"title":"discusión con mi mamá","kind":"conflict"}

INPUT: "Gasté 1850 en Aurrera: 320 detergente, 450 papel higiénico, 500 cable HDMI"
OUTPUT: {"domain":"finance","amount":1850,"currency":"MXN","merchant":"Aurrera","people":[],"dates_text":[],"duration_minutes":null,"items":[{"name":"detergente","amount":320,"category":"hogar"},{"name":"papel higiénico","amount":450,"category":"hogar"},{"name":"cable HDMI","amount":500,"category":"electrónica"}],"title":"compra en Aurrera","kind":"expense"}

INPUT: "Caminé en el parque con mi esposa Daniela durante 45 minutos"
OUTPUT: {"domain":"exercise","amount":null,"currency":null,"merchant":null,"people":["Daniela"],"dates_text":[],"duration_minutes":45,"items":[],"title":"caminata en el parque","kind":"walk"}

INPUT: "Hicimos una caminata familiar de 1 hora en el parque"
OUTPUT: {"domain":"exercise","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":60,"items":[],"title":"caminata familiar","kind":"walk"}

INPUT: "Estoy aprendiendo Claude Code para LifeOS"
OUTPUT: {"domain":"learning","amount":null,"currency":null,"merchant":null,"people":[],"dates_text":[],"duration_minutes":null,"items":[],"title":"aprendiendo Claude Code","kind":"study"}

INPUT: "Empecé el libro Atomic Habits de James Clear"
OUTPUT: {"domain":"learning","amount":null,"currency":null,"merchant":null,"people":["James Clear"],"dates_text":[],"duration_minutes":null,"items":[],"title":"Atomic Habits","kind":"book"}

INPUT: "Mi esposa Daniela y yo nos casamos el 15 de junio de 2018"
OUTPUT: {"domain":"events","amount":null,"currency":null,"merchant":null,"people":["Daniela"],"dates_text":["15 de junio de 2018"],"duration_minutes":null,"items":[],"title":"casamiento con Daniela","kind":"milestone"}

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


def extract(
    text: str,
    *,
    timeout_s: float = 5.0,
    retry_timeout_s: float = 15.0,
    retries: int = 1,
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

    r = runtime.call_nano(
        system=_SYSTEM_PROMPT,
        user=text,
        temperature=0.1,
        max_tokens=800,
        timeout_s=timeout_s,
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
            temperature=0.1,
            max_tokens=800,
            timeout_s=retry_timeout_s,
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
        raw_json=r.content[:1000],
        confidence=0.65,
    )
