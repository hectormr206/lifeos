"""Appointment slot generation (times are minutes since midnight)."""


def slot_starts(open_hour, close_hour, duration_min):
    """Start times of every slot of ``duration_min`` fitting between
    ``open_hour`` and ``close_hour`` (a slot may END exactly at closing)."""
    starts = []
    t = open_hour * 60
    end = close_hour * 60
    while t + duration_min < end:
        starts.append(t)
        t += duration_min
    return starts
