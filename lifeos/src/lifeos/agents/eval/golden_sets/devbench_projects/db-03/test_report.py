import pytest

from expense_parser import parse_line, parse_lines
from report import format_report


# ── existing behaviour: these four MUST stay green ───────────────────────────

def test_parse_line_amount_category_note():
    rec = parse_line("150 comida tacos del martes")
    assert rec["amount"] == 150.0
    assert rec["category"] == "comida"
    assert rec["note"] == "tacos del martes"


def test_parse_line_rejects_short_lines():
    with pytest.raises(ValueError):
        parse_line("150")


def test_parse_lines_skips_blank_lines():
    recs = parse_lines("100 comida\n\n  \n50 transporte\n")
    assert [r["amount"] for r in recs] == [100.0, 50.0]


def test_report_without_dates_keeps_exact_format():
    out = format_report("100 comida\n50.5 transporte")
    assert out == "100.00  comida\n50.50  transporte\nTOTAL 150.50"


# ── new feature: optional ISO date prefix ────────────────────────────────────

def test_parse_line_with_date_prefix():
    rec = parse_line("2026-07-01 150 comida tacos")
    assert rec["date"] == "2026-07-01"
    assert rec["amount"] == 150.0
    assert rec["category"] == "comida"
    assert rec["note"] == "tacos"


def test_parse_line_without_date_has_none_date():
    assert parse_line("150 comida")["date"] is None


def test_report_dated_lines_show_the_date():
    out = format_report("2026-07-01 100 comida")
    assert out == "2026-07-01  100.00  comida\nTOTAL 100.00"


def test_report_mixed_dated_and_dateless_lines():
    out = format_report("2026-07-01 100 comida\n50 transporte")
    assert out == ("2026-07-01  100.00  comida\n"
                   "50.00  transporte\n"
                   "TOTAL 150.00")
