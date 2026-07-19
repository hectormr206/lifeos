"""Agentic briefing engine.

A recurring reminder can carry an `action_prompt` (e.g. "tráeme las 10
noticias tech del día"). When it fires, `run_agentic_briefing` runs that
prompt through the local brain WITH the shared web-search tool, then parses
the model output into a structured digest the Briefings dashboard can render
as a card: a title, a short summary, and a list of items each with a title,
a 1-2 line Spanish summary and a clickable source URL. A markdown fallback
is always produced so prose-only responses still surface to the user.

The mechanism is general — any agentic prompt on a schedule — and reused by
the reminder dispatcher. The brain/web calls are injected (``ask_with_tools``)
so callers and tests stay decoupled from the network and the LLM.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any, Callable

log = logging.getLogger("axi.briefing")

# Default card title when the model omits one (user-facing, Spanish).
_DEFAULT_TITLE = "Boletín"

# Forced-synthesis nudge: appended on the final tool round (with tools removed)
# so the model stops searching and emits the JSON digest from what it gathered.
_FINAL_SYNTHESIS_PROMPT = (
    "Ya tienes suficiente información de las búsquedas anteriores. NO busques "
    "más. Devuelve AHORA únicamente el objeto JSON del boletín, con los ítems "
    "más recientes y relevantes que encontraste. Para cada ítem incluye: "
    "title (original), title_es (traducido al español), summary (1-2 líneas), "
    "detailed_summary (3-6 líneas), url (real), hn_url (discusión en HN si la "
    "encontraste), y hn_comments_summary (resumen de las opiniones de HN si las "
    "buscaste). Si no encontraste nada actual, devuelve pocos ítems o una lista "
    "vacía y explícalo en el resumen. No inventes noticias ni URLs."
)

# Caps on model-derived content. The output is web/LLM-derived and untrusted:
# bound the item count and field lengths so a misbehaving model cannot bloat
# the persisted DB row or the push payload.
_MAX_ITEMS = 10
_MAX_TITLE = 120
_MAX_SUMMARY = 400
_MAX_DETAILED_SUMMARY = 2000
_MAX_URL = 1000
_MAX_HN_COMMENTS = 1500

# Only http(s) links may become a clickable href. Anything else (javascript:,
# data:, file:, …) is dropped — the card renders untrusted web-derived URLs.
_SAFE_URL = re.compile(r"^https?://", re.IGNORECASE)


def _safe_url(value: Any) -> str:
    """Return `value` only if it is a bounded http(s) URL, else ''."""
    u = str(value or "").strip()
    if not u or not _SAFE_URL.match(u):
        return ""
    return u[:_MAX_URL]

# System prompt steering the brain to curate and ALWAYS cite sources. The
# digest text the model writes is user-facing, so it must be in Spanish. The
# current date is injected at run time so the model can enforce freshness
# (today/yesterday only) instead of surfacing stale or undated items.
def build_briefing_system(today: str) -> str:
    """Build the briefing system prompt with the current date injected.

    `today` is an ISO date (YYYY-MM-DD) in the user's timezone. The prompt
    anchors every current-info request to that date, tells the model how to
    signal recency to the search (news category, recency markers in the query,
    a SAFE time_range — never 'day', which returns nothing on the local index),
    and to keep only the freshest items, returning fewer rather than padding
    with stale ones, and never fabricating.
    """
    return (
        "Eres un asistente que prepara boletines curados. "
        f"Estás respondiendo con fecha de HOY = {today}. "
        "Para CUALQUIER consulta que dependa de información ACTUAL (noticias, "
        "lanzamientos, 'lo más reciente', 'los más actuales', precios, estado "
        f"del arte), interpreta el pedido como '… a fecha de hoy {today}'.\n"
        "Si el pedido incluye una URL concreta (un sitio o portada que el "
        "usuario nombró), usa la herramienta web_fetch para LEER esa página "
        "directamente — esa es la fuente que pidió — en vez de web_search. "
        "web_fetch devuelve un campo 'links' con las URLs REALES de la página; "
        "toma de ahí el enlace de cada ítem.\n"
        "Para búsquedas, comunica la actualidad EXPLÍCITAMENTE al buscador así: "
        "(a) para NOTICIAS usa categories='news'; "
        "(b) incluye marcadores de recencia en la propia QUERY de web_search "
        f"(el año o mes de hoy —p. ej. '{today[:4]}'— o palabras como 'más "
        "reciente', 'último', 'actual', 'hoy'); y "
        "(c) si quieres acotar por tiempo usa time_range='week' o 'month'. "
        "IMPORTANTE: NO uses time_range='day' — en este índice suele devolver "
        "CERO resultados. Si una búsqueda vuelve vacía, reintenta con una query "
        "más simple o sin time_range.\n"
        "Regla de frescura: prioriza SIEMPRE lo más reciente. El buscador no "
        "siempre trae la fecha exacta de cada ítem; usa las fechas y pistas que "
        "veas para quedarte con lo más fresco y DESCARTAR lo que sea claramente "
        "viejo (de años o meses anteriores). Si hay menos ítems frescos que los "
        "pedidos, devuelve MENOS en vez de rellenar con viejos. NUNCA inventes "
        "noticias ni fechas: si no encontraste nada actual, devuelve pocos ítems "
        "o ninguno y dilo en el resumen.\n"
        "Selecciona los ítems MÁS relevantes (máximo 10), escribe para CADA "
        "uno un resumen corto de 1 a 2 líneas EN ESPAÑOL.\n"
        "REGLA ABSOLUTA sobre las URLs: usa ÚNICAMENTE URLs REALES que te "
        "devolvieron las herramientas (el campo 'url'/'links' de web_search o "
        "web_fetch). NUNCA inventes, adivines ni construyas una URL. Si para un "
        "ítem no tienes una URL real de las herramientas, deja su 'url' vacío "
        "(\"\") — jamás un enlace inventado.\n\n"
        "ENRIQUECIMIENTO CON HACKER NEWS: para cada ítem, intenta encontrar su "
        "discusión en Hacker News usando web_fetch con la API de búsqueda Algolia:\n"
        "  https://hn.algolia.com/api/v1/search?query=TITULO_CODIFICADO&tags=story&hitsPerPage=3\n"
        "Si hay un hit relevante, su campo 'objectID' es el ID del ítem en HN; "
        "construye la URL de discusión: https://news.ycombinator.com/item?id=OBJECTID. "
        "Para resumir comentarios, usa web_fetch en:\n"
        "  https://hn.algolia.com/api/v1/items/OBJECTID\n"
        "Ese endpoint devuelve el hilo completo; lee los 'children' de primer nivel "
        "(comentarios directos más votados) y resúmelos en español. Si no hay "
        "discusión en HN para un ítem, deja hn_url y hn_comments_summary vacíos (\"\").\n\n"
        "Responde ÚNICAMENTE con un objeto JSON con esta forma exacta:\n"
        '{"title": "<título del boletín>", "summary": "<resumen general breve>", '
        '"items": [{'
        '"title": "<título original del ítem>", '
        '"title_es": "<título traducido al español>", '
        '"summary": "<resumen corto 1-2 líneas en español>", '
        '"detailed_summary": "<resumen detallado 3-6 líneas en español>", '
        '"url": "<url de la fuente>", '
        '"hn_url": "<url de discusión en HN o cadena vacía>", '
        '"hn_comments_summary": "<resumen de las opiniones más votadas en HN o cadena vacía>"'
        '}]}\n'
        "No agregues texto fuera del JSON."
    )


def _today_in_config_tz() -> str:
    """Current date (YYYY-MM-DD) in the user's configured timezone."""
    from datetime import datetime  # noqa: PLC0415
    from zoneinfo import ZoneInfo  # noqa: PLC0415

    tz_name = "America/Mexico_City"
    try:
        from axi import config  # noqa: PLC0415

        tz_name = str(config.get("timezone", tz_name)) or tz_name
    except Exception:  # noqa: BLE001
        pass
    try:
        tz = ZoneInfo(tz_name)
    except Exception:  # noqa: BLE001
        tz = ZoneInfo("America/Mexico_City")
    return datetime.now(tz).strftime("%Y-%m-%d")

# Agentic chat triggers — verbs that mean "fetch/curate something for me".
# These are distinct from reminder triggers (recordame, avísame, …): they
# imply the assistant must go DO research, not just replay a static message.
_AGENTIC_TRIGGER = re.compile(
    r"\b("
    r"tr[aá]eme|m[aá]ndame|b[uú]scame|cons[ií]gueme|"
    r"res[uú]meme|prep[aá]rame|[aá]rmame|dame"
    r")\b",
    re.IGNORECASE,
)

# Content signal — the kind of thing a briefing is about. Required alongside a
# trigger so casual phrasing ("dame un abrazo") never misfires.
_AGENTIC_CONTENT = re.compile(
    r"\b("
    r"noticias|titulares|resumen|res[uú]men|res[uú]menes|clima|"
    r"pron[oó]stico|novedades|reporte|briefing|actualizaci[oó]n|"
    r"highlights|tendencias"
    r")\b",
    re.IGNORECASE,
)


def looks_agentic(text: str) -> bool:
    """True when `text` reads like an agentic fetch/curate request.

    Requires BOTH an agentic trigger verb AND a content noun so casual
    phrasing does not misfire.
    """
    if not text or not isinstance(text, str):
        return False
    return bool(_AGENTIC_TRIGGER.search(text) and _AGENTIC_CONTENT.search(text))


def _extract_json(raw: str) -> dict[str, Any] | None:
    """Best-effort extraction of a JSON object from a model response."""
    if not raw:
        return None
    text = raw.strip()
    # Direct parse first.
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except Exception:  # noqa: BLE001
        pass
    # Strip code fences then retry on the first {...} span.
    fence = re.search(r"```(?:json)?\s*(.+?)```", text, re.DOTALL | re.IGNORECASE)
    if fence:
        text = fence.group(1).strip()
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        candidate = text[start : end + 1]
        try:
            obj = json.loads(candidate)
            if isinstance(obj, dict):
                return obj
        except Exception:  # noqa: BLE001
            return None
    return None


def _items_to_markdown(title: str, items: list[dict[str, str]]) -> str:
    lines = [f"## {title}", ""]
    for it in items:
        t = it.get("title_es") or it.get("title") or ""
        s = it.get("summary") or ""
        u = it.get("url") or ""
        hn = it.get("hn_url") or ""
        if u:
            lines.append(f"- [{t}]({u}) — {s}")
        else:
            lines.append(f"- {t} — {s}")
        if hn:
            lines.append(f"  - [Discusión en HN]({hn})")
    return "\n".join(lines).strip()


def parse_briefing_result(raw: str) -> dict[str, Any]:
    """Parse a model response into a structured digest.

    Returns a dict with keys: ``title``, ``summary``, ``items`` (list of
    {title, summary, url}) and ``markdown`` (always populated). Defensive:
    prose-only responses surface as markdown with an empty item list.
    """
    obj = _extract_json(raw)
    if obj is not None:
        items: list[dict[str, str]] = []
        for it in (obj.get("items") or [])[:_MAX_ITEMS]:
            if not isinstance(it, dict):
                continue
            items.append({
                "title": str(it.get("title") or "").strip()[:_MAX_TITLE],
                "title_es": str(it.get("title_es") or "").strip()[:_MAX_TITLE],
                "summary": str(it.get("summary") or "").strip()[:_MAX_SUMMARY],
                "detailed_summary": str(it.get("detailed_summary") or "").strip()[:_MAX_DETAILED_SUMMARY],
                "url": _safe_url(it.get("url")),
                "hn_url": _safe_url(it.get("hn_url")),
                "hn_comments_summary": str(it.get("hn_comments_summary") or "").strip()[:_MAX_HN_COMMENTS],
            })
        title = (str(obj.get("title") or "").strip() or _DEFAULT_TITLE)[:_MAX_TITLE]
        summary = str(obj.get("summary") or "").strip()[:_MAX_SUMMARY]
        if not summary and items:
            summary = f"{len(items)} resultados nuevos."
        if items:
            markdown = _items_to_markdown(title, items)
        else:
            markdown = str(obj.get("markdown") or "").strip() or (raw or "").strip()
        return {
            "title": title,
            "summary": summary,
            "items": items,
            "markdown": markdown,
            "ok": True,
        }
    # Prose fallback — surface whatever the model said.
    text = (raw or "").strip()
    summary = text[:200] if text else "Sin resultados."
    return {
        "title": _DEFAULT_TITLE,
        "summary": summary,
        "items": [],
        "markdown": text or "Sin resultados.",
        "ok": True,
    }


def _default_ask_with_tools(prompt: str, *, tools, tool_handlers, system, **kwargs):
    from axi import brain  # noqa: PLC0415

    return brain.ask_with_tools(
        prompt, tools=tools, tool_handlers=tool_handlers, system=system, **kwargs
    )


def run_agentic_briefing(
    action_prompt: str,
    *,
    ask_with_tools: Callable[..., str] | None = None,
    today: str | None = None,
    max_tokens: int = 4096,
    timeout: float = 180.0,
) -> dict[str, Any]:
    """Run an agentic prompt through the brain + web search and curate a digest.

    `today` (ISO YYYY-MM-DD, user's timezone) is injected into the system
    prompt to enforce freshness; defaults to the current date in the configured
    timezone when omitted.

    Never raises: on any failure returns a graceful digest with ``ok=False``
    so the dispatcher can still push a "could not generate" notification.
    """
    from axi.web_tools import (  # noqa: PLC0415
        web_fetch_handler,
        web_fetch_tool_def,
        web_search_handler,
        web_search_tool_def,
    )

    ask = ask_with_tools or _default_ask_with_tools
    system = build_briefing_system(today or _today_in_config_tz())
    # Offer BOTH tools: web_search for open-web discovery, web_fetch to read a
    # specific URL the user named (e.g. a news front page) directly.
    tools = [web_search_tool_def(), web_fetch_tool_def()]
    handlers = {"web_search": web_search_handler, "web_fetch": web_fetch_handler}
    try:
        # The 4B model tends to keep searching a new subtopic every round and
        # never stops to write the JSON. So we cap tool rounds low and force a
        # final synthesis: on the last round the brain drops the tools and is
        # told "you have enough — answer now", which reliably produces the
        # digest from the gathered results. Wall-clock stays bounded by the
        # per-call timeout and the scheduler's max_instances=1.
        raw = ask(
            action_prompt,
            tools=tools,
            tool_handlers=handlers,
            system=system,
            max_tokens=max_tokens,
            timeout=timeout,
            max_tool_rounds=5,
            final_synthesis_prompt=_FINAL_SYNTHESIS_PROMPT,
            task="agentic",
        )
    except Exception as e:  # noqa: BLE001
        log.exception("agentic briefing failed for prompt %r", action_prompt)
        return {
            "title": _DEFAULT_TITLE,
            "summary": "No pude generar el briefing.",
            "items": [],
            "markdown": "No pude generar el briefing.",
            "ok": False,
            "error": str(e)[:300],
        }
    # The brain returns a bracketed sentinel string when tool-calling could not
    # complete (exhausted rounds, brain unreachable, malformed/timeout). Treat
    # those as a failure instead of parsing the internal message as card content.
    if _is_brain_failure(raw):
        log.warning("agentic briefing got brain failure sentinel: %r", raw)
        return {
            "title": _DEFAULT_TITLE,
            "summary": "No pude generar el boletín en este momento.",
            "items": [],
            "markdown": "No pude generar el boletín en este momento.",
            "ok": False,
            "error": (raw or "").strip()[:300],
        }
    return parse_briefing_result(raw)


def _is_brain_failure(raw: str) -> bool:
    """True when the brain returned a tool-calling failure sentinel.

    `brain.ask_with_tools` signals failure with a bracketed message like
    "[Axi no pudo completar la llamada a herramientas]" or "[Axi brain …]".
    These are control strings, not digest content.
    """
    t = (raw or "").strip()
    return t.startswith("[Axi ") and t.endswith("]")
