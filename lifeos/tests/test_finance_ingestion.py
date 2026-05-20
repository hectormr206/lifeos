"""Tests for lifeos.finance.ingestion regex parsers."""

from __future__ import annotations


def test_returns_none_for_unrelated_text() -> None:
    from lifeos.finance.ingestion import parse_finance
    assert parse_finance("hola axi") is None
    assert parse_finance("me duele la cabeza") is None
    assert parse_finance("") is None


# Outflows

def test_gaste_simple() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("gasté 250 en gasolina")
    assert fi is not None
    assert fi.kind == "expense"
    assert fi.amount == 250
    assert fi.currency == "MXN"
    assert "gasolina" in fi.title.lower()
    assert fi.category == "transport"


def test_pague_with_pesos() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("pagué 1500 pesos de la luz")
    assert fi is not None
    assert fi.kind == "expense"
    assert fi.amount == 1500
    assert fi.category == "housing"


def test_compre_X_por_N() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("compré unos audífonos por 850")
    assert fi is not None
    assert fi.kind == "expense"
    assert fi.amount == 850
    assert "audífonos" in fi.title.lower() or "audifonos" in fi.title.lower()


def test_big_purchase_threshold_triggers_kind() -> None:
    """Amount >= 2000 MXN → kind='big_purchase' (triggers reflection loop)."""
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("compré una laptop por 18500")
    assert fi is not None
    assert fi.kind == "big_purchase"
    assert fi.amount == 18500
    assert fi.category == "electronics"


def test_below_threshold_is_plain_expense() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("compré un libro por 350")
    assert fi is not None
    assert fi.kind == "expense"


def test_amount_with_thousands_separator() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("pagué 1,500 pesos del internet")
    assert fi is not None
    assert fi.amount == 1500


def test_amount_with_decimal() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("gasté 87.50 en tacos")
    assert fi is not None
    assert fi.amount == 87.5


def test_currency_usd_detected() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("compré un libro por 12 dólares")
    assert fi is not None
    assert fi.currency == "USD"


def test_dollar_sign_alone_is_mxn() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("gasté $50 en café")
    assert fi is not None
    assert fi.currency == "MXN"


# Income

def test_cobre_salary() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("cobré el salario de 18000")
    assert fi is not None
    assert fi.kind == "income"
    assert fi.amount == 18000


def test_recibi_freelance() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("recibí pago freelance 5000 pesos")
    assert fi is not None
    assert fi.kind == "income"
    assert fi.amount == 5000


# Savings

def test_ahorre() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("ahorré 2000 este mes")
    assert fi is not None
    assert fi.kind == "savings"
    assert fi.amount == 2000


# Categorization

def test_category_food_starbucks() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("gasté 95 en Starbucks")
    assert fi is not None
    assert fi.category == "food"


def test_category_transport_uber() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("gasté 120 en Uber al aeropuerto")
    assert fi is not None
    assert fi.category == "transport"


def test_category_subscriptions() -> None:
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance("pagué 199 de Netflix")
    assert fi is not None
    assert fi.category == "entertainment"
