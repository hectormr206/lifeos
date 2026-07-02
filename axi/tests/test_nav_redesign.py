"""Navigation redesign tests — bottom tab bar (mobile) + sidebar (desktop).

Template-level assertions over rendered HTML via TestClient; no daemon or
brain involved. Kept to two page fetches ("/" and "/chat") so it stays light.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

# Every route that was reachable from the old hamburger drawer. The redesign
# must keep all of them reachable from the new nav (tab bar, sheets, sidebar).
OLD_DRAWER_ROUTES = [
    "/", "/chat", "/conversations",
    # LifeOS · tu vida
    "/health", "/finance", "/relationships", "/exercise",
    "/spirituality", "/learning", "/calendar",
    # Proactivo
    "/reminders", "/briefings", "/insights", "/posture",
    # Axi · herramientas
    # (/graph retired → 301 redirect to /brain3d, the knowledge-graph browser)
    "/translate", "/meetings", "/memory", "/brain3d",
    "/models", "/desarrollo", "/calculator",
    # Sistema
    "/setup", "/events", "/config",
]


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


def test_bottom_tabbar_present_with_five_targets(home_html):
    assert 'id="tabbar"' in home_html
    # Direct link tabs: Hoy, Chat, Avisos
    assert 'href="/"' in home_html
    assert 'href="/chat"' in home_html
    assert 'href="/reminders"' in home_html
    # Sheet tabs: Vida and Más open bottom sheets, not pages
    assert "sheet === 'vida' ? null : 'vida'" in home_html
    assert "sheet === 'mas' ? null : 'mas'" in home_html
    assert 'id="sheet-vida"' in home_html
    assert 'id="sheet-mas"' in home_html
    # Spanish tab labels
    for label in ("Hoy", "Chat", "Vida", "Avisos", "Más"):
        assert label in home_html


def test_desktop_sidebar_present_with_sections(home_html):
    assert 'id="sidebar"' in home_html
    for section in ("Tu vida", "Axi", "Sistema"):
        assert section in home_html


def test_hamburger_and_drawer_removed(home_html):
    assert "navOpen" not in home_html
    assert 'aria-label="Abrir menú"' not in home_html
    # Old drawer group headings are gone
    assert "LifeOS · tu vida" not in home_html
    assert "Axi · herramientas" not in home_html
    assert "Proactivo" not in home_html


def test_all_old_drawer_routes_still_reachable(home_html):
    missing = [
        route for route in OLD_DRAWER_ROUTES
        if f'href="{route}"' not in home_html
    ]
    assert not missing, f"routes orphaned by the nav redesign: {missing}"


def test_active_tab_highlight_on_home(home_html):
    # "/" is the current path → the Hoy tab carries the active class.
    assert 'href="/" class="tab active"' in home_html


def test_chat_page_hides_tabbar_but_keeps_sidebar(chat_html):
    # /chat is immersive: its own input bar owns the bottom edge.
    assert 'id="tabbar"' not in chat_html
    assert 'id="sheet-vida"' not in chat_html
    assert 'id="sheet-mas"' not in chat_html
    # Desktop sidebar still renders (chat only drops the mobile tab bar).
    assert 'id="sidebar"' in chat_html
    # Header brand remains as the way back home on mobile.
    assert "LifeOS</a>" in chat_html


def test_badge_wired_to_badge_count_api(home_html):
    assert 'x-data="navBadge()"' in home_html
    assert "/api/badge/count" in home_html
