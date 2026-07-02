"""Detect decision-query intents in chat text.

In v1 we only recognize purchase consults. Adding more question types
(travel consult, exercise plan, …) is a matter of new regex + intent
plus a corresponding composer in this package.

Public:
    parse_query(text) → QueryIntent | None

A QueryIntent is one of:
    PurchaseConsultIntent(item: str)
"""

from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class PurchaseConsultIntent:
    item: str


# Patterns:
#   "¿puedo comprar X?"
#   "puedo comprar X"
#   "¿debería comprar X?"  / "¿debo comprar X?"
#   "¿me conviene comprar X?"
#   "¿vale la pena comprar X?"
#   "¿tiene sentido comprar X?"
#   EN: "should I buy X?" / "can I afford X?" / "is it worth buying X?" /
#       "do I need to buy X?"
_PURCHASE_QUERY = re.compile(
    r"^\s*"
    r"(?:axi[,:\s]+)?"          # optional "axi, " prefix
    r"\s*¿?\s*"                 # ¿ may follow the axi prefix
    r"(?:"
    r"(?:"
    r"puedo|debo|deber[íi]a|me\s+conviene|vale\s+la\s+pena|"
    r"tiene\s+sentido|necesito"
    r")\s+compr(?:ar|arme)"
    r"|should\s+i\s+buy"
    r"|can\s+i\s+afford"
    r"|is\s+it\s+worth\s+buying"
    r"|do\s+i\s+need\s+to\s+buy"
    r")\s+"
    r"(.+?)"
    r"\s*\??\s*$",
    re.IGNORECASE | re.DOTALL,
)


def parse_query(text: str) -> PurchaseConsultIntent | None:
    """Return the decision-query intent for `text`, or None."""
    if not text or not isinstance(text, str):
        return None
    m = _PURCHASE_QUERY.match(text.strip())
    if not m:
        return None
    item = m.group(1).strip().rstrip(" ?!.,;:")
    if not item or len(item) > 200:
        return None
    return PurchaseConsultIntent(item=item)
