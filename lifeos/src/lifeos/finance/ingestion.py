"""Parse finance phrases from free-form chat text. Regex-first, high precision.

Recognized verbs:
    gasté N (en X) / me gasté N (en X)
    pagué N (de X / a X)
    compré X por N / compré X en N pesos / compré X a N
    cobré N / me llegó el salario de N / me depositaron N
    ahorré N / transferí N a ahorros / metí N al ahorro

Currency: assumes MXN by default. Optional explicit "USD"/"euros"/"dólares"
overrides. Numbers can have "pesos" / "$" / "MXN" suffix.

Category guessing: simple keyword map (food/transport/housing/...).
Confidence: 0.85 default. Lower for ambiguous matches.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("lifeos.finance.ingestion")

# Big-purchase threshold (MXN). Expenses above this register as big_purchase
# instead of plain expense, which triggers the +7d reflection loop.
BIG_PURCHASE_THRESHOLD_MXN = 2000.0


@dataclass(frozen=True, slots=True)
class FinanceIntent:
    kind: str
    title: str
    amount: float
    currency: str = "MXN"
    category: str | None = None
    merchant: str | None = None
    body: str | None = None
    tags: list[str] = field(default_factory=list)
    confidence: float = 0.85


def _strip_accents(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", s)
        if not unicodedata.combining(c)
    )


# ─── Amount + currency helpers ─────────────────────────────────────────

# Captures: amount (with optional thousands separator) + optional currency.
# Examples accepted: "1500", "1,500.00", "1.5k", "$50", "50 pesos", "20 USD".
_NUMBER_RE = re.compile(r"(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?|\d+)")
_CURRENCY_HINTS = {
    "usd": "USD", "dólares": "USD", "dolares": "USD", "dolar": "USD",
    "eur": "EUR", "euros": "EUR", "euro": "EUR",
    "mxn": "MXN", "pesos": "MXN", "peso": "MXN", "varos": "MXN",
}


def _parse_amount(num_str: str) -> float | None:
    """Parse "1,500.00" or "1.500" (European). Heuristic: if there's both
    "." and ",", the rightmost is the decimal separator."""
    s = num_str.replace(" ", "")
    if "," in s and "." in s:
        if s.rfind(",") > s.rfind("."):
            s = s.replace(".", "").replace(",", ".")
        else:
            s = s.replace(",", "")
    elif "," in s:
        # If only comma, assume decimal if 1-2 digits after; otherwise thousands sep
        i = s.rfind(",")
        if len(s) - i - 1 in (1, 2):
            s = s.replace(".", "").replace(",", ".")
        else:
            s = s.replace(",", "")
    try:
        return float(s)
    except ValueError:
        return None


def _detect_currency(text: str) -> str:
    """Return the currency code mentioned in text. Defaults to MXN."""
    lower = text.lower()
    if "$" in text and not any(c in lower for c in ("usd", "dólares", "dolares")):
        # $ alone in Mexico = pesos
        return "MXN"
    for hint, code in _CURRENCY_HINTS.items():
        if hint in lower:
            return code
    return "MXN"


# ─── Category guessing ────────────────────────────────────────────────

_CATEGORY_KEYWORDS: list[tuple[str, list[str]]] = [
    ("food", ["restaurante", "comida", "café", "cafe", "bar", "soriana", "walmart",
              "chedraui", "oxxo", "súper", "super", "mercado", "vips",
              "starbucks", "domino", "pizza", "hamburguesa", "sushi", "tacos"]),
    ("transport", ["uber", "didi", "taxi", "gasolina", "gas", "metro", "camión",
                   "camion", "autobús", "autobus", "estacionamiento"]),
    ("housing", ["renta", "alquiler", "luz", "agua", "gas natural", "internet",
                 "telmex", "cfe", "predial"]),
    ("entertainment", ["cine", "netflix", "spotify", "disney", "amazon prime",
                       "paramount", "youtube premium", "hbo", "max", "concierto"]),
    ("electronics", ["celular", "laptop", "monitor", "audífonos", "audifonos",
                     "auriculares", "tableta", "tablet", "kindle", "consola",
                     "playstation", "xbox", "switch"]),
    ("health", ["farmacia", "doctor", "consulta", "medicina", "medicamento",
                "hospital", "dentista", "laboratorio", "ahorro guadalajara",
                "san pablo", "benavides"]),
    ("clothing", ["ropa", "zapatos", "camisa", "pantalón", "pantalon", "tenis",
                  "zara", "h&m", "uniqlo"]),
    ("subscriptions", ["suscripción", "suscripcion", "membresía", "membresia",
                       "github", "chatgpt", "claude", "midjourney"]),
]


def _guess_category(text: str) -> str | None:
    lower = _strip_accents(text).lower()
    for cat, keywords in _CATEGORY_KEYWORDS:
        for kw in keywords:
            if kw in lower:
                return cat
    return None


# ─── Verb patterns ─────────────────────────────────────────────────────

# Common number+currency block. The boundary uses a lookahead (no consume)
# so trailing words like "este mes" don't force backtracking, and we
# exclude "," from the boundary so the thousands separator in "1,500" is
# never confused with end-of-amount.
_NUM = r"\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?|\d+"
_UNIT = r"pesos|peso|mxn|usd|dólares|dolares|eur|euros"

# "gasté N (en X)" / "pagué N (en X)"
_OUTFLOW_RE = re.compile(
    rf"\b(?:me\s+)?(?:gast[éeè]|pagu[éeè])\s+"
    rf"\$?\s*(?P<amount>{_NUM})(?=\s|[.;]|$)\s*"
    rf"(?P<unit>{_UNIT})?\s*"
    rf"(?:(?:en|de|de\s+la|del|a|a\s+la)\s+(?P<what>[^.;]+?))?"
    rf"(?:[.;]|$)",
    re.IGNORECASE,
)

# "compré X por N" / "compré X a N pesos" / "compré X en N"
_PURCHASE_RE = re.compile(
    rf"\b(?:me\s+)?compr[éeè]\s+"
    rf"(?P<what>.+?)\s+"
    rf"(?:por|a|en)\s+"
    rf"\$?\s*(?P<amount>{_NUM})(?=\s|[.;]|$)\s*"
    rf"(?P<unit>{_UNIT})?",
    re.IGNORECASE,
)

# "cobré N" / "me llegó N" / "me depositaron N" / "recibí N"
_INCOME_RE = re.compile(
    rf"\b(?:cobr[éeè]|me\s+lleg(?:[óo]|aron)|me\s+depositaron|recib[íi])\s+"
    rf"(?:(?:el|un|la|una|mi)\s+)?"
    rf"(?P<what>.{{0,30}}?)?"
    rf"\s*\$?\s*(?P<amount>{_NUM})(?=\s|[.;]|$)\s*"
    rf"(?P<unit>{_UNIT})?",
    re.IGNORECASE,
)

# "ahorré N" / "transferí N a ahorros" / "metí N al ahorro"
_SAVINGS_RE = re.compile(
    rf"\b(?:ahorr[éeè]|(?:me\s+)?transfer[íi].*?(?:a|al)\s+ahorr[oa]s?|"
    rf"met[íi].*?(?:a|al)\s+ahorr[oa]s?)\s+"
    rf"\$?\s*(?P<amount>{_NUM})(?=\s|[.;]|$)\s*"
    rf"(?P<unit>{_UNIT})?",
    re.IGNORECASE,
)


def _try_outflow(text: str) -> FinanceIntent | None:
    """Generic outflow: gasté / pagué N (en X)."""
    m = _OUTFLOW_RE.search(text)
    if not m:
        return None
    amount = _parse_amount(m.group("amount"))
    if amount is None or amount <= 0:
        return None
    what = (m.group("what") or "").strip().rstrip(" ,.;:")
    currency = _CURRENCY_HINTS.get((m.group("unit") or "").lower(), "MXN")
    if "$" in text and currency == "MXN":
        currency = "MXN"  # $ alone = pesos in Mexico
    title = f"{what}" if what else f"gasto ${amount:.0f}"
    kind = "big_purchase" if amount >= BIG_PURCHASE_THRESHOLD_MXN and currency == "MXN" else "expense"
    return FinanceIntent(
        kind=kind, title=title, amount=amount, currency=currency,
        category=_guess_category(what or text),
    )


def _try_purchase(text: str) -> FinanceIntent | None:
    """compré X por N — same as outflow but title is the item."""
    m = _PURCHASE_RE.search(text)
    if not m:
        return None
    amount = _parse_amount(m.group("amount"))
    if amount is None or amount <= 0:
        return None
    what = m.group("what").strip().rstrip(" ,.;:")
    if len(what) > 80 or not what:
        return None
    currency = _CURRENCY_HINTS.get((m.group("unit") or "").lower(), "MXN")
    kind = "big_purchase" if amount >= BIG_PURCHASE_THRESHOLD_MXN and currency == "MXN" else "expense"
    return FinanceIntent(
        kind=kind, title=what, amount=amount, currency=currency,
        category=_guess_category(what),
    )


def _try_income(text: str) -> FinanceIntent | None:
    m = _INCOME_RE.search(text)
    if not m:
        return None
    amount = _parse_amount(m.group("amount"))
    if amount is None or amount <= 0:
        return None
    what = (m.group("what") or "").strip().rstrip(" ,.;:")
    title = what or "ingreso"
    currency = _CURRENCY_HINTS.get((m.group("unit") or "").lower(), "MXN")
    return FinanceIntent(
        kind="income", title=title, amount=amount, currency=currency,
    )


def _try_savings(text: str) -> FinanceIntent | None:
    m = _SAVINGS_RE.search(text)
    if not m:
        return None
    amount = _parse_amount(m.group("amount"))
    if amount is None or amount <= 0:
        return None
    currency = _CURRENCY_HINTS.get((m.group("unit") or "").lower(), "MXN")
    return FinanceIntent(
        kind="savings", title="ahorro", amount=amount, currency=currency,
    )


# Order matters: savings before income (both can match "me llegó / transferí")
_PARSERS = (_try_savings, _try_purchase, _try_outflow, _try_income)


def parse_finance(text: str) -> FinanceIntent | None:
    """Try to extract a finance entry from `text`. Returns None on no match."""
    if not text or not isinstance(text, str):
        return None
    for parser in _PARSERS:
        try:
            res = parser(text)
            if res is not None:
                return res
        except Exception as e:  # noqa: BLE001
            log.warning("finance parser %s crashed: %s", parser.__name__, e)
    return None
