"""Parse plain-text expense lines like ``150 comida tacos del martes``."""


def parse_line(line):
    """One line -> record dict.

    ``'150 comida tacos'`` -> ``{"amount": 150.0, "category": "comida",
    "note": "tacos"}``. Raises ValueError on lines without amount+category.
    """
    parts = line.strip().split()
    if len(parts) < 2:
        raise ValueError(f"invalid expense line: {line!r}")
    return {
        "amount": float(parts[0]),
        "category": parts[1],
        "note": " ".join(parts[2:]),
    }


def parse_lines(text):
    """Parse every non-blank line of ``text``."""
    return [parse_line(line) for line in text.splitlines() if line.strip()]
