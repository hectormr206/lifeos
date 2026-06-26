"""SALUD specialized chat — Slice 1.

A health-scoped conversational chat that BOTH registers health data and answers
questions about it, using the Qwen3.5-4B brain (port 8080). Two responsibilities:

  1. Classify + extract the user message in ONE 4B call (thinking OFF, scoped
     HEALTH prompt) into strict JSON:
         {"intent": "register"|"query"|"off_topic",
          "kind": str|null,
          "systolic": int|null, "diastolic": int|null, "pulse_bpm": int|null,
          "glucose_mg_dl": int|null, "weight_kg": number|null,
          "sleep_hours": number|null, "title": str|null}

  2. Dispatch on intent:
       register  → map the extracted vitals to lifeos.health.entries.create(...)
                   (one structured vital per measured value; a note fallback when
                   nothing structured was extracted). when=now.
       off_topic → persist NOTHING; redirect the user out of Salud.
       query     → load the relevant entries with entries.list_recent(...) and
                   make a SECOND brain call (thinking ON) whose system prompt
                   carries TODAY'S date (now, user tz) and the loaded records,
                   so the model answers ONLY from those records and resolves
                   relative dates ("diciembre") against today.

This module NEVER raises: any failure is caught and returned as
{"mode": "error", "answer": "<clear message>"} so the endpoint stays clean.

The data shapes written here MIRROR the existing chat/nano ingestion path in
dashboard.py (blood_pressure / glucose / weight / sleep_hours vitals) so entries
captured through this chat are queryable exactly like every other source.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from typing import Any, Callable

from lifeos.health import entries as health_entries

log = logging.getLogger("axi.health_chat")

# ─── Step 1: classify + extract (thinking OFF) ──────────────────────────────

_EXTRACT_SYSTEM = """Eres el clasificador del chat de SALUD de Axi. Tu ÚNICO trabajo
es leer el mensaje del usuario y devolver un objeto JSON estricto. NO converses,
NO expliques, NO uses Markdown: SOLO el JSON.

Esquema EXACTO (usa null cuando no aplique):
{
  "intent": "register" | "query" | "off_topic",
  "kind": "vital" | "symptom" | "medication" | "condition" | "note" | null,
  "systolic": entero|null,        // presión sistólica (mmHg)
  "diastolic": entero|null,       // presión diastólica (mmHg)
  "pulse_bpm": entero|null,       // pulso (latidos por minuto)
  "glucose_mg_dl": entero|null,   // glucosa (mg/dL)
  "weight_kg": número|null,       // peso (kg)
  "sleep_hours": número|null,     // horas dormidas
  "title": cadena|null            // resumen corto del registro o la pregunta
}

SALUD = cuerpo FÍSICO/MÉDICO: presión, glucosa, peso, pulso, sueño, síntomas,
dolor, enfermedad, medicamentos, estudios médicos, dieta/alimentación.
NO es salud: bienestar mental/espiritual (meditación, rezar, gratitud, paz,
mindfulness → Espiritualidad), rutinas de gimnasio/entrenamiento → Ejercicio,
finanzas, relaciones, trabajo, clima, aprendizaje, calendario.

Reglas de intent:
- "off_topic": el mensaje NO es de salud física/médica según lo de arriba
  (incluye meditación/espiritualidad, ejercicio, finanzas, dinero, trabajo,
  relaciones, clima, etc.). En ese caso TODOS los campos van en null salvo intent.
- "query": el usuario PREGUNTA por sus datos de salud ("¿cuánto pesé?", "qué tomé
  para la gripa de diciembre", "cómo estuvo mi presión esta semana").
- "register": el usuario REPORTA mediciones o eventos de salud ("presión 120/80",
  "glucosa en 90", "dormí 7 horas", "me duele la cabeza", "tomé paracetamol").

Reglas de extracción (solo para intent="register"):
- "presión 120/80" → systolic=120, diastolic=80.
- Extrae cada medición presente; pueden venir varias en un mismo mensaje.
- Si el mensaje es un síntoma/medicamento sin números, usa kind apropiado y title;
  deja los campos numéricos en null.
- NUNCA inventes valores que el usuario no dijo.

Devuelve SOLO el JSON, sin texto adicional."""


def _parse_extract_json(raw: str) -> dict[str, Any]:
    """Parse the extractor output robustly.

    Tolerates code fences and stray prose around the JSON object. Raises
    ValueError when no valid JSON object can be recovered.
    """
    if not raw or not raw.strip():
        raise ValueError("empty extractor response")
    text = raw.strip()
    # Strip ```json ... ``` / ``` ... ``` fences if present.
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, flags=re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    # Fast path: already a clean object.
    try:
        obj = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        # Fallback: grab the outermost {...} span and try again.
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise ValueError("no JSON object found in extractor response")
        obj = json.loads(text[start:end + 1])
    if not isinstance(obj, dict):
        raise ValueError("extractor JSON is not an object")
    return obj


def _num(value: Any) -> float | int | None:
    """Coerce a possibly-string numeric field to int/float, else None."""
    if value is None:
        return None
    if isinstance(value, bool):  # guard: bool is an int subclass
        return None
    if isinstance(value, (int, float)):
        return value
    try:
        f = float(str(value).strip())
    except (TypeError, ValueError):
        return None
    return int(f) if f.is_integer() else f


# ─── Step 2a: register ──────────────────────────────────────────────────────

_VALID_KINDS = {"symptom", "medication", "vital", "condition", "note"}


def _build_register_entries(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
    """Translate extracted fields into a list of entries.create() kwargs.

    One structured vital per measured value (blood pressure is a single combined
    vital, mirroring dashboard.py). Falls back to a single note/symptom entry when
    no plausible structured value was extracted, so the message is never lost.
    Returns a list of dicts: {kind, title, data, fragment} where `fragment` is the
    Spanish confirmation snippet.
    """
    out: list[dict[str, Any]] = []

    systolic = _num(extracted.get("systolic"))
    diastolic = _num(extracted.get("diastolic"))
    pulse = _num(extracted.get("pulse_bpm"))
    glucose = _num(extracted.get("glucose_mg_dl"))
    weight = _num(extracted.get("weight_kg"))
    sleep = _num(extracted.get("sleep_hours"))

    # Blood pressure — one combined vital (mirrors dashboard nano path).
    bp_ok = (
        systolic is not None and diastolic is not None
        and 80 <= systolic <= 220 and 40 <= diastolic <= 130
    )
    if bp_ok:
        data: dict[str, Any] = {
            "type": "blood_pressure",
            "systolic": int(systolic),
            "diastolic": int(diastolic),
            "unit": "mmHg",
        }
        title = f"presión {int(systolic)}/{int(diastolic)}"
        frag = f"presión {int(systolic)}/{int(diastolic)}"
        if pulse is not None and 30 <= pulse <= 220:
            data["pulse_bpm"] = int(pulse)
            title = f"presión {int(systolic)}/{int(diastolic)}, pulso {int(pulse)}"
            frag = f"presión {int(systolic)}/{int(diastolic)}, pulso {int(pulse)}"
        out.append({"kind": "vital", "title": title, "data": data, "fragment": frag})
    elif pulse is not None and 30 <= pulse <= 220:
        # Standalone pulse (no blood pressure context).
        out.append({
            "kind": "vital",
            "title": f"pulso {int(pulse)}",
            "data": {"type": "pulse", "value": int(pulse), "unit": "bpm"},
            "fragment": f"pulso {int(pulse)}",
        })

    if glucose is not None and 30 <= glucose <= 600:
        out.append({
            "kind": "vital",
            "title": f"glucosa {int(glucose)} mg/dL",
            "data": {"type": "glucose", "value": int(glucose), "unit": "mg/dL"},
            "fragment": f"glucosa {int(glucose)}",
        })

    if weight is not None and 20 <= weight <= 300:
        out.append({
            "kind": "vital",
            "title": f"peso {weight} kg",
            "data": {"type": "weight", "value": weight, "unit": "kg"},
            "fragment": f"peso {weight} kg",
        })

    if sleep is not None and 0.5 <= sleep <= 16:
        out.append({
            "kind": "vital",
            "title": f"dormí {sleep}h",
            "data": {"type": "sleep_hours", "value": sleep, "unit": "h"},
            "fragment": f"sueño {sleep}h",
        })

    if out:
        return out

    # No structured vitals — persist a note/symptom/medication so nothing is lost.
    raw_kind = extracted.get("kind")
    kind = raw_kind if raw_kind in _VALID_KINDS and raw_kind != "vital" else "note"
    title = (extracted.get("title") or raw_text).strip()[:80] or "registro de salud"
    return [{"kind": kind, "title": title, "data": None, "fragment": title}]


def _register(extracted: dict[str, Any], raw_text: str, now: datetime) -> dict[str, Any]:
    specs = _build_register_entries(extracted, raw_text)
    entry_ids: list[str] = []
    fragments: list[str] = []
    for spec in specs:
        entry = health_entries.create(
            kind=spec["kind"],
            title=spec["title"],
            when=now,
            body=raw_text,
            data=spec["data"],
            source="chat",
            raw_utterance=raw_text,
        )
        entry_ids.append(entry.id)
        fragments.append(spec["fragment"])
    answer = "Anotado en Salud: " + ", ".join(fragments) + "."
    return {"mode": "register", "answer": answer, "entry_ids": entry_ids}


# ─── Step 2b: query (thinking ON, date-aware) ───────────────────────────────

# Smaller windows for explicitly recent questions; default is broad enough to
# reach the most recent December from mid-year.
_TODAY_RE = re.compile(r"\b(hoy|ayer|anoche|esta\s+noche|esta\s+mañana)\b", re.IGNORECASE)
_WEEK_RE = re.compile(r"\b(esta\s+semana|estos\s+días|últimos\s+días)\b", re.IGNORECASE)
_MONTH_RE = re.compile(r"\b(este\s+mes|este\s+mes)\b", re.IGNORECASE)


def _window_days(text: str) -> int:
    t = text or ""
    if _TODAY_RE.search(t):
        return 3
    if _WEEK_RE.search(t):
        return 10
    if _MONTH_RE.search(t):
        return 40
    return 120


def _format_entries_for_prompt(entries_list: list, tz) -> str:
    if not entries_list:
        return "(sin registros en este periodo)"
    lines: list[str] = []
    for e in entries_list:
        try:
            local_date = e.ts.astimezone(tz).strftime("%Y-%m-%d")
        except Exception:  # noqa: BLE001
            local_date = e.ts.strftime("%Y-%m-%d")
        data = json.dumps(e.data, ensure_ascii=False) if e.data else "{}"
        lines.append(
            f"- id={e.id} fecha={local_date} kind={e.kind} title={e.title} data={data}"
        )
    return "\n".join(lines)


def _build_query_system(now: datetime, entries_list: list) -> str:
    iso_today = now.strftime("%Y-%m-%d")
    records = _format_entries_for_prompt(entries_list, now.tzinfo)
    return (
        "Eres el asistente del chat de SALUD de Axi. Respondes en español, claro y breve.\n"
        f"HOY es {iso_today} (año {now.year}). Usa esta fecha para resolver toda "
        "referencia temporal relativa: 'diciembre' significa el diciembre MÁS RECIENTE "
        "anterior o igual a hoy; 'el mes pasado', 'la semana pasada', etc. se resuelven "
        "siempre contra HOY.\n\n"
        "Responde ÚNICAMENTE con base en los siguientes registros de salud del usuario. "
        "NO inventes datos. Si la información pedida NO está en los registros, di "
        "claramente que no tienes ese registro.\n\n"
        f"REGISTROS DE SALUD (más recientes primero):\n{records}"
    )


def _query(text: str, now: datetime, brain_ask: Callable) -> dict[str, Any]:
    days = _window_days(text)
    entries_list = health_entries.list_recent(days=days, limit=200)
    system = _build_query_system(now, entries_list)
    answer = brain_ask(text, system=system, think=True, max_tokens=512)
    if not isinstance(answer, str):
        answer = str(answer)
    return {"mode": "query", "answer": answer.strip()}


# ─── Public entrypoint ──────────────────────────────────────────────────────


def handle_health_message(
    text: str,
    *,
    now: datetime,
    brain_ask: Callable | None = None,
) -> dict[str, Any]:
    """Handle one SALUD chat message. NEVER raises.

    `now` MUST be a tz-aware datetime (the current time in the user's timezone).
    `brain_ask` defaults to axi.brain.ask; resolved lazily so monkeypatching
    brain.ask in tests/endpoints is honored.
    """
    if brain_ask is None:
        from axi import brain  # lazy import so brain.ask monkeypatching works
        brain_ask = brain.ask

    try:
        clean = (text or "").strip()
        if not clean:
            return {"mode": "error", "answer": "No recibí ningún mensaje de Salud."}

        # Step 1 — classify + extract in ONE call, thinking OFF.
        raw = brain_ask(clean, system=_EXTRACT_SYSTEM, think=False, max_tokens=256)
        if not isinstance(raw, str):
            raw = str(raw)
        try:
            extracted = _parse_extract_json(raw)
        except ValueError as exc:
            log.warning("health_chat: could not parse extractor JSON: %s", exc)
            return {
                "mode": "error",
                "answer": "No pude entender tu mensaje de Salud. ¿Podés reformularlo?",
            }

        intent = str(extracted.get("intent") or "").strip().lower()

        # Step 2 — dispatch.
        if intent == "off_topic":
            return {
                "mode": "off_topic",
                "answer": "Eso no es de Salud. Probá en el apartado correspondiente.",
            }
        if intent == "query":
            return _query(clean, now, brain_ask)
        if intent == "register":
            return _register(extracted, clean, now)

        # Unknown / missing intent — treat as off-topic, save nothing.
        return {
            "mode": "off_topic",
            "answer": "Eso no es de Salud. Probá en el apartado correspondiente.",
        }
    except Exception as exc:  # noqa: BLE001 — never raise into the endpoint
        log.warning("health_chat: unexpected failure: %s", exc, exc_info=True)
        return {
            "mode": "error",
            "answer": "Hubo un problema procesando tu mensaje de Salud. Intentá de nuevo.",
        }
