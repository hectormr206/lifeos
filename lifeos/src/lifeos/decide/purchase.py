"""Purchase consult — "¿puedo comprar X?" with cross-domain context.

Gathers a focused context bundle from the finance domain (and later, mood/
relationships/etc.) and composes a prompt that asks the brain for a
reasoned recommendation. The result includes citations to the specific
entries that informed the decision so the dashboard can render them.

The brain.ask callable is injected — keeps lifeos free of axi imports.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from lifeos.finance import entries as finance_entries

log = logging.getLogger("lifeos.decide.purchase")


# History windows used to build the context block.
_FINANCE_HISTORY_DAYS = 180   # 6 months of big purchases
_FINANCE_RECENT_DAYS = 30     # current burn rate / income / savings


@dataclass(frozen=True, slots=True)
class PurchaseContext:
    """The evidence bundle passed to the brain."""
    item: str
    summary_30d: dict[str, float]
    big_purchases_180d: list[finance_entries.Entry] = field(default_factory=list)
    pending_reflections: list[finance_entries.Entry] = field(default_factory=list)
    impulsive_ratio: float = 0.0
    impulsive_count: int = 0
    planned_count: int = 0
    classified_total: int = 0


@dataclass(frozen=True, slots=True)
class PurchaseConsultResult:
    answer: str
    context: PurchaseContext
    citations: list[str] = field(default_factory=list)  # entry ids referenced


def gather_context(item: str) -> PurchaseContext:
    """Pull the relevant slice of finance data for a purchase consult."""
    summary = finance_entries.summary(days=_FINANCE_RECENT_DAYS)
    history = finance_entries.list_recent(
        days=_FINANCE_HISTORY_DAYS, kind="big_purchase", limit=50,
    )
    pending = finance_entries.pending_reflections()

    impulsive = [p for p in history if "impulsive" in p.tags]
    planned = [p for p in history if "planned" in p.tags]
    classified = impulsive + planned
    ratio = (len(impulsive) / len(classified)) if classified else 0.0

    return PurchaseContext(
        item=item,
        summary_30d=summary,
        big_purchases_180d=history,
        pending_reflections=pending,
        impulsive_ratio=ratio,
        impulsive_count=len(impulsive),
        planned_count=len(planned),
        classified_total=len(classified),
    )


def _fmt_money(amount: float, currency: str = "MXN") -> str:
    return f"${amount:,.0f} {currency}"


def _fmt_short_date(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d")


def build_prompt(ctx: PurchaseContext, language: str = "es-MX") -> str:
    """Render a context-rich prompt for the brain."""
    lang_es = language.lower().startswith("es")
    lines: list[str] = []

    if lang_es:
        lines.append(
            f'Héctor pregunta: "¿puedo comprar {ctx.item}?"\n'
            f"Da una recomendación clara y honesta basada en los DATOS DE SU "
            f"VIDA que aparecen abajo. Termina con una sola línea de "
            f'"Recomendación: SÍ / NO / ESPERAR + razón corta". '
            f"No inventes números — usá solo los que están en los datos.\n"
        )
        lines.append("=== Estado financiero últimos 30 días ===")
        s = ctx.summary_30d
        lines.append(f"  Ingresos: {_fmt_money(s.get('income_total', 0))}")
        lines.append(f"  Gastos: {_fmt_money(s.get('expenses_total', 0))}")
        lines.append(f"  Compras grandes: {_fmt_money(s.get('big_purchases_total', 0))}")
        lines.append(f"  Ahorros: {_fmt_money(s.get('savings_total', 0))}")
        lines.append(f"  Pago de deuda: {_fmt_money(s.get('debt_payments_total', 0))}")
        balance = (
            s.get('income_total', 0) + s.get('savings_total', 0)
            - s.get('expenses_total', 0) - s.get('big_purchases_total', 0)
            - s.get('debt_payments_total', 0)
        )
        lines.append(f"  Balance del mes: {_fmt_money(balance)}")
        lines.append("")

        if ctx.classified_total > 0:
            pct = int(ctx.impulsive_ratio * 100)
            lines.append("=== Patrón de compras grandes (últimos 6 meses) ===")
            lines.append(
                f"  {ctx.classified_total} compras grandes clasificadas: "
                f"{ctx.impulsive_count} impulsivas, {ctx.planned_count} planeadas "
                f"({pct}% impulsivas)"
            )
        else:
            lines.append("=== Patrón de compras grandes ===")
            lines.append("  No hay compras grandes clasificadas todavía.")
        lines.append("")

        if ctx.big_purchases_180d:
            lines.append("=== Últimas compras grandes ===")
            for p in ctx.big_purchases_180d[:10]:
                tags_str = (
                    ("[" + ", ".join(p.tags) + "]") if p.tags else "[sin clasificar]"
                )
                lines.append(
                    f"  · {_fmt_short_date(p.ts)} — {p.title} "
                    f"({_fmt_money(p.amount, p.currency)}) {tags_str}"
                )
            lines.append("")

        if ctx.pending_reflections:
            lines.append("=== Compras esperando reflexión ===")
            for p in ctx.pending_reflections[:5]:
                lines.append(
                    f"  · {_fmt_short_date(p.ts)} — {p.title} "
                    f"({_fmt_money(p.amount, p.currency)})"
                )
            lines.append("")
    else:
        # English mirror
        lines.append(
            f'Héctor asks: "should I buy {ctx.item}?"\n'
            f"Give a clear, honest recommendation based ONLY on the data below. "
            f'End with one line: "Recommendation: YES / NO / WAIT + short reason".\n'
        )
        lines.append("=== Financial state last 30 days ===")
        s = ctx.summary_30d
        lines.append(f"  Income: {_fmt_money(s.get('income_total', 0))}")
        lines.append(f"  Expenses: {_fmt_money(s.get('expenses_total', 0))}")
        lines.append(f"  Big purchases: {_fmt_money(s.get('big_purchases_total', 0))}")
        lines.append(f"  Savings: {_fmt_money(s.get('savings_total', 0))}")
        lines.append("")
        if ctx.classified_total > 0:
            pct = int(ctx.impulsive_ratio * 100)
            lines.append(
                f"Big purchases last 6 months: {ctx.classified_total} classified, "
                f"{ctx.impulsive_count} impulsive vs {ctx.planned_count} planned "
                f"({pct}% impulsive)."
            )
        lines.append("")

    return "\n".join(lines)


def consult(item: str, *, brain_ask: Callable[..., str],
            language: str = "es-MX") -> PurchaseConsultResult:
    """Run a full purchase consult and return the answer.

    `brain_ask` is the callable the dashboard injects (typically
    `axi.brain.ask`). Signature: `brain_ask(prompt: str) -> str`.
    """
    ctx = gather_context(item)
    prompt = build_prompt(ctx, language=language)
    try:
        answer = brain_ask(prompt, max_tokens=1024)
    except TypeError:
        # Some brain.ask signatures may not accept max_tokens kwarg.
        answer = brain_ask(prompt)
    citations = [p.id for p in ctx.big_purchases_180d[:10]]
    return PurchaseConsultResult(answer=answer, context=ctx, citations=citations)
