"""Tests for lifeos.web DI module — configure() and SEARXNG_URL env seam.

TDD Phase 4.1 RED: asserts the DI/configure surface of the web __init__.py.
"""
from __future__ import annotations

import importlib

import pytest

from lifeos.web.port import PageText


def _reload_web():
    """Reload lifeos.web to pick up env changes made in tests."""
    import lifeos.web as mod
    importlib.reload(mod)
    return mod


@pytest.fixture(autouse=True)
def _reset_web_globals():
    """Reset lifeos.web module globals before and after every test.

    Prevents state leakage between tests that call configure() or
    those that rely on the default (unconfigured) module state.
    """
    import lifeos.web as web_mod
    # Reset to pristine state before the test
    web_mod._search_fn = None
    web_mod._read_fn = None
    web_mod._enabled_fn = None
    yield
    # Reset again after the test so the next test starts clean
    web_mod._search_fn = None
    web_mod._read_fn = None
    web_mod._enabled_fn = None


def test_configure_sets_injected_fns():
    """After configure(), _search_fn and _read_fn are the injected callables."""
    import lifeos.web as web_mod

    def fake_search(query: str) -> list:  # noqa: ARG001
        return []

    def fake_read(url: str) -> PageText:  # noqa: ARG001
        return PageText(url=url, text="", ok=False)

    web_mod.configure(search_fn=fake_search, read_fn=fake_read)

    assert web_mod._search_fn is fake_search
    assert web_mod._read_fn is fake_read


def test_configure_sets_enabled_fn():
    """enabled_fn is stored and callable after configure()."""
    import lifeos.web as web_mod

    flag = [True]

    def fake_enabled() -> bool:
        return flag[0]

    def fake_search(query: str) -> list:  # noqa: ARG001
        return []

    def fake_read(url: str) -> PageText:  # noqa: ARG001
        return PageText(url=url, text="", ok=False)

    web_mod.configure(
        search_fn=fake_search,
        read_fn=fake_read,
        enabled_fn=fake_enabled,
    )

    assert web_mod._enabled_fn is fake_enabled
    assert web_mod.is_enabled() is True
    flag[0] = False
    assert web_mod.is_enabled() is False


def test_searxng_url_env_default(monkeypatch):
    """SEARXNG_URL defaults to http://127.0.0.1:8888 when env var is absent."""
    monkeypatch.delenv("SEARXNG_URL", raising=False)
    mod = _reload_web()
    assert mod.SEARXNG_URL == "http://127.0.0.1:8888"


def test_searxng_url_env_override(monkeypatch):
    """SEARXNG_URL is read from the environment when set."""
    monkeypatch.setenv("SEARXNG_URL", "http://192.168.1.10:9999")
    mod = _reload_web()
    assert mod.SEARXNG_URL == "http://192.168.1.10:9999"
