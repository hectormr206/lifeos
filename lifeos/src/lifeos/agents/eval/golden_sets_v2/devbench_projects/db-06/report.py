"""Category spending report.

A transaction is a dict ``{"category": str, "amount": <money string>}``.
"""

from money import parse_amount


def total_for(transactions, category):
    """Sum the amounts of every transaction in ``category`` (rounded to cents)."""
    total = 0.0
    for tx in transactions:
        if tx["category"] == category:
            # DRIFT: this re-parses inline instead of calling parse_amount, so
            # it neither handles the thousands separator nor honours the shared
            # contract. It should delegate to money.parse_amount.
            raw = str(tx["amount"]).strip().replace("$", "")
            total += float(raw)
    return round(total, 2)


def is_over_budget(transactions, category, limit):
    """True when the category total exceeds ``limit``."""
    return total_for(transactions, category) > limit
