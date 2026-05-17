"""Tests for the rule-based cleanup nanoagent."""
from __future__ import annotations

from axi.clean import clean


def test_vocab_substitutes_axi_lifeos_cachyos():
    out = clean("axi corre en cachyos como parte de lifeos")
    assert "Axi" in out
    assert "CachyOS" in out
    assert "LifeOS" in out


def test_shortcut_phrase_to_symbol():
    out = clean("usé control más c y luego control más v")
    assert "Ctrl+C" in out
    assert "Ctrl+V" in out


def test_cachyos_phonetic_mishearing():
    out = clean("instalé cacho ios en mi laptop")
    assert "CachyOS" in out


def test_trailing_period_added_if_missing():
    out = clean("hola mundo")
    assert out.endswith(".")


def test_sentence_capitalization():
    out = clean("hola. axi está vivo. todo bien")
    assert out.startswith("Hola.")
    assert "Axi está vivo." in out


def test_whitespace_normalization():
    out = clean("hola    mundo  ,  qué tal")
    assert "  " not in out
    assert " ," not in out


def test_empty_input_returns_empty():
    assert clean("") == ""


def test_does_not_lowercase_existing_capitalized():
    """Vocab subs preserve existing labels (no false replacement)."""
    out = clean("Axi corre bien")
    assert out.startswith("Axi")
