"""Tests for the cheap scheduling-intent gate `lifeos.parser.looks_schedulish`.

The gate is a regex-only signal detector used to decide whether the expensive
LLM schedule-parser fallback is worth invoking. It must NEVER call an LLM and
must return True on any plausible scheduling phrasing, False on plain chatter.
"""

from __future__ import annotations

import pytest


@pytest.mark.parametrize(
    "text",
    [
        # Recurrence word ("cada") + time marker ("mañana").
        "Quiero que cada mañana me resumas el correo",
        # Agentic enclitic trigger alone (content fetch intent).
        "tráeme las noticias",
        # Explicit reminder trigger.
        "recordame llamar al dentista mañana a las 9",
        # Recurrence word only.
        "todos los días poné al día mi bandeja",
        # Clock time only.
        "el reporte a las 8:30",
        # am/pm marker.
        "mándame el clima a las 7 am",
        # "hoy" time marker.
        "el informe hoy",
    ],
)
def test_looks_schedulish_true(text: str) -> None:
    from lifeos.parser import looks_schedulish

    assert looks_schedulish(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "hola cómo estás",
        "gracias",
        "",
        "   ",
        "me encanta este proyecto",
    ],
)
def test_looks_schedulish_false(text: str) -> None:
    from lifeos.parser import looks_schedulish

    assert looks_schedulish(text) is False


def test_looks_schedulish_handles_non_str() -> None:
    from lifeos.parser import looks_schedulish

    assert looks_schedulish(None) is False  # type: ignore[arg-type]
