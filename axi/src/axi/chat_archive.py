"""Summarize + archive the tail of the chat log so it stays bounded as LifeOS
accumulates data — WITHOUT losing knowledge.

Durable facts already live in the graph (the extractor bridges them), so the raw
old turns are mostly redundant for retrieval. When the conversation log exceeds
``hot_turns + batch``, the OLDEST ``batch`` turns are summarized into a single
``conversation_summary`` graph node (linked to the user hub, dated by the span,
embedded + FTS-indexed so it stays searchable), then the raw turns are deleted.
Conservative defaults: only triggers once the log is genuinely large.
"""
from __future__ import annotations

import datetime
import logging
from zoneinfo import ZoneInfo

log = logging.getLogger("axi.chat_archive")

_SUMMARY_SYSTEM = (
    "Resumí esta tanda de conversación entre Héctor y su asistente Axi en un "
    "párrafo compacto (máximo 8 líneas), en español. CONSERVÁ los hechos y "
    "decisiones importantes (nombres propios, fechas, datos personales, temas "
    "tratados, acuerdos). NO inventes nada que no esté en el texto. Es un "
    "resumen para la memoria de largo plazo de Axi."
)


def _fmt_day(ts, tz) -> str:
    try:
        return datetime.datetime.fromtimestamp(float(ts), tz=tz).strftime("%d/%m/%Y")
    except Exception:  # noqa: BLE001
        return "?"


def summarize_and_archive(hot_turns: int = 400, batch: int = 200) -> int:
    """Summarize + prune the oldest chat turns when the log grows large.

    Returns the number of turns archived (0 if under threshold, disabled, or on
    any error). NEVER raises into the caller.
    """
    try:
        from axi import brain, config, identity, store  # noqa: PLC0415

        if not config.get("chat_archive_enabled", True):
            return 0
        hot_turns = int(config.get("chat_archive_hot_turns", hot_turns))
        batch = int(config.get("chat_archive_batch", batch))

        if store.conversation_count() <= hot_turns + batch:
            return 0
        old = store.oldest_conversations(batch)
        if len(old) < batch:
            return 0

        lines = []
        for r in old:
            u = (r["user_text"] or "").strip()
            a = (r["axi_text"] or "").strip()
            if u or a:
                lines.append(f"Héctor: {u}\nAxi: {a}")
        transcript = "\n".join(lines)[:12000]
        if not transcript:
            return 0

        summary = brain.ask(transcript, system=_SUMMARY_SYSTEM, max_tokens=400, lang="es-MX", task="longsum")
        if not summary or not summary.strip():
            return 0  # no summary -> do NOT delete; try again next cycle

        tz_name = config.get("timezone", "UTC") or "UTC"
        try:
            tz = ZoneInfo(tz_name)
        except Exception:  # noqa: BLE001
            tz = ZoneInfo("UTC")
        span = f"{_fmt_day(old[0]['ts'], tz)} – {_fmt_day(old[-1]['ts'], tz)}"

        nid = store.add_node(
            kind="conversation_summary",
            label=f"Resumen de chat ({span})",
            data={"summary": summary.strip(), "turns": len(old), "span": span},
            occurred_at=(float(old[-1]["ts"]) if old[-1]["ts"] else None),
        )
        try:
            identity.link_fact_to_user(nid)
            store.trigger_embed_for_node(nid)
        except Exception:  # noqa: BLE001
            pass

        n = store.delete_conversations([r["id"] for r in old])
        log.info("archived %d old chat turns into summary node %s (%s)", n, nid, span)
        return n
    except Exception as e:  # noqa: BLE001
        log.warning("chat archive failed: %s", e)
        return 0
