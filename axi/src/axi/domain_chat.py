"""Generic specialized-domain chat ENGINE.

Every per-domain chat (Salud, Finanzas, Ejercicio, Relaciones, Espiritualidad,
Aprendizaje, Calendario) shares this ONE engine. A domain is described by a
``DomainSpec`` (config) — adding a domain is a spec, NOT a copy of this file.
This is the reusable-component invariant: the fragile shared behavior (classify
→ dispatch → register/query, date-aware querying, never-raise error handling)
lives here once; only genuine per-domain variation (the classifier prompt, the
field→entry mapping, the store binding, the wording) lives in each spec.

Flow (identical for every domain):
  1. Classify + extract the message in ONE 4B call (thinking OFF, the spec's
     scoped prompt) into strict JSON {"intent": register|query|off_topic, ...}.
  2. Dispatch on intent:
       register  → spec.build_entries(extracted, raw) → spec.store_create(...)
       off_topic → persist NOTHING; redirect out of the domain.
       query     → load spec.store_list_recent(...) + a SECOND brain call
                   (thinking ON) whose system prompt carries TODAY's date and
                   the loaded records, so the model answers ONLY from them and
                   resolves relative dates ("diciembre") against today.

handle_message NEVER raises: failures return {"mode": "error", "answer": ...}.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable

log = logging.getLogger("axi.domain_chat")


@dataclass(frozen=True)
class DomainSpec:
    """Everything that makes a domain chat differ from the others.

    key                — session id / route key (e.g. "health").
    name               — display name (e.g. "Salud"); also used in messages.
    extract_system     — the classifier+extractor system prompt (thinking OFF).
    build_entries      — (extracted_json, raw_text) -> list of entry specs, each
                         {kind, title, data, fragment}. Where the domain's field
                         validation / shapes live.
    store_create       — entries.create-style callable (kind=,title=,when=,body=,
                         data=,source=,raw_utterance=) returning an obj with .id.
    store_list_recent  — entries.list_recent-style callable (days=, limit=).
    register_prefix    — confirmation prefix, e.g. "Anotado en Salud".
    off_topic_msg      — redirect shown when the message is not for this domain.
    format_record      — (entry, local_date_str) -> one line for the query
                         prompt. Each domain shows its own fields (health uses
                         `data`; finance uses amount/currency/category).
    router_hint        — short description of what belongs to this domain, used
                         to auto-generate the general chat's router prompt.
    store_delete       — (entry_id) -> bool soft-delete, used by the data view.
                         Optional (None when the store has no delete).
    """
    key: str
    name: str
    extract_system: str
    build_entries: Callable[[dict[str, Any], str], list[dict[str, Any]]]
    store_create: Callable[..., Any]
    store_list_recent: Callable[..., list]
    register_prefix: str
    off_topic_msg: str
    format_record: Callable[[Any, str], str]
    router_hint: str
    store_delete: Callable[[str], bool] | None = None


# ─── shared helpers (domain-agnostic) ───────────────────────────────────────


def parse_extract_json(raw: str) -> dict[str, Any]:
    """Parse the extractor output robustly: tolerate code fences and stray prose.
    Raises ValueError when no valid JSON object can be recovered."""
    if not raw or not raw.strip():
        raise ValueError("empty extractor response")
    text = raw.strip()
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, flags=re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    try:
        obj = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise ValueError("no JSON object found in extractor response")
        obj = json.loads(text[start:end + 1])
    if not isinstance(obj, dict):
        raise ValueError("extractor JSON is not an object")
    return obj


def num(value: Any) -> float | int | None:
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


# ─── reusable builders for qualitative domains (no numeric fields) ──────────
# Domains like Espiritualidad / Aprendizaje record a kind + a title, nothing
# numeric. These two helpers keep their specs to just a prompt + bindings.


def qualitative_build_entries(valid_kinds: set[str], default_kind: str):
    """Factory → a build_entries that maps {kind, title} to ONE entry. The model
    picks a kind; we validate it against valid_kinds, else use default_kind."""
    def _build(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
        raw_kind = (extracted.get("kind") or "").strip().lower()
        kind = raw_kind if raw_kind in valid_kinds else default_kind
        title = (extracted.get("title") or raw_text).strip()[:120] or "registro"
        return [{"kind": kind, "title": title, "data": None, "fragment": title}]
    return _build


def simple_format_record(e: Any, local_date: str) -> str:
    """format_record for domains shown as id/date/kind/title (no numeric data)."""
    return f"- id={e.id} fecha={local_date} kind={e.kind} title={e.title}"


# ─── query (thinking ON, date-aware) ────────────────────────────────────────

_TODAY_RE = re.compile(r"\b(hoy|ayer|anoche|esta\s+noche|esta\s+mañana)\b", re.IGNORECASE)
_WEEK_RE = re.compile(r"\b(esta\s+semana|estos\s+días|últimos\s+días)\b", re.IGNORECASE)
_MONTH_RE = re.compile(r"\b(este\s+mes)\b", re.IGNORECASE)


def _window_days(text: str) -> int:
    t = text or ""
    if _TODAY_RE.search(t):
        return 3
    if _WEEK_RE.search(t):
        return 10
    if _MONTH_RE.search(t):
        return 40
    return 120


def _format_entries_for_prompt(spec: DomainSpec, entries_list: list, tz) -> str:
    if not entries_list:
        return "(sin registros en este periodo)"
    lines: list[str] = []
    for e in entries_list:
        try:
            local_date = e.ts.astimezone(tz).strftime("%Y-%m-%d")
        except Exception:  # noqa: BLE001
            local_date = e.ts.strftime("%Y-%m-%d")
        lines.append(spec.format_record(e, local_date))
    return "\n".join(lines)


def _build_query_system(spec: DomainSpec, now: datetime, entries_list: list) -> str:
    iso_today = now.strftime("%Y-%m-%d")
    upper = spec.name.upper()
    records = _format_entries_for_prompt(spec, entries_list, now.tzinfo)
    return (
        f"Eres el asistente del chat de {upper} de Axi. Respondes en español, claro y breve.\n"
        f"HOY es {iso_today} (año {now.year}). Usa esta fecha para resolver toda "
        "referencia temporal relativa: 'diciembre' significa el diciembre MÁS RECIENTE "
        "anterior o igual a hoy; 'el mes pasado', 'la semana pasada', etc. se resuelven "
        "siempre contra HOY.\n\n"
        f"Responde ÚNICAMENTE con base en los siguientes registros de {spec.name} del usuario. "
        "NO inventes datos. Si la información pedida NO está en los registros, di "
        "claramente que no tienes ese registro.\n\n"
        f"REGISTROS DE {upper} (más recientes primero):\n{records}"
    )


def _query(spec: DomainSpec, text: str, now: datetime, brain_ask: Callable) -> dict[str, Any]:
    days = _window_days(text)
    entries_list = spec.store_list_recent(days=days, limit=200)
    system = _build_query_system(spec, now, entries_list)

    def _ask(think: bool, max_tokens: int) -> str:
        a = brain_ask(text, system=system, think=think, max_tokens=max_tokens)
        return (a if isinstance(a, str) else str(a)).strip()

    # Primary: thinking ON (room to resolve relative dates). But think=True can
    # burn the whole token budget reasoning and return an EMPTY answer. The
    # answer is grounded in the records already in the prompt, so chain-of-
    # thought is not required — fall back to think=False (which can't exhaust
    # the budget on reasoning), then to a graceful message. Never return blank.
    answer = _ask(think=True, max_tokens=768)
    if not answer:
        log.warning("domain_chat[%s]: query think=True returned empty — retrying think=False", spec.key)
        try:
            answer = _ask(think=False, max_tokens=512)
        except Exception as exc:  # noqa: BLE001
            log.warning("domain_chat[%s]: query think=False retry failed: %s", spec.key, exc)
            answer = ""
    if not answer:
        answer = "No pude generar una respuesta con tus registros. ¿Podés reformular la pregunta?"
    return {"mode": "query", "answer": answer}


# ─── register ───────────────────────────────────────────────────────────────


def _register(spec: DomainSpec, extracted: dict[str, Any], raw_text: str, now: datetime) -> dict[str, Any]:
    specs = spec.build_entries(extracted, raw_text)
    entry_ids: list[str] = []
    fragments: list[str] = []
    for s in specs:
        entry = spec.store_create(
            kind=s["kind"],
            title=s["title"],
            when=now,
            body=raw_text,
            data=s["data"],
            source="chat",
            raw_utterance=raw_text,
        )
        entry_ids.append(entry.id)
        fragments.append(s["fragment"])
    answer = f"{spec.register_prefix}: " + ", ".join(fragments) + "."
    return {"mode": "register", "answer": answer, "entry_ids": entry_ids}


# ─── public entrypoint ──────────────────────────────────────────────────────


def handle_message(
    spec: DomainSpec,
    text: str,
    *,
    now: datetime,
    brain_ask: Callable | None = None,
) -> dict[str, Any]:
    """Handle one message for *spec*'s domain chat. NEVER raises.

    `now` MUST be a tz-aware datetime (current time in the user's timezone).
    `brain_ask` defaults to axi.brain.ask; resolved lazily so monkeypatching
    brain.ask in tests/endpoints is honored.
    """
    if brain_ask is None:
        from axi import brain  # lazy import so brain.ask monkeypatching works
        brain_ask = brain.ask

    try:
        clean = (text or "").strip()
        if not clean:
            return {"mode": "error", "answer": f"No recibí ningún mensaje de {spec.name}."}

        # Step 1 — classify + extract in ONE call, thinking OFF.
        raw = brain_ask(clean, system=spec.extract_system, think=False, max_tokens=256)
        if not isinstance(raw, str):
            raw = str(raw)
        try:
            extracted = parse_extract_json(raw)
        except ValueError as exc:
            log.warning("domain_chat[%s]: could not parse extractor JSON: %s", spec.key, exc)
            return {
                "mode": "error",
                "answer": f"No pude entender tu mensaje de {spec.name}. ¿Podés reformularlo?",
            }

        intent = str(extracted.get("intent") or "").strip().lower()

        # Step 2 — dispatch.
        if intent == "off_topic":
            return {"mode": "off_topic", "answer": spec.off_topic_msg}
        if intent == "query":
            return _query(spec, clean, now, brain_ask)
        if intent == "register":
            return _register(spec, extracted, clean, now)

        # Unknown / missing intent — treat as off-topic, save nothing.
        return {"mode": "off_topic", "answer": spec.off_topic_msg}
    except Exception as exc:  # noqa: BLE001 — never raise into the endpoint
        log.warning("domain_chat[%s]: unexpected failure: %s", spec.key, exc, exc_info=True)
        return {
            "mode": "error",
            "answer": f"Hubo un problema procesando tu mensaje de {spec.name}. Intentá de nuevo.",
        }
