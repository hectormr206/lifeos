"""Money parsing helpers.

Amounts arrive as display strings from a CSV export, e.g. ``"$1,250.50"``:
a leading ``$``, an OPTIONAL thousands separator (comma) and an optional
decimal part. This module is the single source of truth for turning such a
string into a float — every consumer is meant to call :func:`parse_amount`.
"""


def parse_amount(raw):
    """Parse a money string like ``'$1,250.50'`` into a float.

    ``None`` parses to ``0.0``.
    """
    if raw is None:
        return 0.0
    text = str(raw).strip().replace("$", "")
    # BUG: the thousands separator is never removed, so any amount with a
    # comma (e.g. "1,250.50") raises ValueError here.
    return float(text)
