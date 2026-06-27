"""FINANZAS domain chat — the FINANCE spec for the generic domain_chat engine.

Like health_chat, this is ONLY config: the classifier prompt, the field→entry
mapping, the store binding (adapted to finance_entries' different signature),
the wording and the record formatter. No chat flow lives here — that is in
axi.domain_chat. This file is the proof that adding a domain is a spec, not a
copy of the engine.
"""
from __future__ import annotations

from typing import Any

from lifeos.finance import entries as finance_entries

from axi.domain_chat import DomainSpec, num

# ─── classify + extract prompt (thinking OFF) ───────────────────────────────

_EXTRACT_SYSTEM = """Eres el clasificador del chat de FINANZAS de Axi. Tu ÚNICO
trabajo es leer el mensaje del usuario y devolver un objeto JSON estricto. NO
converses, NO expliques, NO uses Markdown: SOLO el JSON.

Esquema EXACTO (usa null cuando no aplique):
{
  "intent": "register" | "query" | "off_topic",
  "kind": "expense" | "income" | "savings" | "debt_payment" | "big_purchase" | "note" | null,
  "amount": número|null,        // monto (solo el número, sin símbolo)
  "currency": cadena|null,      // "MXN" | "USD" | "EUR" ... (default MXN)
  "category": cadena|null,      // categoría corta: comida, transporte, renta, sueldo...
  "merchant": cadena|null,      // comercio o contraparte, si se menciona
  "title": cadena|null          // resumen corto del registro o la pregunta
}

FINANZAS = dinero: gastos, ingresos, ahorros, pagos de deuda, compras, sueldo,
presupuesto, precios, cuentas. NO es finanzas: salud/cuerpo, ejercicio,
relaciones, espiritualidad, aprendizaje, calendario, clima.

Reglas de intent:
- "off_topic": el mensaje NO es de dinero. TODOS los campos en null salvo intent.
- "query": el usuario PREGUNTA por sus datos financieros ("¿cuánto gasté este mes?",
  "en qué se me fue el dinero en diciembre", "cuánto llevo ahorrado").
- "register": el usuario REPORTA un movimiento ("gasté 200 en el súper", "me pagaron
  15000 de sueldo", "ahorré 1000", "pagué 500 de la tarjeta").

Reglas de extracción (solo para intent="register"):
- "gasté 200 en el súper" → kind="expense", amount=200, category="comida".
- "me pagaron 15000" → kind="income", amount=15000.
- Si no hay número claro, deja amount=null y usa kind="note" con un title.
- NUNCA inventes montos que el usuario no dijo.

Devuelve SOLO el JSON, sin texto adicional."""


# ─── field → entry mapping (finance-specific) ───────────────────────────────

_VALID_KINDS = {"expense", "income", "savings", "debt_payment", "big_purchase", "note"}


def _build_register_entries(extracted: dict[str, Any], raw_text: str) -> list[dict[str, Any]]:
    """Translate extracted finance fields into entry specs {kind,title,data,fragment}.

    `data` carries the finance fields (amount/currency/category/merchant) which the
    store_create adapter unpacks into finance_entries.create(). Falls back to a
    note (amount 0) so a message is never lost.
    """
    amount = num(extracted.get("amount"))
    raw_kind = (extracted.get("kind") or "").strip().lower()
    kind = raw_kind if raw_kind in _VALID_KINDS else None
    currency = (extracted.get("currency") or "MXN").strip().upper() or "MXN"
    category = (extracted.get("category") or None)
    merchant = (extracted.get("merchant") or None)
    title = (extracted.get("title") or raw_text).strip()[:120] or "movimiento"

    if amount is not None and 0 < amount < 100_000_000:
        if kind is None or kind == "note":
            kind = "expense"  # a number with no clear kind is most likely a gasto
        data = {
            "amount": float(amount),
            "currency": currency,
            "category": category,
            "merchant": merchant,
        }
        sign = "+" if kind == "income" else ""
        frag = f"{title} {sign}{amount:.0f} {currency}".strip()
        return [{"kind": kind, "title": title, "data": data, "fragment": frag}]

    # No usable amount — keep the message as a note (amount 0).
    return [{
        "kind": "note",
        "title": title,
        "data": {"amount": 0.0, "currency": currency, "category": category, "merchant": merchant},
        "fragment": title,
    }]


def _store_create(*, kind, title, when, body, data, source, raw_utterance):
    """Adapter: the generic engine's create call -> finance_entries.create()
    (which needs `amount` and finance-specific kwargs)."""
    d = data or {}
    return finance_entries.create(
        kind=kind,
        title=title,
        amount=float(d.get("amount", 0.0)),
        when=when,
        currency=d.get("currency", "MXN"),
        category=d.get("category"),
        merchant=d.get("merchant"),
        body=body,
        source="chat",
        raw_utterance=raw_utterance,
    )


def _format_record(e: Any, local_date: str) -> str:
    """One query-prompt line for a finance entry (id/date/kind/title/amount/cat)."""
    cat = e.category or "—"
    return (
        f"- id={e.id} fecha={local_date} kind={e.kind} title={e.title} "
        f"monto={e.amount:.2f} {e.currency} categoría={cat}"
    )


FINANCE_SPEC = DomainSpec(
    key="finance",
    name="Finanzas",
    extract_system=_EXTRACT_SYSTEM,
    build_entries=_build_register_entries,
    format_record=_format_record,
    # Late-bound so list_recent monkeypatching works; create needs adapting.
    store_create=_store_create,
    store_list_recent=lambda **kw: finance_entries.list_recent(**kw),
    register_prefix="Anotado en Finanzas",
    off_topic_msg="Eso no es de Finanzas. Probá en el apartado correspondiente.",
    router_hint="dinero: gastos, ingresos, ahorros, pagos de deuda, sueldo, "
                "precios, compras, presupuesto, cuentas",
    store_delete=lambda eid: finance_entries.delete(eid),
    store_update_title=lambda eid, title: finance_entries.update_title(eid, title),
)
