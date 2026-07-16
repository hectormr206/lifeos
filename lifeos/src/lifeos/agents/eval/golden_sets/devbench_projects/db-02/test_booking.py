from booking import available_slots, overlaps
from slots import slot_starts


def test_slots_include_one_ending_exactly_at_close():
    # 9:00-10:00, 30-minute slots: 9:00 and 9:30 (the 9:30 slot ends AT close).
    assert slot_starts(9, 10, 30) == [540, 570]


def test_slot_exactly_filling_the_window():
    # 9:00-10:00 with 60-minute slots: exactly one slot.
    assert slot_starts(9, 10, 60) == [540]


def test_partial_slot_is_dropped():
    # 9:00-10:30 with 60-minute slots: only 9:00 fits (10:00 would overrun).
    assert slot_starts(9, 10.5, 60) == [540]


def test_overlaps_touching_is_not_overlap():
    assert overlaps(0, 10, 10, 20) is False
    assert overlaps(0, 10, 5, 15) is True
    assert overlaps(5, 15, 0, 10) is True


def test_touching_booking_does_not_block_slot():
    # Booking 8:00-9:00 must NOT block the 9:00-10:00 slot.
    assert available_slots(9, 11, 60, [(480, 540)]) == [540, 600]


def test_overlapping_booking_blocks_only_its_slot():
    # Booking 9:10-9:30 blocks the 9:00 slot but not the 10:00 one.
    assert available_slots(9, 11, 60, [(550, 570)]) == [600]
