"""Product price lookup. Pretend ``fetch_price`` hits a remote catalog
service: every call is EXPENSIVE and must be treated as such."""


def fetch_price(catalog, product_id):
    """Unit price of one product. Costly — call it as few times as possible."""
    for item in catalog:
        if item["id"] == product_id:
            return item["price"]
    raise KeyError(product_id)
