"""Shared web_search tool definition and handler for chat and voice paths.

Extracted from dashboard.py so both the chat path (dashboard) and the
voice co-pilot path (daemon / _wakeword_ask) can share the same tool
schema and implementation without duplicating code.
"""
from __future__ import annotations

from typing import Any


def web_search_tool_def() -> dict[str, Any]:
    """Return the OpenAI-compatible web_search tool schema."""
    return {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Busca en internet con SearXNG local para información actual o verificable.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Consulta de búsqueda web."},
                    "time_range": {
                        "type": "string",
                        "enum": ["day", "week", "month", "year"],
                        "description": (
                            "Ventana temporal para sesgar resultados a contenido "
                            "fresco. Usá 'day' para noticias de hoy."
                        ),
                    },
                    "categories": {
                        "type": "string",
                        "description": (
                            "Categoría de SearXNG (ej. 'news' para noticias)."
                        ),
                    },
                },
                "required": ["query"],
            },
        },
    }


def web_search_handler(args: dict[str, Any]) -> dict[str, Any]:
    """Whitelisted local web_search tool handler.

    Lazy-imports lifeos.web so this module is usable from the daemon
    (which doesn't import lifeos.web at module level).
    """
    import importlib  # noqa: PLC0415
    _web_research = importlib.import_module("lifeos.web")
    _port = importlib.import_module("lifeos.web.port")
    TOP_N = _port.TOP_N
    MAX_SNIPPET_CHARS = _port.MAX_SNIPPET_CHARS

    query = str(args.get("query") or "").strip()
    if not query:
        return {"ok": False, "error": "query is required", "results": []}
    if not _web_research.is_enabled():
        return {"ok": False, "error": "web research is disabled", "results": []}
    search_fn = _web_research.get_search_fn()
    if search_fn is None:
        return {"ok": False, "error": "search provider is unavailable", "results": []}
    # Forward freshness hints only when present so providers / injected fakes
    # that take a bare (query) keep working unchanged.
    search_kwargs: dict[str, Any] = {}
    time_range = str(args.get("time_range") or "").strip()
    if time_range:
        search_kwargs["time_range"] = time_range
    categories = str(args.get("categories") or "").strip()
    if categories:
        search_kwargs["categories"] = categories
    results = search_fn(query, **search_kwargs)
    # Resilience: some local SearXNG indexes return ZERO for a narrow
    # time_range (notably 'day', whose engines drop undated results). Rather
    # than handing the model an empty result set — which makes it loop and
    # burn its tool rounds — widen the window once by dropping time_range and
    # retry. categories (e.g. 'news') is kept so the bias toward fresh sources
    # survives.
    if not results and "time_range" in search_kwargs:
        retry_kwargs = {k: v for k, v in search_kwargs.items() if k != "time_range"}
        results = search_fn(query, **retry_kwargs)
    results = results[:TOP_N]
    packed: list[dict[str, str]] = []
    for item in results:
        packed.append({
            "title": item.title,
            "url": item.url,
            "snippet": item.snippet[:MAX_SNIPPET_CHARS],
        })
    return {"ok": bool(packed), "query": query, "results": packed}


def web_fetch_tool_def() -> dict[str, Any]:
    """OpenAI-compatible web_fetch tool schema.

    Reads ONE specific URL and returns its extracted page text — use this when
    the user named a concrete site/page (e.g. a news front page) instead of
    searching the open web.
    """
    return {
        "type": "function",
        "function": {
            "name": "web_fetch",
            "description": (
                "Lee el contenido ACTUAL de una URL específica (la portada o "
                "página que el usuario pidió). Usala cuando el pedido trae un "
                "enlace concreto, en vez de web_search."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL http(s) a leer."},
                },
                "required": ["url"],
            },
        },
    }


def web_fetch_handler(args: dict[str, Any]) -> dict[str, Any]:
    """Whitelisted local web_fetch tool handler: read one URL's page text.

    Mirrors web_search_handler's gating. Only http(s) URLs are fetched; the
    underlying read_fn never raises and truncates to MAX_PAGE_CHARS.
    """
    import importlib  # noqa: PLC0415
    _web_research = importlib.import_module("lifeos.web")
    _port = importlib.import_module("lifeos.web.port")
    MAX_PAGE_CHARS = _port.MAX_PAGE_CHARS

    url = str(args.get("url") or "").strip()
    if not url:
        return {"ok": False, "error": "url is required", "url": ""}
    if not (url.startswith("http://") or url.startswith("https://")):
        return {"ok": False, "error": "only http(s) URLs are allowed", "url": url}
    if not _web_research.is_enabled():
        return {"ok": False, "error": "web research is disabled", "url": url}
    read_fn = _web_research.get_read_fn()
    if read_fn is None:
        return {"ok": False, "error": "fetch provider is unavailable", "url": url}
    page = read_fn(url)
    text = (getattr(page, "text", "") or "")[:MAX_PAGE_CHARS]
    links = list(getattr(page, "links", ()) or ())
    return {
        "ok": bool(getattr(page, "ok", False) and (text or links)),
        "url": url,
        "text": text,
        "links": links,  # real [{text, url}] anchors — cite these, never invent
    }
