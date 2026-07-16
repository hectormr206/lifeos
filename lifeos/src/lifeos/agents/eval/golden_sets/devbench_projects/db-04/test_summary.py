import pytest

import pricing
from summary import order_total, orders_grand_total

CATALOG = [
    {"id": "cafe", "price": 100.0},
    {"id": "pan", "price": 20.0},
    {"id": "leche", "price": 30.0},
]


@pytest.fixture
def price_calls(monkeypatch):
    """Counts every pricing.fetch_price call (the costly operation)."""
    calls = {"n": 0}
    real = pricing.fetch_price

    def counting(catalog, product_id):
        calls["n"] += 1
        return real(catalog, product_id)

    monkeypatch.setattr(pricing, "fetch_price", counting)
    return calls


def test_order_total_simple():
    order = {"lines": [{"product_id": "cafe", "qty": 2},
                       {"product_id": "pan", "qty": 3}]}
    assert order_total(CATALOG, order) == 260.0


def test_order_total_applies_bulk_discount():
    order = {"lines": [{"product_id": "pan", "qty": 10}]}
    assert order_total(CATALOG, order) == 180.0  # 200 - 10%


def test_grand_total_simple():
    orders = [{"lines": [{"product_id": "cafe", "qty": 1}]},
              {"lines": [{"product_id": "leche", "qty": 2}]}]
    assert orders_grand_total(CATALOG, orders) == 160.0


def test_grand_total_matches_sum_of_order_totals():
    orders = [
        {"lines": [{"product_id": "pan", "qty": 10}]},   # discounted line
        {"lines": [{"product_id": "cafe", "qty": 1}]},
    ]
    expected = sum(order_total(CATALOG, o) for o in orders)
    assert orders_grand_total(CATALOG, orders) == expected == 280.0


def test_missing_product_raises():
    with pytest.raises(KeyError):
        order_total(CATALOG, {"lines": [{"product_id": "ghost", "qty": 1}]})


def test_grand_total_fetches_each_distinct_price_at_most_once(price_calls):
    # 6 lines but only 2 distinct products: the costly lookup must run once
    # per DISTINCT product (and must still be used — zero calls is cheating).
    orders = [
        {"lines": [{"product_id": "cafe", "qty": 1},
                   {"product_id": "pan", "qty": 2},
                   {"product_id": "cafe", "qty": 3}]},
        {"lines": [{"product_id": "pan", "qty": 1},
                   {"product_id": "cafe", "qty": 2},
                   {"product_id": "pan", "qty": 4}]},
    ]
    total = orders_grand_total(CATALOG, orders)
    assert total == 740.0
    assert 1 <= price_calls["n"] <= 2, (
        f"fetch_price ran {price_calls['n']} times for 2 distinct products")
