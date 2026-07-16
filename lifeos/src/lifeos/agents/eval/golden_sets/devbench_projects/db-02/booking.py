"""Free-slot lookup against existing bookings."""

from slots import slot_starts


def overlaps(a_start, a_end, b_start, b_end):
    """Do the half-open intervals [a_start, a_end) and [b_start, b_end)
    overlap? Intervals that merely TOUCH (one ends where the other starts)
    do not overlap."""
    return a_start <= b_end and b_start <= a_end


def available_slots(open_hour, close_hour, duration_min, booked):
    """Start times of the free slots. ``booked`` is a list of
    ``(start, end)`` pairs in minutes since midnight."""
    free = []
    for start in slot_starts(open_hour, close_hour, duration_min):
        end = start + duration_min
        if all(not overlaps(start, end, b0, b1) for (b0, b1) in booked):
            free.append(start)
    return free
