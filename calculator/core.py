"""Calculator engine with an in-memory operation history.

The engine is deliberately free of any I/O so it can be reused from a CLI,
a web layer, or tests. All arithmetic flows through a single ``_record``
path, which is the only place that appends to the history — one source of
truth for what counts as a recorded operation.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

Number = float


@dataclass(frozen=True)
class HistoryEntry:
    """A single recorded operation and its result."""

    operation: str
    operands: tuple[Number, ...]
    result: Number

    def __str__(self) -> str:
        symbol = _SYMBOLS.get(self.operation, self.operation)
        joined = f" {symbol} ".join(_fmt(n) for n in self.operands)
        return f"{joined} = {_fmt(self.result)}"


# Operator symbols used when rendering history entries.
_SYMBOLS: dict[str, str] = {
    "add": "+",
    "subtract": "-",
    "multiply": "*",
    "divide": "/",
}


def _fmt(value: Number) -> str:
    """Render a number without a trailing ``.0`` for whole values."""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


class Calculator:
    """Performs arithmetic and remembers every operation it carries out."""

    def __init__(self) -> None:
        self._history: list[HistoryEntry] = []

    # -- arithmetic ---------------------------------------------------------

    def add(self, a: Number, b: Number) -> Number:
        return self._record("add", (a, b), a + b)

    def subtract(self, a: Number, b: Number) -> Number:
        return self._record("subtract", (a, b), a - b)

    def multiply(self, a: Number, b: Number) -> Number:
        return self._record("multiply", (a, b), a * b)

    def divide(self, a: Number, b: Number) -> Number:
        if b == 0:
            raise ZeroDivisionError("cannot divide by zero")
        return self._record("divide", (a, b), a / b)

    # -- history ------------------------------------------------------------

    @property
    def history(self) -> list[HistoryEntry]:
        """A copy of the recorded operations, oldest first."""
        return list(self._history)

    @property
    def last(self) -> HistoryEntry | None:
        """The most recent operation, or ``None`` if nothing was computed."""
        return self._history[-1] if self._history else None

    def clear_history(self) -> None:
        self._history.clear()

    # -- internals ----------------------------------------------------------

    def _record(self, operation: str, operands: tuple[Number, ...], result: Number) -> Number:
        self._history.append(HistoryEntry(operation, operands, result))
        return result


# Maps user-facing operator tokens to the engine method that handles them.
OPERATORS: dict[str, Callable[[Calculator, Number, Number], Number]] = {
    "+": Calculator.add,
    "-": Calculator.subtract,
    "*": Calculator.multiply,
    "/": Calculator.divide,
}
