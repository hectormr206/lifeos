import money
import report


def test_parse_amount_handles_thousands_separator():
    assert money.parse_amount("$1,250.50") == 1250.5
    assert money.parse_amount("$99") == 99.0
    assert money.parse_amount(None) == 0.0


TX = [
    {"category": "comida", "amount": "$1,250.50"},
    {"category": "comida", "amount": "$49.50"},
    {"category": "transporte", "amount": "$300"},
]


def test_total_for_sums_a_category():
    assert report.total_for(TX, "comida") == 1300.0
    assert report.total_for(TX, "transporte") == 300.0


def test_is_over_budget():
    assert report.is_over_budget(TX, "comida", 1000) is True
    assert report.is_over_budget(TX, "comida", 2000) is False


def test_report_uses_the_shared_parser(monkeypatch):
    """Dedupe contract: total_for must delegate to money.parse_amount."""
    calls = {"n": 0}
    original = report.parse_amount

    def counting(raw):
        calls["n"] += 1
        return original(raw)

    monkeypatch.setattr(report, "parse_amount", counting)
    report.total_for(TX, "comida")
    assert calls["n"] >= 2  # both 'comida' rows parsed via the shared helper
