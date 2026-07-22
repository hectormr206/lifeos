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


# ─────────────────────── multi-source curated briefing ──────────────────────
#
# A DIGESTIBLE briefing built from SEVERAL source homepages instead of one
# agentic prompt. The pipeline is: fetch each source homepage (web_fetch —
# HTML only; RSS/XML feeds return empty from lifeos.web.fetch.read) → extract
# candidate headlines from the page's REAL anchor links → dedup across sources
# (same/similar title or same URL) → rank + cluster into a digestible shape:
# one `headline`, up to 5 `top` items each with a "por qué importa" line, and
# the rest collapsed into `more`. The FETCH + dedup are DETERMINISTIC (so the
# pipeline is testable and not flaky); only the editorial synthesis (rank /
# cluster / why-lines) may call the brain, with a deterministic fallback when
# the brain is unavailable or misbehaves.

# Default source set — all verified fetchable as HTML homepages. The list is
# config-driven under the `briefing_sources` key (see `briefing_sources()`),
# so it is swappable per install without touching code. Each source carries a
# category tag (tech/ia/general/mx) used for clustering + diversity.
DEFAULT_BRIEFING_SOURCES: list[dict[str, str]] = [
    {"name": "Hacker News", "url": "https://news.ycombinator.com/", "category": "tech"},
    {"name": "Simon Willison", "url": "https://simonwillison.net/", "category": "ia"},
    {"name": "Hugging Face Papers", "url": "https://huggingface.co/papers", "category": "ia"},
    {"name": "AP News", "url": "https://apnews.com/", "category": "general"},
    {"name": "Expansión", "url": "https://expansion.mx/", "category": "mx"},
]

# Anchor text shorter than this is almost always chrome/nav ("login", "more",
# "comments", a lone site name) rather than a real headline.
_MIN_HEADLINE_LEN = 15
# Common link-aggregator navigation/chrome to drop even if long enough.
_NAV_STOPWORDS = frozenset({
    "login", "logout", "sign in", "sign up", "submit", "comments", "reply",
    "past", "more", "next", "prev", "previous", "hide", "flag", "favorite",
    "context", "parent", "new", "show", "ask", "jobs", "threads", "settings",
    "subscribe", "newsletter", "menu", "search", "home", "about", "contact",
})

# Section/hub/nav LABELS whose whole anchor text is a section name, not a
# headline. Matched by EXACT (lowercased) equality only, so a real headline
# that merely contains one of these words ("Russia-Ukraine war enters new
# phase…") is kept. Seeded from the real-network smoke run (AP hubs, Expansión
# nav) plus the usual news-section vocabulary in ES and EN.
_SECTION_LABELS = frozenset({
    "últimas noticias", "ultimas noticias", "lo último", "lo ultimo",
    "más leídas", "mas leidas", "más noticias", "mas noticias",
    "ver más", "ver mas", "ver todo", "ver todas las noticias",
    "todas las noticias", "portada", "inicio", "secciones",
    "world", "world news", "u.s.", "u.s. news", "us news", "politics",
    "business", "sports", "sport", "science", "health", "technology",
    "tecnología", "tecnologia", "entertainment", "opinion", "opinión",
    "climate", "oddities", "russia-ukraine war", "israel-hamas war",
    "mercados", "empresas", "economía", "economia", "negocios",
    "internacional", "nacional", "deportes", "cultura", "elecciones",
    "trending", "más", "mas",
})

# Structural path segments that mark a section/tag/hub/feed URL rather than an
# article. Only STRUCTURAL words (never localized section slugs like
# "empresas", which are the FIRST segment of real Expansión article URLs), so
# multi-segment article paths survive.
_SECTION_PATH_SEGMENTS = frozenset({
    "tag", "tags", "tagged", "hub", "hubs", "section", "sections",
    "category", "categories", "topic", "topics", "author", "authors",
    "label", "labels", "feed", "feeds", "rss", "search", "page",
})

# A tag link rendered as "slug 400" / "pelican-riding-a-bicycle 128": a single
# hyphenated slug token followed by a bare count. Requires a hyphen so real
# short headlines ("Windows 11") never match.
_TAG_COUNT_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)+\s+\d{1,5}$", re.IGNORECASE)

# Known section SLUGS: when a URL path is a SINGLE segment equal to one of
# these, it is a section landing page ("/world", "/empresas"), not an article.
# A real article's single-segment slug ("/gpu", "/some-story-headline") is not
# in this dictionary set, so it survives; multi-segment section-prefixed
# article paths ("/empresas/2026/07/22/slug") also survive (len(segs) > 1).
_SECTION_SLUGS = frozenset({
    "world", "world-news", "us", "us-news", "u-s", "u-s-news", "politics",
    "business", "sports", "sport", "science", "health", "technology", "tech",
    "entertainment", "opinion", "opinions", "climate", "oddities", "lifestyle",
    "mercados", "empresas", "economia", "negocios", "internacional", "nacional",
    "deportes", "cultura", "elecciones", "ultimas-noticias", "ultimas",
    "lo-ultimo", "trending", "portada", "secciones", "live", "video", "videos",
    "photos", "fotos", "podcasts", "newsletters", "opinión",
    # product/nav landings seen on aggregators (Hugging Face, etc.)
    "pro", "pricing", "enterprise", "docs", "support", "quizzes",
    "inference-endpoints", "finanzas-personales", "revistas-digitales",
})


def _is_probable_nav(title: str, url: str) -> bool:
    """True when a (title, url) pair is a section/nav/tag/hub link, not a story.

    Deterministic, per-site-agnostic heuristics distilled from the real smoke
    run: exact section labels, tag-with-count anchor text, structural URL path
    segments (/tags/, /hub/, …), and bare single-segment section paths. Kept
    conservative (exact-match labels, hyphen-required tag pattern) so genuine
    headlines are not dropped.
    """
    from urllib.parse import urlsplit  # noqa: PLC0415

    t = str(title or "").strip()
    low = t.lower()
    if not t or low in _NAV_STOPWORDS or low in _SECTION_LABELS:
        return True
    if _TAG_COUNT_RE.match(t):
        return True
    try:
        segs = [s for s in urlsplit(str(url or "")).path.split("/") if s]
    except Exception:  # noqa: BLE001
        segs = []
    if any(s.lower() in _SECTION_PATH_SEGMENTS for s in segs):
        return True
    if len(segs) == 1 and segs[0].lower() in _SECTION_SLUGS:
        return True
    # A single-segment path whose ONLY query is tracking (utm_*) is a
    # "recommended section" nav link, not an article (real articles carry a
    # dated/id multi-segment path). Catches Expansión's utm section links.
    try:
        split = urlsplit(str(url or ""))
        query = split.query.lower()
    except Exception:  # noqa: BLE001
        query = ""
    if len(segs) == 1 and query and "utm_" in query and "?" not in segs[0]:
        params = [p.split("=", 1)[0] for p in query.split("&") if p]
        if params and all(p.startswith("utm_") for p in params):
            return True
    return False

_MULTI_SOURCE_TITLE = "Boletín multi-fuente"

# A reminder prompt carrying one of these markers selects the multi-source
# pipeline (distinct from the single-URL agentic path).
_MULTI_SOURCE_MARKER = re.compile(
    r"multi[\s-]?fuente|multifuente|varias fuentes|bolet[ií]n curado|multi[\s-]?source",
    re.IGNORECASE,
)


def is_multi_source_request(text: str) -> bool:
    """True when `text` explicitly asks for the multi-source curated briefing."""
    if not text or not isinstance(text, str):
        return False
    return bool(_MULTI_SOURCE_MARKER.search(text))


def briefing_sources() -> list[dict[str, str]]:
    """Return the configured source list, or the built-in default.

    Config-driven under the `briefing_sources` key (a list of
    {name, url, category} dicts). The strict config schema only models scalar
    fields, so this key rides along as a preserved unmanaged value; when absent
    or malformed we fall back to `DEFAULT_BRIEFING_SOURCES`.
    """
    try:
        from axi import config  # noqa: PLC0415

        raw = config.get("briefing_sources", None)
    except Exception:  # noqa: BLE001
        raw = None
    if isinstance(raw, list) and raw:
        clean: list[dict[str, str]] = []
        for s in raw:
            if not isinstance(s, dict):
                continue
            url = _safe_url(s.get("url"))
            if not url:
                continue
            clean.append({
                "name": str(s.get("name") or url).strip()[:_MAX_TITLE],
                "url": url,
                "category": str(s.get("category") or "general").strip()[:32] or "general",
            })
        if clean:
            return clean
    return [dict(s) for s in DEFAULT_BRIEFING_SOURCES]


def _norm_url(url: str) -> str:
    """Normalize a URL for dedup: drop scheme/www, fragment, trailing slash."""
    u = str(url or "").strip().lower()
    u = re.sub(r"^https?://", "", u)
    u = u.split("#", 1)[0]
    if u.startswith("www."):
        u = u[4:]
    return u.rstrip("/")


def _norm_title(title: str) -> str:
    """Normalize a title for similarity dedup: lowercase, alnum + spaces only."""
    t = str(title or "").lower()
    t = re.sub(r"[^0-9a-záéíóúñü ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def _extract_source_candidates(
    fetch_result: dict[str, Any], source: dict[str, str], limit: int,
) -> list[dict[str, str]]:
    """Turn one source's web_fetch result into tagged headline candidates.

    Reads the REAL anchor links (`links: [{text, url}]`) the fetch returned —
    never invents URLs. Drops nav/chrome and links whose text is too short to
    be a headline; dedups within the source by URL; caps at `limit`.
    """
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    name = str(source.get("name") or "").strip()
    category = str(source.get("category") or "general").strip() or "general"
    for link in (fetch_result.get("links") or []):
        if not isinstance(link, dict):
            continue
        title = str(link.get("text") or "").strip()
        url = _safe_url(link.get("url"))
        if not url or not title:
            continue
        if len(title) < _MIN_HEADLINE_LEN:
            continue
        if _is_probable_nav(title, url):
            continue
        key = _norm_url(url)
        if key in seen:
            continue
        seen.add(key)
        out.append({
            "title": title[:_MAX_TITLE],
            "url": url,
            "source": name,
            "category": category,
        })
        if len(out) >= limit:
            break
    return out


def _build_extraction_prompt(
    text: str, links: list[dict[str, str]], source: dict[str, str],
    limit: int, today: str,
) -> str:
    """Prompt the brain to extract a source's REAL top headlines from its page.

    The brain reads the page TEXT (what a human sees) and picks the genuine
    article headlines currently featured, mapping EACH to the INDEX of a real
    link from the numbered list. It never writes a URL, so it cannot fabricate
    one — we resolve indices back to the real fetched links.
    """
    name = str(source.get("name") or "")
    lines = [
        f"Hoy es {today}. Estás leyendo la portada de «{name}».",
        "",
        "TEXTO DE LA PÁGINA (lo que ve un humano):",
        (text or "").strip()[:2400] or "(sin texto extraído)",
        "",
        "ENLACES REALES de la página (índice: texto -> url):",
    ]
    for i, ln in enumerate(links):
        lines.append(f"[{i}] {ln.get('text', '')} -> {ln.get('url', '')}")
    lines += [
        "",
        f"Extrae los {limit} TITULARES DE ARTÍCULO más importantes que la "
        "portada destaca AHORA. IGNORA navegación, secciones, categorías, "
        "etiquetas (tags), hubs, 'Últimas Noticias', login y anuncios: NO son "
        "titulares. Para cada titular, da su texto tal como es noticia y el "
        "ÍNDICE [i] del enlace real que le corresponde (o null si ninguno "
        "encaja). NO inventes URLs ni titulares que no estén en la página.",
        "Responde ÚNICAMENTE con JSON:",
        '{"headlines": [{"title": "<titular>", "link": <índice o null>}]}',
    ]
    return "\n".join(lines)


def _extract_headlines_with_brain(
    fetch_result: dict[str, Any],
    source: dict[str, str],
    ask: Callable[..., str],
    *,
    limit: int,
    today: str,
    max_tokens: int = 1024,
    timeout: float = 90.0,
) -> list[dict[str, str]] | None:
    """Have the brain read one source's page and return its REAL top headlines.

    Returns tagged candidates (title from the brain's read of the page TEXT,
    URL resolved from the page's REAL links by index — never fabricated; an
    unresolved/nav index falls back to the source base URL). Returns ``None``
    when the brain is unavailable or its response carries no ``headlines`` list,
    so the caller can fall back to the deterministic extractor.
    """
    links = [
        ln for ln in (fetch_result.get("links") or [])
        if isinstance(ln, dict) and _safe_url(ln.get("url"))
    ]
    base = _safe_url(source.get("url"))
    name = str(source.get("name") or "").strip()
    category = str(source.get("category") or "general").strip() or "general"
    prompt = _build_extraction_prompt(
        str(fetch_result.get("text") or ""), links, source, limit, today)
    try:
        raw = ask(prompt, max_tokens=max_tokens, timeout=timeout, task="extraction")
    except Exception:  # noqa: BLE001
        log.exception("multi-source brain extraction failed for %s", name)
        return None
    if _is_brain_failure(raw):
        return None
    obj = _extract_json(raw)
    if not isinstance(obj, dict) or not isinstance(obj.get("headlines"), list):
        return None

    out: list[dict[str, str]] = []
    seen: set[str] = set()
    for h in obj["headlines"]:
        if len(out) >= limit:
            break
        if not isinstance(h, dict):
            continue
        title = str(h.get("title") or "").strip()
        if len(title) < _MIN_HEADLINE_LEN:
            continue
        idx = h.get("link")
        url = base
        if not isinstance(idx, bool) and isinstance(idx, int) and 0 <= idx < len(links):
            cand_url = _safe_url(links[idx].get("url"))
            # Only accept the mapped link when it is not itself a nav/section
            # link; otherwise keep the headline on the source's base URL.
            if cand_url and not _is_probable_nav(links[idx].get("text", ""), cand_url):
                url = cand_url
        if not url:
            continue
        # Final guard: even a brain-picked item is dropped if it is clearly a
        # section/nav/tag link (the brain occasionally lists chrome on sparse
        # pages like paper/product aggregators).
        if _is_probable_nav(title, url):
            continue
        key = _norm_title(title)
        if key and key in seen:
            continue
        if key:
            seen.add(key)
        out.append({
            "title": title[:_MAX_TITLE],
            "url": url,
            "source": name,
            "category": category,
        })
    return out


def _dedup_candidates(cands: list[dict[str, str]]) -> list[dict[str, str]]:
    """Drop cross-source duplicates: same normalized URL OR same/similar title.

    Keeps the first occurrence (source order is the initial priority).
    """
    out: list[dict[str, str]] = []
    seen_urls: set[str] = set()
    seen_titles: set[str] = set()
    for c in cands:
        nu = _norm_url(c.get("url", ""))
        nt = _norm_title(c.get("title", ""))
        if (nu and nu in seen_urls) or (nt and nt in seen_titles):
            continue
        if nu:
            seen_urls.add(nu)
        if nt:
            seen_titles.add(nt)
        out.append(c)
    return out


def _rank_candidates(cands: list[dict[str, str]]) -> list[dict[str, str]]:
    """Deterministic diversity ranking: round-robin across categories.

    Interleaving by category (preserving within-category order) keeps the
    surfaced items from being dominated by a single high-volume source, which
    is what makes the fallback digest feel curated rather than a raw dump.
    """
    from collections import OrderedDict  # noqa: PLC0415

    buckets: "OrderedDict[str, list[dict[str, str]]]" = OrderedDict()
    for c in cands:
        buckets.setdefault(c.get("category") or "general", []).append(c)
    ranked: list[dict[str, str]] = []
    queues = list(buckets.values())
    while queues:
        for q in list(queues):
            if q:
                ranked.append(q.pop(0))
            if not q:
                queues.remove(q)
    return ranked


def _to_item(c: dict[str, str], why: str = "") -> dict[str, str]:
    """Map a candidate to the /briefings item shape (title_es + url render)."""
    title = str(c.get("title") or "")[:_MAX_TITLE]
    return {
        "title": title,
        "title_es": title,
        "summary": str(why or "")[:_MAX_SUMMARY],
        "why": str(why or "")[:_MAX_SUMMARY],
        "url": _safe_url(c.get("url")),
        "source": str(c.get("source") or "")[:_MAX_TITLE],
        "category": str(c.get("category") or "")[:32],
    }


def _multi_source_markdown(
    headline: dict[str, str] | None,
    top: list[dict[str, str]],
    more: list[dict[str, str]],
) -> str:
    lines: list[str] = [f"## {_MULTI_SOURCE_TITLE}", ""]
    if headline:
        t, u = headline.get("title", ""), headline.get("url", "")
        src = headline.get("source", "")
        lines.append(f"**Lo más importante:** [{t}]({u})" if u else f"**Lo más importante:** {t}")
        if src:
            lines.append(f"  _{src}_")
        lines.append("")
    if top:
        lines.append("### Vale tu tiempo")
        for it in top:
            t, u, src = it.get("title", ""), it.get("url", ""), it.get("source", "")
            head = f"[{t}]({u})" if u else t
            lines.append(f"- {head} — _{src}_")
            why = it.get("why") or it.get("summary")
            if why:
                lines.append(f"  - {why}")
        lines.append("")
    if more:
        lines.append("### Más")
        for it in more:
            t, u, src = it.get("title", ""), it.get("url", ""), it.get("source", "")
            head = f"[{t}]({u})" if u else t
            lines.append(f"- {head} — _{src}_")
    return "\n".join(lines).strip()


def _cluster_fallback(cands: list[dict[str, str]], max_top: int) -> dict[str, Any]:
    """Deterministic digest (no brain): rank by category diversity, then slice.

    headline = most important (first ranked); top = next `max_top`; the rest
    collapse into `more`. Every candidate is surfaced exactly once.
    """
    ranked = _rank_candidates(cands)
    headline = _to_item(ranked[0]) if ranked else None
    top = [_to_item(c) for c in ranked[1 : 1 + max_top]]
    more = [_to_item(c) for c in ranked[1 + max_top :]]
    return {"headline": headline, "top": top, "more": more, "summary": ""}


def _build_synthesis_prompt(cands: list[dict[str, str]], today: str) -> str:
    """Compact numbered candidate list for the brain, referenced by INDEX.

    The brain never sees a place to write a URL — it picks candidates by index,
    so it cannot invent links. We map indices back to the real fetched URLs.
    """
    lines = [
        f"Hoy es {today}. Estas son las noticias candidatas de varias fuentes, "
        "numeradas. Cúralas en un boletín digerible en español (es-MX).",
        "",
    ]
    for i, c in enumerate(cands):
        lines.append(f"[{i}] ({c.get('category')}/{c.get('source')}) {c.get('title')}")
    lines += [
        "",
        "Elige la ÚNICA noticia más importante del día (headline) y de 4 a 5 que "
        "'valgan tu tiempo' (top), agrupando por tema y evitando repetir. Para "
        "cada una del top escribe una línea corta de 'por qué importa'. NO "
        "inventes noticias ni URLs: refiérete SOLO por el número [i].",
        "Responde ÚNICAMENTE con JSON:",
        '{"summary": "<resumen general breve>", "headline": <indice>, '
        '"top": [{"index": <indice>, "why": "<por qué importa, 1 línea>"}]}',
    ]
    return "\n".join(lines)


def _synthesize_with_brain(
    cands: list[dict[str, str]],
    ask: Callable[..., str],
    *,
    today: str,
    max_top: int,
    max_tokens: int,
    timeout: float,
) -> dict[str, Any] | None:
    """Editorial synthesis via the brain: rank/cluster/why by candidate index.

    Returns the digest dict, or None on any failure so the caller falls back to
    the deterministic clustering. Indices are mapped back to real candidates —
    an out-of-range or duplicate index is ignored, never fabricated.
    """
    prompt = _build_synthesis_prompt(cands, today)
    try:
        raw = ask(prompt, max_tokens=max_tokens, timeout=timeout, task="agentic")
    except Exception:  # noqa: BLE001
        log.exception("multi-source brain synthesis failed")
        return None
    if _is_brain_failure(raw):
        return None
    obj = _extract_json(raw)
    if not isinstance(obj, dict):
        return None

    def _pick(idx: Any) -> dict[str, str] | None:
        if isinstance(idx, bool) or not isinstance(idx, int):
            return None
        return cands[idx] if 0 <= idx < len(cands) else None

    used: set[int] = set()
    headline = None
    h_idx = obj.get("headline")
    hc = _pick(h_idx)
    if hc is not None:
        headline = _to_item(hc)
        used.add(int(h_idx))
    top: list[dict[str, str]] = []
    for entry in (obj.get("top") or []):
        if len(top) >= max_top:
            break
        if not isinstance(entry, dict):
            continue
        idx = entry.get("index")
        c = _pick(idx)
        if c is None or int(idx) in used:
            continue
        used.add(int(idx))
        top.append(_to_item(c, why=str(entry.get("why") or "")))
    if headline is None and top:
        # Promote the first top item to headline so the shape stays valid.
        headline = top.pop(0)
    if headline is None:
        return None
    more = [_to_item(c) for i, c in enumerate(cands) if i not in used]
    summary = str(obj.get("summary") or "").strip()[:_MAX_SUMMARY]
    return {"headline": headline, "top": top, "more": more, "summary": summary}


def _default_web_fetch(url: str) -> dict[str, Any]:
    from axi.web_tools import web_fetch_handler  # noqa: PLC0415

    return web_fetch_handler({"url": url})


def _default_ask(prompt: str, **kwargs: Any) -> str:
    """Default brain completion caller for the multi-source pipeline.

    Both per-source headline extraction and cross-source editorial synthesis
    call the brain as a plain completion (no tools) — the real page links are
    handed in the prompt and referenced by index, so the model never needs a
    web tool and cannot fabricate a URL.
    """
    from axi import brain  # noqa: PLC0415

    return brain.ask(prompt, **kwargs)


_USE_DEFAULT_BRAIN = object()  # sentinel: "caller omitted ask → use real brain"


def run_multi_source_briefing(
    sources: list[dict[str, str]] | None = None,
    *,
    web_fetch: Callable[[str], dict[str, Any]] | None = None,
    ask_with_tools: Callable[..., str] | None | object = _USE_DEFAULT_BRAIN,
    today: str | None = None,
    max_per_source: int = 8,
    max_top: int = 5,
    max_tokens: int = 4096,
    timeout: float = 180.0,
) -> dict[str, Any]:
    """Build a digestible, clustered multi-source briefing. Never raises.

    Fetches each source homepage deterministically, extracts + dedups candidate
    headlines, then produces a `headline` / `top` (≤`max_top`, each with a
    "por qué importa") / `more` digest. Editorial synthesis uses the injected
    brain (`ask_with_tools`) when available, else a deterministic fallback.

    Returns a dict with: title, summary, headline, top, more, items (flat
    headline+top+more for the /briefings card), markdown, sources_used, ok.
    """
    srcs = sources if sources is not None else briefing_sources()
    fetch = web_fetch or _default_web_fetch
    today = today or _today_in_config_tz()
    # Omitted → use the real brain (good production/smoke default). Explicit
    # None → deterministic-only (tests pin this). A callable is used as given.
    if ask_with_tools is _USE_DEFAULT_BRAIN:
        ask_with_tools = _default_ask

    candidates: list[dict[str, str]] = []
    sources_used = 0
    for src in srcs:
        url = _safe_url(src.get("url"))
        if not url:
            continue
        try:
            result = fetch(url)
        except Exception:  # noqa: BLE001
            log.exception("multi-source fetch failed for %s", url)
            continue
        if not isinstance(result, dict):
            continue
        # Preferred: let the brain read the page TEXT and extract this source's
        # REAL top headlines (mapped to real links). Fall back to the
        # deterministic link filter when the brain is absent or fails.
        got: list[dict[str, str]] | None = None
        if ask_with_tools is not None:
            got = _extract_headlines_with_brain(
                result, src, ask_with_tools,
                limit=max_per_source, today=today,
            )
        if got is None:
            got = _extract_source_candidates(result, src, limit=max_per_source)
        if got:
            sources_used += 1
        candidates.extend(got)

    candidates = _dedup_candidates(candidates)

    if not candidates:
        return {
            "title": _MULTI_SOURCE_TITLE,
            "summary": "No encontré noticias en las fuentes de hoy.",
            "headline": None,
            "top": [],
            "more": [],
            "items": [],
            "markdown": "No encontré noticias en las fuentes de hoy.",
            "sources_used": sources_used,
            "ok": True,
        }

    digest: dict[str, Any] | None = None
    if ask_with_tools is not None:
        digest = _synthesize_with_brain(
            candidates, ask_with_tools, today=today, max_top=max_top,
            max_tokens=max_tokens, timeout=timeout,
        )
    if digest is None:
        digest = _cluster_fallback(candidates, max_top=max_top)

    headline = digest["headline"]
    top = digest["top"][:max_top]
    more = digest["more"]
    items = ([headline] if headline else []) + top + more
    summary = digest.get("summary") or (
        f"{len(items)} noticias de {sources_used} fuentes, curadas."
    )
    return {
        "title": _MULTI_SOURCE_TITLE,
        "summary": summary[:_MAX_SUMMARY],
        "headline": headline,
        "top": top,
        "more": more,
        "items": items,
        "markdown": _multi_source_markdown(headline, top, more),
        "sources_used": sources_used,
        "ok": True,
    }


def run_briefing_for_prompt(
    action_prompt: str,
    *,
    today: str | None = None,
) -> dict[str, Any]:
    """Route a reminder's prompt to the right briefing engine.

    Multi-source when the prompt carries a multi-source marker OR the
    `briefing_multi_source` config flag is on; otherwise the single-URL
    agentic path. Keeps the existing agentic path working unchanged.
    """
    multi = is_multi_source_request(action_prompt)
    if not multi:
        try:
            from axi import config  # noqa: PLC0415

            multi = bool(config.get("briefing_multi_source", False))
        except Exception:  # noqa: BLE001
            multi = False
    if multi:
        # Wire the real brain so per-source extraction + editorial synthesis
        # actually run in production (the smoke run showed they silently did
        # not when no brain was injected).
        return run_multi_source_briefing(today=today, ask_with_tools=_default_ask)
    return run_agentic_briefing(action_prompt, today=today)


def _is_brain_failure(raw: str) -> bool:
    """True when the brain returned a tool-calling failure sentinel.

    `brain.ask_with_tools` signals failure with a bracketed message like
    "[Axi no pudo completar la llamada a herramientas]" or "[Axi brain …]".
    These are control strings, not digest content.
    """
    t = (raw or "").strip()
    return t.startswith("[Axi ") and t.endswith("]")
