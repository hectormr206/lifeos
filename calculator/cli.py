"""Interactive REPL for the calculator.

The CLI is a thin presentation layer: it parses input and renders output,
delegating all arithmetic and history bookkeeping to :class:`Calculator`.
"""
from __future__ import annotations

from typing import TextIO

from .core import Calculator, OPERATORS

_HELP = (
    "Commands:\n"
    "  <a> <op> <b>   compute (op is one of + - * /), e.g. 3 + 4\n"
    "  history        show all past operations\n"
    "  clear          clear the history\n"
    "  help           show this help\n"
    "  quit / exit    leave the calculator"
)


def _render_history(calc: Calculator) -> str:
    if not calc.history:
        return "(history is empty)"
    return "\n".join(f"{i}. {entry}" for i, entry in enumerate(calc.history, start=1))


def handle(line: str, calc: Calculator) -> str | None:
    """Process one input line.

    Returns the text to display, or ``None`` to signal that the REPL should
    exit. Unknown or malformed input yields an error message rather than
    raising, so the loop stays alive.
    """
    line = line.strip()
    if not line:
        return ""

    command = line.lower()
    if command in {"quit", "exit"}:
        return None
    if command == "help":
        return _HELP
    if command == "history":
        return _render_history(calc)
    if command == "clear":
        calc.clear_history()
        return "History cleared."

    parts = line.split()
    if len(parts) != 3:
        return "Invalid input. Try '3 + 4' or type 'help'."

    a_raw, op, b_raw = parts
    if op not in OPERATORS:
        return f"Unknown operator '{op}'. Use one of + - * /."
    try:
        a, b = float(a_raw), float(b_raw)
    except ValueError:
        return f"'{a_raw}' and '{b_raw}' must both be numbers."

    try:
        result = OPERATORS[op](calc, a, b)
    except ZeroDivisionError as exc:
        return f"Error: {exc}"
    return str(calc.last)


def run(stdin: TextIO, stdout: TextIO) -> None:
    """Run the REPL until EOF or a quit command."""
    calc = Calculator()
    print("Calculator with history. Type 'help' for commands.", file=stdout)
    while True:
        print("> ", end="", file=stdout, flush=True)
        line = stdin.readline()
        if not line:  # EOF
            break
        output = handle(line, calc)
        if output is None:
            break
        if output:
            print(output, file=stdout)
    print("Bye.", file=stdout)


def main() -> None:
    import sys

    run(sys.stdin, sys.stdout)


if __name__ == "__main__":
    main()
