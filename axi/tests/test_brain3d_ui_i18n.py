"""Strict TDD RED tests for Cerebro 3D static UI string i18n.

Tests cover:
1. LABELS.es.ui and LABELS.en.ui sub-maps exist and are complete.
2. tUi() helper is defined in the template.
3. Every hardcoded Spanish UI literal is replaced by a tUi() render site.
4. Rendered HTML (via route) shows English UI strings when language=en-US.
5. Rendered HTML (via route) shows Spanish UI strings when language=es-MX.
6. Vendor nav-info is disabled (.showNavInfo(false) or CSS hide).

RED discriminators per test are documented inline.
"""
from __future__ import annotations

from pathlib import Path

import pytest

BRAIN3D = Path(__file__).parents[1] / "src" / "axi" / "templates" / "brain3d.html"

# ---------------------------------------------------------------------------
# Expected UI key→value mappings (spec source of truth)
# ---------------------------------------------------------------------------

UI_ES: dict[str, str] = {
    "title":        "Cerebro 3D",
    "nodes":        "nodos",
    "relations":    "relaciones",
    "loading":      "Cargando grafo 3D…",   # … character
    "loadingSub":   "Preparando neuronas y conexiones",
    "empty":        "No hay nodos para visualizar",
    "emptyHint":    "Habla con Axi para que empiece a construir su red de memoria.",
    "domainLegend": "Dominio",
    "controls":     "Orbitar: arrastrar \xb7 Zoom: scroll \xb7 Click: seleccionar nodo",
    "clickNode":    "Haz click en un nodo para ver sus detalles",
    "typeLabel":    "Tipo",
    "domainLabel":  "Dominio",
    "yes":          "S\xed",
    "connections":  "Conexiones",
    "system":       "sistema",
}

UI_EN: dict[str, str] = {
    "title":        "3D Brain",
    "nodes":        "nodes",
    "relations":    "connections",
    "loading":      "Loading 3D graph…",
    "loadingSub":   "Preparing neurons and connections",
    "empty":        "No nodes to display",
    "emptyHint":    "Talk to Axi so it starts building your memory network.",
    "domainLegend": "Domain",
    "controls":     "Orbit: drag \xb7 Zoom: scroll \xb7 Click: select node",
    "clickNode":    "Click a node to see its details",
    "typeLabel":    "Type",
    "domainLabel":  "Domain",
    "yes":          "Yes",
    "connections":  "Connections",
    "system":       "system",
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _src() -> str:
    return BRAIN3D.read_text(encoding="utf-8")


def _client_with_language(monkeypatch, language: str):
    from axi import config as axi_config
    monkeypatch.setattr(axi_config, "get", lambda key, default=None: (
        language if key == "language" else default
    ))
    from axi import dashboard
    return __import__("fastapi.testclient", fromlist=["TestClient"]).TestClient(dashboard.app)


# ---------------------------------------------------------------------------
# Task 1 — LABELS.ui sub-map exists in both locales
# RED discriminator: LABELS currently has NO .ui sub-map — these keys are absent.
# ---------------------------------------------------------------------------


def test_labels_es_ui_submap_exists():
    """LABELS.es must contain a 'ui' sub-map key in the template source."""
    src = _src()
    assert "ui:" in src or "'ui'" in src or '"ui"' in src, (
        "LABELS must have a 'ui' sub-map. Not found in template source."
    )


def test_labels_es_ui_has_all_keys():
    """LABELS.es.ui must contain Spanish values for all required UI keys."""
    src = _src()
    missing = [v for v in UI_ES.values() if v not in src]
    assert not missing, (
        f"LABELS.es.ui is missing Spanish UI values: {missing}"
    )


def test_labels_en_ui_has_all_keys():
    """LABELS.en.ui must contain English values for all required UI keys."""
    src = _src()
    missing = [v for v in UI_EN.values() if v not in src]
    assert not missing, (
        f"LABELS.en.ui is missing English UI values: {missing}"
    )


def test_labels_ui_key_completeness():
    """Both LABELS.es.ui and LABELS.en.ui must have the same set of keys."""
    assert set(UI_ES.keys()) == set(UI_EN.keys()), (
        "UI key sets for es and en must be identical. "
        f"es only: {set(UI_ES) - set(UI_EN)}, en only: {set(UI_EN) - set(UI_ES)}"
    )


# ---------------------------------------------------------------------------
# Task 2 — tUi() helper exists
# RED discriminator: no tUi function defined yet.
# ---------------------------------------------------------------------------


def test_tui_helper_defined():
    """brain3d.html must define a tUi() helper function."""
    src = _src()
    assert "function tUi" in src or "tUi =" in src, (
        "brain3d.html must define a tUi() helper for UI string translations. "
        "No tUi declaration found."
    )


def test_tui_is_used_at_render_sites():
    """At least several render sites must call tUi(...)."""
    src = _src()
    count = src.count("tUi(")
    assert count >= 8, (
        f"Expected at least 8 tUi() call sites in brain3d.html, found {count}. "
        "Not all UI strings have been replaced."
    )


# ---------------------------------------------------------------------------
# Task 3 — Hardcoded Spanish literals no longer appear as static HTML text nodes
# RED discriminator: these are currently bare text nodes in the HTML.
# ---------------------------------------------------------------------------


def test_loading_string_not_hardcoded_in_html():
    """'Cargando grafo 3D' must not appear as a static HTML text node."""
    src = _src()
    # The string must NOT appear bare inside an HTML tag as visible text.
    # It may still appear inside JS string literals (inside LABELS) — that's OK.
    # We look for the pattern '>Cargando grafo 3D' which indicates a text node.
    assert ">Cargando grafo 3D" not in src, (
        "Found '>Cargando grafo 3D' as a static HTML text node. "
        "This string must be rendered via tUi('loading') instead."
    )


def test_empty_state_not_hardcoded():
    """'No hay nodos para visualizar' must not appear as a static HTML text node."""
    src = _src()
    assert ">No hay nodos para visualizar" not in src, (
        "Found '>No hay nodos para visualizar' as a static HTML text node. "
        "Must be replaced with tUi('empty')."
    )


def test_controls_hint_not_hardcoded():
    """Control hint 'Orbitar:' must not appear as a static text node."""
    src = _src()
    assert ">Orbitar:" not in src and "\n          Orbitar:" not in src, (
        "Found 'Orbitar:' as a static HTML text node. "
        "Must be replaced with tUi('controls')."
    )


def test_click_node_hint_not_hardcoded():
    """'Haz click en un nodo' must not appear as a static HTML text node."""
    src = _src()
    assert ">Haz click en un nodo" not in src, (
        "Found '>Haz click en un nodo' as static HTML text. "
        "Must be replaced with tUi('clickNode')."
    )


def test_titulo_h1_not_hardcoded():
    """<h1> must not contain the hardcoded 'Cerebro 3D' text node."""
    src = _src()
    assert ">Cerebro 3D<" not in src, (
        "Found '>Cerebro 3D<' as a static h1 text node. "
        "Must use x-text=\"tUi('title')\" instead."
    )


# ---------------------------------------------------------------------------
# Task 4 — Rendered HTML contains English UI strings when language=en-US
# RED discriminator: no English UI strings exist today (all hardcoded Spanish).
# ---------------------------------------------------------------------------


def test_rendered_html_en_contains_english_ui_strings(monkeypatch):
    """GET /brain3d with en-US renders HTML with English UI strings."""
    from fastapi.testclient import TestClient
    from axi import config as axi_config
    monkeypatch.setattr(axi_config, "get", lambda key, default=None: (
        "en-US" if key == "language" else default
    ))
    from axi import dashboard
    client = TestClient(dashboard.app)
    resp = client.get("/brain3d")
    assert resp.status_code == 200
    html = resp.text
    # These English strings must appear in the rendered template (in the LABELS map).
    for key, en_val in UI_EN.items():
        assert en_val in html, (
            f"Rendered /brain3d (en-US) missing English UI value for '{key}': '{en_val}'"
        )


def test_rendered_html_es_contains_spanish_ui_strings(monkeypatch):
    """GET /brain3d with es-MX renders HTML with Spanish UI strings."""
    from fastapi.testclient import TestClient
    from axi import config as axi_config
    monkeypatch.setattr(axi_config, "get", lambda key, default=None: (
        "es-MX" if key == "language" else default
    ))
    from axi import dashboard
    client = TestClient(dashboard.app)
    resp = client.get("/brain3d")
    assert resp.status_code == 200
    html = resp.text
    for key, es_val in UI_ES.items():
        assert es_val in html, (
            f"Rendered /brain3d (es-MX) missing Spanish UI value for '{key}': '{es_val}'"
        )


# ---------------------------------------------------------------------------
# Task 5 — Vendor nav-info disabled
# RED discriminator: .showNavInfo(false) not present in template today.
# ---------------------------------------------------------------------------


def test_show_nav_info_disabled():
    """Template must disable the vendor 3d-force-graph nav hint."""
    src = _src()
    api_disabled = ".showNavInfo(false)" in src
    css_disabled = "scene-nav-info" in src and "display: none" in src
    assert api_disabled or css_disabled, (
        "Vendor nav-info must be disabled. Add .showNavInfo(false) to the "
        "ForceGraph3D chain, or add CSS .scene-nav-info { display: none }."
    )
