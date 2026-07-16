import pytest

from stats import mean, median, moving_average


def test_mean_basic():
    assert mean([2, 4, 6]) == 4.0


def test_median_even_count():
    assert median([1, 2, 3, 4]) == 2.5


def test_moving_average_basic():
    assert moving_average([1, 2, 3, 4, 5], 3) == [2.0, 3.0, 4.0]


def test_moving_average_window_one_is_identity():
    assert moving_average([3, 7, 9], 1) == [3.0, 7.0, 9.0]


def test_moving_average_window_equals_length():
    assert moving_average([2, 4, 6, 8], 4) == [5.0]


def test_moving_average_invalid_window():
    with pytest.raises(ValueError):
        moving_average([1, 2, 3], 0)
    with pytest.raises(ValueError):
        moving_average([1, 2, 3], 4)
