import io

import pytest

from calculator.cli import handle, run
from calculator.core import Calculator


# -- arithmetic --------------------------------------------------------------


def test_basic_operations():
    calc = Calculator()
    assert calc.add(2, 3) == 5
    assert calc.subtract(10, 4) == 6
    assert calc.multiply(6, 7) == 42
    assert calc.divide(9, 3) == 3


def test_divide_by_zero_raises_and_is_not_recorded():
    calc = Calculator()
    with pytest.raises(ZeroDivisionError):
        calc.divide(1, 0)
    assert calc.history == []


# -- history -----------------------------------------------------------------


def test_history_records_every_operation_in_order():
    calc = Calculator()
    calc.add(1, 1)
    calc.multiply(2, 5)
    history = calc.history
    assert len(history) == 2
    assert history[0].operation == "add"
    assert history[1].result == 10


def test_last_returns_most_recent_entry():
    calc = Calculator()
    assert calc.last is None
    calc.add(1, 2)
    assert calc.last.result == 3


def test_history_is_a_copy():
    calc = Calculator()
    calc.add(1, 1)
    snapshot = calc.history
    snapshot.clear()
    assert len(calc.history) == 1


def test_clear_history():
    calc = Calculator()
    calc.add(1, 1)
    calc.clear_history()
    assert calc.history == []


def test_history_entry_str_formats_whole_numbers():
    calc = Calculator()
    calc.add(2, 3)
    assert str(calc.last) == "2 + 3 = 5"


# -- CLI handler -------------------------------------------------------------


def test_handle_computes_and_records():
    calc = Calculator()
    assert handle("3 + 4", calc) == "3 + 4 = 7"
    assert len(calc.history) == 1


def test_handle_history_and_clear():
    calc = Calculator()
    handle("2 * 5", calc)
    assert "2 * 5 = 10" in handle("history", calc)
    assert handle("clear", calc) == "History cleared."
    assert handle("history", calc) == "(history is empty)"


def test_handle_invalid_input_does_not_crash():
    calc = Calculator()
    assert "Invalid input" in handle("3 +", calc)
    assert "Unknown operator" in handle("3 ^ 4", calc)
    assert "must both be numbers" in handle("a + b", calc)
    assert calc.history == []


def test_handle_divide_by_zero_message():
    calc = Calculator()
    assert "Error" in handle("1 / 0", calc)


def test_handle_quit_returns_none():
    assert handle("quit", Calculator()) is None
    assert handle("exit", Calculator()) is None


# -- REPL --------------------------------------------------------------------


def test_run_repl_end_to_end():
    stdin = io.StringIO("3 + 4\nhistory\nquit\n")
    stdout = io.StringIO()
    run(stdin, stdout)
    out = stdout.getvalue()
    assert "3 + 4 = 7" in out
    assert "Bye." in out
