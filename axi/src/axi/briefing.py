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
from datetime import datetime, timedelta, timezone
from typing import Any, Callable
from zoneinfo import ZoneInfo

log = logging.getLogger("axi.briefing")

# Default timezone for freshness — the user's local day (today/yesterday) is
# what "fresh" means, so feed timestamps (UTC) are converted here first.
_DEFAULT_TZ = "America/Mexico_City"

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

# Default source set — DATED feeds/APIs (boletín v2). Each source declares an
# ADAPTER: "feed" (RSS/Atom parsed by lifeos.web.feeds) or "hn_algolia" (the
# Hacker News Algolia JSON API). This is the fix for the staleness bug: v1
# scraped HTML HOMEPAGES for anchor links with NO date, so weeks-old items
# surfaced. Now candidates come from dated feeds and are freshness-filtered to
# today/yesterday only. The list is config-driven under `briefing_sources`
# (see `briefing_sources()`), swappable per install without touching code.
# Each source carries a category tag (linux/ia/mx/general/tech) for clustering.
#
# General-news slot: AP News has no feed, so it is dropped and replaced with
# BBC Mundo's RSS (https://feeds.bbci.co.uk/mundo/rss.xml — live-verified,
# dated, Spanish). HF *papers* has no feed either → the HF *blog* feed is used.
DEFAULT_BRIEFING_SOURCES: list[dict[str, str]] = [
    {"name": "MuyLinux", "adapter": "feed", "url": "https://www.muylinux.com/feed/", "category": "linux"},
    {"name": "SoplosLinux", "adapter": "feed", "url": "https://soploslinux.com/feed/", "category": "linux"},
    {"name": "Linux en Español", "adapter": "feed", "url": "https://www.xn--linuxenespaol-skb.com/feed/", "category": "linux"},
    {"name": "LinuxAdictos", "adapter": "feed", "url": "https://www.linuxadictos.com/feed/", "category": "linux"},
    {"name": "desdeLinux", "adapter": "feed", "url": "https://blog.desdelinux.net/feed/", "category": "linux"},
    {"name": "Simon Willison", "adapter": "feed", "url": "https://simonwillison.net/atom/everything/", "category": "ia", "lang": "en"},
    {"name": "Hugging Face Blog", "adapter": "feed", "url": "https://huggingface.co/blog/feed.xml", "category": "ia", "lang": "en"},
    {"name": "Expansión", "adapter": "feed", "url": "https://expansion.mx/rss", "category": "mx"},
    {"name": "BBC Mundo", "adapter": "feed", "url": "https://feeds.bbci.co.uk/mundo/rss.xml", "category": "general"},
    {"name": "Hacker News", "adapter": "hn_algolia", "url": "https://news.ycombinator.com/", "category": "tech", "lang": "en"},
]

# Category presentation for the grouped (clusters) view. Order = surfacing
# priority; labels are the es-MX section titles the markdown renders.
_CATEGORY_ORDER: tuple[str, ...] = ("tech", "ia", "general", "mx", "linux")
_CATEGORY_LABELS: dict[str, str] = {
    "tech": "Tecnología",
    "ia": "IA",
    "general": "Mundo",
    "mx": "México",
    "linux": "Linux",
}
# A digestible cluster shows a handful per category, not a raw dump.
_MAX_PER_CLUSTER = 5
# Total surfaced items are bounded so the card stays 15-25, not overwhelming.
_MAX_TOTAL_ITEMS = 25

# English sources whose title/summary must be translated to es-MX for the
# reader. Used as a fallback signal when a candidate carries no explicit `lang`.
_ENGLISH_SOURCES = frozenset({"Hacker News", "Simon Willison", "Hugging Face Blog"})

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
            entry: dict[str, str] = {
                "name": str(s.get("name") or url).strip()[:_MAX_TITLE],
                "url": url,
                "category": str(s.get("category") or "general").strip()[:32] or "general",
            }
            # Preserve an explicit adapter when the config carries one; absent →
            # the pipeline defaults to "feed". (Kept optional so a legacy config
            # without adapters round-trips unchanged.)
            adapter = str(s.get("adapter") or "").strip().lower()
            if adapter:
                entry["adapter"] = adapter
            # Preserve an explicit source language ("en"/"es") so the
            # translation step knows which sources to translate; absent → the
            # pipeline defaults to Spanish (no translation).
            lang = str(s.get("lang") or "").strip().lower()
            if lang:
                entry["lang"] = lang
            clean.append(entry)
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


def _to_item(c: dict[str, Any], why: str = "") -> dict[str, str]:
    """Map a candidate to the /briefings item shape (title_es + url render).

    Feed/Algolia candidates carry a `published` datetime and (for HN) an
    `hn_id`; both are surfaced on the item so the card can show the date and a
    future "ver comentarios" button. `published` is rendered as an ISO string.
    """
    title = str(c.get("title") or "")[:_MAX_TITLE]
    # Spanish title for the reader: the translated `title_es` when present
    # (English sources), else the original (already-Spanish sources).
    title_es = str(c.get("title_es") or title)[:_MAX_TITLE]
    # Displayed summary: the editorial "por qué importa" line when the brain
    # picked this item for `top`, else the (translated) feed summary so cluster
    # items still carry a one-line description.
    summary = str(
        why or c.get("summary_es") or c.get("summary") or ""
    )[:_MAX_SUMMARY]
    item: dict[str, str] = {
        "title": title,
        "title_es": title_es,
        "summary": summary,
        "why": str(why or "")[:_MAX_SUMMARY],
        "url": _safe_url(c.get("url")),
        "source": str(c.get("source") or "")[:_MAX_TITLE],
        "category": str(c.get("category") or "")[:32],
    }
    published = c.get("published")
    if isinstance(published, datetime):
        item["published"] = published.isoformat()
    hn_id = c.get("hn_id")
    if hn_id:
        item["hn_id"] = str(hn_id)[:64]
    return item


def _is_english_candidate(c: dict[str, Any]) -> bool:
    """True when a candidate's title/summary is English and needs translating.

    Uses the explicit `lang` tag first (config/source-driven), falling back to a
    known-English source name so a legacy source without `lang` still translates.
    """
    if str(c.get("lang") or "").strip().lower() == "en":
        return True
    return str(c.get("source") or "").strip() in _ENGLISH_SOURCES


# A translator persona so the brain does NOT mistake the batched title list for
# a live-news request (the default system prompt steers it toward web tools and
# it refuses with "no tengo acceso a internet"). Translation needs no network.
_TRANSLATION_SYSTEM = (
    "Eres un traductor profesional inglés→español de México (es-MX). Tu única "
    "tarea es TRADUCIR el texto que se te entrega. NO necesitas internet, NO "
    "busques nada y NO pidas activar búsquedas: el texto ya está aquí. Conserva "
    "nombres propios, marcas y términos técnicos. Responde ÚNICAMENTE con el "
    "objeto JSON solicitado, sin texto adicional."
)


def _build_translation_prompt(
    cands: list[dict[str, Any]], en_idx: list[int], today: str,
) -> str:
    """Batched es-MX translation prompt referencing candidates by INDEX.

    Only English candidates are listed (already-Spanish ones are never sent).
    The brain returns Spanish text keyed by the SAME index, so it cannot add,
    drop, or reorder candidates — we map the translations straight back.
    """
    lines = [
        f"Hoy es {today}. Traduce al español natural de México (es-MX) el "
        "título y el resumen de CADA noticia numerada. Conserva nombres "
        "propios y términos técnicos; NO agregues ni inventes noticias.",
        "",
    ]
    for i in en_idx:
        c = cands[i]
        lines.append(f"[{i}] TÍTULO: {c.get('title', '')}")
        summ = str(c.get("summary") or "").strip()
        if summ:
            lines.append(f"     RESUMEN: {summ}")
    lines += [
        "",
        "Responde ÚNICAMENTE con JSON, refiriéndote SOLO por el número [i]:",
        '{"translations": [{"index": <i>, "title_es": "<título en español>", '
        '"summary_es": "<resumen en español, 1-2 líneas>"}]}',
    ]
    return "\n".join(lines)


def _translate_candidates(
    cands: list[dict[str, Any]],
    ask: Callable[..., str],
    *,
    today: str,
    max_tokens: int = 2048,
    timeout: float = 120.0,
) -> list[dict[str, Any]]:
    """Translate English candidates' title + summary to es-MX via the brain.

    ONE batched call keyed by candidate index (no fabrication: an unknown or
    out-of-range index is ignored, and only English candidates are eligible).
    Sets `title_es` + `summary_es` and `translated=True` on translated items.
    Already-Spanish candidates are left untouched. On any brain failure the
    English candidates are left intact and marked `translated=False` (the
    displayed title then falls back to the original English) — never a crash.
    """
    en_idx = [i for i, c in enumerate(cands) if _is_english_candidate(c)]
    if not en_idx:
        return cands
    prompt = _build_translation_prompt(cands, en_idx, today)
    try:
        raw = ask(prompt, max_tokens=max_tokens, timeout=timeout,
                  task="translation", system=_TRANSLATION_SYSTEM)
    except Exception:  # noqa: BLE001 — translation must never sink the briefing
        log.exception("multi-source translation failed")
        raw = ""
    obj = None if _is_brain_failure(raw) else _extract_json(raw)
    translations = obj.get("translations") if isinstance(obj, dict) else None
    eligible = set(en_idx)
    if isinstance(translations, list):
        for entry in translations:
            if not isinstance(entry, dict):
                continue
            idx = entry.get("index")
            # Guard: only real, eligible English indices (never fabricated).
            if isinstance(idx, bool) or not isinstance(idx, int) or idx not in eligible:
                continue
            title_es = str(entry.get("title_es") or "").strip()[:_MAX_TITLE]
            summary_es = str(entry.get("summary_es") or "").strip()[:_MAX_SUMMARY]
            if title_es:
                cands[idx]["title_es"] = title_es
            if summary_es:
                cands[idx]["summary_es"] = summary_es
            if title_es or summary_es:
                cands[idx]["translated"] = True
    # Mark any English candidate the brain did not translate as untranslated so
    # the fallback (original text) is explicit rather than silent.
    for i in en_idx:
        cands[i].setdefault("translated", False)
    return cands


def _cluster_date(it: dict[str, Any]) -> str:
    """Recency sort key: the ISO `published` string (lexical = chronological)."""
    return str(it.get("published") or "")


def _build_clusters(
    items: list[dict[str, str]], *, per_cat: int = _MAX_PER_CLUSTER,
) -> dict[str, list[dict[str, str]]]:
    """Group surfaced items into a `{category: [items]}` digest, by recency.

    Known categories come first (in `_CATEGORY_ORDER`), then any others. Each
    category keeps at most `per_cat` items, newest first. Empty categories are
    omitted so the card renders only non-empty sections.
    """
    from collections import OrderedDict  # noqa: PLC0415

    buckets: "OrderedDict[str, list[dict[str, str]]]" = OrderedDict()
    for it in items:
        buckets.setdefault(str(it.get("category") or "general"), []).append(it)
    ordered = [c for c in _CATEGORY_ORDER if c in buckets]
    ordered += [c for c in buckets if c not in _CATEGORY_ORDER]
    clusters: dict[str, list[dict[str, str]]] = {}
    for cat in ordered:
        ranked = sorted(buckets[cat], key=_cluster_date, reverse=True)[:per_cat]
        if ranked:
            clusters[cat] = ranked
    return clusters


def _item_date_label(it: dict[str, Any]) -> str:
    """The YYYY-MM-DD date part of an item's ISO `published`, or ''."""
    return str(it.get("published") or "")[:10]


def _multi_source_markdown(
    headline: dict[str, str] | None,
    clusters: dict[str, list[dict[str, str]]],
) -> str:
    """Render a grouped card: one highlighted headline, then a section per
    non-empty category cluster (Spanish title + one-line summary + link +
    source + date). This is what /briefings shows, so the structure is visible
    without any template change.
    """
    lines: list[str] = [f"## {_MULTI_SOURCE_TITLE}", ""]
    if headline:
        t = headline.get("title_es") or headline.get("title", "")
        u = headline.get("url", "")
        lines.append(
            f"**Lo más importante:** [{t}]({u})" if u
            else f"**Lo más importante:** {t}")
        why = headline.get("why") or headline.get("summary")
        if why:
            lines.append(f"  {why}")
        meta = " · ".join(p for p in (headline.get("source", ""),
                                      _item_date_label(headline)) if p)
        if meta:
            lines.append(f"  _{meta}_")
        lines.append("")
    for cat, items in clusters.items():
        if not items:
            continue
        lines.append(f"## {_CATEGORY_LABELS.get(cat, cat.capitalize())}")
        for it in items:
            t = it.get("title_es") or it.get("title", "")
            u = it.get("url", "")
            head = f"[{t}]({u})" if u else t
            lines.append(f"- {head}")
            summ = it.get("summary") or it.get("why")
            meta = " · ".join(p for p in (it.get("source", ""),
                                          _item_date_label(it)) if p)
            detail = " — ".join(p for p in (summ, f"_{meta}_" if meta else "") if p)
            if detail:
                lines.append(f"  - {detail}")
        lines.append("")
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


# ───────────────────────── freshness + dated adapters ───────────────────────
#
# Boletín v2: candidates come from DATED feeds/APIs and are filtered to fresh
# only. A source that yields zero fresh entries is SKIPPED (recorded in
# `skipped_sources` as "sin noticias recientes") rather than surfacing staleness.

# Hacker News front page via the Algolia JSON API (dated: each hit has
# `created_at` ISO + `objectID` kept for a future comments button).
_HN_ALGOLIA_URL = (
    "http://hn.algolia.com/api/v1/search_by_date?tags=front_page&hitsPerPage=30"
)


def _briefing_tz() -> ZoneInfo:
    """The user's configured timezone (freshness is measured in local days)."""
    tz_name = _DEFAULT_TZ
    try:
        from axi import config  # noqa: PLC0415

        tz_name = str(config.get("timezone", tz_name)) or tz_name
    except Exception:  # noqa: BLE001
        pass
    try:
        return ZoneInfo(tz_name)
    except Exception:  # noqa: BLE001
        return ZoneInfo(_DEFAULT_TZ)


def _is_fresh(dt: Any, *, today, tz: ZoneInfo) -> bool:
    """True iff `dt`, converted to `tz`, falls on `today` or yesterday.

    Undated candidates (`dt is None`) are NOT fresh: without a timestamp we
    cannot prove recency, so they are discarded (that was the v1 bug — undated
    items leaked through). `today` is a `datetime.date` in `tz`.
    """
    if not isinstance(dt, datetime):
        return False
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    try:
        local = dt.astimezone(tz).date()
    except (ValueError, OSError, OverflowError):
        return False
    return local == today or local == today - timedelta(days=1)


def _hn_algolia_candidates(
    *, http_get: Callable[[str], bytes] | None = None, limit: int = 30,
) -> list[dict[str, Any]]:
    """Dated Hacker News front-page candidates from the Algolia JSON API.

    Each returned candidate carries the story `title`, real `url` (falling back
    to the HN item page for text/Ask posts), `published` (from `created_at`),
    `source`/`category`, and `hn_id` (the `objectID`, kept for a future
    comments link). Never raises → `[]` on any error.
    """
    from lifeos.web import feeds  # noqa: PLC0415

    getter = http_get or feeds._default_http_get
    try:
        body = getter(_HN_ALGOLIA_URL)
        data = json.loads(body)
    except Exception:  # noqa: BLE001 — network/JSON errors must not raise
        log.debug("HN Algolia fetch/parse failed")
        return []
    if not isinstance(data, dict):
        return []
    out: list[dict[str, Any]] = []
    for hit in (data.get("hits") or [])[:limit]:
        if not isinstance(hit, dict):
            continue
        oid = str(hit.get("objectID") or "").strip()
        title = str(hit.get("title") or "").strip()
        if not title:
            continue
        url = _safe_url(hit.get("url"))
        if not url and oid:
            url = f"https://news.ycombinator.com/item?id={oid}"
        if not url:
            continue
        out.append({
            "title": title[:_MAX_TITLE],
            "url": url,
            "published": feeds.parse_feed_date(hit.get("created_at")),
            "source": "Hacker News",
            "category": "tech",
            "hn_id": oid,
        })
    return out


def _freshness_summary(
    base: str, today_str: str, skipped: list[str],
) -> str:
    """Append the freshness note (and any skipped sources) to a card summary."""
    parts = [base.strip(), f"Frescura: solo hoy/ayer ({today_str})."]
    if skipped:
        parts.append("Sin novedades recientes: " + ", ".join(skipped) + ".")
    return " ".join(p for p in parts if p)[:_MAX_SUMMARY]


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
    http_get: Callable[[str], bytes] | None = None,
    feed_fetch: Callable[..., list[Any]] | None = None,
    ask_with_tools: Callable[..., str] | None | object = _USE_DEFAULT_BRAIN,
    today: str | None = None,
    now: datetime | None = None,
    max_per_source: int = 18,
    max_top: int = 5,
    max_items: int = _MAX_TOTAL_ITEMS,
    max_tokens: int = 4096,
    timeout: float = 180.0,
) -> dict[str, Any]:
    """Build a date-aware, freshness-filtered multi-source briefing. Never raises.

    Boletín v2: for each configured source, use its ADAPTER ("feed" → RSS/Atom
    via lifeos.web.feeds, "hn_algolia" → the HN Algolia JSON API) to get DATED
    candidates, keep only the fresh ones (today/yesterday in the user's tz), and
    SKIP any source with zero fresh entries (recording it in `skipped_sources`).
    The surviving dated candidates are deduped, then ranked/clustered into a
    `headline` / `top` (≤`max_top`, each with a "por qué importa") / `more`
    digest — via the injected brain when available, else a deterministic fallback.
    Feed/Algolia URLs are REAL (never fabricated).

    Injection seams (all tests use these — no network): `http_get(url)->bytes`
    drives both feed parsing and the Algolia call; `feed_fetch` overrides the
    feed parser; `now` pins the clock for freshness.

    English sources (lang="en": Hacker News, Simon Willison, HF blog) have their
    title + summary translated to es-MX in ONE batched brain call (by candidate
    index — no fabrication) before synthesis; already-Spanish sources are left
    intact, and a brain failure leaves the English text untouched.

    Returns a dict with: title, summary, headline, top, more, items (flat
    headline+top+more, capped at `max_items`), clusters ({category: [items]}
    grouped view, each ≤`_MAX_PER_CLUSTER`, empty categories omitted), markdown
    (grouped by category), sources_used, skipped_sources, ok.
    """
    from lifeos.web import feeds  # noqa: PLC0415

    srcs = sources if sources is not None else briefing_sources()
    fetch_one = feed_fetch or feeds.fetch_feed
    tz = _briefing_tz()
    now_dt = now or datetime.now(tz)
    today_date = now_dt.astimezone(tz).date()
    today_str = today or today_date.isoformat()
    # Omitted → use the real brain (good production/smoke default). Explicit
    # None → deterministic-only (tests pin this). A callable is used as given.
    if ask_with_tools is _USE_DEFAULT_BRAIN:
        ask_with_tools = _default_ask

    candidates: list[dict[str, Any]] = []
    skipped_sources: list[str] = []
    sources_used = 0
    for src in srcs:
        name = str(src.get("name") or "").strip()
        adapter = str(src.get("adapter") or "feed").strip().lower()
        category = str(src.get("category") or "general").strip() or "general"
        # Source language drives the translation step: "en" sources are
        # translated to es-MX; absent → Spanish (no translation).
        lang = str(src.get("lang") or "es").strip().lower() or "es"
        try:
            if adapter == "hn_algolia":
                raw_cands = _hn_algolia_candidates(
                    http_get=http_get, limit=max_per_source)
            else:
                url = _safe_url(src.get("url"))
                if not url:
                    continue
                entries = fetch_one(url, limit=max_per_source, http_get=http_get)
                raw_cands = [
                    {
                        "title": str(getattr(e, "title", "") or "").strip()[:_MAX_TITLE],
                        "url": _safe_url(getattr(e, "url", "")),
                        "published": getattr(e, "published", None),
                        "source": name,
                        "category": category,
                        "summary": str(getattr(e, "summary", "") or "").strip()[:_MAX_SUMMARY],
                    }
                    for e in entries
                    if str(getattr(e, "title", "") or "").strip()
                    and _safe_url(getattr(e, "url", ""))
                ]
        except Exception:  # noqa: BLE001 — one bad source must not sink the run
            log.exception("multi-source adapter failed for %s", name or adapter)
            if name:
                skipped_sources.append(name)
            continue
        # Tag language + ensure a summary field on every candidate (HN has none)
        # so the translation step and cluster rendering have a uniform shape.
        for c in raw_cands:
            c.setdefault("lang", lang)
            c.setdefault("summary", "")
        fresh = [
            c for c in raw_cands
            if _is_fresh(c.get("published"), today=today_date, tz=tz)
        ]
        if not fresh:
            # Zero fresh entries → skip the source (do not surface staleness).
            if name:
                skipped_sources.append(name)
            continue
        sources_used += 1
        candidates.extend(fresh)

    candidates = _dedup_candidates(candidates)

    if not candidates:
        summary = _freshness_summary(
            "No encontré noticias frescas en las fuentes.", today_str, skipped_sources)
        return {
            "title": _MULTI_SOURCE_TITLE,
            "summary": summary,
            "headline": None,
            "top": [],
            "more": [],
            "items": [],
            "clusters": {},
            "markdown": "No encontré noticias frescas en las fuentes de hoy.",
            "sources_used": sources_used,
            "skipped_sources": skipped_sources,
            "ok": True,
        }

    # Spanish (es-MX) for the reader: translate English sources' title + summary
    # in ONE batched brain call before synthesis. Deterministic-only runs
    # (ask=None) skip this and keep the original text (marked untranslated).
    if ask_with_tools is not None:
        candidates = _translate_candidates(
            candidates, ask_with_tools, today=today_str,
            max_tokens=max_tokens, timeout=timeout,
        )

    digest: dict[str, Any] | None = None
    if ask_with_tools is not None:
        digest = _synthesize_with_brain(
            candidates, ask_with_tools, today=today_str, max_top=max_top,
            max_tokens=max_tokens, timeout=timeout,
        )
    if digest is None:
        digest = _cluster_fallback(candidates, max_top=max_top)

    headline = digest["headline"]
    top = digest["top"][:max_top]
    # Interleave the tail by category BEFORE capping so trimming removes each
    # category's tail evenly instead of dropping whole (source-order-last)
    # categories like Hacker News / BBC Mundo.
    more = _rank_candidates(digest["more"])
    # Bound the total surfaced items to keep the card 15-25, not overwhelming:
    # the headline + top are always kept; the tail (`more`) is trimmed.
    keep_more = max(0, max_items - (1 if headline else 0) - len(top))
    more = more[:keep_more]
    items = ([headline] if headline else []) + top + more
    # Organized-by-category view (headline excluded — it is shown once on top).
    clusters = _build_clusters(top + more, per_cat=_MAX_PER_CLUSTER)
    base_summary = digest.get("summary") or (
        f"{len(items)} noticias frescas de {sources_used} fuentes, curadas."
    )
    return {
        "title": _MULTI_SOURCE_TITLE,
        "summary": _freshness_summary(base_summary, today_str, skipped_sources),
        "headline": headline,
        "top": top,
        "more": more,
        "items": items,
        "clusters": clusters,
        "markdown": _multi_source_markdown(headline, clusters),
        "sources_used": sources_used,
        "skipped_sources": skipped_sources,
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
