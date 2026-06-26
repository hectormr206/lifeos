"""General-chat auto-router.

The general chat is the daily driver: the user types ANYTHING and Axi figures
out where it goes. This module is the thin router on top of the domain specs:

  1. classify_domain(): one fast 4B call (thinking OFF) picks the most likely
     domain key (or "general"). The prompt is BUILT FROM THE REGISTRY, so adding
     a domain spec updates the router automatically — no edit here.
  2. route_and_handle(): if a domain is picked, dispatch to that domain's spec
     (the SAME engine the specialized chats use). The spec's own classifier then
     confirms register/query — and if it disagrees (off_topic), the router
     yields (returns None) so the general brain handles the message instead.

Two-stage by design: the router picks the lane; the domain spec is the
authority on its own data. A misroute degrades to general conversation, never
to wrong data.
"""
from __future__ import annotations

import logging
import re
from datetime import datetime
from typing import Any, Callable

from axi import domain_chat

log = logging.getLogger("axi.chat_router")


def _build_router_system() -> str:
    """Build the classifier prompt from the live domain registry."""
    from axi.domain_registry import DOMAINS
    lines = [f"- {spec.key}: {spec.router_hint}" for spec in DOMAINS.values()]
    return (
        "Eres el enrutador del chat de Axi. Clasifica el mensaje del usuario en "
        "UNO de estos dominios, o en 'general', o en 'uncertain'. Responde SOLO "
        "con la clave (una palabra), sin explicar.\n\n"
        "Dominios:\n" + "\n".join(lines) + "\n"
        "- general: charla, saludos, opiniones, preguntas abiertas — cualquier cosa "
        "que NO sea un dato personal para registrar.\n"
        "- uncertain: SOLO cuando el mensaje claramente reporta un DATO PERSONAL o "
        "un hecho que el usuario probablemente quiere registrar, pero NO podés "
        "determinar con confianza a qué dominio pertenece. NO uses 'uncertain' para "
        "charla ni preguntas.\n\n"
        "Reglas: charla/pregunta → general. Dato claro de un dominio → su clave. "
        "Dato personal pero ambiguo → uncertain. Clave:"
    )


def classify_domain(text: str, brain_ask: Callable) -> str:
    """Return a registered domain key, 'uncertain', or 'general'. Never raises."""
    try:
        raw = brain_ask(text, system=_build_router_system(), think=False, max_tokens=8)
    except Exception as exc:  # noqa: BLE001
        log.warning("router classify failed: %s", exc)
        return "general"
    if not isinstance(raw, str) or not raw.strip():
        return "general"
    # Take the first bare word and strip punctuation/casing.
    key = re.sub(r"[^a-z_]", "", raw.strip().lower().split()[0]) if raw.split() else ""
    if key == "uncertain":
        return "uncertain"
    from axi.domain_registry import get_spec
    return key if get_spec(key) is not None else "general"


def route_and_handle(
    text: str,
    now: datetime,
    brain_ask: Callable | None = None,
) -> dict[str, Any] | None:
    """Route *text* to a domain spec if it is clearly domain data.

    Returns the spec's result dict (with an added "domain" key) on a successful
    register/query, or None when the message should fall through to the general
    brain (classified 'general', or the domain spec said off_topic/error).
    """
    if brain_ask is None:
        from axi import brain
        brain_ask = brain.ask

    key = classify_domain(text, brain_ask)
    if key == "general":
        return None

    # Uncertain: it looks like data the user wants to keep, but the domain is
    # ambiguous. Ask instead of guessing — the user picks and we re-process
    # (the frontend re-POSTs to /api/chat/domain/{key}). Never silently lost.
    if key == "uncertain":
        from axi.domain_registry import DOMAINS
        return {
            "mode": "clarify",
            "answer": "No estoy seguro de dónde guardar esto. ¿Querés registrarlo en alguno?",
            "options": [{"key": s.key, "name": s.name} for s in DOMAINS.values()],
            "original_text": text,
        }

    from axi.domain_registry import get_spec
    spec = get_spec(key)
    if spec is None:
        return None

    result = domain_chat.handle_message(spec, text, now=now, brain_ask=brain_ask)
    if result.get("mode") in ("register", "query"):
        return {**result, "domain": key}
    # The domain spec disagreed with the router (off_topic / error) — let the
    # general chat handle it rather than forcing wrong data.
    return None
