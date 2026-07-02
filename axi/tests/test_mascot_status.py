"""Living mascot status indicator tests — awake / thinking / asleep.

Template-level assertions over rendered HTML via TestClient; no daemon or
brain involved. Kept to two page fetches ("/" and "/chat") so it stays light.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    return TestClient(dashboard.app)


@pytest.fixture
def home_html(client):
    r = client.get("/")
    assert r.status_code == 200
    return r.text


@pytest.fixture
def chat_html(client):
    r = client.get("/chat")
    assert r.status_code == 200
    return r.text


def test_mascot_class_on_both_brand_instances(home_html):
    # Exactly two mascot instances: mobile header brand + desktop sidebar brand.
    assert home_html.count('class="axi-mascot"') == 2
    assert home_html.count('class="axi-mascot-wrap"') == 2


def test_state_css_rules_present(home_html):
    # asleep: grayscale + dimmed + "z z" affordance on the wrapper.
    assert 'html[data-axi-state="asleep"] .axi-mascot' in home_html
    assert "grayscale(0.9)" in home_html
    assert '.axi-mascot-wrap::after' in home_html
    assert "content: 'z z'" in home_html
    # thinking: bob animation, gated behind prefers-reduced-motion.
    assert 'html[data-axi-state="thinking"] .axi-mascot' in home_html
    assert "axiMascotBob" in home_html
    assert "prefers-reduced-motion: reduce" in home_html


def test_state_script_markers(home_html):
    # Single source of truth + the 400ms debounce + observer hooks.
    assert "dataset.axiState" in home_html
    assert "_axiMascotInFlightChanged" in home_html
    assert "400" in home_html
    assert "window.addEventListener('axi-reachability', _axiApplyMascotState)" in home_html
    # Spanish tooltips for the three states.
    assert "Axi está aquí" in home_html
    assert "Axi está pensando…" in home_html
    assert "Axi no responde (¿VPN? ¿servicio?)" in home_html


def test_chat_page_keeps_both_mascots(chat_html):
    # /chat overrides the tabbar block only — the mascot lives in the header
    # and sidebar (outside tabbar), so both instances must still render.
    assert chat_html.count('class="axi-mascot"') == 2
    assert 'html[data-axi-state="asleep"] .axi-mascot' in chat_html
