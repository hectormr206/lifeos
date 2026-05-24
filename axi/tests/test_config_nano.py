"""Tests for the nano_endpoint config kill-switch (dashboard.py / lifeos.agents.runtime).

We test _apply_nano_endpoint in isolation — no need to spin up the full
FastAPI lifespan — because that helper is the entire propagation mechanism.
"""
from __future__ import annotations

import os
import sys
import types

import pytest


def test_apply_nano_endpoint_sets_env_and_runtime(monkeypatch):
    """_apply_nano_endpoint should update both os.environ and the runtime module attr."""
    # Inject a fake lifeos.agents.runtime into sys.modules so we don't need
    # the real package.
    fake_runtime = types.ModuleType("lifeos.agents.runtime")
    fake_runtime.NANO_ENDPOINT = "http://127.0.0.1:8090"

    # Ensure the parent packages exist in sys.modules too.
    fake_agents = types.ModuleType("lifeos.agents")
    fake_agents.runtime = fake_runtime
    monkeypatch.setitem(sys.modules, "lifeos.agents", fake_agents)
    monkeypatch.setitem(sys.modules, "lifeos.agents.runtime", fake_runtime)

    from axi.dashboard import _apply_nano_endpoint

    _apply_nano_endpoint("http://127.0.0.1:9999")

    assert os.environ.get("LIFEOS_NANO_ENDPOINT") == "http://127.0.0.1:9999"
    assert fake_runtime.NANO_ENDPOINT == "http://127.0.0.1:9999"


def test_apply_nano_endpoint_empty_string_is_noop(monkeypatch):
    """Passing an empty string must not overwrite the current env value."""
    prev = os.environ.get("LIFEOS_NANO_ENDPOINT", "sentinel")
    os.environ["LIFEOS_NANO_ENDPOINT"] = "http://original:8090"

    from axi.dashboard import _apply_nano_endpoint

    _apply_nano_endpoint("")

    assert os.environ.get("LIFEOS_NANO_ENDPOINT") == "http://original:8090"
    # Restore
    if prev == "sentinel":
        os.environ.pop("LIFEOS_NANO_ENDPOINT", None)
    else:
        os.environ["LIFEOS_NANO_ENDPOINT"] = prev


def test_apply_nano_endpoint_survives_missing_runtime(monkeypatch):
    """If lifeos.agents.runtime cannot be imported, _apply_nano_endpoint must
    still set the env var and not raise."""
    # Force the import to fail.
    monkeypatch.setitem(sys.modules, "lifeos.agents.runtime", None)

    from axi.dashboard import _apply_nano_endpoint

    _apply_nano_endpoint("http://127.0.0.1:7777")

    assert os.environ.get("LIFEOS_NANO_ENDPOINT") == "http://127.0.0.1:7777"
