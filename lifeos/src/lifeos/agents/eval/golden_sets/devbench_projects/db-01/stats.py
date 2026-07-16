"""Small numeric helpers for LifeOS records."""


def mean(values):
    """Arithmetic mean. Raises ValueError on an empty list."""
    if not values:
        raise ValueError("mean() of empty list")
    return sum(values) / len(values)


def median(values):
    """Median (average of the middle two for even-sized lists)."""
    if not values:
        raise ValueError("median() of empty list")
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def moving_average(values, window):
    """Averages of each run of ``window`` consecutive values.

    Not implemented yet — see TASK.md for the exact contract.
    """
    raise NotImplementedError("moving_average is not implemented")
