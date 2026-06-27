"""SALUD domain chat — the HEALTH spec for the generic domain_chat engine.

This module no longer contains the chat flow (classify → dispatch → register/
query): that lives ONCE in axi.domain_chat. Here we only declare what makes
Salud different — the classifier prompt, the field→entry mapping, the store
binding and the wording — as a DomainSpec. Adding another domain (Finanzas,
Ejercicio, …) is another spec, NOT a copy of the engine.

`handle_health_message` is kept as a thin backward-compatible wrapper.
"""
from __future__ import annotations

import json
from datetime import datetime
from typing import Any, Callable

from lifeos.health import entries as health_entries

from axi.domain_chat import DomainSpec, handle_message, num

# ─── classify + extract prompt (thinking OFF) ───────────────────────────────

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


# ─── field → entry mapping (health-specific) ────────────────────────────────

_VALID_KINDS = {"symptom", "medication", "vital", "condition", "note"}


def _build_register_entries(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
    """Translate extracted health fields into entries.create() specs.

    One structured vital per measured value (blood pressure is a single combined
    vital, mirroring dashboard.py). Falls back to a single note/symptom entry when
    no plausible structured value was extracted, so the message is never lost.
    Each spec: {kind, title, data, fragment} (fragment = ES confirmation snippet).
    """
    out: list[dict[str, Any]] = []

    systolic = num(extracted.get("systolic"))
    diastolic = num(extracted.get("diastolic"))
    pulse = num(extracted.get("pulse_bpm"))
    glucose = num(extracted.get("glucose_mg_dl"))
    weight = num(extracted.get("weight_kg"))
    sleep = num(extracted.get("sleep_hours"))

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


# ─── the spec + backward-compatible wrapper ─────────────────────────────────

def _format_record(e: Any, local_date: str) -> str:
    """One query-prompt line for a health entry (id/date/kind/title/data)."""
    data = json.dumps(e.data, ensure_ascii=False) if e.data else "{}"
    return f"- id={e.id} fecha={local_date} kind={e.kind} title={e.title} data={data}"


def _edit_fields(e: Any) -> list[dict]:
    """Editable fields depend on the vital type (BP has two numbers; glucose/
    weight/sleep have one; a note/symptom has only its title)."""
    data = getattr(e, "data", None) or {}
    vtype = data.get("type")
    if vtype == "blood_pressure":
        return [
            {"key": "systolic", "label": "Sistólica (mmHg)", "type": "number"},
            {"key": "diastolic", "label": "Diastólica (mmHg)", "type": "number"},
        ]
    if "value" in data:
        unit = data.get("unit", "")
        return [{"key": "value", "label": f"Valor ({unit})" if unit else "Valor", "type": "number"}]
    return [{"key": "title", "label": "Título", "type": "text"}]


def _update_fields(eid: str, changes: dict) -> bool:
    """Apply an edit. For structured vitals the title is REGENERATED from the
    (possibly edited) value so the display never drifts from the data. Returns
    False on missing entry or any error; never raises."""
    try:
        e = health_entries.get(eid)
        if e is None:
            return False
        data = dict(e.data) if e.data else None
        title = e.title
        if data and data.get("type") == "blood_pressure":
            if "systolic" in changes:
                data["systolic"] = int(float(changes["systolic"]))
            if "diastolic" in changes:
                data["diastolic"] = int(float(changes["diastolic"]))
            title = f"presión {data['systolic']}/{data['diastolic']}"
            if data.get("pulse_bpm"):
                title += f", pulso {int(data['pulse_bpm'])}"
        elif data and "value" in data and "value" in changes:
            v = float(changes["value"])
            vtype = data.get("type")
            if vtype == "glucose":
                data["value"] = int(v); title = f"glucosa {int(v)} mg/dL"
            elif vtype == "weight":
                data["value"] = v; title = f"peso {v} kg"
            elif vtype == "sleep_hours":
                data["value"] = v; title = f"dormí {v}h"
            elif vtype == "pulse":
                data["value"] = int(v); title = f"pulso {int(v)}"
            else:
                data["value"] = v
        elif "title" in changes:
            title = str(changes["title"]).strip() or e.title
        return health_entries.update(eid, kind=e.kind, title=title, when=e.ts, data=data, body=e.body) is not None
    except Exception:  # noqa: BLE001
        return False


HEALTH_SPEC = DomainSpec(
    key="health",
    name="Salud",
    extract_system=_EXTRACT_SYSTEM,
    build_entries=_build_register_entries,
    format_record=_format_record,
    # Late-bound (lambda) so the function is resolved at call time — respects
    # monkeypatching of health_entries.* in tests and any future reassignment.
    store_create=lambda **kw: health_entries.create(**kw),
    store_list_recent=lambda **kw: health_entries.list_recent(**kw),
    register_prefix="Anotado en Salud",
    off_topic_msg="Eso no es de Salud. Probá en el apartado correspondiente.",
    router_hint="salud física/médica: presión, glucosa, peso, pulso, sueño, "
                "síntomas, dolor, enfermedad, medicamentos, estudios médicos",
    store_delete=lambda eid: health_entries.delete(eid),
    store_update_title=lambda eid, title: health_entries.update_title(eid, title),
    edit_fields=_edit_fields,
    store_update_fields=_update_fields,
)


def handle_health_message(
    text: str,
    *,
    now: datetime,
    brain_ask: Callable | None = None,
) -> dict[str, Any]:
    """Backward-compatible entrypoint — delegates to the generic engine."""
    return handle_message(HEALTH_SPEC, text, now=now, brain_ask=brain_ask)
