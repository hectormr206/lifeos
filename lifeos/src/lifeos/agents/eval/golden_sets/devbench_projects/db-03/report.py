"""Format parsed expenses as a plain-text report."""

from expense_parser import parse_lines


def format_report(text):
    """One line per expense (``amount  category``) plus a TOTAL line."""
    records = parse_lines(text)
    total = sum(r["amount"] for r in records)
    lines = [f"{r['amount']:.2f}  {r['category']}" for r in records]
    lines.append(f"TOTAL {total:.2f}")
    return "\n".join(lines)
