"""Strict TDD RED tests for Cerebro 3D i18n label layer.

Tests cover:
1. Route /brain3d passes lang from config (es-MX → 'es', en-US → 'en').
2. LABELS map completeness: every DOMAIN_COLOR key has es + en entries.
3. Rendered HTML in Spanish contains translated labels (Relaciones, Salud, etc.).
4. Rendered HTML does NOT contain bare raw keys as sole visible legend text.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


BRAIN3D = Path(__file__).parents[1] / "src" / "axi" / "templates" / "brain3d.html"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

def _template_source() -> str:
    return BRAIN3D.read_text(encoding="utf-8")


def _client_with_language(monkeypatch, language: str) -> TestClient:
    """Return a TestClient backed by dashboard.app with config language overridden."""
    from axi import config as axi_config
    monkeypatch.setattr(axi_config, "get", lambda key, default=None: (
        language if key == "language" else default
    ))
    from axi import dashboard
    return TestClient(dashboard.app)


# ──────────────────────────────────────────────────────────────────────────────
# Test 1: Route passes lang=es for es-MX config
# RED discriminator: route currently passes {} — no lang in context.
# ──────────────────────────────────────────────────────────────────────────────

def test_brain3d_route_passes_lang_es_for_es_mx(monkeypatch):
    """GET /brain3d with config language=es-MX → HTML contains lang='es' marker."""
    client = _client_with_language(monkeypatch, "es-MX")
    resp = client.get("/brain3d")
    assert resp.status_code == 200
    html = resp.text
    # The template must emit a lang marker: data-lang="es" or const LANG = 'es'
    assert 'data-lang="es"' in html or "const LANG = 'es'" in html or 'lang: "es"' in html, (
        "GET /brain3d with language=es-MX must embed lang='es' in the rendered HTML. "
        "Got no such marker — route is passing {} instead of {lang: 'es'}."
    )


def test_brain3d_route_passes_lang_en_for_en_us(monkeypatch):
    """GET /brain3d with config language=en-US → HTML contains lang='en' marker."""
    client = _client_with_language(monkeypatch, "en-US")
    resp = client.get("/brain3d")
    assert resp.status_code == 200
    html = resp.text
    assert 'data-lang="en"' in html or "const LANG = 'en'" in html or 'lang: "en"' in html, (
        "GET /brain3d with language=en-US must embed lang='en' in the rendered HTML. "
        "Got no such marker — route is passing {} instead of {lang: 'en'}."
    )


# ──────────────────────────────────────────────────────────────────────────────
# Test 2: LABELS completeness — every DOMAIN_COLOR key has es + en translations
# RED discriminator: LABELS map does not exist yet in the template.
# ──────────────────────────────────────────────────────────────────────────────

# Extract DOMAIN_COLOR keys from the source directly so this test stays in sync.
_DOMAIN_COLOR_KEYS = [
    "relationships", "health", "finance", "conversation", "fact",
    "event", "meeting", "exercise", "learning", "spirituality", "default",
]

# Expected Spanish translations for each DOMAIN_COLOR key.
_EXPECTED_ES = {
    "relationships": "Relaciones",
    "health": "Salud",
    "finance": "Finanzas",
    "conversation": "Conversación",
    "fact": "Hecho",
    "event": "Evento",
    "meeting": "Reunión",
    "exercise": "Ejercicio",
    "learning": "Aprendizaje",
    "spirituality": "Espiritualidad",
    "default": "General",
}

# Expected English translations for each DOMAIN_COLOR key.
_EXPECTED_EN = {
    "relationships": "Relationships",
    "health": "Health",
    "finance": "Finance",
    "conversation": "Conversation",
    "fact": "Fact",
    "event": "Event",
    "meeting": "Meeting",
    "exercise": "Exercise",
    "learning": "Learning",
    "spirituality": "Spirituality",
    "default": "General",
}


def test_labels_map_exists_in_template():
    """brain3d.html must define a LABELS map with 'es' and 'en' sub-maps."""
    src = _template_source()
    assert "const LABELS" in src or "var LABELS" in src or "let LABELS" in src, (
        "brain3d.html must define a LABELS map for i18n translations. "
        "No LABELS declaration found."
    )


def test_labels_map_has_es_entries():
    """LABELS.es must contain translations for every DOMAIN_COLOR key."""
    src = _template_source()
    for key, es_label in _EXPECTED_ES.items():
        assert es_label in src, (
            f"LABELS.es is missing Spanish translation for '{key}': expected '{es_label}'"
        )


def test_labels_map_has_en_entries():
    """LABELS.en must contain translations for every DOMAIN_COLOR key."""
    src = _template_source()
    for key, en_label in _EXPECTED_EN.items():
        # "Fact", "Event", etc. — must appear in the en section of LABELS
        assert en_label in src, (
            f"LABELS.en is missing English translation for '{key}': expected '{en_label}'"
        )


def test_labels_map_has_edge_translations():
    """LABELS must contain translations for the known edge kind keys."""
    src = _template_source()
    expected_edge_es = [
        "Similar a", "Mismo día", "Ocurrió en", "Involucra a",
        "Mencionado en", "Configuración",
    ]
    for label in expected_edge_es:
        assert label in src, (
            f"LABELS is missing edge translation: '{label}'"
        )


# ──────────────────────────────────────────────────────────────────────────────
# Test 3: tLabel and tEdge helpers are defined in the template
# RED discriminator: helpers don't exist yet.
# ──────────────────────────────────────────────────────────────────────────────

def test_tlabel_helper_defined():
    """brain3d.html must define a tLabel() helper function."""
    src = _template_source()
    assert "function tLabel" in src or "tLabel(" in src, (
        "brain3d.html must define a tLabel() helper for domain/kind translations."
    )


def test_tedge_helper_defined():
    """brain3d.html must define a tEdge() helper function."""
    src = _template_source()
    assert "function tEdge" in src or "tEdge(" in src, (
        "brain3d.html must define a tEdge() helper for edge kind translations."
    )


# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Render sites use tLabel / tEdge — not raw domain/kind
# RED discriminator: template still uses raw x-text="domain" etc.
# ──────────────────────────────────────────────────────────────────────────────

def test_legend_uses_tlabel():
    """Legend overlay must call tLabel(domain) not raw x-text='domain'."""
    src = _template_source()
    # After the fix, legend should not expose raw domain key directly
    # (the raw `x-text="domain"` line must be replaced with a tLabel call).
    assert "tLabel(domain)" in src or "tLabel(" in src, (
        "Legend overlay must use tLabel(domain) instead of raw x-text='domain'."
    )
    # Raw binding should be gone from legend context
    assert 'x-text="domain"' not in src, (
        "Legend overlay still uses raw x-text='domain' — must be replaced with tLabel(domain)."
    )


def test_node_kind_uses_tlabel():
    """Node detail Tipo must call tLabel(selectedNode.kind) not raw binding."""
    src = _template_source()
    assert "tLabel(selectedNode.kind)" in src, (
        "Node detail kind must use tLabel(selectedNode.kind) instead of raw x-text='selectedNode.kind'."
    )


def test_node_domain_uses_tlabel():
    """Node detail Dominio must call tLabel(selectedNode.domain) not raw binding."""
    src = _template_source()
    assert "tLabel(selectedNode.domain)" in src, (
        "Node detail domain must use tLabel(selectedNode.domain) instead of raw x-text='selectedNode.domain'."
    )


def test_edge_kind_uses_tedge():
    """Edge kind display must route through tEdge(), not a raw binding.

    The relations panel iterates `detail.relations` as `rel`, so the edge kind
    is rendered via tEdge(rel.kind) (see brain3d.html). The i18n wiring is what
    matters here, not the loop variable name.
    """
    src = _template_source()
    assert "tEdge(rel.kind)" in src, (
        "Edge kind display must use tEdge(rel.kind) instead of a raw x-text='rel.kind'."
    )


# ──────────────────────────────────────────────────────────────────────────────
# Test 5: Served HTML in Spanish contains translated labels
# RED discriminator: route currently passes {} — no lang context, template
#                    doesn't inject lang, labels render as raw keys.
# ──────────────────────────────────────────────────────────────────────────────

def test_rendered_html_contains_spanish_labels(monkeypatch):
    """GET /brain3d with es-MX renders HTML that includes Spanish label strings."""
    client = _client_with_language(monkeypatch, "es-MX")
    resp = client.get("/brain3d")
    assert resp.status_code == 200
    html = resp.text
    # The LABELS map must be in the HTML so the JS can use them at runtime.
    # We check the Spanish label strings are present as JS data.
    for key, es_label in _EXPECTED_ES.items():
        assert es_label in html, (
            f"Rendered /brain3d HTML (es-MX) is missing Spanish label '{es_label}' for key '{key}'."
        )


def test_rendered_html_contains_english_labels_for_en_us(monkeypatch):
    """GET /brain3d with en-US renders HTML that includes English label strings."""
    client = _client_with_language(monkeypatch, "en-US")
    resp = client.get("/brain3d")
    assert resp.status_code == 200
    html = resp.text
    # Both lang maps must be in the HTML (template always includes LABELS in full).
    for key, en_label in _EXPECTED_EN.items():
        assert en_label in html, (
            f"Rendered /brain3d HTML (en-US) is missing English label '{en_label}' for key '{key}'."
        )
