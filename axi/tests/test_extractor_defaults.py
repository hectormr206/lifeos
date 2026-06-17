"""WU-2: TDD assertions for prod/eval determinism.

Asserts that extract() defaults to temperature=0.0 and seed=0 so that the prod
call path (dashboard.py calls extract(text) with no kwargs) is deterministic and
matches the eval harness.
"""
from __future__ import annotations

import inspect

from lifeos.agents.extractor import extract


def test_extract_default_temperature_is_zero():
    """extract() must default to temperature=0.0 (not 0.1)."""
    sig = inspect.signature(extract)
    default = sig.parameters["temperature"].default
    assert default == 0.0, (
        f"extract() temperature default is {default!r}; expected 0.0. "
        "Prod calls extract(text) with no kwargs, so this must be 0.0 "
        "to match the eval harness."
    )


def test_extract_default_seed_is_zero():
    """extract() must default to seed=0 (not None)."""
    sig = inspect.signature(extract)
    default = sig.parameters["seed"].default
    assert default == 0, (
        f"extract() seed default is {default!r}; expected 0. "
        "A seed=None default means prod is non-deterministic."
    )


def test_extract_has_no_mode_param():
    """extract() must NOT have a mode parameter — A/B research code was stripped."""
    sig = inspect.signature(extract)
    assert "mode" not in sig.parameters, (
        "extract() still has a 'mode' parameter. "
        "Approach A/B was stripped; extract() should be monolith-only."
    )
