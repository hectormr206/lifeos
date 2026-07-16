"""Order totals over the costly pricing service.

Business rule: a line with ``qty >= 10`` gets a 10% bulk discount on that
line's subtotal.
"""

import pricing


def order_total(catalog, order):
    """Total of one order (bulk discount applied per line)."""
    total = 0.0
    for line in order["lines"]:
        price = pricing.fetch_price(catalog, line["product_id"])
        subtotal = price * line["qty"]
        if line["qty"] >= 10:
            subtotal *= 0.9
        total += subtotal
    return total


def orders_grand_total(catalog, orders):
    """Total across every order."""
    total = 0.0
    for order in orders:
        for line in order["lines"]:
            price = pricing.fetch_price(catalog, line["product_id"])
            total += price * line["qty"]
    return total
