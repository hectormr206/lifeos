"""FIX 2 RED/GREEN: XSS safety in brain3d.html nodeLabel.

The nodeLabel callback previously injected n.label directly as raw HTML, enabling
stored XSS. This test asserts that:
  1. An escHtml() helper function is defined in the template.
  2. nodeLabel passes n.label through escHtml() before HTML interpolation.
"""
from __future__ import annotations

from pathlib import Path


BRAIN3D = Path(__file__).parents[1] / "src" / "axi" / "templates" / "brain3d.html"


def _source() -> str:
    return BRAIN3D.read_text(encoding="utf-8")


def test_brain3d_has_esc_html_function():
    """FIX 2 RED: brain3d.html must define an escHtml() helper."""
    src = _source()
    assert "function escHtml" in src, (
        "brain3d.html is missing escHtml() HTML-escape helper — XSS risk in nodeLabel"
    )


def test_brain3d_esc_html_escapes_special_chars():
    """FIX 2 RED: escHtml must at minimum handle & < > \" ' characters."""
    src = _source()
    # The helper must replace the five dangerous HTML characters.
    for char in ("&amp;", "&lt;", "&gt;", "&quot;", "&#39;"):
        assert char in src, (
            f"escHtml() in brain3d.html does not handle '{char}' — incomplete XSS protection"
        )


def test_brain3d_node_label_uses_esc_html():
    """FIX 2 RED: nodeLabel must pass n.label through escHtml(), not inject it raw."""
    src = _source()
    # After the fix, nodeLabel should use escHtml(n.label), not the raw ${n.label}.
    assert "escHtml(n.label)" in src, (
        "nodeLabel in brain3d.html does not call escHtml(n.label) — stored XSS vulnerability"
    )
    # Ensure the raw interpolation of n.label is gone from the nodeLabel call.
    # We look for the pattern that embeds raw n.label inside the template literal.
    # A safe version will only have escHtml(n.label), not a bare ${n.label}.
    import re
    node_label_block = re.search(r"\.nodeLabel\(.*?\)", src, re.DOTALL)
    if node_label_block:
        block = node_label_block.group(0)
        assert "${n.label}" not in block, (
            "nodeLabel still contains raw ${n.label} interpolation — XSS not fixed"
        )
